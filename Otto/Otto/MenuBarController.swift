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
}
