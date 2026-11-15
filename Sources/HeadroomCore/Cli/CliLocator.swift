import Foundation

/// Resolves CLI executables. Apps started from Finder or at login inherit a minimal PATH
/// (`/usr/bin:/bin:/usr/sbin:/sbin`), so the login shell's PATH and common install directories
/// are searched as well.
public enum CliLocator {
    private static let cache = LoginShellPathCache()

    public static func find(_ name: String, overrideEnvironmentVariable: String? = nil) -> String? {
        if let overrideEnvironmentVariable,
           let explicitPath = ProcessInfo.processInfo.environment[overrideEnvironmentVariable],
           !explicitPath.trimmingCharacters(in: .whitespaces).isEmpty
        {
            // An explicit override is authoritative; never fall back to discovery.
            return isExecutable(explicitPath) ? explicitPath : nil
        }

        for directory in searchDirectories() {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if isExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    /// The PATH handed to child processes, so npm shims (`#!/usr/bin/env node`) can find their runtime.
    public static var searchPath: String {
        searchDirectories().joined(separator: ":")
    }

    static func searchDirectories() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let common = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(home)/.npm-global/bin",
            "\(home)/.bun/bin",
            "\(home)/.volta/bin",
            "\(home)/Library/pnpm",
            "/usr/bin",
            "/bin",
        ]

        var seen = Set<String>()
        var directories = [String]()
        for pathList in [inherited, cache.value ?? ""] {
            for raw in pathList.split(separator: ":") {
                append(String(raw), to: &directories, seen: &seen)
            }
        }
        for directory in common {
            append(directory, to: &directories, seen: &seen)
        }
        return directories
    }

    private static func append(_ raw: String, to directories: inout [String], seen: inout Set<String>) {
        let directory = (raw.trimmingCharacters(in: .whitespaces) as NSString).expandingTildeInPath
        // Relative PATH entries would resolve against our working directory; ignore them.
        guard directory.hasPrefix("/"), seen.insert(directory).inserted else {
            return
        }
        directories.append(directory)
    }

    private static func isExecutable(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && !isDirectory.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Reads the PATH a login shell would set up (nvm, Homebrew, etc.) once per app run.
private final class LoginShellPathCache: @unchecked Sendable {
    private let lock = NSLock()
    private var loaded = false
    private var path: String?

    var value: String? {
        lock.lock()
        defer { lock.unlock() }
        if !loaded {
            path = Self.readLoginShellPath()
            loaded = true
        }
        return path
    }

    private static func readLoginShellPath() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        guard FileManager.default.isExecutableFile(atPath: shell) else {
            return nil
        }

        // Markers separate PATH from anything the shell's startup files print.
        let marker = "__HEADROOM_PATH__"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-l", "-i", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
        } catch {
            return nil
        }

        // Never let a slow shell profile block discovery for long.
        let deadline = DispatchTime.now() + 5
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            finished.signal()
        }
        if finished.wait(timeout: deadline) == .timedOut {
            process.terminate()
            return nil
        }

        let text = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let start = text.range(of: marker),
              let end = text.range(of: marker, range: start.upperBound..<text.endIndex)
        else {
            return nil
        }
        return String(text[start.upperBound..<end.lowerBound])
    }
}
