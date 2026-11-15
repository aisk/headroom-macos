# Headroom for macOS

A menu bar app that shows how much quota is left in **Antigravity (`agy`)**, **Claude Code**, **Codex**, and **Grok**. A native Swift port of [Headroom for Windows](https://github.com/aisk/headroom).

Headroom never talks to vendor servers itself and never reads your credentials. It asks the CLIs you already have signed in for their usage, using commands that send no prompts and spend no tokens:

| Tool | What Headroom runs |
| --- | --- |
| Antigravity | `agy -p /usage --output-format json` |
| Claude Code | `claude auth status --json`, then `claude /usage` |
| Codex | `codex app-server` (`account/rateLimits/read`) |
| Grok | `grok agent stdio` (`_x.ai/billing`) |

Old CLI versions that might treat `/usage` as a prompt are skipped, and signed-out CLIs are not polled repeatedly.

## Install

Requires macOS 13 or later. Download `Headroom-<version>.dmg` from [Releases](https://github.com/aisk/headroom-macos/releases/latest) (universal: Apple silicon and Intel) and drag Headroom into Applications.

The app is not notarized by Apple, so macOS refuses to open it at first ("Headroom is damaged" or "cannot be verified"). Remove the download quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/Headroom.app
```

Alternatively, try to open it, then choose **Open Anyway** in **System Settings › Privacy & Security**.

## Usage

Click the menu bar icon to see your usage; right-click it for Refresh, Settings and Quit. The icon shows one bar per tool, which turns red below 10%.

Settings: launch at login, which tools to show, refresh interval, and whether to show your account email in full, partially hidden, or not at all.

## Build

Requires Xcode 16.

```sh
swift test
make app    # build/Headroom.app
make dmg    # build/Headroom-<version>.dmg (universal)
```

## License

[GPL-3.0](LICENSE). Not affiliated with Google, Anthropic, OpenAI, or xAI.
