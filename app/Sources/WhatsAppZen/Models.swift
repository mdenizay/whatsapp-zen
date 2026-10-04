import AppKit
import Foundation

/// Looks up a user-facing string in the app's language. Keys are the English
/// text; `args` fill %@ / %lld placeholders.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: key, value: key, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// A photo staged for sending: already converted to the JPEG that goes out.
struct PendingImage: Identifiable {
    let id = UUID()
    let jpeg: Data
    let thumb: String
    let width: Int
    let height: Int
    let preview: NSImage
}

struct Chat: Decodable, Identifiable, Equatable {
    let jid: String
    let name: String
    let isGroup: Bool
    let lastTs: Int
    let unread: Int
    let lastType: String
    let lastText: String
    let lastFromMe: Bool
    let lastStatus: Int
    let lastSender: String
    let lastFile: String
    let archived: Bool
    let pinned: Bool
    var muted = false
    /// Disappearing-message timer in seconds; 0 when off.
    var ephemeral = 0

    var id: String { jid }

    /// One-line preview of the newest message for chat lists.
    var preview: String {
        let body = Message.label(type: lastType, text: lastText, fileName: lastFile)
        if isGroup, !lastFromMe, !lastSender.isEmpty { return "\(lastSender): \(body)" }
        return body
    }
}

struct Reaction: Decodable, Equatable {
    let emoji: String
    let sender: String
    let name: String
    let fromMe: Bool
}

struct Message: Decodable, Identifiable, Equatable {
    let id: String
    let chat: String
    let sender: String
    let senderName: String
    let fromMe: Bool
    let ts: Int
    let type: String
    let text: String
    let thumb: String?
    let mediaPath: String?
    let fileName: String?
    let w: Int
    let h: Int
    let quotedId: String?
    let quotedText: String?
    let quotedSender: String?
    let status: Int
    let edited: Bool
    let deleted: Bool
    let starred: Bool
    let pinned: Bool
    var linkTitle: String?
    var linkDesc: String?
    var mentionsMe = false
    var poll: Poll?
    let reactions: [Reaction]

    var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
    var isVisual: Bool { type == "image" || type == "sticker" }

    /// What "copy" puts on the pasteboard and what previews show.
    var plainText: String { Message.label(type: type, text: text, fileName: fileName ?? "") }

    static func label(type: String, text: String, fileName: String) -> String {
        if type == "deleted" { return L("🚫 This message was deleted") }
        if !text.isEmpty { return text }
        switch type {
        case "image": return L("📷 Photo")
        case "video": return L("🎥 Video")
        case "audio": return L("🎤 Voice message")
        case "document": return "📄 \(fileName)"
        case "sticker": return L("Sticker")
        case "poll": return "📊 \(text)"
        default: return ""
        }
    }
}

struct Presence: Equatable {
    var online: Bool
    var lastSeen: Int
}

enum Status {
    static let failed = -1
    static let pending = 0
    static let sent = 1
    static let delivered = 2
    static let read = 3
}

enum Format {
    private static let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let day: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        f.dateFormat = "d MMMM yyyy"
        return f
    }()

    private static let shortDay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "dd.MM.yyyy"
        return f
    }()

    static func time(_ date: Date) -> String { time.string(from: date) }

    /// Day heading inside a conversation.
    static func day(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("Today") }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        return day.string(from: date)
    }

    /// Compact stamp for chat lists: time today, otherwise the day.
    static func listStamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return L("Yesterday") }
        return shortDay.string(from: date)
    }

    /// Day and time of a message for result lists: just the time for today.
    static func stamp(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        if Calendar.current.isDateInToday(date) { return time.string(from: date) }
        return "\(listStamp(ts)) \(time.string(from: date))"
    }

    static func lastSeen(_ ts: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return L("last seen today at %@", time.string(from: date)) }
        if cal.isDateInYesterday(date) { return L("last seen yesterday at %@", time.string(from: date)) }
        return L("last seen %@", "\(shortDay.string(from: date)) \(time.string(from: date))")
    }
}
