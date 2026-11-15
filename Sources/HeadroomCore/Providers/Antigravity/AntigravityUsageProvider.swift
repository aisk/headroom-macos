import Foundation

/// Reads Antigravity quota through the official non-interactive report:
/// `agy -p /usage --output-format json`. The report is a local command, so no model prompt is sent.
public struct AntigravityUsageProvider: UsageProvider {
    // Non-interactive usage reports were introduced in agy 1.1.11.
    private static let minimumVersion = CliVersion(1, 1, 11)
    private static let overrideVariable = "ANTIGRAVITY_CLI_PATH"

    public init() {}

    public var id: String { "antigravity" }

    public var displayName: String { "Antigravity" }

    // A signed-out agy may try to start browser sign-in; only retry when the user asks for it.
    public var pauseAutoRefreshWhenSignedOut: Bool { true }

    public func isInstalled() -> Bool {
        CliLocator.find("agy", overrideEnvironmentVariable: Self.overrideVariable) != nil
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let executable = CliLocator.find("agy", overrideEnvironmentVariable: Self.overrideVariable) else {
            throw UsageProviderError("agy CLI not found. Install Antigravity CLI and run `agy` once to sign in.")
        }

        let probeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("headroom-agy-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: probeDirectory) }

        let environment = makeEnvironment(probeDirectory)
        let versionResult = try await CliProcess.run(
            executable, ["--version"], workingDirectory: probeDirectory.path, environment: environment, timeout: 10)
        // Older builds would treat "/usage" as a model prompt; never risk spending tokens on an unknown version.
        guard let version = CliProcess.parseVersion(versionResult.standardOutput) else {
            throw UsageProviderError("Could not determine the agy version; skipping the usage report.")
        }
        if version < Self.minimumVersion {
            throw UsageProviderError("agy \(version) is too old for usage reports; update to \(Self.minimumVersion) or later.")
        }

        let result = try await CliProcess.run(
            executable, ["-p", "/usage", "--output-format", "json"],
            workingDirectory: probeDirectory.path, environment: environment, timeout: 90)

        guard let json = extractJSONObject(result.standardOutput) else {
            throw AntigravityFailureClassifier.classify(
                exitCode: result.exitCode, output: result.standardOutput + "\n" + result.standardError)
        }
        return try AntigravityUsageParser.parse(json, now: Date(), exitCode: result.exitCode, stderr: result.standardError)
    }

    private func makeEnvironment(_ probeDirectory: URL) -> [String: String?] {
        // A launcher that always fails keeps a background probe from opening browser sign-in tabs.
        // Besides $BROWSER, macOS tools usually run `open` from PATH, so shadow it in the probe directory.
        let launcherDirectory = probeDirectory.appendingPathComponent("bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: launcherDirectory, withIntermediateDirectories: true)
        let failingLauncher = launcherDirectory.appendingPathComponent("no-browser")
        for name in ["no-browser", "open", "xdg-open"] {
            let url = launcherDirectory.appendingPathComponent(name)
            try? "#!/bin/sh\nexit 1\n".write(to: url, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }

        return [
            // Passive probes must never trigger a CLI self-update. agy only accepts the literal "true".
            "AGY_CLI_DISABLE_AUTO_UPDATE": "true",
            "BROWSER": failingLauncher.path,
            "NO_COLOR": "1",
            "PATH": launcherDirectory.path + ":" + CliLocator.searchPath,
        ]
    }
}
