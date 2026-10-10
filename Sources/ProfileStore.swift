import Foundation

public enum ProfileStoreError: Error, Equatable {
    case duplicateID
    case duplicateProviderID
    case invalidProfile
    case unreadable
    case encoding
}

/// Persists only non-sensitive profile metadata under Application Support.
public final class ProfileStore {
    public let fileURL: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL = fileURL {
            self.fileURL = fileURL
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            self.fileURL = support.appendingPathComponent("Codex Provider Manager", isDirectory: true).appendingPathComponent("profiles.json")
        }
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    public func load() throws -> [ProviderProfile] {
        try lock.withLock {
            guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
            let values: [ProviderProfile]
            do { values = try decoder.decode([ProviderProfile].self, from: Data(contentsOf: fileURL)) }
            catch { throw ProfileStoreError.unreadable }
            try validate(values)
            return values
        }
    }

    public func save(_ profiles: [ProviderProfile]) throws {
        try lock.withLock {
            try validate(profiles)
            let data: Data
            do { data = try encoder.encode(profiles.map { try $0.validated() }) } catch { throw ProfileStoreError.encoding }
            let directory = fileURL.deletingLastPathComponent()
            try makeDirectory(directory)
            try setPermissions(directory, mode: 0o700)
            let temporary = directory.appendingPathComponent(".profiles.\(UUID().uuidString).tmp")
            defer { try? fileManager.removeItem(at: temporary) }
            guard fileManager.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]) else {
                throw ProfileStoreError.encoding
            }
            try setPermissions(temporary, mode: 0o600)
            if fileManager.fileExists(atPath: fileURL.path) {
                _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary, backupItemName: nil, options: .usingNewMetadataOnly)
            } else {
                try fileManager.moveItem(at: temporary, to: fileURL)
            }
            try setPermissions(fileURL, mode: 0o600)
        }
    }

    public func addOrUpdate(_ profile: ProviderProfile) throws {
        var profiles = try load()
        guard (try? profile.validated()) != nil else { throw ProfileStoreError.invalidProfile }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) { profiles[index] = profile } else { profiles.append(profile) }
        try save(profiles)
    }

    public func remove(id: String) throws {
        try save(try load().filter { $0.id != id })
    }

    private func validate(_ profiles: [ProviderProfile]) throws {
        var ids = Set<String>()
        var providerIDs = Set<String>()
        for profile in profiles {
            guard (try? profile.validated()) != nil else { throw ProfileStoreError.invalidProfile }
            guard ids.insert(profile.id).inserted else { throw ProfileStoreError.duplicateID }
            guard providerIDs.insert(profile.providerID).inserted else { throw ProfileStoreError.duplicateProviderID }
        }
    }

    private func makeDirectory(_ url: URL) throws {
        try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
    }

    private func setPermissions(_ url: URL, mode: Int16) throws {
        do {
            try fileManager.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        } catch {
            throw ProfileStoreError.encoding
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }; return try body()
    }
}
