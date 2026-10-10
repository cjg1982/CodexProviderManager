import Foundation
import Security

public enum KeychainStoreError: LocalizedError, Equatable {
    case invalidInput
    case itemNotFound
    case commandFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "钥匙串参数无效"
        case .itemNotFound: return "钥匙串中没有保存 API Key"
        case .commandFailed(let status): return "macOS 钥匙串操作失败（状态 \(status)）"
        }
    }
}

/// Stores secrets with Security.framework, never command-line arguments or temp files.
/// The item trusts /usr/bin/security so Codex can retrieve the key directly.
public final class KeychainStore {
    public let service: String
    private let lock = NSLock()
    private let executable = "/usr/bin/security"
    private let keychainPath: String?

    public init(service: String = "com.local.codex-provider-manager.api-key", keychainPath: String? = nil) {
        self.service = service
        self.keychainPath = keychainPath
    }

    public func setAPIKey(_ key: String, account: String) throws {
        try validate(account: account, key: key)
        try lock.withLock {
            var trusted: SecTrustedApplication?
            var status = SecTrustedApplicationCreateFromPath(executable, &trusted)
            guard status == errSecSuccess, let trustedApplication = trusted else { throw KeychainStoreError.commandFailed(status) }
            var current: SecTrustedApplication?
            status = SecTrustedApplicationCreateFromPath(nil, &current)
            guard status == errSecSuccess, let currentApplication = current else { throw KeychainStoreError.commandFailed(status) }
            var access: SecAccess?
            status = SecAccessCreate("Codex Provider Manager API Key" as CFString, [trustedApplication, currentApplication] as CFArray, &access)
            guard status == errSecSuccess, let itemAccess = access else { throw KeychainStoreError.commandFailed(status) }
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                        kSecAttrAccount as String: account, kSecAttrService as String: service]
            var keychain: SecKeychain?
            if let path = keychainPath {
                status = SecKeychainOpen(path, &keychain)
                guard status == errSecSuccess, let selected = keychain else { throw KeychainStoreError.commandFailed(status) }
                query[kSecMatchSearchList as String] = [selected]
            }
            let attributes: [String: Any] = [kSecValueData as String: Data(key.utf8), kSecAttrAccess as String: itemAccess]
            // Preserve the existing ACL on update; replacing it can require a separate
            // macOS authorization dialog even when updating an item we created.
            status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data(key.utf8)] as CFDictionary)
            if status == errSecItemNotFound {
                query.removeValue(forKey: kSecMatchSearchList as String)
                if let keychain = keychain { query[kSecUseKeychain as String] = keychain }
                query.merge(attributes) { _, new in new }
                status = SecItemAdd(query as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw KeychainStoreError.commandFailed(status) }
        }
    }

    public func apiKey(account: String) throws -> String {
        try validate(account: account, key: nil)
        return try lock.withLock {
            let result = try run(arguments: ["find-generic-password", "-a", account, "-s", service, "-w"], stdin: nil)
            guard result.status == 0 else {
                if result.status == 44 { throw KeychainStoreError.itemNotFound }
                throw KeychainStoreError.commandFailed(result.status)
            }
            guard let value = String(data: result.output, encoding: .utf8)?.trimmingCharacters(in: .newlines), !value.isEmpty else {
                throw KeychainStoreError.itemNotFound
            }
            return value
        }
    }

    public func contains(account: String) throws -> Bool {
        try validate(account: account, key: nil)
        return try lock.withLock {
            let result = try run(arguments: ["find-generic-password", "-a", account, "-s", service], stdin: nil)
            if result.status == 0 { return true }
            if result.status == 44 { return false }
            throw KeychainStoreError.commandFailed(result.status)
        }
    }

    public func delete(account: String) throws {
        try validate(account: account, key: nil)
        try lock.withLock {
            let result = try run(arguments: ["delete-generic-password", "-a", account, "-s", service], stdin: nil)
            guard result.status == 0 || result.status == 44 else { throw KeychainStoreError.commandFailed(result.status) }
        }
    }

    public func set(_ value: String, account: String) throws { try setAPIKey(value, account: account) }
    public func get(account: String) throws -> String { try apiKey(account: account) }
    public func exists(account: String) throws -> Bool { try contains(account: account) }

    private func validate(account: String, key: String?) throws {
        let values = [account, service] + (key.map { [$0] } ?? [])
        guard values.allSatisfy({ !$0.isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }) else {
            throw KeychainStoreError.invalidInput
        }
    }

    private func run(arguments: [String], stdin: Data?) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments + (keychainPath.map { [$0] } ?? [])
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        var inputPipe: Pipe?
        if let stdin = stdin {
            let pipe = Pipe()
            inputPipe = pipe
            process.standardInput = pipe
            try process.run()
            pipe.fileHandleForWriting.write(stdin)
            pipe.fileHandleForWriting.closeFile()
        } else {
            try process.run()
        }
        process.waitUntilExit()
        _ = errors.fileHandleForReading.readDataToEndOfFile() // deliberately discarded; may contain metadata
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = inputPipe
        return (process.terminationStatus, data)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
