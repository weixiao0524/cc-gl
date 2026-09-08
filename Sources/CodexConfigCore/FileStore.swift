import Foundation
import Darwin

enum SecureFile {
    static let maximumSize = 8 * 1024 * 1024

    static func read(_ url: URL, limit: Int = maximumSize) throws -> (Data, UInt16) {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ConfigError("无法读取 \(url.lastPathComponent)，请检查文件是否存在、权限及是否为符号链接。") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_size <= limit, info.st_nlink == 1 else {
            throw ConfigError("\(url.lastPathComponent) 必须是大小不超过 \(limit / 1024 / 1024) MB 的普通文件，且不能是硬链接。")
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw ConfigError("读取 \(url.lastPathComponent) 失败。") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw ConfigError("文件过大，已停止读取。") }
        }
        return (data, info.st_mode & 0o777)
    }

    static func directory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else {
            throw ConfigError("管理器数据目录必须是普通目录。")
        }
        guard chmod(url.path, 0o700) == 0 else { throw ConfigError("无法保护管理器数据目录。") }
    }

    static func write(_ data: Data, to url: URL, mode: UInt16 = 0o600,
                      beforeRename: () throws -> Void = {}) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".cgl-\(UUID().uuidString).tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ConfigError("无法在 \(url.deletingLastPathComponent().lastPathComponent) 中创建临时文件。") }
        defer { close(fd); unlink(temporary.path) }
        try data.withUnsafeBytes { bytes in
            var total = 0
            while total < data.count {
                let n = Darwin.write(fd, bytes.baseAddress!.advanced(by: total), data.count - total)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ConfigError("写入临时文件失败。") }
                total += n
            }
        }
        guard fchmod(fd, mode_t(mode)) == 0, fsync(fd) == 0 else { throw ConfigError("无法同步文件到磁盘。") }
        try beforeRename()
        guard rename(temporary.path, url.path) == 0 else { throw ConfigError("替换 \(url.lastPathComponent) 失败。") }
        let parent = open(url.deletingLastPathComponent().path, O_RDONLY)
        if parent >= 0 { _ = fsync(parent); close(parent) }
    }

    static func locked<T>(in directory: URL, _ action: () throws -> T) throws -> T {
        try self.directory(directory)
        let lock = directory.appendingPathComponent("write.lock")
        let fd = open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw ConfigError("无法创建管理器写入锁。") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConfigError("另一个管理器正在写入，请稍后重试。") }
        defer { flock(fd, LOCK_UN) }
        return try action()
    }
}

public struct FileSnapshot: Equatable, Codable {
    public let config: Data
    public let auth: Data
    let configMode: UInt16
    let authMode: UInt16
}

public struct CurrentConfiguration {
    public let snapshot: FileSnapshot
    public let config: ConfigDocument
    public let auth: AuthDocument
}

private struct Journal: Codable {
    enum Phase: String, Codable { case pending, applied, restoring }
    let codexPath: String
    let before: FileSnapshot
    let after: FileSnapshot
    let date: Date
    var phase: Phase
    var yolo: Bool? = nil
}

public final class ConfigurationService {
    public let codexDirectory: URL
    public let supportDirectory: URL
    private var configURL: URL { codexDirectory.appendingPathComponent("config.toml") }
    private var authURL: URL { codexDirectory.appendingPathComponent("auth.json") }
    private var journalURL: URL { supportDirectory.appendingPathComponent("last-change.json") }
    // Fault injection is internal and used only by temporary-fixture tests.
    var beforeReplace: ((URL) throws -> Void)?

    public init(codexDirectory: URL, supportDirectory: URL) {
        self.codexDirectory = codexDirectory.standardizedFileURL
        self.supportDirectory = supportDirectory.standardizedFileURL
    }

    public var hasBackup: Bool { FileManager.default.fileExists(atPath: journalURL.path) }
    public var needsRecovery: Bool {
        guard hasBackup else { return false }
        guard let journal = try? readJournal() else { return true }
        return journal.phase != .applied
    }

    public func load() throws -> CurrentConfiguration {
        let snapshot = try capture()
        return try CurrentConfiguration(snapshot: snapshot, config: ConfigDocument(data: snapshot.config),
                                        auth: AuthDocument(data: snapshot.auth))
    }

