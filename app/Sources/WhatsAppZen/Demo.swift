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
        chat("900000000001", "Elif Yılmaz", ago: 120, unread: 2, text: "Akşam 8 gibi uygun musun?"),
        chat("120363000000000001", "Proje Ekibi", group: true, ago: 900, unread: 5, text: "Sunum dosyasını yükledim", sender: "Mert"),
        chat("900000000002", "Can Demir", ago: 3600, text: "Tamamdır, teşekkürler 🙏", fromMe: true, status: 3),
        chat("900000000003", "Annem", ago: 7200, type: "image", text: "", status: 2),
        chat("120363000000000002", "Halı Saha", group: true, ago: 90000, text: "Cumartesi kimler var?", sender: "Burak"),
        chat("900000000004", "Zeynep Kaya", ago: 180_000, type: "audio", text: "", fromMe: true, status: 2),
        chat("900000000005", "Deniz Arslan", ago: 400_000, text: "Görüşürüz o zaman", fromMe: true, status: 1),
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
                fileName: type == "document" ? "Teklif-2026.pdf" : nil, w: w, h: 0,
                quotedId: quoted == nil ? nil : "demo-1", quotedText: quoted, quotedSender: quotedBy,
                status: status, edited: edited, deleted: deleted, starred: n == 3, pinned: n == 8, reactions: reactions)
    }

    static func messages(for chat: String) -> [Message] {
        if chat.hasSuffix("@g.us") {
            let mert = "900000000010@s.whatsapp.net", ayse = "900000000011@s.whatsapp.net"
            return [
                message(chat, 1, ago: 90000, sender: mert, name: "Mert", "Günaydın, bugünkü toplantı saat kaçta?"),
                message(chat, 2, ago: 89900, sender: ayse, name: "Ayşe", "14:00'te, davet takvimde olmalı."),
                message(chat, 3, ago: 89800, me: true, "Ben 10 dakika gecikebilirim, siz başlayın."),
                message(chat, 4, ago: 4000, sender: mert, name: "Mert", "Sorun değil 👍",
                        reactions: [Reaction(emoji: "👍", sender: ayse, name: "Ayşe", fromMe: false)]),
                message(chat, 5, ago: 3900, sender: mert, name: "Mert", type: "document", ""),
                message(chat, 6, ago: 900, sender: mert, name: "Mert", "Sunum dosyasını yükledim"),
            ]
        }
        return [
            message(chat, 1, ago: 90000, "Selam! Hafta sonu için planın var mı?"),
            message(chat, 2, ago: 89000, me: true, "Henüz yok, bir önerin mi var?"),
            message(chat, 3, ago: 88000, "Yeni açılan sergiye gidelim diyordum. https://example.com/sergi adresinde detaylar var, cumartesi öğleden sonra uygun olur mu sence?"),
            message(chat, 4, ago: 87000, me: true, "Olur, harika fikir!", quoted: "Selam! Hafta sonu için planın var mı?", quotedBy: "Elif Yılmaz",
                    reactions: [Reaction(emoji: "❤️", sender: chat, name: "Elif", fromMe: false)]),
            message(chat, 5, ago: 4000, type: "audio", "", w: 23),
            message(chat, 6, ago: 3900, me: true, "Dinledim, tamam.", edited: true),
            message(chat, 7, ago: 3800, me: true, "", deleted: true),
            message(chat, 8, ago: 300, "Biletleri ben alıyorum o zaman"),
            message(chat, 9, ago: 120, "Akşam 8 gibi uygun musun?"),
            message(chat, 10, ago: 60, me: true, "Uygunum 👌", status: 2),
        ]
    }
}
