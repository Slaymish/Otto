import Carbon
import SwiftUI
import AppKit

@main
struct OttoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}


@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    private let engine = OttoEngine()
    let updateChecker = UpdateChecker()
    private var paletteController: PaletteController?
    private var journalController: JournalController?
    private var settingsController: SettingsController?
    private var menuBarController: MenuBarController?
    private var hotkeyManager: HotkeyManager?
    private var journalHotkeyManager: HotkeyManager?
    private var onboardingWindow: NSWindow?
    private var updateTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[Otto] app started")

        let hasEnvKey = !(ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "").isEmpty
        if !hasEnvKey && !SettingsStore.shared.isConfigured {
            NSApp.setActivationPolicy(.regular)
            showOnboarding()
        } else {
            NSApp.setActivationPolicy(.accessory)
            startMainApp()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
    }

    // MARK: - Onboarding

    private func showOnboarding() {
        let view = OnboardingView {
            DispatchQueue.main.async {
                self.onboardingWindow?.orderOut(nil)
                self.onboardingWindow = nil
                NSApp.setActivationPolicy(.accessory)
                self.startMainApp()
            }
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Set Up Otto"
        window.contentView = NSHostingView(rootView: view)
        window.center()
        onboardingWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: - Main app startup

    private func startMainApp() {
        paletteController = PaletteController(bridge: engine)
        journalController = JournalController(bridge: engine)
        settingsController = SettingsController(updateChecker: updateChecker, onSaved: { [weak self] in
            self?.restartHotkeys()
            self?.restartEngine()
        })

        paletteController?.onOpenJournal = { [weak self] in self?.journalController?.show() }

        let menuBar = MenuBarController()
        menuBar.onOpenSearch = { [weak self] in self?.paletteController?.show() }
        menuBar.onOpenJournal = { [weak self] in self?.journalController?.show() }
        menuBar.onOpenSettings = { [weak self] in self?.settingsController?.show() }
        menuBar.onQuit = { NSApp.terminate(nil) }
        menuBar.install()
        menuBarController = menuBar

        updateChecker.onUpdateFound = { [weak self] in
            self?.menuBarController?.setUpdateAvailable(self?.updateChecker.availableUpdate?.version)
        }
        menuBar.onInstallUpdate = { [weak self] in
            Task { await self?.updateChecker.downloadAndInstall() }
        }
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            await self?.updateChecker.checkForUpdates()
            self?.scheduleDailyUpdateCheck()
        }

        registerHotkeys()
        engine.start()
    }

    // MARK: - Engine restart (e.g. after settings change)

    private func restartEngine() {
        engine.stop()
        engine.start()
    }

    // MARK: - Hotkeys

    private func registerHotkeys() {
        let summon = SettingsStore.shared.summonHotkey
        let journal = SettingsStore.shared.journalHotkey

        let s = HotkeyManager(keyCode: summon.keyCode, modifiers: summon.carbonModifiers, id: 1,
                              onToggle: { [weak self] in self?.paletteController?.toggle() })
        s.register()
        hotkeyManager = s

        let j = HotkeyManager(keyCode: journal.keyCode, modifiers: journal.carbonModifiers, id: 2,
                              onToggle: { [weak self] in self?.journalController?.show() })
        j.register()
        journalHotkeyManager = j
    }

    func restartHotkeys() {
        hotkeyManager?.unregister()
        journalHotkeyManager?.unregister()
        registerHotkeys()
    }

    private func scheduleDailyUpdateCheck() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { await self?.updateChecker.checkForUpdates() }
        }
    }
}
