import AppKit
import SwiftUI
import CodexConfigCore
import Network

@MainActor
final class CloudSyncModel: ObservableObject {
    @Published var enabled = false
    @Published var busy = false
    @Published var status = "未启用"
    @Published var detail = ""
    @Published var folder: URL?
    @Published var lastSync: Date?
    @Published var error: String?
    private struct Settings: Codable {
        var bookmark: Data
        var secretID: UUID
    }
    private let network = NWPathMonitor()
    private var online = true
    private var settings: Settings?
    private var engine: CloudSyncEngine?
    private var timer: Task<Void, Never>?
    private let store: ProfileStore
    private let settingsURL: URL
    private let secrets: SecretStorage
    private let isDemo: Bool
    var onChange: (() -> Void)?

    init(store: ProfileStore, support: URL, isDemo: Bool) {
        self.store = store; self.settingsURL = support.appendingPathComponent("cloud-sync.json")
        self.isDemo = isDemo; self.secrets = isDemo ? DemoSecrets() : KeychainStorage()
        network.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in self?.online = path.status == .satisfied }
        }
        network.start(queue: DispatchQueue(label: "CodexConfig.sync-network"))
        guard !isDemo, FileManager.default.fileExists(atPath: settingsURL.path) else { return }
        do {
            let settings = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: settingsURL))
            var stale = false
            let url = try URL(resolvingBookmarkData: settings.bookmark, options: [.withoutUI], bookmarkDataIsStale: &stale)
            guard !stale, let key = Data(base64Encoded: try secrets.read(settings.secretID)), key.count == 32 else {
                throw ConfigError("请重新选择同步文件夹并输入同步密码。")
            }
            self.settings = settings; self.folder = url
            self.engine = CloudSyncEngine(folder: url, key: key, stateDirectory: support, store: store)
            enabled = true
            startTimer()
        } catch { status = "需要重新连接"; self.error = message(error) }
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "选择 iCloud Drive 中的同步文件夹"
        panel.message = "两台 Mac 选择同一个专用文件夹。新建同步空间时请选择空文件夹。"
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let drive = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs")
        panel.directoryURL = isDemo ? FileManager.default.temporaryDirectory : drive
        if panel.runModal() == .OK { folder = panel.url; error = nil }
    }

    @discardableResult
    func connect(password: String, create: Bool) async -> Bool {
        guard let folder, !busy, !enabled else { return false }
        busy = true; error = nil; status = "正在连接…"
        defer { busy = false }
        do {
            if !isDemo {
                let values = try folder.resourceValues(forKeys: [.isUbiquitousItemKey])
                guard values.isUbiquitousItem == true else {
                    throw ConfigError("请选择 iCloud Drive 中的文件夹，并确认系统已开启 iCloud Drive。")
                }
            }
            let key = try await Task.detached {
                try CloudSyncEngine.connect(folder: folder, password: password, create: create)
            }.value
            let newSettings = Settings(bookmark: try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil), secretID: UUID())
            try secrets.write(key.base64EncodedString(), id: newSettings.secretID)
            do {
                try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try JSONEncoder().encode(newSettings).write(to: settingsURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settingsURL.path)
            } catch { try? secrets.delete(newSettings.secretID); throw error }
            if let old = settings { try? secrets.delete(old.secretID) }
            settings = newSettings
            engine = CloudSyncEngine(folder: folder, key: key, stateDirectory: settingsURL.deletingLastPathComponent(), store: store)
            enabled = true
            status = "等待同步"
            startTimer()
            return true
        } catch {
            self.error = message(error); status = "连接失败"
            return false
        }
    }

    func syncNow() async {
        guard enabled, !busy, let engine else { return }
        busy = true; error = nil; status = "同步中…"
        defer { busy = false }
        do {
            let conflicts = try await Task.detached { try engine.sync() }.value
            onChange?()
            lastSync = Date()
            detail = conflicts > 0 ? "保留了 \(conflicts) 条冲突副本，请在收藏中核对。" : "收藏与 API Key 已合并；当前线路和 YOLO 保持本机设置。"
            status = online ? try uploadStatus() : "离线 · 等待网络"
        } catch { status = online ? "同步暂停 · 将重试" : "离线 · 等待网络"; self.error = message(error) }
    }

    private func uploadStatus() throws -> String {
        guard !isDemo, let folder else { return "演示同步完成" }
        let keys: Set<URLResourceKey> = [.isUbiquitousItemKey, .ubiquitousItemIsUploadedKey,
                                        .ubiquitousItemUploadingErrorKey, .ubiquitousItemDownloadingErrorKey,
                                        .ubiquitousItemHasUnresolvedConflictsKey]
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: Array(keys))
            .filter { $0.pathExtension == "cglsync" || $0.lastPathComponent == "vault.json" }
        for file in files {
            let values = try file.resourceValues(forKeys: keys)
            if values.ubiquitousItemUploadingError != nil || values.ubiquitousItemDownloadingError != nil {
                return "iCloud 传输失败 · 将重试"
            }
            if values.ubiquitousItemHasUnresolvedConflicts == true { return "iCloud 文件冲突 · 请检查" }
            if values.isUbiquitousItem != true || values.ubiquitousItemIsUploaded != true {
                return "等待 iCloud 上传"
            }
        }
        return "已同步"
    }

    func disconnect() {
        guard !busy else { return }
        do {
            if FileManager.default.fileExists(atPath: settingsURL.path) { try FileManager.default.removeItem(at: settingsURL) }
            let previous = settings
            timer?.cancel(); timer = nil; engine = nil; settings = nil
            enabled = false; status = "未启用"; detail = "本机收藏和 iCloud 文件均保留。"; error = nil
            if let previous { try secrets.delete(previous.secretID) }
        } catch { self.error = message(error) }
    }

    private func startTimer() {
        timer?.cancel()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncNow()
                do { try await Task.sleep(nanoseconds: 15_000_000_000) } catch { break }
            }
        }
    }
    private func message(_ error: Error) -> String {
        (error as? ConfigError)?.message ?? "同步暂不可用。请检查 iCloud 登录、网络、文件下载和钥匙串访问，稍后重试。"
    }
}

