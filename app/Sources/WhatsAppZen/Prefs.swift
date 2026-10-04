import AppKit
import LocalAuthentication
import SwiftUI

/// App-wide preferences, kept in UserDefaults.
final class Prefs: ObservableObject {
    static let shared = Prefs()

    private static func value<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: key) as? T ?? fallback
    }

    // Appearance
    @Published var fontSize: Double = value("fontSize", 13) { didSet { saveLook("fontSize", fontSize) } }
    @Published var accent: String = value("accent", "green") { didSet { saveLook("accent", accent) } }
    @Published var compact: Bool = value("compact", false) { didSet { save("compact", compact) } }

    // Personalization
    /// "system", "light" or "dark".
    @Published var appearance: String = value("appearance", "system") { didSet { saveLook("appearance", appearance) } }
    /// The user's own accent colour as 0xRRGGBB, used when `accent` is "custom".
    @Published var customAccent: Int = value("customAccent", 0x1DAA61) { didSet { saveLook("customAccent", customAccent) } }
    @Published var bubbleRadius: Double = value("bubbleRadius", 18) { didSet { saveLook("bubbleRadius", bubbleRadius) } }
    /// "none", "tint", "gradient" or "image".
    @Published var wallpaper: String = value("wallpaper", "none") { didSet { saveLook("wallpaper", wallpaper) } }
    @Published var wallpaperPath: String = value("wallpaperPath", "") {
        didSet {
            saveLook("wallpaperPath", wallpaperPath)
            wallpaperImage = nil
        }
    }
    /// How strongly a picture wallpaper is faded toward the window colour.
    @Published var wallpaperDim: Double = value("wallpaperDim", 0.55) { didSet { saveLook("wallpaperDim", wallpaperDim) } }
    /// "default", "rounded", "serif" or "monospaced".
    @Published var fontDesign: String = value("fontDesign", "default") { didSet { saveLook("fontDesign", fontDesign) } }
    @Published var squareAvatars: Bool = value("squareAvatars", false) { didSet { save("squareAvatars", squareAvatars) } }
    @Published var hour12: Bool = value("hour12", false) { didSet { save("hour12", hour12) } }
    @Published var previewLines: Int = value("previewLines", 1) { didSet { save("previewLines", previewLines) } }
    /// The quick reactions, separated by spaces.
    @Published var reactions: String = value("reactions", "👍 ❤️ 😂 😮 😢 🙏") { didSet { save("reactions", reactions) } }

    var quickReactions: [String] {
        let list = reactions.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        return list.isEmpty ? ["👍", "❤️", "😂", "😮", "😢", "🙏"] : Array(list.prefix(10))
    }

    var design: Font.Design {
        switch fontDesign {
        case "rounded": return .rounded
        case "serif": return .serif
        case "monospaced": return .monospaced
        default: return .default
        }
    }

    private var wallpaperImage: NSImage?

    /// The chosen wallpaper picture, decoded once and no larger than a screen.
    func wallpaperPicture() -> NSImage? {
        if let wallpaperImage { return wallpaperImage }
        guard wallpaper == "image", !wallpaperPath.isEmpty,
              let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: wallpaperPath) as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: 2400,
              ] as CFDictionary) else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        wallpaperImage = image
        return image
    }

    // Writing
    /// Turn typed emoticons such as :) into emoji.
    @Published var emoticons: Bool = value("emoticons", true) { didSet { save("emoticons", emoticons) } }

    // Menu bar
    @Published var menuBarCount: Bool = value("menuBarCount", false) { didSet { save("menuBarCount", menuBarCount) } }

    // Storage
    @Published var autoDownload: Bool = value("autoDownload", true) { didSet { save("autoDownload", autoDownload) } }

    // Privacy
    @Published var appLock: Bool = value("appLock", false) { didSet { save("appLock", appLock) } }
    /// Minutes away from the app before it locks again; 0 locks at once.
    @Published var lockAfter: Int = value("lockAfter", 5) { didSet { save("lockAfter", lockAfter) } }
    /// Chats that need Touch ID to open, as "account/jid".
    @Published var lockedChats: Set<String> = Set(value("lockedChats", [String]())) {
        didSet { save("lockedChats", Array(lockedChats)) }
    }

    /// Notifications stay quiet until this moment (Do Not Disturb).
    @Published var pauseUntil: Date = Date(timeIntervalSince1970: value("pauseUntil", 0.0)) {
        didSet { save("pauseUntil", pauseUntil.timeIntervalSince1970) }
    }

    /// The version whose release notes were last shown.
    var notesShownFor: String {
        get { Self.value("notesShownFor", "") }
        set { save("notesShownFor", newValue) }
    }

    var paused: Bool { pauseUntil > Date() }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    // MARK: A look per account

    /// Key prefix for the look settings: empty for the shared look, or
    /// "account.<id>." while an account with its own look is active.
    private var scope = ""
    private var account = ""
    private var loading = false

    /// Whether the active account has a look of its own.
    @Published private(set) var ownLook = false

    private func saveLook(_ key: String, _ value: Any) {
        guard !loading else { return }
        UserDefaults.standard.set(value, forKey: scope + key)
    }

    /// A look setting for the current scope, falling back to the shared one.
    private func look<T>(_ key: String, _ fallback: T) -> T {
        UserDefaults.standard.object(forKey: scope + key) as? T ?? Self.value(key, fallback)
    }

    private func loadLook() {
        loading = true
        defer { loading = false }
        fontSize = look("fontSize", 13.0)
        accent = look("accent", "green")
        appearance = look("appearance", "system")
        customAccent = look("customAccent", 0x1DAA61)
        bubbleRadius = look("bubbleRadius", 18.0)
        wallpaper = look("wallpaper", "none")
        wallpaperPath = look("wallpaperPath", "")
        wallpaperDim = look("wallpaperDim", 0.55)
        fontDesign = look("fontDesign", "default")
    }

    /// Called when the active account changes: brings in that account's look.
    func activate(account id: String) {
        account = id
        ownLook = UserDefaults.standard.bool(forKey: "account.\(id).ownLook")
        scope = ownLook ? "account.\(id)." : ""
        loadLook()
    }

    /// Gives the active account a look of its own (starting from the current
    /// one), or returns it to the shared look.
    func setOwnLook(_ on: Bool) {
        guard !account.isEmpty else { return }
        UserDefaults.standard.set(on, forKey: "account.\(account).ownLook")
        ownLook = on
        scope = on ? "account.\(account)." : ""
        if on {
            // Start the account's look as a copy of what is on screen.
            for (key, value) in [("fontSize", fontSize), ("accent", accent), ("appearance", appearance), ("customAccent", customAccent),
                                 ("bubbleRadius", bubbleRadius), ("wallpaper", wallpaper), ("wallpaperPath", wallpaperPath),
                                 ("wallpaperDim", wallpaperDim), ("fontDesign", fontDesign)] as [(String, Any)] {
                UserDefaults.standard.set(value, forKey: scope + key)
            }
        } else {
            loadLook()
        }
    }

    static let accents: [(id: String, light: UInt32, dark: UInt32, bubbleLight: UInt32, bubbleDark: UInt32)] = [
        ("green", 0x1DAA61, 0x25C46B, 0x1A9F5A, 0x1B8A50),
        ("blue", 0x0A84FF, 0x409CFF, 0x0A7AEB, 0x1769C4),
        ("purple", 0x8E5BE8, 0xA982F5, 0x8251DB, 0x6C45B8),
        ("pink", 0xE8497F, 0xF2709C, 0xD93F74, 0xB8386A),
        ("orange", 0xE8792B, 0xF59A4F, 0xD96F26, 0xB85F22),
        ("graphite", 0x6E6E73, 0x98989D, 0x636368, 0x55555A),
    ]

    var accentEntry: (id: String, light: UInt32, dark: UInt32, bubbleLight: UInt32, bubbleDark: UInt32) {
        if accent == "custom" {
            // Bubbles carry white text, so they use a darker shade of the colour.
            let base = UInt32(customAccent)
            let darker = Self.scale(base, 0.82)
            return ("custom", base, Self.scale(base, 1.12), darker, Self.scale(base, 0.7))
        }
        return Self.accents.first { $0.id == accent } ?? Self.accents[0]
    }

    private static func scale(_ hex: UInt32, _ factor: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 { UInt32(min(255, Double((hex >> shift) & 0xFF) * factor)) }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}

