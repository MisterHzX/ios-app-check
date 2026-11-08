# iOS App Check

在未越狱 iPhone 上查看本机已安装 App 的 App Store 下载账号，按 Apple ID 分组并导出 UTF-8 TXT。App 会在前台自动查询，也可以手动重查。查不到邮箱的 App 会单独列出。

## 下载与安装

提交到 main 后，打开 GitHub 的 **Actions → Build IPA**，进入成功的构建，从 **Artifacts → iOS-App-Check** 下载压缩包。解压得到 `iOS-App-Check.ipa`，用自己的签名工具安装。也可以在 Actions 页面手动运行构建。

## iPhone 17 首次设置

1. 在 iPhone 开启开发者模式，按系统提示重启并确认。
2. 把 iPhone 连到 Windows，解锁并点「信任」。在 [idevice_pair](https://github.com/jkcoxson/idevice_pair/releases) 中选 **Remote pairing → Create**，按界面提示完成配对，然后选 **Save to file**。iOS 26.4 及以上需要 Remote Pairing 文件。
3. 把配对文件传到这台 iPhone，在本 App 中导入。配对文件含设备凭据，请不要上传到公开仓库或发给他人。
4. 连接 [LocalDevVPN](https://apps.apple.com/app/localdevvpn/id6755608044)，再打开本 App。默认连接 `10.7.0.1:49152`。如果你的 LocalDevVPN **Device IP** 不同，在 App 的设置页修改地址。
5. 查询后点 **导出 TXT**，用系统文件选择器选择保存位置。

## 查询范围

App 使用本机远程配对隧道连接 iOS 的应用安装服务，只请求 App 标识、名称和下载元数据。导出内容由本机生成。只使用系统返回的 Apple ID 字段，字段缺失时保留为「未读取到 Apple ID」。若连接正常却所有邮箱都为空，这台设备通过此路径没有提供可识别的 Apple ID；需要真机验证具体 iOS 版本。

## 本地构建

在安装 Xcode 的 macOS 上，安装 Rust stable 并执行：

```sh
rustup target add aarch64-apple-ios
bash scripts/build-ipa.sh
```

打包结果在 `build/iOS-App-Check.ipa`。
