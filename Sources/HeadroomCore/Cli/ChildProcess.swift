import Darwin
import Foundation

/// A child process with piped stdio, started in its own process group so that the whole tree
/// (e.g. node workers started by a CLI) can be killed at once.
final class ChildProcess: @unchecked Sendable {
    let pid: pid_t
    let name: String
    private let lock = NSLock()
    private var stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private var exitTask: Task<Int32, Never>!

    private init(pid: pid_t, name: String, stdinFD: Int32, stdoutFD: Int32, stderrFD: Int32) {
        self.pid = pid
        self.name = name
        self.stdinFD = stdinFD
        self.stdoutFD = stdoutFD
        self.stderrFD = stderrFD
        exitTask = Task {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).async {
                    var status: Int32 = 0
                    while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                    continuation.resume(returning: ChildProcess.exitCode(fromWaitStatus: status))
                }
            }
        }
    }

    deinit {
        closeStdin()
        close(stdoutFD)
        close(stderrFD)
    }

    /// Starts `executable`. `environment` entries override the inherited environment; nil removes a variable.
    static func spawn(
        executable: String,
        arguments: [String],
        workingDirectory: String? = nil,
        environment: [String: String?] = [:]
    ) throws -> ChildProcess {
        let displayName = (executable as NSString).lastPathComponent
        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            for fd in stdinPipe + stdoutPipe + stderrPipe where fd >= 0 { close(fd) }
            throw UsageProviderError("Failed to start \(displayName): \(String(cString: strerror(errno)))")
        }

        // Our end of each pipe must not leak into the child.
        for fd in [stdinPipe[1], stdoutPipe[0], stderrPipe[0]] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        if let workingDirectory {
            posix_spawn_file_actions_addchdir_np(&actions, workingDirectory)
        }

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // A new process group, no inherited descriptors besides stdio, and default signal handlers
        // (the app ignores SIGPIPE, which would otherwise be inherited).
        var defaultSignals = sigset_t()
        sigfillset(&defaultSignals)
        posix_spawnattr_setsigdefault(&attributes, &defaultSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attributes, &noSignals)
        posix_spawnattr_setpgroup(&attributes, 0)
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment {
            mergedEnvironment[key] = value
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        let envp = mergedEnvironment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard result == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw UsageProviderError("Failed to start \(displayName): \(String(cString: strerror(result)))")
        }

        return ChildProcess(pid: pid, name: displayName, stdinFD: stdinPipe[1], stdoutFD: stdoutPipe[0], stderrFD: stderrPipe[0])
    }

    /// Closing stdin makes interactive CLIs behave as non-interactive and never wait for input.
    func closeStdin() {
        lock.lock()
        defer { lock.unlock() }
        if stdinFD >= 0 {
            close(stdinFD)
            stdinFD = -1
        }
    }

    func write(_ text: String) throws {
        lock.lock()
        defer { lock.unlock() }
        guard stdinFD >= 0 else {
            throw UsageProviderError("\(name) input is closed.")
        }

        var data = Array(text.utf8)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeMutableBytes { buffer in
                Darwin.write(stdinFD, buffer.baseAddress! + offset, buffer.count - offset)
            }
            if written < 0 {
                if errno == EINTR { continue }
                throw UsageProviderError("\(name) connection failed: \(String(cString: strerror(errno)))")
            }
            offset += written
        }
    }

    /// The exit code, or 128 + signal number when the process was killed.
    func waitForExit() async -> Int32 {
        await exitTask.value
    }

    /// Whether the process exits within `seconds`.
    func waitForExit(seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await self.waitForExit(); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first {
                // The waiter cannot be cancelled; kill the process so it returns.
                killTree()
            }
            return first
        }
    }

    /// Kills the whole process group. Best effort: the processes may have exited concurrently.
    func killTree() {
        kill(-pid, SIGKILL)
        kill(pid, SIGKILL)
    }

    /// Reads stdout to the end, keeping at most `limit` bytes.
    func readStandardOutput(limit: Int = 1024 * 1024) async -> String {
        await readAll(stdoutFD, limit: limit)
    }

    /// Reads stderr to the end, keeping at most `limit` bytes.
    func readStandardError(limit: Int = 1024 * 1024) async -> String {
        await readAll(stderrFD, limit: limit)
    }

    /// Lines of stdout, finishing at end of file.
    func standardOutputLines() -> AsyncStream<String> {
        lines(stdoutFD)
    }

    /// Lines of stderr, finishing at end of file.
    func standardErrorLines() -> AsyncStream<String> {
        lines(stderrFD)
    }

    // Readers keep `self` alive so the descriptor is not closed by deinit while being read.
    private func readAll(_ fd: Int32, limit: Int) async -> String {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { withExtendedLifetime(self) {} }
                var collected = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    if collected.count < limit {
                        collected.append(contentsOf: buffer[0..<min(count, limit - collected.count)])
                    }
                }
                continuation.resume(returning: String(decoding: collected, as: UTF8.self))
            }
        }
    }

    private func lines(_ fd: Int32) -> AsyncStream<String> {
        AsyncStream { continuation in
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { withExtendedLifetime(self) {} }
                var pending = [UInt8]()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { break }
                    pending.append(contentsOf: buffer[0..<count])
                    while let newline = pending.firstIndex(of: UInt8(ascii: "\n")) {
                        var line = Array(pending[..<newline])
                        if line.last == UInt8(ascii: "\r") { line.removeLast() }
                        pending.removeSubrange(...newline)
                        continuation.yield(String(decoding: line, as: UTF8.self))
                    }
                    // Guard against a runaway line without a newline.
                    if pending.count > 16 * 1024 * 1024 { pending.removeAll() }
                }
                if !pending.isEmpty {
                    continuation.yield(String(decoding: pending, as: UTF8.self))
                }
                continuation.finish()
            }
        }
    }

    private static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }
}