/// Typed emoticons and the emoji they stand for.
enum Emoticons {
    private static let table: [String: String] = [
        ":)": "🙂", ":-)": "🙂", "(:": "🙂", ":D": "😀", ":-D": "😀", "xD": "😆", "XD": "😆", ";)": "😉", ";-)": "😉",
        ":(": "🙁", ":-(": "🙁", ":'(": "😢", ":P": "😛", ":p": "😛", ":-P": "😛", ":O": "😮", ":o": "😮", ":-O": "😮",
        ":*": "😘", ":-*": "😘", ":|": "😐", ":-|": "😐", ":/": "😕", ":-/": "😕", ":\\": "😕", "B)": "😎", "8)": "😎",
        ">:(": "😠", ":$": "😳", "<3": "❤️", "</3": "💔", ":3": "😺", "^^": "😊", "^_^": "😊", "-_-": "😑", "o.O": "🤨",
        "O:)": "😇", ":')": "🥲", "D:": "😧",
    ]

    /// Converts emoticons that stand as words of their own. Anything glued
    /// to other text (the ":/" in "https://", say) is left alone.
    static func convert(_ text: String) -> String {
        guard Prefs.shared.emoticons else { return text }
        var out = ""
        var word = ""
        func flush() {
            out += table[word] ?? word
            word = ""
        }
        for character in text {
            if character.isWhitespace {
                flush()
                out.append(character)
            } else {
                word.append(character)
            }
        }
        flush()
        return out
    }

    /// While typing: converts the word just finished by a space or return.
    static func convertLastWord(_ text: String) -> String? {
        guard Prefs.shared.emoticons, let last = text.last, last.isWhitespace else { return nil }
        let body = text.dropLast()
        let start = body.lastIndex(where: \.isWhitespace).map { body.index(after: $0) } ?? body.startIndex
        guard let emoji = table[String(body[start...])] else { return nil }
        return String(body[..<start]) + emoji + String(last)
    }
}

/// Touch ID (or the account password where there is no sensor).
enum Auth {
    static func unlock(reason: String, done: @escaping (Bool) -> Void) {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // No way to authenticate on this Mac: don't lock the user out.
            return done(true)
        }
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { ok, _ in
            DispatchQueue.main.async { done(ok) }
        }
    }
}

/// The bundled change log, one section per version ("## 0.4.0").
enum ReleaseNotes {
    static func current() -> String? {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var lines: [String] = []
        var inside = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("## ") {
                if inside { break }
                inside = line.dropFirst(3).trimmingCharacters(in: .whitespaces).hasPrefix(Links.version)
                continue
            }
            if inside { lines.append(line) }
        }
        let notes = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return notes.isEmpty ? nil : notes
    }
}