struct SyncConnectionForm {
    var password = ""
    var confirmation = ""
    var create = false

    var passwordError: String? {
        if password.isEmpty { return "请输入同步密码。" }
        if password.utf8.count > 1024 { return "同步密码不能超过 1024 字节。" }
        return create && password.count < 12 ? "同步密码至少需要 12 个字符。" : nil
    }
    var confirmationError: String? {
        guard create else { return nil }
        return password == confirmation ? nil : "两次输入的密码不一致。"
    }
    var isValid: Bool { passwordError == nil && confirmationError == nil }

    mutating func finishConnection(succeeded: Bool) {
        guard succeeded else { return }
        password = ""
        confirmation = ""
    }
}

struct CloudSyncView: View {
    @ObservedObject var model: CloudSyncModel
    @Environment(\.dismiss) private var dismiss
    @State private var form = SyncConnectionForm()
    @State private var visitedFields: Set<Field> = []
    @FocusState private var focusedField: Field?
    private enum Field: Hashable { case password, confirmation }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("iCloud 同步", systemImage: "icloud").font(.title2.weight(.semibold))
                Spacer()
                Button("完成") { dismiss() }.keyboardShortcut(.cancelAction).disabled(model.busy)
            }
            Text("收藏和 API Key 跨 Mac 自动同步。当前线路与 YOLO 各自独立。")
                .font(.callout).foregroundStyle(.secondary)
            if model.enabled {
                syncStatus
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
                if let date = model.lastSync {
                    Text("最近合并：\(date.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("应用打开期间每 15 秒合并一次，关闭后暂停。离线修改会在恢复连接后同步；同一收藏的并发修改保留冲突副本。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("暂停并断开") { model.disconnect() }
                    Spacer()
                    Button("立即同步") { Task { await model.syncNow() } }.buttonStyle(.borderedProminent)
                }.disabled(model.busy)
            } else {
                Picker("同步空间", selection: $form.create) {
                    Text("连接已有").tag(false)
                    Text("首次创建").tag(true)
                }.pickerStyle(.segmented).disabled(model.busy)
                Button { model.chooseFolder() } label: {
                    Label(model.folder?.lastPathComponent ?? "选择 iCloud Drive 文件夹", systemImage: "folder")
                }
                .disabled(model.busy)
                VStack(alignment: .leading, spacing: 6) {
                    Text("同步密码").font(.system(size: 13, weight: .medium))
                    SecureField(form.create ? "至少 12 个字符" : "另一台 Mac 设置的密码", text: $form.password)
                        .focused($focusedField, equals: .password)
                        .accessibilityLabel("同步密码")
                        .accessibilityIdentifier("sync-password")
                        .disabled(model.busy)
                    if visitedFields.contains(.password), let error = form.passwordError {
                        validationMessage(error)
                    }
                }
                if form.create {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("确认密码").font(.system(size: 13, weight: .medium))
                        SecureField("再次输入同步密码", text: $form.confirmation)
                            .focused($focusedField, equals: .confirmation)
                            .accessibilityLabel("确认同步密码")
                            .accessibilityIdentifier("sync-password-confirmation")
                            .disabled(model.busy)
                        if (visitedFields.contains(.confirmation) || !form.confirmation.isEmpty), let error = form.confirmationError {
                            validationMessage(error)
                        }
                    }
                }
                Text(form.create ? "请妥善保存密码；在其他 Mac 连接时需要它，遗忘后无法解密。已有本机收藏将上传到所选空间。" : "解锁后自动合并两端收藏，API Key 写入本机钥匙串。已有空间请勿重新创建。")
                    .font(.caption).foregroundStyle(.secondary)
                Text("内容使用 AES-256-GCM 加密；本机钥匙串保存解锁密钥，重启应用后自动继续同步。")
                    .font(.caption).foregroundStyle(.secondary)
                if model.busy { syncStatus }
                Button(model.busy ? "正在连接…" : form.create ? "创建并启用同步" : "解锁并启用同步") {
                    let supplied = form
                    focusedField = nil
                    Task {
                        let succeeded = await model.connect(password: supplied.password, create: supplied.create)
                        form.finishConnection(succeeded: succeeded)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.folder == nil || !form.isValid || model.busy)
                .help(model.folder == nil ? "请先选择同步文件夹" : form.passwordError ?? form.confirmationError ?? "启用加密同步")
            }
            if let folder = model.folder {
                Text(folder.path).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(2)
            }
            if let error = model.error { Text(error).font(.caption).foregroundStyle(.orange) }
        }
        .padding(24).frame(width: 460)
        .textFieldStyle(.roundedBorder)
        .interactiveDismissDisabled(model.busy)
        .onChange(of: focusedField) { [focusedField] _ in
            if let focusedField { visitedFields.insert(focusedField) }
        }
        .onChange(of: form.create) { _ in visitedFields = [] }
    }

    private var syncStatus: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small) }
            else { Image(systemName: "icloud") }
            Text(model.status).font(.system(size: 13))
        }
        .accessibilityElement(children: .combine)
    }

    private func validationMessage(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.system(size: 11)).foregroundStyle(.red)
    }
}

struct CloudSyncSidebarButton: View {
    @ObservedObject var model: CloudSyncModel
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "icloud")
                Text("iCloud 同步")
                Spacer(minLength: 0)
                if model.busy { ProgressView().controlSize(.mini) }
                else if model.enabled {
                    Circle().fill(model.error == nil && model.status == "已同步" ? Color.green : Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .font(.system(size: 12))
        .help(model.status)
        .accessibilityLabel("iCloud 同步，\(model.status)")
    }
}
