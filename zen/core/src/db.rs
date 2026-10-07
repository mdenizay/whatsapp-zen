//! The app's own database: chats and messages as the UI shows them. The
//! schema is the one the Go core wrote, so a database made by either opens
//! in the other. The protocol library keeps its keys in a database of its own.

use std::path::Path;
use std::sync::Mutex;

use base64::Engine as _;
use rusqlite::{params, params_from_iter, Connection, OptionalExtension, Row};
use serde::Serialize;

pub mod status {
    pub const FAILED: i32 = -1;
    pub const PENDING: i32 = 0;
    pub const SENT: i32 = 1;
    pub const DELIVERED: i32 = 2;
    pub const READ: i32 = 3;
}

const SCHEMA: &str = "
CREATE TABLE IF NOT EXISTS chats(
    jid TEXT PRIMARY KEY,
    name TEXT NOT NULL DEFAULT '',
    last_ts INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0,
    archived INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE IF NOT EXISTS messages(
    chat TEXT NOT NULL,
    id TEXT NOT NULL,
    sender TEXT NOT NULL,
    from_me INTEGER NOT NULL,
    ts INTEGER NOT NULL,
    type TEXT NOT NULL,
    text TEXT NOT NULL DEFAULT '',
    thumb BLOB,
    raw BLOB,
    media_path TEXT NOT NULL DEFAULT '',
    file_name TEXT NOT NULL DEFAULT '',
    w INTEGER NOT NULL DEFAULT 0,
    h INTEGER NOT NULL DEFAULT 0,
    quoted_id TEXT NOT NULL DEFAULT '',
    quoted_text TEXT NOT NULL DEFAULT '',
    quoted_sender TEXT NOT NULL DEFAULT '',
    status INTEGER NOT NULL DEFAULT 0,
    unread INTEGER NOT NULL DEFAULT 0,
    edited INTEGER NOT NULL DEFAULT 0,
    deleted INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY(chat, id)
);
CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages(chat, ts);
CREATE TABLE IF NOT EXISTS reactions(
    chat TEXT NOT NULL,
    msg_id TEXT NOT NULL,
    sender TEXT NOT NULL,
    emoji TEXT NOT NULL,
    PRIMARY KEY(chat, msg_id, sender)
);
CREATE TABLE IF NOT EXISTS names(jid TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS contacts(jid TEXT PRIMARY KEY, name TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS poll_votes(chat TEXT NOT NULL, msg_id TEXT NOT NULL, voter TEXT NOT NULL,
    options TEXT NOT NULL, PRIMARY KEY(chat, msg_id, voter));
";

/// Columns added after the first schema; each fails harmlessly when present.
const MIGRATIONS: &[&str] = &[
    "ALTER TABLE messages ADD COLUMN starred INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE messages ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE chats ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE chats ADD COLUMN muted_until INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE chats ADD COLUMN ephemeral INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE messages ADD COLUMN link_title TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE messages ADD COLUMN link_desc TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE messages ADD COLUMN poll TEXT NOT NULL DEFAULT ''",
    "ALTER TABLE messages ADD COLUMN mentions_me INTEGER NOT NULL DEFAULT 0",
    "ALTER TABLE messages ADD COLUMN expires_at INTEGER NOT NULL DEFAULT 0",
];

#[derive(Serialize, Clone, Debug, Default)]
pub struct Chat {
    pub jid: String,
    pub name: String,
    pub is_group: bool,
    pub last_ts: i64,
    pub unread: i64,
    pub last_type: String,
    pub last_text: String,
    pub last_from_me: bool,
    pub last_status: i32,
    pub last_sender: String,
    pub last_file: String,
    pub archived: bool,
    pub pinned: bool,
    pub muted: bool,
    pub ephemeral: i64,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct Reaction {
    pub emoji: String,
    pub sender: String,
    pub name: String,
    pub from_me: bool,
}

#[derive(Serialize, Clone, Debug, Default)]
pub struct Message {
    pub id: String,
    pub chat: String,
    pub sender: String,
    pub sender_name: String,
    pub from_me: bool,
    pub ts: i64,
    #[serde(rename = "type")]
    pub kind: String,
    pub text: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub thumb: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub media_path: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub file_name: String,
    pub w: i64,
    pub h: i64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub quoted_id: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub quoted_text: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub quoted_sender: String,
    pub status: i32,
    pub edited: bool,
    pub deleted: bool,
    pub starred: bool,
    pub pinned: bool,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub link_title: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub link_desc: String,
    pub mentions_me: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub poll: Option<serde_json::Value>,
    /// The poll's definition as stored: options, how many may be chosen, its secret.
    #[serde(skip)]
    pub poll_raw: String,
    pub reactions: Vec<Reaction>,
}

/// A message on its way into the database.
#[derive(Clone, Debug, Default)]
pub struct NewMessage {
    pub chat: String,
    pub id: String,
    pub sender: String,
    pub from_me: bool,
    pub ts: i64,
    pub kind: String,
    pub text: String,
    pub thumb: Option<Vec<u8>>,
    pub raw: Option<Vec<u8>>,
    pub file_name: String,
    pub w: i64,
    pub h: i64,
    pub quoted_id: String,
    pub quoted_text: String,
    pub quoted_sender: String,
    pub status: i32,
    pub unread: bool,
    pub link_title: String,
    pub link_desc: String,
    /// A poll's definition as JSON; empty for anything else.
    pub poll: String,
    pub mentions_me: bool,
    /// When a disappearing message goes, in seconds since 1970; 0 for never.
    pub expires_at: i64,
    /// Who the text mentions, as the protocol names them. Not stored.
    pub mentioned: Vec<String>,
}

const MSG_COLS: &str = "id,chat,sender,from_me,ts,type,text,thumb,media_path,file_name,w,h,quoted_id,quoted_text,quoted_sender,status,edited,deleted,starred,pinned,link_title,link_desc,mentions_me,poll";

pub struct Db {
    conn: Mutex<Connection>,
}

impl Db {
    pub fn open(path: &Path) -> rusqlite::Result<Db> {
        let conn = Connection::open(path)?;
        conn.pragma_update(None, "journal_mode", "WAL")?;
        conn.pragma_update(None, "synchronous", "NORMAL")?;
        conn.pragma_update(None, "cache_size", -1024)?;
        conn.busy_timeout(std::time::Duration::from_secs(5))?;
        conn.execute_batch(SCHEMA)?;
        for migration in MIGRATIONS {
            let _ = conn.execute_batch(migration);
        }
        Ok(Db { conn: Mutex::new(conn) })
    }

    /// Takes over the names the Go core knew: it kept address-book and
    /// display names in its own store, not in this database. Done once, when
    /// this database has none of its own yet, so an account that was just
    /// moved over shows names at once instead of numbers.
    pub fn import_old_names(&self, store: &Path) {
        if !store.exists() || self.count("SELECT (SELECT COUNT(*) FROM contacts) + (SELECT COUNT(*) FROM names)", &[]) > 0 {
            return;
        }
        let conn = self.conn.lock().unwrap();
        let path = store.to_string_lossy();
        if conn.execute("ATTACH DATABASE ?1 AS old", [path.as_ref()]).is_err() {
            return;
        }
        let _ = conn.execute_batch(
            "INSERT INTO contacts(jid,name) SELECT their_jid, full_name FROM old.whatsmeow_contacts
                 WHERE full_name != '' AND their_jid LIKE '%@s.whatsapp.net' ON CONFLICT(jid) DO NOTHING;
             INSERT INTO names(jid,name) SELECT their_jid, push_name FROM old.whatsmeow_contacts
                 WHERE push_name != '' AND their_jid LIKE '%@s.whatsapp.net' ON CONFLICT(jid) DO NOTHING;",
        );
        let _ = conn.execute_batch("DETACH DATABASE old");
    }

    /// Runs several writes as one transaction (a history sync is thousands).
    pub fn write<T>(&self, work: impl FnOnce(&Writer) -> T) -> T {
        let conn = self.conn.lock().unwrap();
        let _ = conn.execute_batch("BEGIN IMMEDIATE");
        let out = work(&Writer { conn: &conn });
        let _ = conn.execute_batch("COMMIT");
        out
    }

    /// A name for a chat or a person: the group's subject, the name they gave
    /// themselves, or their number.
    pub fn name_of(&self, jid: &str) -> String {
        let conn = self.conn.lock().unwrap();
        name_of(&conn, jid)
    }

    pub fn chats(&self) -> Vec<Chat> {
        let conn = self.conn.lock().unwrap();
        let mut list: Vec<(Chat, String)> = {
            let mut stmt = conn
                .prepare_cached(
                    "SELECT c.jid, c.last_ts, c.unread, c.archived, c.pinned,
                            (c.muted_until < 0 OR c.muted_until > strftime('%s','now')), c.ephemeral,
                            COALESCE(m.type,''), COALESCE(m.text,''), COALESCE(m.from_me,0), COALESCE(m.status,0),
                            COALESCE(m.sender,''), COALESCE(m.deleted,0), COALESCE(m.file_name,'')
                     FROM chats c LEFT JOIN messages m ON m.chat=c.jid
                          AND m.id=(SELECT id FROM messages WHERE chat=c.jid ORDER BY ts DESC, id DESC LIMIT 1)
                     WHERE c.last_ts>0 ORDER BY c.pinned DESC, c.last_ts DESC LIMIT 600",
                )
                .expect("chats query");
            let rows = stmt.query_map([], |r| {
                let jid: String = r.get(0)?;
                let deleted: bool = r.get(12)?;
                Ok((
                    Chat {
                        is_group: jid.ends_with("@g.us"),
                        jid,
                        last_ts: r.get(1)?,
                        unread: r.get(2)?,
                        archived: r.get(3)?,
                        pinned: r.get(4)?,
                        muted: r.get(5)?,
                        ephemeral: r.get(6)?,
                        last_type: if deleted { "deleted".into() } else { r.get(7)? },
                        last_text: if deleted { String::new() } else { r.get(8)? },
                        last_from_me: r.get(9)?,
                        last_status: r.get(10)?,
                        last_file: r.get(13)?,
                        ..Default::default()
                    },
                    r.get::<_, String>(11)?,
                ))
            });
            rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
        };
        for (chat, sender) in &mut list {
            chat.name = name_of(&conn, &chat.jid);
            if chat.is_group && !chat.last_from_me && !sender.is_empty() {
                chat.last_sender = name_of(&conn, sender);
            }
        }
        list.into_iter().map(|(chat, _)| chat).collect()
    }

    /// Messages matching `tail` (a WHERE clause and whatever follows it).
    pub fn query(&self, tail: &str, args: &[&dyn rusqlite::ToSql]) -> Vec<Message> {
        let conn = self.conn.lock().unwrap();
        let mut list: Vec<Message> = {
            let Ok(mut stmt) = conn.prepare_cached(&format!("SELECT {MSG_COLS} FROM messages WHERE {tail}")) else {
                return Vec::new();
            };
            let rows = stmt.query_map(args, message_from);
            rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
        };
        if list.is_empty() {
            return list;
        }
        for message in &mut list {
            if !message.from_me {
                message.sender_name = name_of(&conn, &message.sender);
            }
            if !message.quoted_sender.is_empty() {
                message.quoted_sender = name_of(&conn, &message.quoted_sender);
            }
        }
        // Polls: their options, and the tally of the votes seen so far.
        for message in &mut list {
            if message.poll_raw.is_empty() {
                continue;
            }
            let Ok(def) = serde_json::from_str::<serde_json::Value>(&message.poll_raw) else { continue };
            let names: Vec<String> = def["options"].as_array().map(|a| a.iter().filter_map(|o| o.as_str().map(String::from)).collect()).unwrap_or_default();
            let mut votes = vec![0u32; names.len()];
            let mut mine = vec![false; names.len()];
            let mut voters = 0;
            if let Ok(mut stmt) = conn.prepare_cached("SELECT voter, options FROM poll_votes WHERE chat=?1 AND msg_id=?2") {
                let cast: Vec<(String, String)> = stmt.query_map(params![message.chat, message.id], |r| Ok((r.get(0)?, r.get(1)?))).map(|rows| rows.flatten().collect()).unwrap_or_default();
                for (voter, raw) in cast {
                    let chosen: Vec<String> = serde_json::from_str(&raw).unwrap_or_default();
                    if chosen.is_empty() {
                        continue;
                    }
                    voters += 1;
                    for name in chosen {
                        if let Some(i) = names.iter().position(|n| *n == name) {
                            votes[i] += 1;
                            mine[i] |= voter.is_empty();
                        }
                    }
                }
            }
            message.poll = Some(serde_json::json!({
                "options": names.iter().enumerate().map(|(i, name)| serde_json::json!({"name": name, "votes": votes[i], "mine": mine[i]})).collect::<Vec<_>>(),
                "selectable": def["selectable"].as_u64().unwrap_or(1),
                "voters": voters,
            }));
        }
        // Reactions for the whole page in one query.
        let marks = vec!["?"; list.len()].join(",");
        let chat = list[0].chat.clone();
        let ids: Vec<String> = std::iter::once(chat).chain(list.iter().map(|m| m.id.clone())).collect();
        if let Ok(mut stmt) = conn.prepare(&format!("SELECT msg_id,sender,emoji FROM reactions WHERE chat=? AND msg_id IN ({marks})")) {
            let found: Vec<(String, String, String)> = stmt
                .query_map(params_from_iter(ids.iter()), |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))
                .map(|rows| rows.flatten().collect())
                .unwrap_or_default();
            for (id, sender, emoji) in found {
                if let Some(message) = list.iter_mut().find(|m| m.id == id) {
                    message.reactions.push(Reaction { emoji, name: name_of(&conn, &sender), from_me: sender.is_empty(), sender });
                }
            }
        }
        list
    }

    /// One page in ascending order: the newest, or the one just older than
    /// (`before_ts`, `before_id`).
    pub fn messages(&self, chat: &str, before_ts: i64, before_id: &str, limit: i64) -> Vec<Message> {
        // Disappearing messages whose time is up.
        self.write(|w| w.exec("DELETE FROM messages WHERE expires_at > 0 AND expires_at < strftime('%s','now')", &[]));
        let limit = if limit <= 0 || limit > 200 { 50 } else { limit };
        let mut list = if before_ts > 0 {
            self.query("chat=?1 AND (ts,id) < (?2,?3) ORDER BY ts DESC, id DESC LIMIT ?4", &[&chat, &before_ts, &before_id, &limit])
        } else {
            self.query("chat=?1 ORDER BY ts DESC, id DESC LIMIT ?2", &[&chat, &limit])
        };
        list.reverse();
        list
    }

    pub fn message(&self, chat: &str, id: &str) -> Option<Message> {
        self.query("chat=?1 AND id=?2", &[&chat, &id]).into_iter().next()
    }

    pub fn count(&self, sql: &str, args: &[&dyn rusqlite::ToSql]) -> i64 {
        let conn = self.conn.lock().unwrap();
        conn.query_row(sql, args, |r| r.get(0)).optional().ok().flatten().unwrap_or(0)
    }

    /// Ids and senders of the messages not yet read in a chat.
    pub fn unread_messages(&self, chat: &str) -> Vec<(String, String)> {
        let conn = self.conn.lock().unwrap();
        let Ok(mut stmt) = conn.prepare_cached("SELECT id,sender FROM messages WHERE chat=?1 AND unread=1 AND from_me=0") else {
            return Vec::new();
        };
        let rows = stmt.query_map([chat], |r| Ok((r.get(0)?, r.get(1)?)));
        rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    /// One row, read by `map`; `None` when there is none.
    pub fn get<T>(&self, sql: &str, args: &[&dyn rusqlite::ToSql], map: impl FnOnce(&Row) -> rusqlite::Result<T>) -> Option<T> {
        let conn = self.conn.lock().unwrap();
        conn.query_row(sql, args, map).optional().ok().flatten()
    }

    /// The address-book contacts, for starting a new chat.
    pub fn contacts(&self) -> Vec<serde_json::Value> {
        let conn = self.conn.lock().unwrap();
        let Ok(mut stmt) = conn.prepare("SELECT jid, name FROM contacts WHERE jid LIKE '%@s.whatsapp.net' AND name != '' ORDER BY name COLLATE NOCASE") else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |r| Ok(serde_json::json!({"jid": r.get::<_, String>(0)?, "name": r.get::<_, String>(1)?})));
        rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    /// Every hidden id ("…@lid") the database still refers to.
    pub fn hidden_ids(&self) -> Vec<String> {
        let conn = self.conn.lock().unwrap();
        let Ok(mut stmt) = conn.prepare(
            "SELECT jid FROM chats WHERE jid LIKE '%@lid'
             UNION SELECT DISTINCT chat FROM messages WHERE chat LIKE '%@lid'
             UNION SELECT DISTINCT sender FROM messages WHERE sender LIKE '%@lid'
             UNION SELECT DISTINCT quoted_sender FROM messages WHERE quoted_sender LIKE '%@lid'
             UNION SELECT jid FROM names WHERE jid LIKE '%@lid'",
        ) else {
            return Vec::new();
        };
        let rows = stmt.query_map([], |r| r.get(0));
        rows.map(|rows| rows.flatten().collect()).unwrap_or_default()
    }

    pub fn is_muted(&self, chat: &str) -> bool {
        self.count("SELECT (muted_until < 0 OR muted_until > strftime('%s','now')) FROM chats WHERE jid=?1", &[&chat]) != 0
    }
}

fn message_from(r: &Row) -> rusqlite::Result<Message> {
    let thumb: Option<Vec<u8>> = r.get(7)?;
    Ok(Message {
        id: r.get(0)?,
        chat: r.get(1)?,
        sender: r.get(2)?,
        from_me: r.get(3)?,
        ts: r.get(4)?,
        kind: r.get(5)?,
        text: r.get(6)?,
        thumb: thumb.filter(|t| !t.is_empty()).map(|t| base64::engine::general_purpose::STANDARD.encode(t)).unwrap_or_default(),
        media_path: r.get(8)?,
        file_name: r.get(9)?,
        w: r.get(10)?,
        h: r.get(11)?,
        quoted_id: r.get(12)?,
        quoted_text: r.get(13)?,
        quoted_sender: r.get(14)?,
        status: r.get(15)?,
        edited: r.get(16)?,
        deleted: r.get(17)?,
        starred: r.get(18)?,
        pinned: r.get(19)?,
        link_title: r.get(20)?,
        link_desc: r.get(21)?,
        mentions_me: r.get(22)?,
        poll_raw: r.get(23)?,
        ..Default::default()
    })
}

fn name_of(conn: &Connection, jid: &str) -> String {
    if jid.is_empty() {
        return String::new();
    }
    let stored: Option<String> = conn
        .query_row(
            "SELECT COALESCE(NULLIF((SELECT name FROM chats WHERE jid=?1),''), (SELECT name FROM contacts WHERE jid=?1), (SELECT name FROM names WHERE jid=?1))",
            [jid],
            |r| r.get(0),
        )
        .optional()
        .ok()
        .flatten()
        .flatten();
    stored.filter(|name: &String| !name.is_empty()).unwrap_or_else(|| display_number(jid))
}

/// "+905551234567" for a JID with no known name.
pub fn display_number(jid: &str) -> String {
    let user = jid.split('@').next().unwrap_or(jid).split(':').next().unwrap_or(jid);
    if jid.ends_with("@s.whatsapp.net") && !user.is_empty() && user.chars().all(|c| c.is_ascii_digit()) {
        format!("+{user}")
    } else {
        user.to_string()
    }
}

/// Writes, inside [`Db::write`].
pub struct Writer<'a> {
    conn: &'a Connection,
}

impl Writer<'_> {
    pub fn exec(&self, sql: &str, args: &[&dyn rusqlite::ToSql]) -> usize {
        self.conn.prepare_cached(sql).and_then(|mut s| s.execute(args)).unwrap_or(0)
    }

    /// Adds a message; false if it was already there.
    pub fn insert_message(&self, m: &NewMessage) -> bool {
        self.exec(
            "INSERT OR IGNORE INTO messages(chat,id,sender,from_me,ts,type,text,thumb,raw,file_name,w,h,quoted_id,quoted_text,quoted_sender,status,unread,
                 link_title,link_desc,poll,mentions_me,expires_at)
             VALUES(?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)",
            params![m.chat, m.id, m.sender, m.from_me, m.ts, m.kind, m.text, m.thumb, m.raw, m.file_name, m.w, m.h, m.quoted_id, m.quoted_text, m.quoted_sender, m.status, m.unread,
                m.link_title, m.link_desc, m.poll, m.mentions_me, m.expires_at],
        ) > 0
    }

    /// Makes sure the chat exists and is no older than `ts` in the list.
    pub fn touch_chat(&self, jid: &str, ts: i64) {
        self.exec(
            "INSERT INTO chats(jid,last_ts) VALUES(?1,?2) ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(last_ts, excluded.last_ts)",
            params![jid, ts],
        );
    }

    /// A person's name as they set it themselves.
    pub fn set_name(&self, jid: &str, name: &str) {
        if !jid.is_empty() && !name.is_empty() {
            self.exec("INSERT INTO names(jid,name) VALUES(?1,?2) ON CONFLICT(jid) DO UPDATE SET name=excluded.name", params![jid, name]);
        }
    }
}
