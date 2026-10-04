import Foundation

/// Canned data for WA_DEMO=1: lets the UI be exercised and screenshotted
/// without a paired account or anyone's real conversations.
enum Demo {
    private static let now = Int(Date().timeIntervalSince1970)

    private static func chat(_ user: String, _ name: String, group: Bool = false, ago: Int, unread: Int = 0,
                             type: String = "text", text: String, fromMe: Bool = false, status: Int = 3,
                             sender: String = "") -> Chat {
        Chat(jid: "\(user)@\(group ? "g.us" : "s.whatsapp.net")", name: name, isGroup: group, lastTs: now - ago,
             unread: unread, lastType: type, lastText: text, lastFromMe: fromMe, lastStatus: status,
             lastSender: sender, lastFile: "", archived: false, pinned: user == "900000000001")
    }

    static let chats: [Chat] = [
        chat("900000000001", "Emma Wilson", ago: 120, unread: 2, text: "Does 8 pm work for you?"),
        chat("120363000000000001", "Design Team", group: true, ago: 900, unread: 5, text: "I've uploaded the deck", sender: "Liam"),
        chat("900000000002", "James Carter", ago: 3600, text: "Perfect, thank you 🙏", fromMe: true, status: 3),
        chat("900000000003", "Mom", ago: 7200, type: "image", text: "", status: 2),
        chat("120363000000000002", "Sunday Football", group: true, ago: 90000, text: "Who's in for Saturday?", sender: "Ben"),
        chat("900000000004", "Olivia Brown", ago: 180_000, type: "audio", text: "", fromMe: true, status: 2),
        chat("900000000005", "Noah Miller", ago: 400_000, text: "See you then", fromMe: true, status: 1),
    ]

    static let presence: [String: Presence] = [
        "900000000001@s.whatsapp.net": Presence(online: true, lastSeen: 0),
        "900000000002@s.whatsapp.net": Presence(online: false, lastSeen: now - 5400),
    ]

    private static func message(_ chat: String, _ n: Int, ago: Int, me: Bool = false, sender: String = "", name: String = "",
                                type: String = "text", _ text: String, w: Int = 0, status: Int = 3,
                                quoted: String? = nil, quotedBy: String? = nil, reactions: [Reaction] = [],
                                edited: Bool = false, deleted: Bool = false) -> Message {
        Message(id: "demo-\(n)", chat: chat, sender: me ? "me@s.whatsapp.net" : (sender.isEmpty ? chat : sender),
                senderName: name, fromMe: me, ts: now - ago, type: type, text: text, thumb: nil, mediaPath: nil,
                fileName: type == "document" ? "Proposal-2026.pdf" : nil, w: w, h: 0,
                quotedId: quoted == nil ? nil : "demo-1", quotedText: quoted, quotedSender: quotedBy,
                status: status, edited: edited, deleted: deleted, starred: n == 3, pinned: n == 8, reactions: reactions)
    }

    static func messages(for chat: String) -> [Message] {
        if chat.hasSuffix("@g.us") {
            let mert = "900000000010@s.whatsapp.net", ayse = "900000000011@s.whatsapp.net"
            return [
                message(chat, 1, ago: 90000, sender: mert, name: "Liam", "Morning! What time is the review today?"),
                message(chat, 2, ago: 89900, sender: ayse, name: "Sophie", "2 pm, the invite should be in your calendar."),
                message(chat, 3, ago: 89800, me: true, "I might be 10 minutes late, start without me."),
                message(chat, 4, ago: 4000, sender: mert, name: "Liam", "No problem 👍",
                        reactions: [Reaction(emoji: "👍", sender: ayse, name: "Sophie", fromMe: false)]),
                message(chat, 5, ago: 3900, sender: mert, name: "Liam", type: "document", ""),
                message(chat, 6, ago: 900, sender: mert, name: "Liam", "I've uploaded the deck"),
            ]
        }
        return [
            message(chat, 1, ago: 90000, "Hey! Any plans for the weekend?"),
            message(chat, 2, ago: 89000, me: true, "Not yet, what do you have in mind?"),
            message(chat, 3, ago: 88000, "I was thinking we could see the new exhibition. Details are at https://example.com/exhibition — would Saturday afternoon work?"),
            message(chat, 4, ago: 87000, me: true, "Sounds great, I'm in!", quoted: "Hey! Any plans for the weekend?", quotedBy: "Emma Wilson",
                    reactions: [Reaction(emoji: "❤️", sender: chat, name: "Emma", fromMe: false)]),
            message(chat, 5, ago: 4000, type: "audio", "", w: 23),
            message(chat, 6, ago: 3900, me: true, "Listened, all good.", edited: true),
            message(chat, 7, ago: 3800, me: true, "", deleted: true),
            message(chat, 8, ago: 300, "I'll get the tickets then"),
            message(chat, 11, ago: 200, type: "other", "📍 Location: Galata Tower\nhttps://maps.apple.com/?ll=41.025631,28.974170"),
            message(chat, 9, ago: 120, "Does 8 pm work for you?"),
            message(chat, 10, ago: 60, me: true, "Works for me 👌", status: 2),
        ]
    }
}
