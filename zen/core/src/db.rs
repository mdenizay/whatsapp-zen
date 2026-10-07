//! The app's own database: chats and messages as the UI shows them. The
//! protocol library keeps its keys and sessions in a database of its own.

use std::path::Path;
use std::sync::Mutex;

use rusqlite::{params, Connection, OptionalExtension};

use crate::model::{Chat, Message};

pub struct Db {
    conn: Mutex<Connection>,
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS chats(
    jid TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    last_ts INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0,
    pinned INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages(
    chat TEXT NOT NULL,
    id TEXT NOT NULL,
    sender TEXT NOT NULL DEFAULT '',
    from_me INTEGER NOT NULL DEFAULT 0,
    ts INTEGER NOT NULL DEFAULT 0,
    kind TEXT NOT NULL DEFAULT 'text',
    text TEXT NOT NULL DEFAULT '',
    status INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(chat, id)
);
CREATE INDEX IF NOT EXISTS messages_by_time ON messages(chat, ts DESC, id DESC);
CREATE TABLE IF NOT EXISTS names(jid TEXT PRIMARY KEY, name TEXT NOT NULL);
";

impl Db {
    pub fn open(path: &Path) -> rusqlite::Result<Db> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "cache_size", -1024)?;
        conn.execute_batch(SCHEMA)?;
        Ok(Db { conn: Mutex::new(conn) })
    }

    pub fn in_memory() -> Db {
        let conn = Connection::open_in_memory().expect("in-memory database");
        conn.execute_batch(SCHEMA).expect("schema");
        Db { conn: Mutex::new(conn) }
    }

    /// Runs several writes as one transaction (a history sync is thousands).
    pub fn batch<T>(&self, work: impl FnOnce(&Writer) -> T) -> T {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute_batch("BEGIN IMMEDIATE");
        let out = work(&Writer { conn: &conn });
        let _ = conn.execute_batch("COMMIT");
        out
    }

    pub fn chats(&self) -> Vec<Chat> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare_cached(
                "SELECT c.jid,
                        COALESCE(NULLIF(c.name,''), (SELECT name FROM names n WHERE n.jid=c.jid), ''),
                        c.last_ts, c.unread, c.pinned, c.archived,
                        m.text, m.kind, m.from_me, m.status
                 FROM chats c
                 LEFT JOIN messages m ON m.chat=c.jid AND m.id=(
                     SELECT id FROM messages WHERE chat=c.jid ORDER BY ts DESC, id DESC LIMIT 1)
                 WHERE c.last_ts > 0
                 ORDER BY c.pinned DESC, c.last_ts DESC LIMIT 600",
            )
            .expect("chats query");
        let rows = stmt.query_map([], |r| {
            let jid: String = r.get(0)?;
            let name: String = r.get(1)?;
            let text: Option<String> = r.get(6)?;
            let kind: Option<String> = r.get(7)?;
            Ok(Chat {
                is_group: jid.ends_with("@g.us"),
                name: if name.is_empty() { display_number(&jid) } else { name },
                last_ts: r.get(2)?,
                unread: r.get(3)?,
                pinned: r.get(4)?,
                archived: r.get(5)?,
                last_text: preview(kind.as_deref().unwrap_or("text"), text.as_deref().unwrap_or("")),
                last_from_me: r.get::<_, Option<bool>>(8)?.unwrap_or(false),
                last_status: r.get::<_, Option<i32>>(9)?.unwrap_or(0),
                jid,
            })
        });
        rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    /// The newest `limit` messages of a chat, oldest first.
    pub fn messages(&self, chat: &str, limit: usize) -> Vec<Message> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare_cached(
                "SELECT m.id, m.sender, m.from_me, m.ts, m.kind, m.text, m.status,
                        COALESCE((SELECT name FROM names n WHERE n.jid=m.sender), '')
                 FROM messages m WHERE m.chat=?1 ORDER BY m.ts DESC, m.id DESC LIMIT ?2",
            )
            .expect("messages query");
        let rows = stmt.query_map(params![chat, limit as i64], |r| {
            let sender: String = r.get(1)?;
            let name: String = r.get(7)?;
            Ok(Message {
                id: r.get(0)?,
                chat: chat.to_string(),
                sender_name: if name.is_empty() { display_number(&sender) } else { name },
                sender,
                from_me: r.get(2)?,
                ts: r.get(3)?,
                kind: r.get(4)?,
                text: r.get(5)?,
                status: r.get(6)?,
            })
        });
        let mut list: Vec<Message> = rows.map(|rows| rows.flatten().collect()).unwrap_or_default();
        list.reverse();
        list
    }

    pub fn unread_ids(&self, chat: &str, count: u32) -> Vec<(String, String)> {
        let conn = self.conn.lock().unwrap();
        let mut stmt = conn
            .prepare_cached("SELECT id, sender FROM messages WHERE chat=?1 AND from_me=0 ORDER BY ts DESC, id DESC LIMIT ?2")
            .expect("unread query");
        let rows = stmt.query_map(params![chat, count], |r| Ok((r.get(0)?, r.get(1)?)));
        rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    pub fn unread(&self, chat: &str) -> u32 {
        let conn = self.conn.lock().unwrap();
        conn.query_row("SELECT unread FROM chats WHERE jid=?1", [chat], |r| r.get(0)).optional().ok().flatten().unwrap_or(0)
    }
}

