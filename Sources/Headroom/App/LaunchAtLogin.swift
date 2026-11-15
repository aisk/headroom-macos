import AppKit
import ServiceManagement

enum LaunchAtLoginState: Equatable {
    case enabled
    case disabled
    /// Registered, but the user has to allow it in System Settings › General › Login Items.
    case requiresApproval
    /// Not running from an app bundle that can be registered (e.g. `swift run`).
    case unavailable
}

/// Registers Headroom as a login item with `SMAppService`.
enum LaunchAtLogin {
    static var state: LaunchAtLoginState {
        guard Bundle.main.bundleIdentifier != nil else {
            return .unavailable
        }
        switch SMAppService.mainApp.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        // An app bundle that was never registered reports notFound rather than notRegistered.
        case .notRegistered, .notFound: return .disabled
        @unknown default: return .disabled
        }
    }

    /// Changes the login item and returns the state macOS actually ended up with.
    @discardableResult
    static func set(_ enabled: Bool) -> LaunchAtLoginState {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Report whatever state macOS ended up with.
        }
        return state
    }

    static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    /// Whether this process was started as a login item rather than by the user.
    static func isLoginLaunch() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication)
        else {
            return false
        }
        return event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == AEEventClass(keyAELaunchedAsLogInItem)
    }
}
