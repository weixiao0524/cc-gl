import Foundation
import SwiftUI
import CodexConfigCore

// Demo mode has isolated files and in-memory secrets; it never reads ~/.codex or Keychain.
final class DemoSecrets: SecretStorage {
    private var values: [UUID: String] = [:]
    func read(_ id: UUID) throws -> String { values[id] ?? "" }
    func write(_ value: String, id: UUID) throws { values[id] = value }
    func delete(_ id: UUID) throws { values.removeValue(forKey: id) }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var profiles: [Profile] = []
    @Published private(set) var activeProfileIDs: Set<UUID> = []
    @Published var draft = Profile(name: "当前配置", baseURL: "")
    @Published var apiKey = ""
    @Published var selection: UUID?
    @Published var current: CurrentConfiguration?
    @Published var status = "正在读取本地配置…"
    @Published var statusIsError = false
    @Published var errorMessage: String?
    @Published var showDiscard = false
    @Published var showApply = false
    @Published var showRestore = false
    @Published var showDelete = false
    @Published var hasBackup = false
    @Published var needsRecovery = false
    @Published var storeReadable = true
    @Published var detector: DetectionViewModel?
    private var baseline = Profile(name: "当前配置", baseURL: "")
    private var baselineKey = ""
    private var pendingAction: (() -> Void)?
    let service: ConfigurationService
    let store: ProfileStore
    let isDemo: Bool
    var cloudSync: CloudSyncModel!

