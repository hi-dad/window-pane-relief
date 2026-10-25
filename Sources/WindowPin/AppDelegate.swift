import AppKit
import Carbon.HIToolbox
import ScreenCaptureKit
import Sparkle

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var pins: [PinnedWindow] = []
    private var hotKey: HotKey?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Updates.start()
        setUpStatusItem()

        hotKey = HotKey(keyCode: kVK_ANSI_P, modifiers: controlKey | optionKey) { [weak self] in
            self?.togglePinOnFrontWindow()
        }
        if hotKey == nil { debugLog("couldn't register ⌃⌥P; another app may be using it") }

        if !Permissions.hasScreenRecording { Permissions.requestScreenRecording() }
        if !Permissions.hasAccessibility { Permissions.requestAccessibility() }

        if debugEnabled {
            debugLog("screen recording allowed: \(Permissions.hasScreenRecording), accessibility allowed: \(Permissions.hasAccessibility)")
            for window in WindowCatalog.onScreenWindows() {
                debugLog("window \(window.id): \(window.ownerName) — \"\(window.title)\"")
            }
        }
    }

    // MARK: Menu

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Window Pane Relief")
        image?.isTemplate = true
        item.button?.image = image

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time the menu opens, so the window list is current.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let frontItem = NSMenuItem(title: "Pin Front Window", action: #selector(pinFrontWindow), keyEquivalent: "p")
        frontItem.keyEquivalentModifierMask = [.control, .option]
        frontItem.target = self
        menu.addItem(frontItem)

        if !pins.isEmpty {
            menu.addItem(.separator())
            menu.addItem(header("Pinned"))
            for pin in pins {
                let item = NSMenuItem(title: "Unpin \(pin.target.menuTitle)", action: #selector(unpinItem(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = pin
                item.image = appIcon(for: pin.target.ownerPID)
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())
        menu.addItem(header("Pin a Window"))
        let pinnedIDs = Set(pins.map(\.target.id))
        let windows = WindowCatalog.onScreenWindows().filter { !pinnedIDs.contains($0.id) }
        if windows.isEmpty {
            menu.addItem(header("No windows found"))
        }
        for window in windows.sorted(by: { $0.menuTitle.localizedCaseInsensitiveCompare($1.menuTitle) == .orderedAscending }) {
            let item = NSMenuItem(title: window.menuTitle, action: #selector(pinItem(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = WindowBox(window)
            item.image = appIcon(for: window.ownerPID)
            menu.addItem(item)
        }

        menu.addItem(.separator())
        if !Permissions.hasScreenRecording {
            let item = NSMenuItem(title: "Screen Recording: not allowed (click to fix)", action: #selector(openScreenRecording), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if !Permissions.hasAccessibility {
            let item = NSMenuItem(title: "Accessibility: not allowed (click to fix)", action: #selector(openAccessibility), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        let update = NSMenuItem(title: "Check for Updates…", action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)), keyEquivalent: "")
        update.target = Updates.controller
        menu.addItem(update)
        menu.addItem(NSMenuItem(title: "Quit Window Pane Relief", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func header(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func appIcon(for pid: pid_t) -> NSImage? {
        guard let icon = NSRunningApplication(processIdentifier: pid)?.icon?.copy() as? NSImage else { return nil }
        icon.size = NSSize(width: 16, height: 16)
        return icon
    }

    @objc private func pinItem(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? WindowBox else { return }
        pin(box.window)
    }

    @objc private func unpinItem(_ sender: NSMenuItem) {
        (sender.representedObject as? PinnedWindow)?.close()
    }

    @objc private func pinFrontWindow() {
        guard let window = WindowCatalog.frontWindow() else {
            NSSound.beep()
            return
        }
        pin(window)
    }

    @objc private func openScreenRecording() {
        Permissions.openScreenRecordingSettings()
    }

    @objc private func openAccessibility() {
        Permissions.requestAccessibility()
        Permissions.openAccessibilitySettings()
    }

    // MARK: Pinning

    /// The keyboard shortcut pins the window you're looking at, or unpins it if it's pinned.
    private func togglePinOnFrontWindow() {
        guard let window = WindowCatalog.frontWindow() else {
            NSSound.beep()
            return
        }
        if let existing = pins.first(where: { $0.target.id == window.id }) {
            existing.close()
        } else {
            pin(window)
        }
    }

    private func pin(_ target: AppWindow) {
        guard !pins.contains(where: { $0.target.id == target.id }) else { return }
        guard Permissions.hasScreenRecording else {
            showScreenRecordingAlert()
            return
        }

        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { content, error in
            DispatchQueue.main.async {
                guard let scWindow = content?.windows.first(where: { $0.windowID == target.id }) else {
                    debugLog("couldn't find \(target.menuTitle) to capture: \(error.map { "\($0)" } ?? "not listed")")
                    NSSound.beep()
                    return
                }
                guard !self.pins.contains(where: { $0.target.id == target.id }) else { return }
                let pin = PinnedWindow(target: target, scWindow: scWindow)
                pin.onClose = { [weak self] closed in
                    self?.pins.removeAll { $0 === closed }
                }
                self.pins.append(pin)
                debugLog("pinned \(target.menuTitle)")
                pin.start()
            }
        }
    }

    private func showScreenRecordingAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Window Pane Relief needs Screen Recording permission"
        alert.informativeText = "It uses it only to show the live view of the windows you pin. Nothing is recorded or saved.\n\nAfter allowing it in System Settings, quit and reopen Window Pane Relief."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.requestScreenRecording()
            Permissions.openScreenRecordingSettings()
        }
    }
}

/// Lets a window struct ride along in `NSMenuItem.representedObject`.
private final class WindowBox {
    let window: AppWindow
    init(_ window: AppWindow) { self.window = window }
}

// MARK: - Updates

/// Self-updating from this app's GitHub releases (Sparkle): checks about once a day and offers new versions.
enum Updates {
    static let controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    static func start() { controller.startUpdater() }
    static func check() { controller.checkForUpdates(nil) }
}