    public func apply(baseURL: String, apiKey: String, expected: FileSnapshot, yolo: Bool? = nil) throws {
        try locked {
            if needsRecovery { throw ConfigError("上次写入未完成或备份不可读。请先恢复上次配置，不会继续覆盖。") }
            let current = try capture()
            guard current == expected else { throw ConfigError("Codex 文件已被其他程序修改。请先重新读取，再应用配置。") }
            let configDocument = try ConfigDocument(data: current.config)
            let authDocument = try AuthDocument(data: current.auth)
            try ConfigDocument.validateURL(baseURL)
            try AuthDocument.validateKey(apiKey)
            if yolo == nil && configDocument.baseURL == baseURL && authDocument.apiKey == apiKey { return }
            var config = configDocument.baseURL == baseURL ? current.config : try configDocument.replacingBaseURL(baseURL)
            if let yolo { config = try ConfigDocument(data: config).replacingYOLO(yolo) }
            let auth = authDocument.apiKey == apiKey ? current.auth : try authDocument.replacingAPIKey(apiKey)
            let next = FileSnapshot(config: config, auth: auth, configMode: current.configMode, authMode: current.authMode)
            guard next != current else { return }
            var journal = Journal(codexPath: codexDirectory.path, before: current, after: next, date: Date(), phase: .pending, yolo: yolo)
            try saveJournal(journal)
            do {
                try replace(config, at: configURL, mode: current.configMode) {
                    guard try self.capture() == current else { throw ConfigError("文件在写入前发生变化，已中止。") }
                }
                try replace(auth, at: authURL, mode: current.authMode) {
                    let actual = try self.capture()
                    guard actual.config == next.config, actual.auth == current.auth,
                          actual.configMode == next.configMode, actual.authMode == current.authMode else {
                        throw ConfigError("文件在写入过程中被其他程序修改，已中止。")
                    }
                }
                guard try capture() == next else { throw ConfigError("写入后文件发生变化。") }
                journal.phase = .applied
                try saveJournal(journal)
            } catch {
                // Only restore when every current file is exactly an old/new transaction version.
                do { try restoreLocked(journal) }
                catch { throw ConfigError("应用未完成，自动回滚也未完成。备份已保留；请停止其他配置写入后点击恢复上次配置。") }
                throw ConfigError("应用失败，已恢复原文件。\((error as? ConfigError)?.message ?? "请检查磁盘和文件权限。")")
            }
        }
    }

    public func setYOLO(_ enabled: Bool, expected: FileSnapshot) throws {
        let config = try ConfigDocument(data: expected.config)
        let auth = try AuthDocument(data: expected.auth)
        try apply(baseURL: config.baseURL, apiKey: auth.apiKey, expected: expected, yolo: enabled)
    }

    public func restore() throws {
        try locked { try restoreLocked(readJournal()) }
    }

    private func capture() throws -> FileSnapshot {
        let (config, configMode) = try SecureFile.read(configURL)
        let (auth, authMode) = try SecureFile.read(authURL)
        return FileSnapshot(config: config, auth: auth, configMode: configMode, authMode: authMode)
    }

    private func restoreLocked(_ saved: Journal) throws {
        var journal = saved
        let current = try capture()
        if journal.phase == .applied {
            guard current == journal.after else { throw ConfigError("应用后文件已有其他修改，为避免覆盖其他设置，不能直接恢复旧备份。") }
        }
        try validateRecovery(current, journal)
        journal.phase = .restoring
        try saveJournal(journal)
        try replace(journal.before.config, at: configURL, mode: journal.before.configMode) {
            try self.validateRecovery(self.capture(), journal)
        }
        try replace(journal.before.auth, at: authURL, mode: journal.before.authMode) {
            try self.validateRecovery(self.capture(), journal)
        }
        guard try capture() == journal.before else { throw ConfigError("恢复后校验失败，备份已保留。") }
        try FileManager.default.removeItem(at: journalURL)
    }

    private func validateRecovery(_ snapshot: FileSnapshot, _ journal: Journal) throws {
        guard [journal.before.config, journal.after.config].contains(snapshot.config),
              [journal.before.auth, journal.after.auth].contains(snapshot.auth),
              snapshot.configMode == journal.before.configMode,
              snapshot.authMode == journal.before.authMode else {
            throw ConfigError("文件含有本次切换以外的改动，已拒绝覆盖，备份仍保留在管理器目录。")
        }
    }

    private func replace(_ data: Data, at url: URL, mode: UInt16, check: () throws -> Void) throws {
        try check()
        let current = try SecureFile.read(url)
        if current.0 == data && current.1 == mode { return }
        try beforeReplace?(url)
        try SecureFile.write(data, to: url, mode: mode, beforeRename: check)
    }

    private func readJournal() throws -> Journal {
        let data = try SecureFile.read(journalURL, limit: 64 * 1024 * 1024).0
        guard let journal = try? JSONDecoder().decode(Journal.self, from: data),
              journal.codexPath == codexDirectory.path else {
            throw ConfigError("备份无效或不属于当前 Codex 目录，不会恢复。")
        }
        let beforeConfig = try ConfigDocument(data: journal.before.config)
        let afterConfig = try ConfigDocument(data: journal.after.config)
        let beforeAuth = try AuthDocument(data: journal.before.auth)
        let afterAuth = try AuthDocument(data: journal.after.auth)
        var expectedConfig = beforeConfig.baseURL == afterConfig.baseURL ? journal.before.config : try beforeConfig.replacingBaseURL(afterConfig.baseURL)
        if let yolo = journal.yolo { expectedConfig = try ConfigDocument(data: expectedConfig).replacingYOLO(yolo) }
        let expectedAuth = beforeAuth.apiKey == afterAuth.apiKey ? journal.before.auth : try beforeAuth.replacingAPIKey(afterAuth.apiKey)
        guard expectedConfig == journal.after.config, expectedAuth == journal.after.auth,
              journal.before.configMode == journal.after.configMode,
              journal.before.authMode == journal.after.authMode else {
            throw ConfigError("备份包含目标字段以外的改动，已拒绝恢复。")
        }
        return journal
    }

    private func saveJournal(_ journal: Journal) throws {
        try SecureFile.write(JSONEncoder().encode(journal), to: journalURL)
    }

    private func locked<T>(_ action: () throws -> T) throws -> T {
        try SecureFile.locked(in: supportDirectory, action)
    }
}
