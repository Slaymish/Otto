import Foundation

/// Dotted-numeric version comparison, tolerant of a leading "v" and uneven lengths.
enum SemVer {
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = parts(candidate)
        let b = parts(current)
        let n = max(a.count, b.count)
        for i in 0..<n {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    private static func parts(_ v: String) -> [Int] {
        v.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
