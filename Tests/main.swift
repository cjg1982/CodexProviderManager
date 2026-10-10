import Foundation
import Security

private var failures = 0
private var assertions = 0
private func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) {
    assertions += 1
    let passed: Bool
    do { passed = try condition() } catch { passed = false }
    if !passed {
        failures += 1
        fputs("FAIL: \(message)\n", stderr)
    }
}

private func expectThrows(_ message: String, _ operation: () throws -> Void) {
    do { try operation(); expect(false, message) }
    catch { expect(true, message) }
}

private let source = """
model = "gpt-old"
model_provider = "old"
model_reasoning_effort = "medium"
# [model_providers.comment] must survive

[model_providers.old]
name = "Old"
base_url = "https://old.example/v1"
wire_api = "responses"

[model_providers.old.auth]
command = "/usr/bin/security"
args = ["find-generic-password", "-a", "user", "-s", "old", "-w"]

[projects."/tmp/demo"]
trust_level = "trusted"

[features]
js_repl = false
"""

let profile = ProviderProfile(name: "Flat Test", baseURL: "https://api.example.com/v1", model: "gpt-test", providerID: "flat-test", keychainService: "test-service", keychainAccount: "test-account")

do {
    let applied = try CodexConfigEditor.apply(profile: profile, to: source)
    expect(applied.contains("model = \"gpt-test\""), "third-party model inserted")
    expect(applied.contains("model_provider = \"flat-test\""), "provider selected")
    expect(applied.contains("[model_providers.flat-test.auth]"), "auth table inserted")
    expect(applied.contains("command = \"/usr/bin/security\""), "fixed security command inserted")
    expect(applied.contains("\"-s\", \"test-service\""), "Keychain service referenced")
    expect(applied.contains("model_providers.old"), "unrelated provider preserved")
    expect(applied.contains("[projects.\"/tmp/demo\"]\ntrust_level = \"trusted\""), "project section preserved")
    expect(applied.contains("model_reasoning_effort = \"medium\""), "reasoning preserved")
    expect(applied.contains("# [model_providers.comment] must survive"), "comment preserved")

    let official = try CodexConfigEditor.restoreOfficial(from: applied)
    expect(!official.contains("model_provider ="), "provider selector removed")
    expect(official.contains("[model_providers.flat-test]"), "unused provider definitions preserved")
    expect(!official.contains("model = \"gpt-test\""), "official restore removes vendor-only model override")
    expect(official.contains("[features]\njs_repl = false"), "features preserved")

    let twice = try CodexConfigEditor.restoreOfficial(from: official)
    expect(twice == official, "official restore is idempotent")

    let bracketProfile = ProviderProfile(name: "Bracket", baseURL: "https://api.example.com/v1", model: "vendor[model", providerID: "bracket", keychainService: "test-service", keychainAccount: "test-account")
    let bracketApplied = try CodexConfigEditor.apply(profile: bracketProfile, to: source)
    let bracketOfficial = try CodexConfigEditor.restoreOfficial(from: bracketApplied)
    expect(bracketOfficial.contains("[projects.\"/tmp/demo\"]"), "bracket in model never consumes following config")

    let unknownTable = source + "\n[model_providers_extra]\nkeep = true\n"
    let unknownOfficial = try CodexConfigEditor.restoreOfficial(from: unknownTable)
    expect(unknownOfficial.contains("[model_providers_extra]\nkeep = true"), "similarly named unknown table is preserved")

    let multilineProvider = #"""
model = "old"
model_provider = "old"
[model_providers.old]
name = "Old"
note = """
not a header
[projects.fake]
"""
base_url = "https://old.example/v1"
wire_api = "responses"
[projects.real]
trust_level = "trusted"
"""#
    let multilineApplied = try CodexConfigEditor.apply(profile: profile, to: multilineProvider)
    expect(multilineApplied.contains("not a header"), "unrelated provider multiline value preserved")
    expect(multilineApplied.contains("[projects.real]"), "real table after multiline provider preserved")

    let commentTriple = "# documentation: \"\"\"\n" + source
    let commentRestored = try CodexConfigEditor.restoreOfficial(from: commentTriple)
    expect(!commentRestored.contains("model_provider ="), "triple quote in comment never hides managed keys")

    let multilineModel = #"""
model = """
vendor-model
"""
model_provider = "old"
[model_providers.old]
name = "Old"
base_url = "https://old.example/v1"
wire_api = "responses"
[projects.real]
trust_level = "trusted"
"""#
    let multilineModelRestored = try CodexConfigEditor.restoreOfficial(from: multilineModel)
    expect(!multilineModelRestored.contains("vendor-model"), "multiline model value removed completely")
    expect(multilineModelRestored.contains("[projects.real]"), "config after multiline model remains intact")
} catch {
    failures += 1
    fputs("FAIL: config editor threw \(error)\n", stderr)
}

do {
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpm-test-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let config = temp.appendingPathComponent("config.toml")
    let backups = temp.appendingPathComponent("backups", isDirectory: true)
    try Data(source.utf8).write(to: config)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
    let writer = AtomicConfigWriter(configURL: config, backupDirectoryURL: backups)
    let backup = try writer.apply(.provider(profile), validator: { true })
    expect(FileManager.default.fileExists(atPath: backup.path), "backup created")
    let attrs = try FileManager.default.attributesOfItem(atPath: config.path)
    expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600, "config remains 0600")
    let candidate = try Data(contentsOf: config)
    do {
        _ = try writer.write(Data("model = \"broken\"\n".utf8), expectedOriginal: candidate, validator: { false })
        expect(false, "validator failure should throw")
    } catch {}
    let afterRollback = try Data(contentsOf: config)
    expect(afterRollback == candidate, "validation failure rolls back")

    let firstBackup = try writer.apply(.official, validator: { true })
    let secondBackup = try writer.apply(.provider(profile), validator: { true })
    expect(firstBackup.path != secondBackup.path, "rapid switches use unique backup names")

    let emptyConfig = temp.appendingPathComponent("empty.toml")
    FileManager.default.createFile(atPath: emptyConfig.path, contents: Data())
    let emptyWriter = AtomicConfigWriter(configURL: emptyConfig, backupDirectoryURL: backups)
    do { _ = try emptyWriter.apply(.provider(profile), validator: { false }); expect(false, "empty config validation should fail") }
    catch {}
    expect(FileManager.default.fileExists(atPath: emptyConfig.path), "failed write preserves existing empty config file")
    let emptyAfterRollback = try Data(contentsOf: emptyConfig)
    expect(emptyAfterRollback.isEmpty, "failed write restores zero-byte contents")

    let missingConfig = temp.appendingPathComponent("missing.toml")
    let missingWriter = AtomicConfigWriter(configURL: missingConfig, backupDirectoryURL: backups)
    do { _ = try missingWriter.apply(.provider(profile), validator: { false }); expect(false, "missing config validation should fail") }
    catch {}
    expect(!FileManager.default.fileExists(atPath: missingConfig.path), "failed write preserves previously missing state")

    let runner = ProcessRunner()
    let largeOutput = try runner.run("/usr/bin/python3", arguments: ["-c", "print('x' * 200000); import sys; print('e' * 200000, file=sys.stderr)"], timeout: 15)
    expect(largeOutput.succeeded && largeOutput.stdout.count >= 200000 && largeOutput.stderr.count >= 200000, "process runner drains large stdout and stderr without deadlock")
} catch {
    failures += 1
    fputs("FAIL: atomic writer threw \(error)\n", stderr)
}

do {
    let sameName1 = ProviderProfile(name: "Same", baseURL: "https://api.example.com", model: "model-id")
    let sameName2 = ProviderProfile(name: "Same", baseURL: "https://api.example.com", model: "model-id")
    expect(sameName1.providerID != sameName2.providerID, "identical display names have distinct provider IDs")
    expect(try sameName1.validated().baseURL == "https://api.example.com/v1", "host-only base URL normalized")
    let probe = ProviderProbe()
    for (base, expected) in [("https://api.example.com", "https://api.example.com/v1/models"),
                             ("https://api.example.com/v1/", "https://api.example.com/v1/models"),
                             ("https://api.example.com/gateway/api", "https://api.example.com/gateway/api/models"),
                             ("http://[::1]:8080/v1", "http://[::1]:8080/v1/models")] {
        let actual = try probe.makeEndpoint(baseURL: base, endpointName: "models").absoluteString
        expect(actual == expected, "probe preserves the configured API root")
    }
    for base in ["http://api.example.com", "https://user:pass@api.example.com", "https://api.example.com?key=dummy", "https://api.example.com/v1/responses", "https://api.example.com/#fragment"] {
        expectThrows("rejects unsafe or endpoint-specific base URL") { _ = try ProviderProfile.normalizedBaseURL(base) }
    }
    for reserved in ["openai", "ollama", "lmstudio", "amazon-bedrock", "bad.id"] {
        var invalid = profile; invalid.providerID = reserved
        expectThrows("rejects reserved or invalid provider ID") { _ = try invalid.validated() }
    }
    let quoted = "\"model\" = 'old' # comment\n'model_provider' = \"old\"\n[model_providers . \"flat-test\"]\nname = 'Previous'\n[model_providers . \"flat-test\" . auth]\ncommand = '/bin/false'\n[projects.\"/tmp/a]b\"]\ntrust_level = 'trusted'\n"
    let applied = try CodexConfigEditor.apply(profile: profile, to: quoted)
    expect(!applied.contains("Previous"), "replaces matching quoted provider table and child tables")
    expect(!applied.contains("/bin/false"), "old auth reference removed for replaced provider")
    expect(applied.contains("[projects.\"/tmp/a]b\"]"), "bracket inside quoted table path preserved")
    let imported = try CodexConfigEditor.currentProfile(in: applied)
    expect(imported?.providerID == profile.providerID && imported?.keychainAccount == profile.keychainAccount, "imports current profile and Keychain reference")
    expect(try CodexConfigEditor.currentProfile(in: "[projects.demo]\nmodel_provider = 'other'\nmodel = 'other'\n") == nil, "nested selector is not treated as the active provider")
    let crlf = source.replacingOccurrences(of: "\n", with: "\r\n")
    let crlfApplied = try CodexConfigEditor.apply(profile: profile, to: crlf)
    expect(crlfApplied.contains("[projects.\"/tmp/demo\"]\r\ntrust_level"), "CRLF preserved")
    expect(!crlfApplied.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "no mixed newline endings introduced")
    expectThrows("duplicate quoted root key rejected") { _ = try CodexConfigEditor.apply(profile: profile, to: "model='one'\n\"model\"='two'\n") }
    expectThrows("inline provider map rejected without editing") { _ = try CodexConfigEditor.apply(profile: profile, to: "model_providers = { old = { name = 'Old' } }\n") }
    expectThrows("active named profile cannot silently override switching") { _ = try CodexConfigEditor.apply(profile: profile, to: "profile = 'work'\n" + source) }
    let quotedTriple = "note = '\"\"\"' # quoted documentation\n" + source
    expect(try CodexConfigEditor.restoreOfficial(from: quotedTriple).contains("[projects.\"/tmp/demo\"]"), "triple quotes inside a literal string do not hide table headers")
    let escaped = ProviderProfile(name: "Quote \" and \\ slash", baseURL: "https://api.example.com/custom", model: "model-id", providerID: "escaped", keychainAccount: "a\"b\\c")
    let escapedConfig = try CodexConfigEditor.apply(profile: escaped, to: "")
    let importedEscaped = try CodexConfigEditor.currentProfile(in: escapedConfig)
    expect(importedEscaped?.name == escaped.name && importedEscaped?.keychainAccount == escaped.keychainAccount, "escaped profile metadata round trips")

    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpm-extra-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let store = ProfileStore(fileURL: temp.appendingPathComponent("profiles.json"))
    expect(try store.load().isEmpty, "empty profile store has no bundled providers")
    try store.save([sameName1, sameName2])
    expect(try store.load().count == 2, "multiple profiles persist")
    let metadata = try String(contentsOf: store.fileURL)
    expect(!metadata.contains("apiKey"), "profile JSON contains no API key field")
    var duplicate = sameName1; duplicate.id = UUID().uuidString
    expectThrows("duplicate provider IDs rejected") { try store.save([sameName1, duplicate]) }
    let config = temp.appendingPathComponent("config.toml")
    try Data(source.utf8).write(to: config)
    let writer = AtomicConfigWriter(configURL: config)
    expectThrows("stale snapshot rejected") { _ = try writer.write(Data(), expectedOriginal: Data("stale".utf8)) }
    let link = temp.appendingPathComponent("link.toml")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
    expectThrows("config symlink rejected") { _ = try AtomicConfigWriter(configURL: link).apply(.official) }
    let lock = temp.appendingPathComponent(".config.toml.lock")
    try FileManager.default.removeItem(at: lock)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: config)
    expectThrows("lock symlink rejected") { _ = try writer.apply(.official) }
    try FileManager.default.removeItem(at: lock)
    expectThrows("rollback refuses to overwrite concurrent edits") {
        _ = try writer.apply(.provider(profile), validator: { try? Data("# external edit\n".utf8).write(to: config); return false })
    }
    expect(try String(contentsOf: config) == "# external edit\n", "concurrent edit survives failed validation")
    expect(CodexLocation.home(environment: ["CODEX_HOME": temp.path]) == temp, "custom CODEX_HOME respected")
    expect(CodexLocation.cliPath(environment: ["CODEX_CLI_PATH": "/does/not/exist"]) == nil, "invalid explicit CLI path does not fall back")
    expectThrows("process timeout is enforced") { _ = try ProcessRunner().run("/bin/sleep", arguments: ["2"], timeout: 0.05) }
} catch {
    failures += 1
    fputs("FAIL: regression tests threw \(error)\n", stderr)
}

// Use a private temporary Keychain and dummy values; never read the user's keys.
do {
    SecKeychainSetUserInteractionAllowed(false)
    defer { SecKeychainSetUserInteractionAllowed(true) }
    let temp = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpm-keychain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    let path = temp.appendingPathComponent("tests.keychain-db").path
    let runner = ProcessRunner()
    let created = try runner.run("/usr/bin/security", arguments: ["create-keychain", "-p", "cpm-test-only", path], timeout: 10)
    guard created.succeeded else { throw KeychainStoreError.commandFailed(created.status) }
    defer { _ = try? runner.run("/usr/bin/security", arguments: ["delete-keychain", path], timeout: 10) }
    let keychain = KeychainStore(service: "cpm-test-\(UUID().uuidString)", keychainPath: path)
    expect(try !keychain.contains(account: "dummy"), "fresh isolated Keychain has no key")
    try keychain.setAPIKey("dummy-secret-for-tests", account: "dummy")
    expect(try keychain.apiKey(account: "dummy") == "dummy-secret-for-tests", "Security.framework write and security CLI read round trip")
    try keychain.setAPIKey("dummy-replacement", account: "dummy")
    expect(try keychain.apiKey(account: "dummy") == "dummy-replacement", "Keychain replacement works")
    try keychain.delete(account: "dummy")
    expect(try !keychain.contains(account: "dummy"), "isolated Keychain delete works")
} catch {
    failures += 1
    fputs("FAIL: isolated Keychain test threw \(error)\n", stderr)
}

private final class MockURLProtocol: URLProtocol {
    static var payload = Data()
    static var status = 200
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.payload)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

let mockConfiguration = URLSessionConfiguration.ephemeral
mockConfiguration.protocolClasses = [MockURLProtocol.self]
let mockProbe = ProviderProbe(configuration: mockConfiguration)
func mockedProbe(_ payload: String, responses: Bool = false, status: Int = 200) -> Result<ProbeResult, Error>? {
    MockURLProtocol.payload = Data(payload.utf8); MockURLProtocol.status = status
    var result: Result<ProbeResult, Error>?
    let done: (Result<ProbeResult, Error>) -> Void = { result = $0 }
    if responses { mockProbe.testResponses(profile: profile, apiKey: "dummy-test-key", completion: done) }
    else { mockProbe.testModels(profile: profile, apiKey: "dummy-test-key", completion: done) }
    let deadline = Date().addingTimeInterval(5)
    while result == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    return result
}
if case .success(let result)? = mockedProbe(#"{"data":[{"id":"test-model"}]}"#) {
    expect(result.modelIDs == ["test-model"], "models JSON parsed")
    expect(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "Authorization") == "Bearer dummy-test-key", "probe sends bearer auth only to configured request")
} else { expect(false, "models request succeeds") }
for malformed in ["<html>login</html>", #"{"error":"bad key"}"#, #"{"data":[{"name":"missing ID"}]}"#] {
    if case .failure? = mockedProbe(malformed) { expect(true, "HTTP 200 malformed body rejected") }
    else { expect(false, "HTTP 200 malformed body must fail") }
}
if case .success(let result)? = mockedProbe(#"{"id":"resp_test","status":"completed","output":[{"type":"message"}]}"#, responses: true) {
    expect(result.succeeded, "completed Responses API result accepted")
} else { expect(false, "completed Responses API result should pass") }
for payload in [#"{"id":"resp_test","status":"failed","output":[]}"#, #"{"id":"resp_test","status":"incomplete","output":[]}"#, "{}"] {
    if case .failure? = mockedProbe(payload, responses: true) { expect(true, "failed/incomplete Responses API result rejected") }
    else { expect(false, "failed/incomplete Responses API result must fail") }
}
if case .success(let result)? = mockedProbe("{}", status: 401) { expect(!result.succeeded, "HTTP auth failure reported accurately") }
else { expect(false, "HTTP auth failure should have a status result") }
if case .failure? = mockedProbe(String(repeating: "x", count: 1_048_577)) { expect(true, "oversized response rejected") }
else { expect(false, "oversized response must fail") }

// Validate a generated provider config with the installed Codex parser in an isolated CODEX_HOME.
if let codexCLI = CodexLocation.cliPath() {
    do {
        let home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpm-codex-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let generated = try CodexConfigEditor.apply(profile: profile, to: source)
        try Data(generated.utf8).write(to: home.appendingPathComponent("config.toml"))
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = home.path
        let result = try ProcessRunner().run(codexCLI, arguments: ["doctor", "--json", "--summary"], environment: environment, timeout: 45)
        let data = Data(result.stdout.utf8)
        let errorText = result.stderr
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let checks = json?["checks"] as? [String: Any]
        let config = checks?["config.load"] as? [String: Any]
        // Doctor can exit non-zero when the fake endpoint is intentionally unreachable;
        // config.load is the authoritative parser result for this integration test.
        let configIsValid = config?["status"] as? String == "ok"
        if !configIsValid { fputs("Codex doctor stderr: \(errorText)\nGenerated config:\n\(generated)\n", stderr) }
        expect(configIsValid, "generated config passes Codex parser")
    } catch {
        failures += 1
        fputs("FAIL: Codex integration test threw \(error)\n", stderr)
    }
} else { print("SKIP: Codex parser integration (Codex CLI not installed)") }

if failures == 0 {
    print("All \(assertions) assertions passed")
    exit(0)
}
print("\(failures) test(s) failed")
exit(1)
