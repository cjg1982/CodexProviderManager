import Foundation
import Darwin

public enum AtomicConfigWriterError: LocalizedError, Equatable {
    case symbolicLink
    case notRegularFile
    case concurrentModification
    case lockFailed(Int32)
    case backupFailed
    case writeFailed
    case validationFailed
    case rollbackRefused

    public var errorDescription: String? {
        switch self {
        case .symbolicLink: return "配置文件是符号链接，已拒绝修改"
        case .notRegularFile: return "配置路径不是普通文件"
        case .concurrentModification: return "配置已被其他程序修改，请重新操作"
        case .lockFailed: return "无法锁定 Codex 配置，请检查权限和锁文件"
        case .backupFailed: return "无法备份 Codex 配置，未执行修改"
        case .writeFailed: return "无法读写 Codex 配置，请检查文件权限"
        case .validationFailed: return "Codex 未能验证新配置，已恢复修改前状态；请检查 CLI 是否支持 doctor 和命令认证"
        case .rollbackRefused: return "配置被其他程序更改或无法恢复，已停止回滚；请检查配置与备份"
        }
    }
}

/// Single entry point for changing config.toml. The writer never resolves or follows a
/// symlink at the config path, and keeps its lock and temporary files beside the target.
public final class AtomicConfigWriter {
    public let configURL: URL
    public let backupDirectoryURL: URL
    public let lockURL: URL
    private let fileManager: FileManager
    private let editor: CodexConfigEditor
    private static let processLock = NSLock()

    public init(
        configURL: URL? = nil,
        backupDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        editor: CodexConfigEditor = CodexConfigEditor()
    ) {
        self.fileManager = fileManager
        let resolvedConfigURL = configURL ?? CodexLocation.home().appendingPathComponent("config.toml")
        self.configURL = resolvedConfigURL
        self.backupDirectoryURL = backupDirectoryURL ?? resolvedConfigURL.deletingLastPathComponent().appendingPathComponent("backups/provider-switcher", isDirectory: true)
        self.lockURL = self.configURL.deletingLastPathComponent().appendingPathComponent(".config.toml.lock")
        self.editor = editor
    }

    @discardableResult
    public func apply(_ mode: CodexConfigMode, validator: (() -> Bool)? = nil) throws -> URL {
        try withLock {
            let original = try readCurrent()
            let candidate = try editor.edit(original.data, mode: mode)
            return try replace(original: original.data, originalExisted: original.existed, candidate: candidate, validator: validator)
        }
    }

    @discardableResult
    public func write(_ candidate: Data, expectedOriginal: Data? = nil, validator: (() -> Bool)? = nil) throws -> URL {
        try withLock {
            let original = try readCurrent()
            if let expectedOriginal = expectedOriginal, expectedOriginal != original.data { throw AtomicConfigWriterError.concurrentModification }
            return try replace(original: original.data, originalExisted: original.existed, candidate: candidate, validator: validator)
        }
    }

    public func read() throws -> Data { try readCurrent().data }

    private struct Current {
        let data: Data
        let existed: Bool
    }

    private func readCurrent() throws -> Current {
        let parent = configURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        var info = stat()
        if lstat(configURL.path, &info) == 0 {
            if (info.st_mode & S_IFMT) == S_IFLNK { throw AtomicConfigWriterError.symbolicLink }
            if (info.st_mode & S_IFMT) != S_IFREG { throw AtomicConfigWriterError.notRegularFile }
            guard let data = try? Data(contentsOf: configURL, options: [.mappedIfSafe]) else { throw AtomicConfigWriterError.writeFailed }
            return Current(data: data, existed: true)
        }
        if errno != ENOENT { throw AtomicConfigWriterError.writeFailed }
        return Current(data: Data(), existed: false)
    }

    private func replace(original: Data, originalExisted: Bool, candidate: Data, validator: (() -> Bool)?) throws -> URL {
        if candidate == original { return backupURLForNoop() }
        try fileManager.createDirectory(at: backupDirectoryURL, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let backup = backupDirectoryURL.appendingPathComponent("config-\(timestamp())-\(UUID().uuidString).toml")
        try chmodPath(backupDirectoryURL.path, mode: 0o700)
        if originalExisted {
            guard fileManager.createFile(atPath: backup.path, contents: original, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else { throw AtomicConfigWriterError.backupFailed }
            try chmodPath(backup.path, mode: 0o600)
        }

        let parent = configURL.deletingLastPathComponent()
        let temporary = parent.appendingPathComponent(".config.toml.\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporary) }
        guard fileManager.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else { throw AtomicConfigWriterError.writeFailed }
        let fd = open(temporary.path, O_WRONLY | O_TRUNC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AtomicConfigWriterError.writeFailed }
        let bytes = [UInt8](candidate)
        var totalWritten = 0
        let writeSucceeded = bytes.withUnsafeBytes { ptr -> Bool in
            guard let base = ptr.baseAddress else { return bytes.isEmpty }
            while totalWritten < ptr.count {
                let count = Darwin.write(fd, base.advanced(by: totalWritten), ptr.count - totalWritten)
                if count <= 0 { return false }
                totalWritten += count
            }
            return true
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard writeSucceeded, totalWritten == bytes.count, synced else { throw AtomicConfigWriterError.writeFailed }
        try chmodPath(temporary.path, mode: 0o600)
        let latest = try readCurrent()
        guard latest.existed == originalExisted, latest.data == original else {
            throw AtomicConfigWriterError.concurrentModification
        }
        guard rename(temporary.path, configURL.path) == 0 else { throw AtomicConfigWriterError.writeFailed }
        _ = fsyncDirectory(parent.path)
        try chmodPath(configURL.path, mode: 0o600)

        if let validator = validator, !validator() {
            // Roll back only if no other writer changed the candidate underneath us.
            if let current = try? readCurrent(), current.existed, current.data == candidate {
                if !originalExisted {
                    guard unlink(configURL.path) == 0 else { throw AtomicConfigWriterError.rollbackRefused }
                } else {
                    let rollback = parent.appendingPathComponent(".config.toml.rollback.\(UUID().uuidString).tmp")
                    guard fileManager.createFile(atPath: rollback.path, contents: original, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else { throw AtomicConfigWriterError.rollbackRefused }
                    defer { try? fileManager.removeItem(at: rollback) }
                    guard rename(rollback.path, configURL.path) == 0 else { throw AtomicConfigWriterError.rollbackRefused }
                }
                _ = fsyncDirectory(parent.path)
            } else { throw AtomicConfigWriterError.rollbackRefused }
            throw AtomicConfigWriterError.validationFailed
        }
        return backup
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        Self.processLock.lock()
        defer { Self.processLock.unlock() }
        let parent = lockURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        let fd = open(lockURL.path, O_RDWR | O_CREAT | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw AtomicConfigWriterError.lockFailed(errno) }
        defer { close(fd) }
        var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
        guard fcntl(fd, F_SETLKW, &lock) >= 0 else { throw AtomicConfigWriterError.lockFailed(errno) }
        defer {
            lock.l_type = Int16(F_UNLCK)
            _ = fcntl(fd, F_SETLK, &lock)
        }
        return try body()
    }

    private func chmodPath(_ path: String, mode: mode_t) throws {
        guard chmod(path, mode) == 0 else { throw AtomicConfigWriterError.writeFailed }
    }

    private func fsyncDirectory(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return fsync(fd) == 0
    }

    private func timestamp() -> String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
    }

    private func backupURLForNoop() -> URL { backupDirectoryURL.appendingPathComponent("config-unchanged.toml") }
}
