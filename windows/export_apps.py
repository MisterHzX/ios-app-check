import asyncio
import csv
import plistlib
import threading
import tkinter as tk
from pathlib import Path
from tkinter import filedialog, messagebox, ttk

from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.installation_proxy import InstallationProxyService


def text_value(value):
    return value.strip() if isinstance(value, str) else ""


def app_row(app):
    metadata = app.get("iTunesMetadata")
    if isinstance(metadata, bytes):
        try:
            metadata = plistlib.loads(metadata)
        except (plistlib.InvalidFileException, ValueError, OverflowError):
            metadata = None
    if not isinstance(metadata, dict):
        metadata = {}
    download = metadata.get("com.apple.iTunesStore.downloadInfo")
    account = download.get("accountInfo") if isinstance(download, dict) else None
    apple_id = text_value(account.get("AppleID")) if isinstance(account, dict) else ""
    name = next(
        (name for value in (
            app.get("CFBundleDisplayName"),
            metadata.get("itemName"),
            app.get("CFBundleName"),
            app.get("CFBundleIdentifier"),
        ) if (name := text_value(value))),
        "",
    )
    return name, apple_id


async def scan():
    async with await create_using_usbmux(connection_type="USB") as lockdown:
        async with InstallationProxyService(lockdown) as service:
            apps = await service.browse(
                options={"ApplicationType": "User"},
                attributes=[
                    "CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName",
                    "ApplicationSINF", "iTunesMetadata",
                ],
            )
    return sorted((app_row(app) for app in apps), key=lambda row: row[0].casefold())


def save_report(path, rows):
    with open(path, "w", encoding="utf-8-sig", newline="") as report:
        writer = csv.writer(report, delimiter="\t")
        writer.writerow(("App 名称", "Apple ID"))
        writer.writerows(rows)


def main():
    root = tk.Tk()
    root.title("iPhone App 下载账号")
    root.resizable(False, False)
    panel = ttk.Frame(root, padding=20)
    panel.pack(fill="both", expand=True)
    ttk.Label(panel, text="用数据线连接并解锁 iPhone，在手机上点「信任」。").pack(anchor="w")
    status = tk.StringVar(value="等待查询")
    ttk.Label(panel, textvariable=status).pack(anchor="w", pady=(10, 10))

    def finish(rows, error):
        button.configure(state="normal")
        if error:
            status.set("查询失败")
            messagebox.showerror("查询失败", f"请确认数据线、信任状态和 Apple 设备驱动。\n\n{error}", parent=root)
            return
        if not rows:
            status.set("没有收到已安装 App 列表")
            return
        known = sum(bool(apple_id) for _, apple_id in rows)
        status.set(f"已读取 {len(rows)} 个 App，其中 {known} 个有 Apple ID")
        filename = filedialog.asksaveasfilename(
            parent=root, title="保存 TXT", initialfile="iPhone-App-Apple-ID.txt",
            defaultextension=".txt", filetypes=[("文本文件", "*.txt")],
        )
        if filename:
            try:
                save_report(Path(filename), rows)
            except OSError as exc:
                messagebox.showerror("导出失败", str(exc), parent=root)
            else:
                status.set(f"已保存 {len(rows)} 行，其中 {known} 个有 Apple ID")

    def read_in_background():
        try:
            rows = asyncio.run(asyncio.wait_for(scan(), timeout=35))
        except Exception as exc:
            message = str(exc) or type(exc).__name__
            root.after(0, finish, None, message)
        else:
            root.after(0, finish, rows, None)

    def start():
        button.configure(state="disabled")
        status.set("正在读取已安装的 App…")
        threading.Thread(target=read_in_background, daemon=True).start()

    button = ttk.Button(panel, text="查询并导出 TXT", command=start)
    button.pack(anchor="w")
    root.mainloop()


if __name__ == "__main__":
    main()
