import Foundation

@main
struct Test {
    static func main() {
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
        }

        expect(SemVer.isNewer("0.0.5", than: "0.0.4"), "0.0.5 > 0.0.4")
        expect(SemVer.isNewer("v0.0.5", than: "0.0.4"), "v-prefix stripped")
        expect(SemVer.isNewer("0.1.0", than: "0.0.9"), "0.1.0 > 0.0.9")
        expect(SemVer.isNewer("1.0", than: "0.0.4"), "1.0 > 0.0.4 (uneven length)")
        expect(!SemVer.isNewer("0.0.4", than: "0.0.4"), "equal is not newer")
        expect(!SemVer.isNewer("0.0.3", than: "0.0.4"), "older is not newer")
        expect(!SemVer.isNewer("0.0.4", than: "0.0.4.0"), "0.0.4 == 0.0.4.0")

        print("ok")
    }
}
