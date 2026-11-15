# Headroom for macOS

Headroom is a small macOS menu bar app that shows how much quota you have left in your AI coding CLIs: **Antigravity (`agy`)**, **Claude Code**, **Codex**, and **Grok**.

It is a native Swift port of the [Windows Headroom tray app](https://github.com/aisk/headroom), with the same behavior: it does not talk to any vendor server itself. It runs the CLIs you already have installed and signed in, asks them for your usage the same way you would by hand, and shows the result in a popover under the menu bar icon.

## Will this get my account banned, or use up my tokens?

Headroom is designed to avoid both:

- **No unofficial API access.** It never reads your stored credentials, never calls private web endpoints, and never imitates a browser or a CLI. The usage data comes from the vendor's own CLI.
- **No prompts are sent.** Every query is a local command or an account query (see [How it works](#how-it-works)). None of them starts a conversation with a model, so polling uses no tokens and no message quota.
- **Old CLIs are skipped.** On an old CLI, `/usage` might be treated as an ordinary prompt, so Headroom checks the version first (agy ≥ 1.1.11, Claude Code ≥ 2.0) and refuses to run it otherwise.
- **Your setup is left alone.** Probes run with a read-only sandbox (Codex), with hooks and MCP servers disabled for that one process (Claude Code), and with self-updates and browser launches disabled (agy). Your saved settings are not changed. Claude Code transcripts created by the probe are deleted afterwards.
- **Signed-out CLIs are not hammered.** Claude Code's login is checked before `/usage` runs. If agy is signed out, Headroom stops polling it until you press Refresh, so it cannot keep trying to sign in.

The traffic is what the CLI itself sends when you check usage by hand, a few times an hour. This is not a guarantee from any vendor; check their terms if you are unsure.

## How it works

For each tool, Headroom runs one of these commands or protocols, which the CLI provides for reading usage, and parses the output:

| Tool | What Headroom runs |
| --- | --- |
| Antigravity | `agy -p /usage --output-format json`: the CLI's built-in usage report. |
| Claude Code | `claude auth status --json` to check the login, then `claude /usage`: the same `/usage` command you can type in Claude Code. |
| Codex | `codex app-server`: the JSON-RPC server Codex provides for editor integrations, queried with `account/read` and `account/rateLimits/read`. |
| Grok | `grok agent stdio`: Grok's Agent Client Protocol server, queried with its `_x.ai/billing` method. |

Apps started from Finder or at login get a minimal `PATH`, so Headroom also looks in your login shell's `PATH` and in common install directories (`~/.local/bin`, Homebrew, npm, Bun, Volta). Set `ANTIGRAVITY_CLI_PATH` to point at a specific `agy`.

Tools whose CLI is not installed are hidden. By default, usage refreshes every 5 minutes, when the panel is opened with data older than 2 minutes, or on demand from the refresh button or the menu. All of this can be changed in Settings.

## Install

Requires macOS 13 Ventura or later and at least one of the supported CLIs installed and signed in.

Download `Headroom-<version>.dmg` from [Releases](https://github.com/aisk/headroom-macos/releases/latest) and drag Headroom into Applications. The app is a universal binary for Apple silicon and Intel Macs.

The release is ad-hoc signed and not notarized, so macOS blocks the first launch. Open it once anyway from **System Settings › Privacy & Security › Open Anyway**, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/Headroom.app
```

To build it yourself instead:

```sh
make app          # builds build/Headroom.app
cp -R build/Headroom.app /Applications/
open /Applications/Headroom.app
```

Click the menu bar icon to see your usage. Right-click (or Control-click) it for **Show Usage**, **Refresh Now**, **Settings…**, and **Quit Headroom**; the same commands are in the panel's **⋯** menu. In Settings you can make Headroom launch at login, turn off tools you don't want to see (they are then never run), choose how often usage refreshes (including manual only), and show your account email in full, partially hidden, or not at all.

The menu bar icon draws one bar per tool, filled with the quota left in its most constrained window; a bar turns red below 10%. Hover over it for a summary.

## Build

Requires Xcode 16 (Swift 5.10 or later).

```sh
swift build
swift test
scripts/build-app.sh                  # build/Headroom.app, ad-hoc signed
UNIVERSAL=1 scripts/build-app.sh      # Apple silicon + Intel
scripts/build-dmg.sh                  # build/Headroom-<version>.dmg, universal
swift tools/generate-icon.swift       # regenerate the app icon
```

`scripts/build-app.sh` accepts `VERSION`, `BUNDLE_ID`, and `SIGN_IDENTITY` (for example a Developer ID certificate) as environment variables.

## Project layout

- `Sources/HeadroomCore`: CLI discovery, usage providers, and output parsers (no UI).
- `Sources/Headroom`: the AppKit/SwiftUI app: menu bar icon, usage popover, Settings window.
- `Tests/HeadroomCoreTests`: parser and behavior tests based on real CLI output.
- `tools/generate-icon.swift`: draws the app icon.

## License

Headroom is licensed under the [GNU General Public License v3.0](LICENSE).

Headroom is not affiliated with Google, Anthropic, OpenAI, or xAI. Product names are used only to identify the CLIs it works with.
