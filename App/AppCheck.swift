import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct InstalledApp: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let apple_id: String?
}

struct ScanResponse: Decodable {
    let apps: [InstalledApp]?
    let error: String?
}

struct TXTReport: FileDocument {
    static let readableContentTypes: [UTType] = [.plainText]
    var text: String

    init(text: String) {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents,
              let text = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        self.text = text
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}

private struct PairingFilePicker: UIViewControllerRepresentable {
    let onPick: (URL) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL) -> Void
        let onCancel: () -> Void

        init(onPick: @escaping (URL) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            onPick(url)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onCancel()
        }
    }
}

@main
struct AppCheck: App {
    var body: some Scene {
        WindowGroup { ResultsView() }
    }
}

struct ResultsView: View {
    @AppStorage("deviceAddress") private var address = "10.7.0.1:49152"
    @Environment(\.scenePhase) private var scenePhase
    @State private var apps: [InstalledApp] = []
    @State private var reading = false
    @State private var importing = false
    @State private var exporting = false
    @State private var editing = false
    @State private var importAfterSettings = false
    @State private var pairingImported = false
    @State private var error: String?
    @State private var report = TXTReport(text: "")
    @State private var lastScan: Date?

    private var pairingFile: URL {
        URL.applicationSupportDirectory.appendingPathComponent("remote-pairing.plist")
    }

    private var groups: [(account: String, apps: [InstalledApp])] {
        let grouped = Dictionary(grouping: apps, by: { $0.apple_id ?? "" })
        return grouped.keys.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a.localizedStandardCompare(b) == .orderedAscending
        }.map { key in
            let sorted = (grouped[key] ?? []).sorted {
                let order = $0.name.localizedStandardCompare($1.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            return (key.isEmpty ? "未读取到 Apple ID" : key, sorted)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if reading { ProgressView("正在读取已安装的 App…") }
                    if pairingImported { Label("配对文件已导入", systemImage: "checkmark.circle") }
                    if let error { Text(error).foregroundStyle(.red) }
                    if let lastScan {
                        let known = apps.filter { $0.apple_id != nil }.count
                        Text("已读取邮箱 \(known)/\(apps.count) 个 App")
                        Text(lastScan.formatted(date: .abbreviated, time: .standard))
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if !reading && lastScan == nil {
                        Text("首次导入此 iPhone 的 Remote Pairing 文件，并连接 LocalDevVPN。")
                        Button("导入配对文件") { importing = true }.disabled(reading)
                    }
                    Button("重新查询", action: scan).disabled(reading)
                }

                ForEach(groups, id: \.account) { group in
                    Section(group.account) {
                        ForEach(group.apps) { app in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(app.name)
                                Text(app.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("App 下载账号")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("设置") { editing = true }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("导出 TXT", action: export).disabled(reading || apps.isEmpty)
                }
            }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            if phase == .active && !importing && !exporting && !editing,
               FileManager.default.fileExists(atPath: pairingFile.path) {
                scan()
            }
        }
        .sheet(isPresented: $editing, onDismiss: {
            if importAfterSettings {
                importAfterSettings = false
                importing = true
            }
        }) {
            NavigationStack {
                Form {
                    TextField("设备 IPv4 地址:端口", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("填 LocalDevVPN 设置里的 Device IP，端口默认 49152。")
                    Button("更换配对文件") {
                        importAfterSettings = true
                        editing = false
                    }.disabled(reading)
                }
                .navigationTitle("连接设置")
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { editing = false }
                    }
                }
            }
        }
        .sheet(isPresented: $importing) {
            PairingFilePicker(onPick: { url in
                importing = false
                importPairingFile(url)
            }, onCancel: {
                importing = false
            })
        }
        .fileExporter(
            isPresented: $exporting, document: report,
            contentType: .plainText, defaultFilename: "iPhone-App-Apple-ID.txt"
        ) { result in
            if case .failure(let failure) = result {
                error = "导出失败：\(failure.localizedDescription)"
            }
        }
    }

    private func importPairingFile(_ source: URL) {
        do {
            let data = try Data(contentsOf: source)
            guard let record = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  (record["public_key"] as? Data)?.count == 32,
                  (record["private_key"] as? Data)?.count == 32,
                  let identifier = record["identifier"] as? String, !identifier.isEmpty else {
                error = "请选择 idevice_pair 通过 Remote pairing 导出的文件。"
                return
            }
            var directory = pairingFile.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var attributes = URLResourceValues()
            attributes.isExcludedFromBackup = true
            try directory.setResourceValues(attributes)
            try data.write(to: pairingFile, options: [.atomic, .completeFileProtection])
            pairingImported = true
            scan()
        } catch {
            self.error = "导入配对文件失败：\(error.localizedDescription)"
        }
    }

    private func scan() {
        guard !reading else { return }
        guard FileManager.default.fileExists(atPath: pairingFile.path) else {
            error = "请先导入 Remote Pairing 文件。"
            return
        }
        reading = true
        error = nil
        let path = pairingFile.path
        let endpoint = address.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { @MainActor in
            let output = await Task.detached(priority: .userInitiated) {
                path.withCString { pathPointer in
                    endpoint.withCString { addressPointer in
                        let result = appcheck_scan(pathPointer, addressPointer)!
                        defer { appcheck_free(result) }
                        return Data(String(cString: result).utf8)
                    }
                }
            }.value
            defer { reading = false }
            do {
                let response = try JSONDecoder().decode(ScanResponse.self, from: output)
                if let fresh = response.apps {
                    apps = fresh
                    lastScan = Date()
                    if fresh.allSatisfy({ $0.apple_id == nil }) {
                        error = "应用列表读取成功，但系统没有返回任何可识别的 Apple ID 邮箱。"
                    }
                } else {
                    error = response.error ?? "未收到查询结果。"
                }
            } catch {
                self.error = "查询结果无法读取：\(error.localizedDescription)"
            }
        }
    }

    private func export() {
        var lines = ["iPhone App 下载账号", lastScan?.formatted() ?? ""]
        for group in groups {
            lines.append("")
            lines.append("[\(group.account)]")
            lines.append(contentsOf: group.apps.map { "\($0.name)\t\($0.id)" })
        }
        report = TXTReport(text: lines.joined(separator: "\n") + "\n")
        exporting = true
    }
}
