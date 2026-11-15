import Foundation

/// A JSON-RPC error response returned by the CLI.
public struct JsonRpcError: Error, LocalizedError, Sendable {
    public static let methodNotFound = -32601

    public var method: String
    public var code: Int
    public var detail: String

    public var message: String { "\(method): \(detail)" }

    public var errorDescription: String? { message }

    /// The same failure as a user-presentable provider error.
    public var asProviderError: UsageProviderError { UsageProviderError(message) }
}

/// A CLI child process speaking newline-delimited JSON-RPC 2.0 over stdin/stdout
/// (used by `codex app-server` and `grok agent stdio`).
public final class JsonRpcProcess: @unchecked Sendable {
    private let process: ChildProcess
    private let name: String
    private var lines: AsyncStream<String>.Iterator
    private var nextId = 0
    private let stderrLock = NSLock()
    private var stderr = ""

    private init(process: ChildProcess, name: String) {
        self.process = process
        self.name = name
        lines = process.standardOutputLines().makeAsyncIterator()
    }

    public static func start(
        _ executable: String,
        _ arguments: [String],
        displayName: String,
        workingDirectory: String? = nil,
        environment: [String: String?] = [:]
    ) throws -> JsonRpcProcess {
        let process = try ChildProcess.spawn(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            environment: CliProcess.childEnvironment(environment))
        let rpc = JsonRpcProcess(process: process, name: displayName)
        Task.detached { [weak rpc] in
            for await line in process.standardErrorLines() {
                rpc?.appendStderr(line)
            }
        }
        return rpc
    }

    public func notify(_ method: String) throws {
        try write(["jsonrpc": "2.0", "method": .string(method)])
    }

    /// Sends a request and waits for its response, skipping notifications and server requests.
    public func request(_ method: String, _ parameters: JSONValue? = nil, timeout: TimeInterval) async throws -> JSONValue? {
        nextId += 1
        let id = nextId
        var message: [String: JSONValue] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if let parameters {
            message["params"] = parameters
        }

        try write(.object(message))
        let outcome = try await withThrowingTaskGroup(of: JSONValue??.self) { group in
            group.addTask { [self] in .some(try await readResponse(id: id, method: method)) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .none
            }
            let first = try await group.next()!
            group.cancelAll()
            return first
        }

        guard let response = outcome else {
            if Task.isCancelled { throw CancellationError() }
            throw UsageProviderError("\(name) did not answer \(method) within \(Int(timeout))s.")
        }
        return response
    }

    private func readResponse(id: Int, method: String) async throws -> JSONValue? {
        while true {
            guard let line = await lines.next() else {
                if Task.isCancelled { throw CancellationError() }
                let detail = CliProcess.firstLine(lastStderrLine())
                throw UsageProviderError(detail.map { "\(name) exited: \($0)" } ?? "\(name) exited unexpectedly.")
            }

            // Skip non-JSON output, notifications, server-initiated requests and responses to other requests.
            guard let response = JSONValue.tryParse(line)?.objectValue,
                  response["id"]?.intValue == id,
                  response["method"] == nil
            else {
                continue
            }

            if let error = response["error"], error.isObject {
                throw JsonRpcError(
                    method: method,
                    code: error["code"]?.intValue ?? 0,
                    detail: error["message"]?.stringValue ?? error.jsonString)
            }
            return response["result"]
        }
    }

    private func write(_ message: JSONValue) throws {
        try process.write(message.jsonString + "\n")
    }

    private func appendStderr(_ line: String) {
        stderrLock.lock()
        defer { stderrLock.unlock() }
        if stderr.utf8.count < 16 * 1024 {
            stderr += line + "\n"
        }
    }

    private func lastStderrLine() -> String {
        stderrLock.lock()
        let text = stderr
        stderrLock.unlock()
        // The most recent ERROR line is usually the most useful one.
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return lines.last(where: { $0.contains("ERROR") }) ?? lines.last ?? ""
    }

    /// Closing stdin asks the server to shut down; give it a moment before killing it.
    public func close() async {
        process.closeStdin()
        _ = await process.waitForExit(seconds: 2)
        process.killTree()
    }
}

/// Runs `body` with a JSON-RPC server and always shuts the server down afterwards.
func withJsonRpcProcess<T>(
    _ executable: String,
    _ arguments: [String],
    displayName: String,
    _ body: (JsonRpcProcess) async throws -> T
) async throws -> T {
    let rpc = try JsonRpcProcess.start(executable, arguments, displayName: displayName)
    do {
        let result = try await withTaskCancellationHandler {
            try await body(rpc)
        } onCancel: {
            rpc.killNow()
        }
        await rpc.close()
        return result
    } catch {
        await rpc.close()
        throw error
    }
}

extension JsonRpcProcess {
    fileprivate func killNow() {
        process.killTree()
    }
}
