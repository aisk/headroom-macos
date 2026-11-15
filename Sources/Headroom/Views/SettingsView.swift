import AppKit
import HeadroomCore
import SwiftUI

/// Settings shown in the window; every change applies immediately.
@MainActor
final class SettingsModel: ObservableObject {
    struct Tool: Identifiable {
        var id: String
        var name: String
    }

    @Published var settings: AppSettings {
        didSet {
            if settings != oldValue {
                onChange?(settings)
            }
        }
    }

    @Published private(set) var launchAtLogin = LaunchAtLogin.state

    let tools: [Tool]

    /// Called after the user changed a setting.
    var onChange: ((AppSettings) -> Void)?

    init(settings: AppSettings, tools: [Tool]) {
        self.settings = settings
        self.tools = tools
    }

    /// The login item can also change in System Settings, so it is re-read whenever the window comes back.
    func reloadLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.state
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLogin = LaunchAtLogin.set(enabled)
    }

    var intervalChoices: [Int] {
        var choices = AppSettings.refreshIntervalChoices
        if !choices.contains(settings.refreshIntervalMinutes) {
            // Keep a value edited by hand in the settings file selectable.
            choices.append(settings.refreshIntervalMinutes)
            choices.sort()
        }
        return choices
    }

    func isEnabled(_ tool: Tool) -> Binding<Bool> {
        Binding(
            get: { self.settings.isProviderEnabled(tool.id) },
            set: { self.settings.setProviderEnabled(tool.id, $0) })
    }
}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin == .enabled || model.launchAtLogin == .requiresApproval },
                    set: { model.setLaunchAtLogin($0) }))
                    .disabled(model.launchAtLogin == .unavailable)

                if let note = launchAtLoginNote {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if model.launchAtLogin == .requiresApproval {
                            Button("Open Login Items Settings…") {
                                LaunchAtLogin.openLoginItemsSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            }

            Section {
                ForEach(model.tools) { tool in
                    Toggle(tool.name, isOn: model.isEnabled(tool))
                }
            } header: {
                Text("Tools")
            } footer: {
                Text("Tools that are turned off are hidden from the panel and the menu bar icon, and their CLI is never run.")
                    .footnoteStyle()
            }

            Section {
                Picker("Account", selection: $model.settings.accountDisplay) {
                    ForEach(AccountDisplay.allCases, id: \.self) { display in
                        Text(display.title).tag(display)
                    }
                }
            } header: {
                Text("Privacy")
            } footer: {
                Text("Controls how signed-in email addresses appear in the panel, for example when sharing your screen. "
                    + "Partially hidden shows \(AccountMasker.mask("name@example.com")).")
                    .footnoteStyle()
            }

            Section {
                Picker("Refresh automatically", selection: $model.settings.refreshIntervalMinutes) {
                    ForEach(model.intervalChoices, id: \.self) { minutes in
                        Text(Formatting.intervalText(minutes)).tag(minutes)
                    }
                }
                Toggle(isOn: $model.settings.refreshOnOpen) {
                    Text("Refresh when the panel opens and the data is more than 2 minutes old")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text("Refresh")
            } footer: {
                Text("The refresh button and the menu always refresh right away.")
                    .footnoteStyle()
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var launchAtLoginNote: String? {
        switch model.launchAtLogin {
        case .requiresApproval:
            return "Headroom needs your approval in System Settings › General › Login Items."
        case .unavailable:
            return "Launch at login is available when Headroom runs from its app bundle."
        case .enabled, .disabled:
            return nil
        }
    }
}

private extension AccountDisplay {
    var title: String {
        switch self {
        case .full: return "Show"
        case .masked: return "Partially hidden"
        case .hidden: return "Hidden"
        }
    }
}

private extension Text {
    /// Section footers read as left-aligned captions, like System Settings.
    func footnoteStyle() -> some View {
        font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Hosts `SettingsView` in a standard titled window.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    let model: SettingsModel

    init(model: SettingsModel) {
        self.model = model
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = [.preferredContentSize]
        let window = NSWindow(contentViewController: hosting)
        window.title = "Headroom Settings"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("HeadroomSettings")
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func bringToFront() {
        guard let window else { return }
        if !window.isVisible {
            window.center()
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        model.reloadLaunchAtLogin()
    }
}
