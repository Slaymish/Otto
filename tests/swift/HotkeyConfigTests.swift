import AppKit

@main
struct Test {
    static func main() {
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
        }

        // Carbon constants: optionKey 0x0800, shiftKey 0x0200, cmdKey 0x0100, controlKey 0x1000
        let opt = HotkeyConfig.carbonModifiers(from: [.option])
        expect(opt == 0x0800, "option maps to 0x0800, got \(opt)")

        let optShift = HotkeyConfig.carbonModifiers(from: [.option, .shift])
        expect(optShift == 0x0800 | 0x0200, "option+shift maps to 0x0A00, got \(optShift)")

        // Defaults
        expect(HotkeyConfig.summonDefault.keyCode == 49, "summon keyCode 49")
        expect(HotkeyConfig.summonDefault.carbonModifiers == 0x0800, "summon = option")
        expect(HotkeyConfig.journalDefault.carbonModifiers == 0x0800 | 0x0200, "journal = option+shift")

        // Reject combos with no modifier
        expect(HotkeyConfig(keyCode: 49, modifierFlags: []) == nil, "no-modifier combo rejected")

        // Display string
        expect(HotkeyConfig.summonDefault.displayString == "⌥Space", "summon display, got \(HotkeyConfig.summonDefault.displayString)")
        expect(HotkeyConfig.journalDefault.displayString == "⌥⇧Space", "journal display, got \(HotkeyConfig.journalDefault.displayString)")

        // Codable round-trip (used for UserDefaults storage)
        let data = try! JSONEncoder().encode(HotkeyConfig.journalDefault)
        let decoded = try! JSONDecoder().decode(HotkeyConfig.self, from: data)
        expect(decoded == HotkeyConfig.journalDefault, "codable round-trip")

        print("ok")
    }
}
