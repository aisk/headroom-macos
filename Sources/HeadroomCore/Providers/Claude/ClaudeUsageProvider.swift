import Foundation

/// Reads Claude subscription usage by running Claude Code's built-in `/usage` command
/// non-interactively. `/usage` is a local slash command, so it does not send a model prompt.
public struct ClaudeUsageProvider: UsageProvider {
    // Guard against old CLIs that might treat "/usage" as a prompt and spend tokens.
    private static let minimumVersion = CliVersion(2, 0, 0)
    private static let probeDirectoryName = "ClaudeProbe"
    private static let probeSettings = #"{"remoteControlAtStartup":false,"disableAllHooks":true}"#

    public init() {}

    public var id: String { "claude" }

    public var displayName: String { "Claude" }

    public func isInstalled() -> Bool {
        CliLocator.find("claude") != nil
    }

    public func fetch() async throws -> UsageSnapshot {
        guard let executable = CliLocator.find("claude") else {
            throw UsageProviderError("Claude Code not found. Install it and run `claude` once to sign in.")
        }

        let probeDirectory = AppPaths.supportDirectory.appendingPathComponent(Self.probeDirectoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: probeDirectory, withIntermediateDirectories: true)
        let settingsURL = probeDirectory.appendingPathComponent("probe-settings.json")
        try? Self.probeSettings.write(to: settingsURL, atomically: true, encoding: .utf8)
        defer { Self.cleanupProbeTranscripts(probeDirectory) }

        let workingDirectory = probeDirectory.path
        let versionResult = try await CliProcess.run(
            executable, ["--version"], workingDirectory: workingDirectory, timeout: 15)
        guard let version = CliProcess.parseVersion(versionResult.standardOutput) else {
            throw UsageProviderError("Could not determine the Claude Code version; skipping /usage.")
        }
        if version < Self.minimumVersion {
            throw UsageProviderError("Claude Code \(version) is too old for /usage; update to \(Self.minimumVersion) or later.")
        }

        // Check the local login first so a signed-out CLI never runs /usage.
        let authResult = try await CliProcess.run(
            executable, ["auth", "status", "--json"], workingDirectory: workingDirectory, timeout: 15)
        let auth = ClaudeAuthStatus.tryParse(authResult.standardOutput)
        if let auth, !auth.loggedIn {
            throw UsageProviderError("Claude Code is not signed in. Run `claude` and use /login.", kind: .signInRequired)
        }
        if let auth, !auth.isSubscription {
            throw UsageProviderError(
                "Claude Code is signed in with \(auth.authMethod ?? auth.apiProvider ?? "a non-subscription login"); "
                    + "plan usage is only available for claude.ai subscriptions.")
        }

        // --strict-mcp-config skips the user's MCP servers; the settings disable hooks and remote control
        // for this process only, leaving saved settings untouched.
        let result = try await CliProcess.run(
            executable, ["--strict-mcp-config", "--settings", settingsURL.path, "/usage"],
            workingDirectory: workingDirectory, environment: ["NO_COLOR": "1"], timeout: 60)

        var snapshot = try ClaudeUsageParser.parse(result.standardOutput + "\n" + result.standardError, now: Date())
        snapshot.account = auth?.email
        snapshot.plan = auth?.planDisplayName
        return snapshot
    }

    /// Claude Code records every run as a project transcript. Remove the ones created by our dedicated
    /// probe directory so background polling does not clutter the user's history.
    static func cleanupProbeTranscripts(_ probeDirectory: URL) {
        var configDirectory = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"] ?? ""
        if configDirectory.trimmingCharacters(in: .whitespaces).isEmpty {
            configDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude").path
        }

        let projectName = probeProjectName(probeDirectory)
        // Only ever delete the folder that belongs to our own probe directory.
        guard projectName.hasSuffix("-Headroom-" + probeDirectoryName) else {
            return
        }

        let projectDirectory = URL(fileURLWithPath: configDirectory)
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent(projectName, isDirectory: true)
        // Best effort; a leftover transcript is harmless.
        try? FileManager.default.removeItem(at: projectDirectory)
    }

    /// Claude Code names a project folder after its path with every non-alphanumeric character replaced by "-".
    static func probeProjectName(_ probeDirectory: URL) -> String {
        let path = probeDirectory.standardizedFileURL.path
        return String(path.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }
}
