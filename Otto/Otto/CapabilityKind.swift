import Foundation

/// Classifies a capability template by whether it has a `{token}` placeholder.
/// Templates that arrive empty (dict templates serialized to "" over IPC) are simple.
enum CapabilityKind {
    /// A placeholder is `{` + one-or-more identifier chars + `}` (e.g. {app}, {query}, {scene}).
    /// This excludes JS object/function braces like `(){ return 1 }` which contain spaces/punctuation.
    static func isParameterized(template: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "\\{[A-Za-z_][A-Za-z0-9_]*\\}") else { return false }
        let range = NSRange(template.startIndex..., in: template)
        return regex.firstMatch(in: template, range: range) != nil
    }
}