    var isDirty: Bool { draft != baseline || apiKey != baselineKey }
    var isSaved: Bool { profiles.contains { $0.id == draft.id } }
    var validDraft: Bool {
        (try? ConfigDocument.validateURL(draft.baseURL)) != nil &&
        (try? AuthDocument.validateKey(apiKey)) != nil &&
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var matchesCurrent: Bool { current?.config.baseURL == draft.baseURL && current?.auth.apiKey == apiKey }
    var destinationHost: String { URLComponents(string: draft.baseURL)?.host ?? draft.baseURL }

    init(isDemo: Bool = CommandLine.arguments.contains("--demo")) {
        self.isDemo = isDemo
        let home = FileManager.default.homeDirectoryForCurrentUser
        let support: URL
        let codex: URL
        let secrets: SecretStorage
        if isDemo {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("CodexConfig-Demo-\(UUID().uuidString)")
            codex = root.appendingPathComponent("codex")
            support = root.appendingPathComponent("manager")
            secrets = DemoSecrets()
            do {
                try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try Data("""
                # Demo fixture — not the real Codex configuration
                model_provider = "custom"
                [model_providers.custom]
                name = "Custom"
                requires_openai_auth = true
                base_url = "https://api.example.com/v1" # keep this comment

                """.utf8).write(to: codex.appendingPathComponent("config.toml"))
                try Data("{\n  \"OPENAI_API_KEY\": \"demo-key-not-a-real-secret\"\n}\n".utf8).write(to: codex.appendingPathComponent("auth.json"))
            } catch { /* Normal loading below reports fixture creation failure without exposing contents. */ }
        } else {
            codex = home.appendingPathComponent(".codex")
            support = home.appendingPathComponent("Library/Application Support/CodexConfig")
            secrets = KeychainStorage()
        }
        service = ConfigurationService(codexDirectory: codex, supportDirectory: support)
        store = ProfileStore(directory: support, secrets: secrets)
        if isDemo {
            _ = try? store.save(Profile(name: "日常使用", baseURL: "https://api.example.com/v1"), key: "demo-key-not-a-real-secret")
            _ = try? store.save(Profile(name: "备用线路", baseURL: "https://backup.example.com/v1"), key: "demo-backup-key")
        }
        refreshProfiles()
        reload()
        cloudSync = CloudSyncModel(store: store, support: support, isDemo: isDemo)
        cloudSync.onChange = { [weak self] in
            guard let self else { return }
            let selected = self.selection
            let dirty = self.isDirty
            self.refreshProfiles()
            if !dirty, let selected {
                if let profile = self.profiles.first(where: { $0.id == selected }) { self.select(profile) }
                else { self.useCurrent() }
            }
        }
    }

    func request(_ action: @escaping () -> Void) {
        if isDirty { pendingAction = action; showDiscard = true }
        else { action() }
    }

    func discardAndContinue() {
        let action = pendingAction
        pendingAction = nil
        action?()
    }

    func reload() {
        do {
            let environment = ProcessInfo.processInfo.environment
            if !isDemo, let custom = environment["CODEX_HOME"],
               URL(fileURLWithPath: custom).standardizedFileURL != service.codexDirectory {
                throw ConfigError("检测到 CODEX_HOME 指向其他目录。本工具仅操作 ~/.codex，不会写入其他位置。")
            }
            current = try service.load()
            useCurrent()
            status = "已读取本地文件，尚未进行修改"
            statusIsError = false
        } catch {
            current = nil
            status = safeMessage(error)
            statusIsError = true
        }
        updateBackup()
    }

    func useCurrent() {
        selection = nil
        draft = Profile(name: "当前配置", baseURL: current?.config.baseURL ?? "")
        apiKey = current?.auth.apiKey ?? ""
        rememberBaseline()
    }

    func select(_ profile: Profile) {
        selection = profile.id
        draft = profile
        apiKey = ""
        do { apiKey = try store.key(for: profile) }
        catch { report(error) }
        rememberBaseline()
    }

    func newProfile() {
        draft = Profile(name: "", baseURL: "")
        selection = draft.id
        apiKey = ""
        rememberBaseline()
    }

    func openDetector() {
        detector = DetectionViewModel(baseURL: draft.baseURL, apiKey: apiKey,
                                      profileName: draft.name, isDemo: isDemo)
    }

    func save() {
        do {
            draft = try store.save(draft, key: apiKey)
            selection = draft.id
            refreshProfiles()
            rememberBaseline()
            status = "已保存到收藏，未修改 Codex 文件"
            statusIsError = false
        } catch { report(error) }
    }

    func apply() {
        guard let current else { return }
        do {
            try service.apply(baseURL: draft.baseURL, apiKey: apiKey, expected: current.snapshot)
            self.current = try service.load()
            status = "已应用。请重启 Codex 或相关会话以读取新配置"
            statusIsError = false
        } catch { report(error) }
        updateBackup()
    }

    // Menu switching applies the saved entry, never the editor's unsaved draft.
    @discardableResult
    func applySavedProfile(_ profile: Profile) -> Bool {
        guard storeReadable, !needsRecovery, let current else { return false }
        do {
            guard let saved = try store.load().first(where: { $0.id == profile.id }), saved == profile else {
                throw ConfigError("收藏已发生变化，请重新打开菜单后再试。")
            }
            let key = try store.key(for: saved)
            try service.apply(baseURL: saved.baseURL, apiKey: key, expected: current.snapshot)
            self.current = try service.load()
            status = "已切换到“\(saved.name)”。请重启 Codex 或相关会话"
            statusIsError = false
            updateBackup()
            return true
        } catch {
            report(error)
            updateBackup()
            return false
        }
    }

    func refreshMenu() {
        refreshProfiles()
        do {
            if !isDemo, let custom = ProcessInfo.processInfo.environment["CODEX_HOME"],
               URL(fileURLWithPath: custom).standardizedFileURL != service.codexDirectory {
                throw ConfigError("检测到 CODEX_HOME 指向其他目录。本工具仅操作 ~/.codex，不会写入其他位置。")
            }
            current = try service.load()
        } catch { current = nil; report(error) }
        updateBackup()
    }

    func setYOLO(_ enabled: Bool) {
        guard let current else { return }
        do {
            try service.setYOLO(enabled, expected: current.snapshot)
            self.current = try service.load()
            status = enabled
                ? "YOLO 已开启：免审批、完全访问。请重启 Codex 或新建会话"
                : "YOLO 已关闭：工作区写入、按需审批。请重启 Codex 或新建会话"
            statusIsError = false
        } catch { report(error) }
        updateBackup()
    }

    func restore() {
        do {
            try service.restore()
            reload()
            status = "已恢复上次切换前的原始文件"
            statusIsError = false
        } catch { report(error) }
        updateBackup()
    }

    func delete() {
        do {
            try store.delete(draft)
            refreshProfiles()
            useCurrent()
            status = "已删除收藏，Codex 文件未改变"
            statusIsError = false
        } catch { refreshProfiles(); report(error) }
    }

    private func rememberBaseline() { baseline = draft; baselineKey = apiKey }
    private func refreshProfiles() {
        do { profiles = try store.load(); storeReadable = true }
        catch { storeReadable = false; report(error) }
        refreshActiveProfiles()
    }
    private func refreshActiveProfiles() {
        guard storeReadable, let current else {
            activeProfileIDs = []
            return
        }
        // Resolve secrets once per refresh, not during SwiftUI body evaluation.
        activeProfileIDs = Set(profiles.compactMap { profile in
            guard profile.baseURL == current.config.baseURL,
                  let key = try? store.key(for: profile), key == current.auth.apiKey else { return nil }
            return profile.id
        })
    }

    private func updateBackup() {
        hasBackup = service.hasBackup
        needsRecovery = service.needsRecovery
        refreshActiveProfiles()
    }
    private func report(_ error: Error) {
        let message = safeMessage(error)
        errorMessage = message
        status = message
        statusIsError = true
    }
    private func safeMessage(_ error: Error) -> String {
        (error as? ConfigError)?.message ?? "本地操作失败。请检查文件权限、磁盘空间及钥匙串访问状态。"
    }
}
