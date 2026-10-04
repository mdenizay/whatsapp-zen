import AppKit
import Foundation
import Security

/// Keeps the app current from its GitHub releases: downloads the newest
/// build in the background, checks that it is signed by the same developer
/// as the running app, and swaps it in on restart.
final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle, checking, upToDate
        case downloading(String)
        case ready(String)
        case failed(String)
    }

    @Published private(set) var state = State.idle
    @Published var automatic = UserDefaults.standard.object(forKey: "autoUpdate") as? Bool ?? true {
        didSet { UserDefaults.standard.set(automatic, forKey: "autoUpdate") }
    }

    private static let latestRelease = URL(string: "https://api.github.com/repos/mdenizay/whatsapp-zen/releases/latest")!
    private var staged: URL?
    private var timer: Timer?
    private var announced = false

    /// The team that signed this build; nil for local (ad hoc) builds, which
    /// never update themselves because nothing could vouch for the download.
    private let teamID: String? = {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess else { return nil }
        return (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    }()

    var available: Bool { teamID != nil && !AppStore.isDemo }

    /// WA_UPDATE_FROM pretends to be an older version, to exercise an update.
    private var currentVersion: String {
        ProcessInfo.processInfo.environment["WA_UPDATE_FROM"] ?? Links.version
    }

    func start() {
        guard available else { return }
        if automatic { check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            guard let self, self.automatic else { return }
            self.check()
        }
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadUrl: URL
        }

        let tagName: String
        let assets: [Asset]
    }

    func check() {
        guard available else { return }
        switch state {
        case .checking, .downloading, .ready: return
        default: break
        }
        state = .checking
        Task { @MainActor in
            do {
                let (data, _) = try await URLSession.shared.data(from: Self.latestRelease)
                let release = try Core.decoder.decode(Release.self, from: data)
                let version = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
                guard Self.isNewer(version, than: currentVersion),
                      let asset = release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
                    state = .upToDate
                    return
                }
                state = .downloading(version)
                staged = try await fetch(asset.browserDownloadUrl)
                state = .ready(version)
                announce(version)
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        a.compare(b, options: .numeric) == .orderedDescending
    }

    /// Downloads and unpacks a release and returns the verified app inside it.
    private func fetch(_ url: URL) async throws -> URL {
        let (zip, _) = try await URLSession.shared.download(from: url)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wa-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", zip.path, dir.path]
        try unzip.run()
        unzip.waitUntilExit()
        try? FileManager.default.removeItem(at: zip)
        guard unzip.terminationStatus == 0,
              let name = try FileManager.default.contentsOfDirectory(atPath: dir.path).first(where: { $0.hasSuffix(".app") }) else {
            throw CoreError(message: L("The update could not be unpacked."))
        }
        let app = dir.appendingPathComponent(name)
        guard verify(app) else { throw CoreError(message: L("The update is not signed by the developer of this app.")) }
        return app
    }

    /// True if the bundle is intact and signed with our Developer ID.
    private func verify(_ app: URL) -> Bool {
        guard let teamID, let bundleID = Bundle.main.bundleIdentifier else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let rule = "anchor apple generic and identifier \"\(bundleID)\" and certificate leaf[subject.OU] = \"\(teamID)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(rule as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        return SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
    }

    /// Tells the user once per launch; Settings keeps offering the restart.
    private func announce(_ version: String) {
        guard !announced else { return }
        announced = true
        if ProcessInfo.processInfo.environment["WA_UPDATE_FROM"] != nil { return installAndRelaunch() }
        let alert = NSAlert()
        alert.messageText = L("WhatsApp Zen %@ is ready to install", version)
        alert.informativeText = L("The update has been downloaded. It is installed when you restart the app.")
        alert.addButton(withTitle: L("Restart Now"))
        alert.addButton(withTitle: L("Later"))
        if alert.runModal() == .alertFirstButtonReturn { installAndRelaunch() }
    }

    /// Replaces the running app with the downloaded one and starts it again.
    func installAndRelaunch() {
        guard let staged else { return }
        let current = Bundle.main.bundleURL
        let old = current.deletingLastPathComponent().appendingPathComponent(".\(current.lastPathComponent).old-\(getpid())")
        let fm = FileManager.default
        do {
            try fm.moveItem(at: current, to: old)
            do {
                try fm.moveItem(at: staged, to: current)
            } catch {
                try? fm.moveItem(at: old, to: current)
                throw error
            }
            try? fm.removeItem(at: old)
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        // Open the new copy once this process is gone.
        let relaunch = Process()
        relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
        relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", current.path]
        try? relaunch.run()
        NSApp.terminate(nil)
    }
}
