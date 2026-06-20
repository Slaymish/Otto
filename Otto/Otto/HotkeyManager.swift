import Carbon
import AppKit

/// Registers a global Carbon hotkey (default: ⌥Space) to summon/dismiss the palette.
/// Uses RegisterEventHotKey — no event tap, no special permissions required.
final class HotkeyManager {

    // ⌥Space: keyCode 49, modifiers optionKey (0x0800)
    // Change these to customise the summon shortcut.
    private let keyCode: UInt32
    private let modifiers: UInt32
    // Each HotkeyManager instance uses a unique id so the Carbon handler chain
    // can tell which hotkey fired and return eventNotHandledErr for mismatches,
    // letting the other handler in the chain pick it up.
    let hotKeyId: UInt32

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let onToggle: () -> Void

    init(keyCode: UInt32 = 49, modifiers: UInt32 = UInt32(optionKey), id: UInt32 = 1,
         onToggle: @escaping () -> Void) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.hotKeyId = id
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
        // Read the fired hotkey id from the event and bail early on a mismatch so the
        // Carbon handler chain continues to whichever other HotkeyManager owns that id.
        let callback: EventHandlerUPP = { _, event, userData -> OSStatus in
            guard let ptr = userData, let event else { return OSStatus(eventNotHandledErr) }
            var firedID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &firedID)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(ptr).takeUnretainedValue()
            guard firedID.id == manager.hotKeyId else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { manager.onToggle() }
            return noErr
        }

        InstallEventHandler(target, callback, 1, &spec, retained, &handlerRef)

        let hkID = EventHotKeyID(signature: OSType(0x564F5331), id: hotKeyId) // 'VOS1'
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
