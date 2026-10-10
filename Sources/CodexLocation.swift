import Foundation

/// Shared by the application and integration tests; never reads auth.json.
public enum CodexLocation {
    public static func home(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let path = environment["CODEX_HOME"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex", isDirectory: true)
    }

    public static func cliPath(environment: [String: String] = ProcessInfo.processInfo.environment,
                               fileManager: FileManager = .default) -> String? {
        var candidates: [String] = []
        if let override = environment["CODEX_CLI_PATH"], !override.isEmpty {
            // An invalid explicit override must not silently select a different binary.
            return fileManager.isExecutableFile(atPath: override) ? override : nil
        }
        for prefix in ["/Applications", NSHomeDirectory() + "/Applications"] {
            candidates += [
                prefix + "/Codex.app/Contents/Resources/codex",
                prefix + "/Codex.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex",
                prefix + "/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"
            ]
        }
        candidates += ["/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        candidates += (environment["PATH"] ?? "").split(separator: ":").map { String($0) + "/codex" }
        return candidates.first { fileManager.isExecutableFile(atPath: $0) }
    }
}
