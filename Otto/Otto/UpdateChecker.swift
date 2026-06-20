import AppKit
import Foundation
import Observation

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

struct UpdateInfo: Equatable {
    let version: String      // numeric, e.g. "0.0.5"
    let pkgURL: URL
    let releaseURL: URL
    let notes: String
}

@MainActor
@Observable
final class UpdateChecker {
    enum Status: Equatable {
        case idle
        case checking
        case downloading(Double)
        case failed(String)
    }

    private static let latestURL = URL(string: "https://api.github.com/repos/Slaymish/Otto/releases/latest")!

    let currentVersion: String
    var availableUpdate: UpdateInfo?
    var status: Status = .idle
    /// Called when availableUpdate transitions to non-nil (wired by AppDelegate for the menu badge).
    var onUpdateFound: (() -> Void)?

    init() {
        currentVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
    }

    func checkForUpdates() async {
        status = .checking
        do {
            var req = URLRequest(url: Self.latestURL)
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                status = .failed("Malformed release data")
                return
            }
            let numeric = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let releaseURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                ?? URL(string: "https://github.com/Slaymish/Otto/releases/latest")!
            let notes = (json["body"] as? String) ?? ""

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let pkgURLString = assets.first { ($0["name"] as? String)?.hasSuffix(".pkg") == true }?["browser_download_url"] as? String

            status = .idle
            guard SemVer.isNewer(tag, than: currentVersion), let pkgStr = pkgURLString, let pkgURL = URL(string: pkgStr) else {
                availableUpdate = nil
                return
            }
            availableUpdate = UpdateInfo(version: numeric, pkgURL: pkgURL, releaseURL: releaseURL, notes: notes)
            onUpdateFound?()
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func downloadAndInstall() async {
        guard let update = availableUpdate else { return }
        status = .downloading(0)
        do {
            let (tmpURL, _) = try await URLSession.shared.download(from: update.pkgURL)
            let dest = FileManager.default.temporaryDirectory
                .appendingPathComponent("Otto-v\(update.version).pkg")
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: tmpURL, to: dest)
            status = .idle
            NSWorkspace.shared.open(dest)   // launches macOS Installer
            // Give Installer a beat to take over, then quit so it can replace the bundle.
            try? await Task.sleep(nanoseconds: 800_000_000)
            NSApp.terminate(nil)
        } catch {
            status = .failed(error.localizedDescription)
        }
    }
}
