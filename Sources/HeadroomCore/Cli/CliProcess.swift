import Foundation

public struct CliResult: Sendable {
    public var exitCode: Int32
    public var standardOutput: String
    public var standardError: String
}

/// A "major.minor.patch" version.
public struct CliVersion: Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(_ major: Int, _ minor: Int, _ patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public static func < (lhs: CliVersion, rhs: CliVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// Launches CLI tools with stdin closed and bounded runtime.
public enum CliProcess {
    /// Runs a CLI to completion. The whole process tree is killed afterwards or on timeout.
    public static func run(
        _ executable: String,
        _ arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String?] = [:],
        timeout: TimeInterval
    ) async throws -> CliResult {
        let process = try ChildProcess.spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: childEnvironment(environment))
        process.closeStdin()
        defer { process.killTree() }

        let name = ((executable as NSString).lastPathComponent as NSString).deletingPathExtension
        return try await withTaskCancellationHandler {
            async let stdout = process.readStandardOutput()
            async let stderr = process.readStandardError()
            if await !process.waitForExit(seconds: timeout) {
                _ = await (stdout, stderr)
                if Task.isCancelled { throw CancellationError() }
                throw UsageProviderError("\(name) timed out after \(Int(timeout))s.")
            }

            let exitCode = await process.waitForExit()
            // Helpers left behind by the CLI may keep the pipes open; they are not needed any more.
            process.killTree()
            let result = CliResult(exitCode: exitCode, standardOutput: await stdout, standardError: await stderr)
            if Task.isCancelled { throw CancellationError() }
            return result
        } onCancel: {
            process.killTree()
        }
    }

    /// The inherited environment plus a PATH that includes the discovered CLI directories.
    static func childEnvironment(_ overrides: [String: String?]) -> [String: String?] {
        var environment = overrides
        if environment.index(forKey: "PATH") == nil {
            environment["PATH"] = CliLocator.searchPath
        }
        return environment
    }

    /// Returns the first meaningful line of CLI output, for error messages.
    public static func firstLine(_ text: String?, maxLength: Int = 200) -> String? {
        guard let line = text?
            .split(separator: "\n")
            .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            .first(where: { !$0.isEmpty })
        else {
            return nil
        }
        return line.count <= maxLength ? line : String(line.prefix(maxLength)) + "…"
    }

    /// Parses the leading "major.minor.patch" from version output.
    public static func parseVersion(_ text: String?) -> CliVersion? {
        guard let text,
              let match = text.firstMatch(of: #/(\d+)\.(\d+)(?:\.(\d+))?/#),
              let major = Int(match.1), let minor = Int(match.2)
        else {
            return nil
        }
        return CliVersion(major, minor, match.3.flatMap { Int($0) } ?? 0)
    }
}
