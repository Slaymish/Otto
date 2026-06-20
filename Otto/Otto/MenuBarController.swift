import AppKit

/// Owns the menu-bar status item and its dropdown.
/// Menu: Open Search · Journal · Settings · Quit.
/// Each item forwards to a closure wired up by AppDelegate.
final class MenuBarController: NSObject {
    private var statusItem: NSStatusItem?

    var onOpenSearch: () -> Void = {}
    var onOpenJournal: () -> Void = {}
    var onOpenSettings: () -> Void = {}
    var onQuit: () -> Void = { NSApp.terminate(nil) }
    var onInstallUpdate: () -> Void = {}
    private var pendingUpdateVersion: String?

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Otto")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Otto"
        }
        item.menu = buildMenu()
        statusItem = item
    }

    /// Show/hide the update affordance. Pass nil to clear.
    func setUpdateAvailable(_ version: String?) {
        pendingUpdateVersion = version
        applyBadge()
        statusItem?.menu = buildMenu()
    }

    private func applyBadge() {
        guard let button = statusItem?.button else { return }
        let base = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Otto")
        base?.isTemplate = true
        if pendingUpdateVersion != nil {
            // Overlay a small dot to signal an available update.
            let badged = NSImage(size: NSSize(width: 20, height: 18), flipped: false) { rect in
                base?.draw(in: rect)
                NSColor.systemBlue.setFill()
                NSBezierPath(ovalIn: NSRect(x: rect.maxX - 6, y: rect.maxY - 6, width: 6, height: 6)).fill()
                return true
            }
            badged.isTemplate = false
            button.image = badged
        } else {
            button.image = base
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        menu.addItem(menuItem(
            title: "Open Search",
            action: #selector(openSearch),
            keyEquivalent: " ",
            modifiers: [.option]
        ))
        menu.addItem(menuItem(
            title: "Journal",
            action: #selector(openJournal),
            keyEquivalent: " ",
            modifiers: [.option, .shift]
        ))
        menu.addItem(menuItem(
            title: "Settings\u{2026}",
            action: #selector(openSettings),
            keyEquivalent: ",",
            modifiers: [.command]
        ))

        if let v = pendingUpdateVersion {
            menu.addItem(.separator())
            let updateItem = NSMenuItem(title: "Update to v\(v)\u{2026}", action: #selector(installUpdate), keyEquivalent: "")
            updateItem.target = self
            menu.addItem(updateItem)
        }

        menu.addItem(.separator())

        menu.addItem(menuItem(
            title: "Quit Otto",
            action: #selector(quit),
            keyEquivalent: "q",
            modifiers: [.command]
        ))

        return menu
    }

    private func menuItem(
        title: String,
        action: Selector,
        keyEquivalent: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    // MARK: - Actions

    @objc private func openSearch() { onOpenSearch() }
    @objc private func openJournal() { onOpenJournal() }
    @objc private func openSettings() { onOpenSettings() }
    @objc private func quit() { onQuit() }
    @objc private func installUpdate() { onInstallUpdate() }
}