/// Writes, inside [`Db::batch`].
pub struct Writer<'a> {
    conn: &'a Connection,
}

impl Writer<'_> {
    /// Adds a message; false if it was already there.
    pub fn insert_message(&self, m: &Message) -> bool {
        self.conn
            .prepare_cached(
                "INSERT OR IGNORE INTO messages(chat,id,sender,from_me,ts,kind,text,status) VALUES(?1,?2,?3,?4,?5,?6,?7,?8)",
            )
            .and_then(|mut s| s.execute(params![m.chat, m.id, m.sender, m.from_me, m.ts, m.kind, m.text, m.status]))
            .map(|n| n > 0)
            .unwrap_or(false)
    }

    /// Makes sure the chat exists and is no older than `ts` in the list.
    pub fn touch_chat(&self, jid: &str, ts: i64) {
        let _ = self.conn.execute(
            "INSERT INTO chats(jid,last_ts) VALUES(?1,?2) ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(last_ts, excluded.last_ts)",
            params![jid, ts],
        );
    }

    pub fn set_chat_name(&self, jid: &str, name: &str) {
        if !name.is_empty() {
            let _ = self.conn.execute("UPDATE chats SET name=?2 WHERE jid=?1", params![jid, name]);
        }
    }

    pub fn set_chat_flags(&self, jid: &str, archived: bool, pinned: bool) {
        let _ = self.conn.execute("UPDATE chats SET archived=?2, pinned=?3 WHERE jid=?1", params![jid, archived, pinned]);
    }

    pub fn set_unread(&self, jid: &str, unread: u32) {
        let _ = self.conn.execute("UPDATE chats SET unread=?2 WHERE jid=?1", params![jid, unread]);
    }

    pub fn add_unread(&self, jid: &str) {
        let _ = self.conn.execute("UPDATE chats SET unread=unread+1 WHERE jid=?1", [jid]);
    }

    /// A person's name as they set it themselves.
    pub fn set_name(&self, jid: &str, name: &str) {
        if !name.is_empty() {
            let _ = self.conn.execute(
                "INSERT INTO names(jid,name) VALUES(?1,?2) ON CONFLICT(jid) DO UPDATE SET name=excluded.name",
                params![jid, name],
            );
        }
    }

    /// Raises a sent message's status; true if that changed anything.
    pub fn raise_status(&self, chat: &str, id: &str, status: i32) -> bool {
        self.conn
            .execute(
                "UPDATE messages SET status=?3 WHERE chat=?1 AND id=?2 AND from_me=1 AND status>=0 AND status<?3",
                params![chat, id, status],
            )
            .map(|n| n > 0)
            .unwrap_or(false)
    }

    pub fn set_status(&self, chat: &str, id: &str, status: i32) {
        let _ = self.conn.execute("UPDATE messages SET status=?3 WHERE chat=?1 AND id=?2", params![chat, id, status]);
    }

    /// A message sent optimistically got its real id from the library.
    pub fn rename_message(&self, chat: &str, from: &str, to: &str) {
        let _ = self.conn.execute("UPDATE OR REPLACE messages SET id=?3 WHERE chat=?1 AND id=?2", params![chat, from, to]);
    }
}

/// "+90 555 123 45 67"-ish for a JID with no known name.
pub fn display_number(jid: &str) -> String {
    let user = jid.split('@').next().unwrap_or(jid).split(':').next().unwrap_or(jid);
    if jid.ends_with("@s.whatsapp.net") && user.chars().all(|c| c.is_ascii_digit()) {
        format!("+{user}")
    } else {
        user.to_string()
    }
}

/// The chat list's one line for a message.
pub fn preview(kind: &str, text: &str) -> String {
    match kind {
        "text" => text.to_string(),
        "image" => caption("📷 Photo", text),
        "video" => caption("🎥 Video", text),
        "audio" => "🎤 Voice message".to_string(),
        "document" => caption("📄 Document", text),
        "sticker" => "Sticker".to_string(),
        _ => if text.is_empty() { "Message".to_string() } else { text.to_string() },
    }
}

fn caption(label: &str, text: &str) -> String {
    if text.is_empty() { label.to_string() } else { format!("{label} · {text}") }
}
