import Foundation

public enum CodexConfigEditorError: LocalizedError, Equatable {
    case invalidUTF8
    case malformedTarget
    case invalidProviderID
    case invalidProfile
    case activeProfile

    public var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Codex 配置不是 UTF-8 文件"
        case .malformedTarget: return "配置包含重复或不支持的供应商写法；请使用独立的 [model_providers.<id>] 表"
        case .invalidProviderID, .invalidProfile: return "供应商资料或标识无效"
        case .activeProfile: return "配置启用了命名 profile，可能覆盖切换结果；请先取消顶层 profile 设置后再切换"
        }
    }
}

public enum CodexConfigMode {
    case official
    case provider(ProviderProfile)
}

/// Byte-preserving editor for the small part of config.toml owned by this app.
/// It intentionally does not parse/re-serialize the complete TOML document.
public struct CodexConfigEditor {
    public init() {}

    public func edit(_ data: Data, mode: CodexConfigMode) throws -> Data {
        guard let text = String(data: data, encoding: .utf8) else { throw CodexConfigEditorError.invalidUTF8 }
        let result: String
        switch mode {
        case .official: result = try Self.restoreOfficial(from: text)
        case .provider(let profile): result = try Self.apply(profile: profile, to: text)
        }
        return Data(result.utf8)
    }

    public static func apply(profile: ProviderProfile, to text: String) throws -> String {
        guard let profile = try? profile.validated(), validBareKey(profile.providerID) else { throw CodexConfigEditorError.invalidProfile }
        return try transform(text: text, provider: profile)
    }

    public static func applyThirdParty(profile: ProviderProfile, to text: String) throws -> String {
        try apply(profile: profile, to: text)
    }

    public static func restoreOfficial(from text: String) throws -> String {
        try transform(text: text, provider: nil)
    }

    public static func removeThirdPartyProvider(from text: String) throws -> String {
        try restoreOfficial(from: text)
    }

    public static func apply(profile: ProviderProfile, to data: Data) throws -> Data {
        try CodexConfigEditor().edit(data, mode: .provider(profile))
    }

    public static func restoreOfficial(from data: Data) throws -> Data {
        try CodexConfigEditor().edit(data, mode: .official)
    }

    private struct Line {
        let content: String
        let ending: String
        var full: String { content + ending }
    }

    private static func transform(text: String, provider: ProviderProfile?) throws -> String {
        let lines = splitLines(text)
        var blocksToRemove = Set<Int>()
        var multiline: Character? = nil
        var providerBlockStart: Int? = nil
        for (index, line) in lines.enumerated() {
            let code = stripComment(line.content, multiline: multiline)
            if multiline == nil, let header = tableHeader(code) {
                if let start = providerBlockStart {
                    for i in start..<index { blocksToRemove.insert(i) }
                    providerBlockStart = nil
                }
                if let provider = provider, header.count >= 2,
                   header[0] == "model_providers", header[1] == provider.providerID {
                    providerBlockStart = index
                }
            }
            multiline = updateMultilineState(in: code, current: multiline)
        }
        if let start = providerBlockStart {
            for i in start..<lines.count { blocksToRemove.insert(i) }
        }

        var targetStarts: [(index: Int, key: String)] = []
        var root = true
        multiline = nil
        for (index, line) in lines.enumerated() {
            let code = stripComment(line.content, multiline: multiline)
            if multiline == nil, tableHeader(code) != nil {
                root = false
            }
            if root && multiline == nil, let path = assignment(code)?.key, path.first == "model_providers" {
                // Inline/dotted provider definitions need a full TOML rewrite. Refuse
                // rather than create conflicting definitions or remove unknown settings.
                throw CodexConfigEditorError.malformedTarget
            }
            if root && multiline == nil, assignment(code)?.key == ["profile"] { throw CodexConfigEditorError.activeProfile }
            if root && multiline == nil, let key = targetKey(code) {
                targetStarts.append((index, key))
            }
            multiline = updateMultilineState(in: code, current: multiline)
        }

        var seenKeys = Set<String>()
        for target in targetStarts {
            guard seenKeys.insert(target.key).inserted else { throw CodexConfigEditorError.malformedTarget }
        }
        var remove = blocksToRemove
        for target in targetStarts { remove.insert(target.index) }
        for target in targetStarts {
            let end = valueEnd(lines: lines, start: target.index)
            for i in (target.index + 1)..<end { remove.insert(i) }
        }

        let retained = lines.indices.filter { !remove.contains($0) }.map { lines[$0] }
        guard let provider = provider else { return retained.map { $0.full }.joined() }

        let ending = lineEnding(lines)
        var firstTable = retained.count
        var state: Character? = nil
        for (index, line) in retained.enumerated() {
            let code = stripComment(line.content, multiline: state)
            if state == nil, tableHeader(code) != nil { firstTable = index; break }
            state = updateMultilineState(in: code, current: state)
        }

        var output: [String] = [canonicalRoot(provider: provider, lineEnding: ending)]
        output.append(contentsOf: retained[..<firstTable].map { $0.full })
        if let last = output.last, !last.isEmpty, !last.hasSuffix("\n") { output.append(ending) }
        output.append(providerBlock(provider, lineEnding: ending))
        if firstTable < retained.count { output.append(contentsOf: retained[firstTable...].map { $0.full }) }
        return output.joined()
    }

