import Foundation

/// Non-sensitive information describing one OpenAI-compatible Codex provider.
/// The API key is deliberately not a property of this type; it belongs in KeychainStore.
public struct ProviderProfile: Codable, Equatable, Identifiable {
    public var id: String
    public var name: String
    public var baseURL: String
    public var model: String
    public var providerID: String
    public var keychainService: String
    public var keychainAccount: String

    public init(
        id: String = UUID().uuidString,
        name: String,
        baseURL: String,
        model: String,
        providerID: String? = nil,
        keychainService: String = "com.local.codex-provider-manager.api-key",
        keychainAccount: String? = nil
    ) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.model = model
        self.providerID = providerID ?? ProviderProfile.makeProviderID(from: name, fallback: id)
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount ?? id
    }

    /// Compatibility spelling useful to callers that use provider terminology.
    public var apiBaseURL: String {
        get { baseURL }
        set { baseURL = newValue }
    }

    public func validated() throws -> ProviderProfile {
        let values = [id, name, baseURL, model, providerID, keychainService, keychainAccount]
        guard values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !$0.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) }),
              providerID.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }),
              !["openai", "ollama", "lmstudio", "amazon-bedrock"].contains(providerID) else {
            throw ProviderProfileError.invalidField
        }
        var result = self
        result.baseURL = try Self.normalizedBaseURL(baseURL)
        return result
    }

    /// A host-only URL uses /v1. Custom API paths are kept exactly as supplied.
    public static func normalizedBaseURL(_ value: String) throws -> String {
        guard var components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased())),
              components.port.map({ (1...65535).contains($0) }) ?? true else {
            throw ProviderProfileError.invalidBaseURL
        }
        let path = components.path.split(separator: "/").map(String.init)
        guard !["models", "responses", "chat", "completions"].contains(path.last ?? "") else {
            throw ProviderProfileError.endpointInsteadOfBaseURL
        }
        components.path = path.isEmpty ? "/v1" : "/" + path.joined(separator: "/")
        guard let url = components.url else { throw ProviderProfileError.invalidBaseURL }
        return url.absoluteString
    }

    private static func makeProviderID(from name: String, fallback: String) -> String {
        let scalars = name.lowercased().unicodeScalars.map { scalar -> Character in
            if (scalar.value >= 97 && scalar.value <= 122) || (scalar.value >= 48 && scalar.value <= 57) {
                return Character(String(scalar))
            }
            return "-"
        }
        let value = String(scalars).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        let suffix = fallback.filter { $0.isLetter || $0.isNumber }.prefix(12)
        return "cpm-\(value.isEmpty ? "provider" : value)-\(suffix)"
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, baseURL, apiBaseURL, model, providerID, keychainService, keychainAccount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decode(String.self, forKey: .name)
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? c.decode(String.self, forKey: .apiBaseURL)
        model = try c.decode(String.self, forKey: .model)
        let decodedProviderID = try c.decodeIfPresent(String.self, forKey: .providerID)
        if let decodedProviderID = decodedProviderID { providerID = decodedProviderID } else { providerID = ProviderProfile.makeProviderID(from: name, fallback: id) }
        if let decodedService = try c.decodeIfPresent(String.self, forKey: .keychainService) { keychainService = decodedService } else { keychainService = "com.local.codex-provider-manager.api-key" }
        let decodedAccount = try c.decodeIfPresent(String.self, forKey: .keychainAccount)
        if let decodedAccount = decodedAccount { keychainAccount = decodedAccount } else { keychainAccount = id }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(baseURL, forKey: .baseURL)
        try c.encode(model, forKey: .model)
        try c.encode(providerID, forKey: .providerID)
        try c.encode(keychainService, forKey: .keychainService)
        try c.encode(keychainAccount, forKey: .keychainAccount)
    }
}

public enum ProviderProfileError: LocalizedError, Equatable {
    case invalidField
    case invalidBaseURL
    case endpointInsteadOfBaseURL

    public var errorDescription: String? {
        switch self {
        case .invalidField: return "请填写有效的供应商名称、模型和资料标识；供应商 ID 不能使用 Codex 保留名称"
        case .invalidBaseURL: return "Base URL 必须是 HTTPS 地址（本机地址可用 HTTP），且不能包含账号、查询参数或片段"
        case .endpointInsteadOfBaseURL: return "请填写 API 根地址，例如 https://api.example.com/v1，不要包含 /models 或 /responses 等接口路径"
        }
    }
}
