import Foundation
import AppKit

public enum CodexDoctorError: LocalizedError {
    case unavailable
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable: return "找不到 Codex CLI"
        case .failed(let message): return message
        }
    }
}

public protocol CodexManaging: AnyObject {
    func apply(profile: ProviderProfile, apiKey: String, completion: @escaping (Result<Void, Error>) -> Void)
    func restoreOfficial(completion: @escaping (Result<Void, Error>) -> Void)
    func currentProfile(completion: @escaping (Result<ProviderProfile?, Error>) -> Void)
}

/// Coordinates Keychain, config transactions and Codex validation.
public final class CodexDoctor: CodexManaging {
    public static var cliPath: String? { CodexLocation.cliPath() }

    private let writer: AtomicConfigWriter
    private let runner: ProcessRunner

    public init(writer: AtomicConfigWriter = AtomicConfigWriter(), runner: ProcessRunner = ProcessRunner()) {
        self.writer = writer
        self.runner = runner
    }

    public func apply(profile: ProviderProfile, apiKey: String, completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                _ = try profile.validated()
                guard !apiKey.isEmpty else { throw ProviderProbeError.missingAPIKey }
                let keychain = KeychainStore(service: profile.keychainService)
                guard try keychain.contains(account: profile.keychainAccount) else { throw KeychainStoreError.itemNotFound }
                guard Self.cliPath != nil else { throw CodexDoctorError.unavailable }
                _ = try self.writer.apply(.provider(profile), validator: { self.validateCurrentConfig() })
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func restoreOfficial(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard Self.cliPath != nil else { throw CodexDoctorError.unavailable }
                _ = try self.writer.apply(.official, validator: { self.validateCurrentConfig() })
                DispatchQueue.main.async { completion(.success(())) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func currentProfile(completion: @escaping (Result<ProviderProfile?, Error>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try self.writer.read()
                let text = String(data: data, encoding: .utf8) ?? ""
                let profile = try CodexConfigEditor.currentProfile(in: text)
                DispatchQueue.main.async { completion(.success(profile)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    public func validateCurrentConfig() -> Bool {
        guard let cliPath = Self.cliPath else { return false }
        guard let result = try? runner.run(cliPath, arguments: ["doctor", "--json", "--summary"], timeout: 45),
              let data = result.stdout.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let checks = json["checks"] as? [String: Any],
              let config = checks["config.load"] as? [String: Any],
              let status = config["status"] as? String else { return false }
        return status == "ok"
    }

    /// Requests a normal quit and relaunch. It never force-terminates the app.
    public func requestNormalRestart(completion: @escaping (Result<Void, Error>) -> Void) {
        DispatchQueue.main.async {
            let identifiers = ["com.openai.codex", "com.openai.chat"]
            let running = identifiers.lazy.compactMap { NSRunningApplication.runningApplications(withBundleIdentifier: $0).first }.first
            let appURL = running?.bundleURL ?? identifiers.lazy.compactMap { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }.first
            guard let url = appURL else {
                completion(.failure(CodexDoctorError.failed("找不到 ChatGPT/Codex 应用")))
                return
            }
            if let running = running {
                guard running.terminate() else {
                    completion(.failure(CodexDoctorError.failed("应用拒绝正常退出，请手动重启")))
                    return
                }
                let deadline = Date().addingTimeInterval(12)
                func waitForExit() {
                    if running.isTerminated {
                        let configuration = NSWorkspace.OpenConfiguration()
                        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                            if let error = error { completion(.failure(error)) } else { completion(.success(())) }
                        }
                    } else if Date() >= deadline {
                        completion(.failure(CodexDoctorError.failed("应用尚未退出，请稍后手动重新打开")))
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: waitForExit)
                    }
                }
                waitForExit()
            } else {
                let configuration = NSWorkspace.OpenConfiguration()
                NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                    if let error = error { completion(.failure(error)) } else { completion(.success(())) }
                }
            }
        }
    }

}