    private static func canonicalRoot(provider: ProviderProfile?, lineEnding: String) -> String {
        guard let provider = provider else { return "" }
        return "model = \"\(escape(provider.model))\"\(lineEnding)model_provider = \"\(escape(provider.providerID))\"\(lineEnding)"
    }

    private static func providerBlock(_ profile: ProviderProfile, lineEnding: String) -> String {
        let baseURL = profile.baseURL.hasSuffix("/") ? String(profile.baseURL.dropLast()) : profile.baseURL
        return "[model_providers.\(profile.providerID)]\(lineEnding)" +
            "name = \"\(escape(profile.name))\"\(lineEnding)" +
            "base_url = \"\(escape(baseURL))\"\(lineEnding)" +
            "wire_api = \"responses\"\(lineEnding)\(lineEnding)" +
            "[model_providers.\(profile.providerID).auth]\(lineEnding)" +
            "command = \"/usr/bin/security\"\(lineEnding)" +
            "args = [\"find-generic-password\", \"-a\", \"\(escape(profile.keychainAccount))\", \"-s\", \"\(escape(profile.keychainService))\", \"-w\"]\(lineEnding)"
    }

    private static func splitLines(_ text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        // Foundation splitting also handles CRLF, a single Swift Character.
        let parts = text.components(separatedBy: "\n")
        return parts.enumerated().compactMap { index, part in
            if index == parts.count - 1 {
                return part.isEmpty ? nil : Line(content: part, ending: "")
            }
            return Line(content: part.hasSuffix("\r") ? String(part.dropLast()) : part,
                        ending: part.hasSuffix("\r") ? "\r\n" : "\n")
        }
    }

