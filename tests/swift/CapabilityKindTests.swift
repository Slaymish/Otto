import Foundation

@main
struct Test {
    static func main() {
        func expect(_ cond: Bool, _ msg: String) {
            if !cond { FileHandle.standardError.write(Data(("FAIL: " + msg + "\n").utf8)); exit(1) }
        }

        expect(CapabilityKind.isParameterized(template: "tell application \"{app}\" to activate"), "{app} is a param")
        expect(CapabilityKind.isParameterized(template: "https://www.google.com/search?q={query}"), "{query} is a param")
        expect(!CapabilityKind.isParameterized(template: "tell application \"Spotify\" to playpause"), "no braces = simple")
        expect(!CapabilityKind.isParameterized(template: ""), "empty (dict template) = simple")
        expect(!CapabilityKind.isParameterized(template: "func(){ return 1 }"), "JS braces with non-token content = simple")

        print("ok")
    }
}
