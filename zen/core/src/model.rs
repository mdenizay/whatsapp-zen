//! What the UI sees: plain values, with nothing of the protocol in them.

/// One row of the chat list.
#[derive(Clone, Debug, PartialEq)]
pub struct Chat {
    pub jid: String,
    pub name: String,
    pub is_group: bool,
    /// Time of the newest message, in seconds since 1970.
    pub last_ts: i64,
    pub unread: u32,
    pub last_text: String,
    pub last_from_me: bool,
    pub last_status: i32,
    pub pinned: bool,
    pub archived: bool,
}

/// Delivery state of a message we sent.
pub mod status {
    pub const FAILED: i32 = -1;
    pub const PENDING: i32 = 0;
    pub const SENT: i32 = 1;
    pub const DELIVERED: i32 = 2;
    pub const READ: i32 = 3;
}

#[derive(Clone, Debug, PartialEq)]
pub struct Message {
    pub id: String,
    pub chat: String,
    pub sender: String,
    pub sender_name: String,
    pub from_me: bool,
    pub ts: i64,
    /// "text", "image", "video", "audio", "document", "sticker" or "other".
    pub kind: String,
    pub text: String,
    pub status: i32,
}

/// Where the account is on its way to being usable.
#[derive(Clone, Debug, PartialEq)]
pub enum State {
    Starting,
    /// Waiting to be linked: the text to show as a QR code.
    Qr(String),
    Connecting,
    Connected,
    LoggedOut,
    Failed(String),
}

/// What changed; the UI re-reads what it shows.
#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    State(State),
    Chats,
    /// Messages of this chat; empty for "any chat".
    Messages(String),
}
