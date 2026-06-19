import Carbon
import AppKit

/// Registers a global Carbon hotkey (default: ⌥Space) to summon/dismiss the palette.
/// Uses RegisterEventHotKey — no event tap, no special permissions required.
final class HotkeyManager {

    // ⌥Space: keyCode 49, modifiers optionKey (0x0800)
    // Change these to customise the summon shortcut.
    private let keyCode: UInt32
    private let modifiers: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onToggle: () -> Void

    init(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey), onToggle: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.onToggle = onToggle
    }

    func register() {
        let target = GetApplicationEventTarget()
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        // Box `self` so the C callback can reach it.
        let retained = Unmanaged.passRetained(self).toOpaque()

        // Non-capturing closure satisfies EventHandlerUPP directly — NewEventHandlerUPP
        // was removed from the macOS SDK; on modern platforms UPPs are just function pointers.
        let callback: EventHandlerUPP = { _, _, userData -> OSStatus in
            guard let ptr = userData else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
            DispatchQueue.main.async { manager.onToggle() }
            return noErr
        }

        InstallEventHandler(target, callback, 1, &spec, retained, &handlerRef)

        var hkID = EventHotKeyID(signature: OSType(0x564F5331), id: 1) // 'VOS1'
        RegisterEventHotKey(keyCode, modifiers, hkID, target, 0, &hotKeyRef)
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref) }
        if let ref = handlerRef { RemoveEventHandler(ref) }
        hotKeyRef = nil
        handlerRef = nil
    }

    deinit { unregister() }
}