    private static func lineEnding(_ lines: [Line]) -> String { lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n" }

    private static func targetKey(_ code: String) -> String? {
        guard let key = assignment(code)?.key, key.count == 1,
              ["model_provider", "model"].contains(key[0]) else { return nil }
        return key[0]
    }

    private static func valueEnd(lines: [Line], start: Int) -> Int {
        guard lines.indices.contains(start) else { return lines.count }
        let firstCode = stripComment(lines[start].content, multiline: nil)
        var multiline = updateMultilineState(in: firstCode, current: nil)
        guard multiline != nil else { return min(start + 1, lines.count) }
        var index = start + 1
        while index < lines.count {
            let code = stripComment(lines[index].content, multiline: multiline)
            multiline = updateMultilineState(in: code, current: multiline)
            index += 1
            if multiline == nil { return index }
        }
        return lines.count
    }

    private static func tableHeader(_ code: String) -> [String]? {
        let t = code.trimmingCharacters(in: .whitespaces)
        let count = t.hasPrefix("[[") ? 2 : 1
        guard t.hasPrefix("["), t.hasSuffix(String(repeating: "]", count: count)), t.count > count * 2 else { return nil }
        return keyPath(String(t.dropFirst(count).dropLast(count)))
    }

    private static func assignment(_ code: String) -> (key: [String], value: String)? {
        var quote: Character? = nil
        var escaped = false
        for i in code.indices {
            let ch = code[i]
            if escaped { escaped = false; continue }
            if quote == "\"", ch == "\\" { escaped = true; continue }
            if let active = quote { if ch == active { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "=" {
                guard let key = keyPath(String(code[..<i])) else { return nil }
                return (key, String(code[code.index(after: i)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    private static func keyPath(_ text: String) -> [String]? {
        var parts: [String] = []
        var start = text.startIndex
        var quote: Character? = nil
        var escaped = false
        for i in text.indices {
            let ch = text[i]
            if escaped { escaped = false; continue }
            if quote == "\"", ch == "\\" { escaped = true; continue }
            if let active = quote { if ch == active { quote = nil }; continue }
            if ch == "\"" || ch == "'" { quote = ch; continue }
            if ch == "." { parts.append(String(text[start..<i])); start = text.index(after: i) }
        }
        guard quote == nil else { return nil }
        parts.append(String(text[start...]))
        var result: [String] = []
        for part in parts {
            let value = part.trimmingCharacters(in: .whitespaces)
            if let decoded = stringValue(value) { result.append(decoded) }
            else if validBareKey(value) { result.append(value) }
            else { return nil }
        }
        return result
    }

    private static func stringValue(_ value: String) -> String? {
        if value.hasPrefix("'"), value.hasSuffix("'"), value.count >= 2 {
            return String(value.dropFirst().dropLast())
        }
        guard value.hasPrefix("\""), value.hasSuffix("\""),
              let data = ("[" + value + "]").data(using: .utf8),
              let array = try? JSONSerialization.jsonObject(with: data) as? [String] else { return nil }
        return array.first
    }

    /// Reads only provider metadata and a Keychain reference, never bearer tokens.
    public static func currentProfile(in text: String) throws -> ProviderProfile? {
        var section: [String] = []
        var fields: [[String]: [String: String]] = [:]
        var state: Character? = nil
        for line in splitLines(text) {
            let code = stripComment(line.content, multiline: state)
            if state == nil {
                if let header = tableHeader(code) { section = header }
                else if let pair = assignment(code), pair.key.count == 1 { fields[section, default: [:]][pair.key[0]] = pair.value }
            }
            state = updateMultilineState(in: code, current: state)
        }
        guard let raw = fields[[]]?["model_provider"] else { return nil }
        guard let providerID = stringValue(raw) else { throw CodexConfigEditorError.malformedTarget }
        if providerID == "openai" { return nil }
        let block = fields[["model_providers", providerID]] ?? [:]
        guard let base = block["base_url"].flatMap(stringValue),
              let model = fields[[]]?["model"].flatMap(stringValue) else { throw CodexConfigEditorError.malformedTarget }
        let auth = fields[["model_providers", providerID, "auth"]] ?? [:]
        let args = auth["args"].flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String] } ?? []
        func argument(_ key: String) -> String? {
            guard let i = args.firstIndex(of: key), args.indices.contains(i + 1) else { return nil }
            return args[i + 1]
        }
        return try ProviderProfile(name: block["name"].flatMap(stringValue) ?? providerID, baseURL: base, model: model,
                                   providerID: providerID, keychainService: argument("-s") ?? "com.local.codex-provider-manager.api-key",
                                   keychainAccount: argument("-a")).validated()
    }

    private static func stripComment(_ input: String, multiline: Character?) -> String {
        scanLine(input, current: multiline).code
    }

    private static func updateMultilineState(in input: String, current: Character?) -> Character? {
        scanLine(input, current: current).multiline
    }

    private static func scanLine(_ input: String, current: Character?) -> (code: String, multiline: Character?) {
        let chars = Array(input)
        var multiline = current
        var quote: Character? = nil
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            if let active = multiline {
                if active == "\"", ch == "\\" { i += 2; continue }
                if ch == active, i + 2 < chars.count, chars[i + 1] == active, chars[i + 2] == active {
                    multiline = nil
                    i += 3
                    // TOML permits one or two extra quotes at the end of a multiline string.
                    for _ in 0..<2 { if i < chars.count && chars[i] == active { i += 1 } }
                    continue
                }
            } else if let active = quote {
                if active == "\"", ch == "\\" { i += 2; continue }
                if ch == active { quote = nil }
            } else {
                if ch == "#" { return (String(chars[..<i]), multiline) }
                if ch == "\"" || ch == "'" {
                    if i + 2 < chars.count, chars[i + 1] == ch, chars[i + 2] == ch { multiline = ch; i += 3; continue }
                    quote = ch
                }
            }
            i += 1
        }
        return (input, multiline)
    }

    private static func validBareKey(_ value: String) -> Bool {
        !value.isEmpty && value.unicodeScalars.allSatisfy { ($0.value >= 48 && $0.value <= 57) || ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) || $0.value == 45 || $0.value == 95 }
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
    }

}
