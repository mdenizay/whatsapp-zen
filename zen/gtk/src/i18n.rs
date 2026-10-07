//! The app's words in the user's language. Keys are the English text;
//! English and Turkish for now, others fall back to English.

use std::sync::OnceLock;

/// The language code the app speaks, from the usual environment variables.
pub fn language() -> &'static str {
    static LANG: OnceLock<String> = OnceLock::new();
    LANG.get_or_init(|| {
        for var in ["LANGUAGE", "LC_ALL", "LC_MESSAGES", "LANG"] {
            if let Ok(value) = std::env::var(var) {
                let code: String = value.chars().take_while(|c| c.is_ascii_alphabetic()).collect();
                if !code.is_empty() && code != "C" {
                    return code.to_lowercase();
                }
            }
        }
        "en".to_string()
    })
}

pub fn t(key: &'static str) -> &'static str {
    if language() != "tr" {
        return key;
    }
    match key {
        "Chats" => "Sohbetler",
        "Search" => "Ara",
        "Message" => "Mesaj",
        "Send" => "Gönder",
        "Attach a file" => "Dosya ekle",
        "Reply" => "Yanıtla",
        "Copy" => "Kopyala",
        "Delete for Me" => "Benden sil",
        "Delete for Everyone" => "Herkesten sil",
        "Open" => "Aç",
        "Save to Downloads" => "İndirilenlere kaydet",
        "Saved to Downloads" => "İndirilenlere kaydedildi",
        "Older messages" => "Daha eski mesajlar",
        "Link to WhatsApp" => "WhatsApp'a bağlan",
        "Open WhatsApp on your phone, go to Settings → Linked Devices → Link a Device, and point your phone at this code." => {
            "Telefonunuzda WhatsApp'ı açın, Ayarlar → Bağlı Cihazlar → Cihaz Bağla'ya gidin ve telefonunuzu bu koda tutun."
        }
        "Connecting…" => "Bağlanıyor…",
        "Starting…" => "Başlatılıyor…",
        "Choose a chat" => "Bir sohbet seçin",
        "Your messages stay on your phone and on this computer." => "Mesajlarınız telefonunuzda ve bu bilgisayarda kalır.",
        "Photo" => "Fotoğraf",
        "Video" => "Video",
        "Voice message" => "Sesli mesaj",
        "Sticker" => "Çıkartma",
        "Document" => "Belge",
        "Poll" => "Anket",
        "This message was deleted" => "Bu mesaj silindi",
        "You" => "Siz",
        "edited" => "düzenlendi",
        "Today" => "Bugün",
        "Yesterday" => "Dün",
        "typing…" => "yazıyor…",
        "online" => "çevrimiçi",
        "Replying to" => "Yanıtlanıyor:",
        "Cancel" => "Vazgeç",
        "Could not send" => "Gönderilemedi",
        "Downloading…" => "İndiriliyor…",
        "The file could not be downloaded" => "Dosya indirilemedi",
        "No chats yet" => "Henüz sohbet yok",
        "Get older messages from your phone" => "Eski mesajları telefondan iste",
        "Logged out. Link this computer again." => "Oturum kapandı. Bu bilgisayarı yeniden bağlayın.",
        "New message" => "Yeni mesaj",
        _ => key,
    }
}
