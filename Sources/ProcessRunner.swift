import Foundation
import Darwin

public struct ProcessResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
    public var succeeded: Bool { status == 0 }
}

public enum ProcessRunnerError: LocalizedError {
    case executableNotFound(String)
    case launchFailed(Error)
    case timedOut(String)

    public var errorDescription: String? {
        switch self {
        case .executableNotFound(let path): return "找不到可执行文件：\(path)"
        case .launchFailed(let error): return "启动进程失败：\(error.localizedDescription)"
        case .timedOut(let executable): return "进程超时：\(executable)"
        }
    }
}

/// Runs a fixed executable without a shell. Output is redirected to temporary files rather
/// than pipes, so descendants cannot deadlock the parent by inheriting a pipe write handle.
public final class ProcessRunner {
    public init() {}

    @discardableResult
    public func run(_ executable: String, arguments: [String] = [], environment: [String: String]? = nil, timeout: TimeInterval = 30) throws -> ProcessResult {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("cpm-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let stdoutURL = directory.appendingPathComponent("stdout")
        let stderrURL = directory.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { stdoutHandle.closeFile(); stderrHandle.closeFile() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let environment = environment { process.environment = environment }
        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle
        do {
            try process.run()
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
            throw ProcessRunnerError.executableNotFound(executable)
        } catch {
            throw ProcessRunnerError.launchFailed(error)
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.03) }
        if process.isRunning {
            process.terminate()
            let grace = Date().addingTimeInterval(1)
            while process.isRunning && Date() < grace { Thread.sleep(forTimeInterval: 0.03) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            throw ProcessRunnerError.timedOut(executable)
        }
        stdoutHandle.synchronizeFile(); stderrHandle.synchronizeFile()
        let output = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let errors = (try? Data(contentsOf: stderrURL)) ?? Data()
        return ProcessResult(status: process.terminationStatus,
                             stdout: String(data: output, encoding: .utf8) ?? "",
                             stderr: String(data: errors, encoding: .utf8) ?? "")
    }

    public static func executableURL(named name: String) -> URL? {
        let candidates = ["/usr/bin/\(name)", "/bin/\(name)", "/usr/local/bin/\(name)", "/opt/homebrew/bin/\(name)"]
        return candidates.lazy.map(URL.init(fileURLWithPath:)).first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}
