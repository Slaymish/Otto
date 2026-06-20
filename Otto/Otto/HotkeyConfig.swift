import AppKit
import Carbon.HIToolbox

/// A persistable global-hotkey description: a virtual key code plus Carbon modifier mask.
/// Carbon masks (from <Carbon/HIToolbox/Events.h>): cmdKey 0x0100, shiftKey 0x0200,
/// optionKey 0x0800, controlKey 0x1000.
struct HotkeyConfig: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let summonDefault  = HotkeyConfig(keyCode: 49, carbonModifiers: UInt32(optionKey))
    static let journalDefault = HotkeyConfig(keyCode: 49, carbonModifiers: UInt32(optionKey | shiftKey))

    /// Map AppKit modifier flags to a Carbon modifier mask.
    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift)   { mask |= UInt32(shiftKey) }
        if flags.contains(.option)  { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// Build from a captured key event; requires at least one modifier.
    init?(keyCode: UInt32, modifierFlags: NSEvent.ModifierFlags) {
        let mods = Self.carbonModifiers(from: modifierFlags)
        guard mods != 0 else { return nil }
        self.keyCode = keyCode
        self.carbonModifiers = mods
    }

    init(keyCode: UInt32, carbonModifiers: UInt32) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
    }

    /// Human-readable glyph string, e.g. "⌥⇧Space".
    var displayString: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    /// Minimal key-code → label map covering common summon keys.
    private static func keyName(_ code: UInt32) -> String {
        switch Int(code) {
        case kVK_Space:        return "Space"
        case kVK_Return:       return "Return"
        case kVK_Tab:          return "Tab"
        case kVK_Escape:       return "Esc"
        case kVK_ANSI_A: return "A"; case kVK_ANSI_B: return "B"; case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"; case kVK_ANSI_E: return "E"; case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"; case kVK_ANSI_H: return "H"; case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"; case kVK_ANSI_K: return "K"; case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"; case kVK_ANSI_N: return "N"; case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"; case kVK_ANSI_Q: return "Q"; case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"; case kVK_ANSI_T: return "T"; case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"; case kVK_ANSI_W: return "W"; case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"; case kVK_ANSI_Z: return "Z"
        default:               return "Key\(code)"
        }
    }
}
