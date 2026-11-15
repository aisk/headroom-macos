import AppKit
import SwiftUI

/// The menu bar icon. A click toggles the usage popover; a right-click (or Control-click) opens
/// the menu with Refresh, Settings and Quit.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: MainViewModel
    private var textTimer: Timer?

    var onSettings: (() -> Void)?
    var onQuit: (() -> Void)?

    init(model: MainViewModel) {
        self.model = model
        super.init()

        let panel = UsagePanelView(
            model: model,
            onSettings: { [weak self] in self?.onSettings?() },
            onQuit: { [weak self] in self?.onQuit?() })
        let hosting = NSHostingController(rootView: panel)
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem.autosaveName = "HeadroomStatusItem"
        update()
    }

    var isPanelShown: Bool { popover.isShown }

    func update() {
        guard let button = statusItem.button else { return }
        button.image = StatusIconRenderer.render(model.statusBars)
        button.toolTip = model.statusTooltip
    }

    // MARK: - Panel

    func togglePanel() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let button = statusItem.button else { return }
        model.refreshTexts()
        if !popover.isShown {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }

        // Opening the panel refreshes stale data without hammering the CLIs.
        if model.refreshOnOpen {
            model.refresh(maxAge: 120)
        }
    }

    func closePanel() {
        popover.performClose(nil)
    }

    func popoverDidShow(_ notification: Notification) {
        // Keep "Resets in…" texts current while the panel is open.
        textTimer?.invalidate()
        textTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.model.refreshTexts() }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        textTimer?.invalidate()
        textTimer = nil
    }

    // MARK: - Menu

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            togglePanel()
        }
    }

    private func showMenu() {
        popover.performClose(nil)
        let menu = NSMenu()
        menu.addItem(item("Show Usage", #selector(menuShowUsage)))
        menu.addItem(item("Refresh Now", #selector(menuRefresh), key: "r"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(menuSettings), key: ","))
        menu.addItem(.separator())
        menu.addItem(item("Quit Headroom", #selector(menuQuit), key: "q"))
        menu.delegate = self

        // Attaching the menu only while it is open keeps left clicks for the popover.
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        statusItem.menu = nil
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func menuShowUsage() {
        // Wait for the menu to finish closing before anchoring the popover to the button.
        DispatchQueue.main.async { self.showPanel() }
    }

    @objc private func menuRefresh() {
        model.refresh(manual: true)
    }

    @objc private func menuSettings() {
        onSettings?()
    }

    @objc private func menuQuit() {
        onQuit?()
    }
}
