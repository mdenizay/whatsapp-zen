//! One linked WhatsApp account: the connection, what it writes into the
//! app's database as things arrive, and the commands the UI sends it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::{json, Value};
use whatsapp_rust::prelude::*;
use whatsapp_rust::waproto::buffa::{Message as _, MessageField};
use whatsapp_rust::waproto::whatsapp as wa;

use crate::db::{status, Db, NewMessage};

/// Sends one event (a JSON object) to the UI.
pub type Emit = Arc<dyn Fn(Value) + Send + Sync>;

/// A command from the UI. Every command uses some of these fields.
#[derive(Deserialize, Default, Debug)]
#[serde(default)]
pub struct Request {
    pub cmd: String,
    pub account: String,
    pub chat: String,
    pub id: String,
    pub jid: String,
    pub text: String,
    pub reply_to: String,
    pub on: bool,
    pub limit: i64,
    pub before_ts: i64,
    pub before_id: String,
    pub ts: i64,
    pub unlink: bool,
    pub emoji: String,
    pub seconds: i64,
    /// A length of time for muting and disappearing messages, in seconds.
    pub duration: i64,
    pub path: String,
    pub thumb: String,
    pub w: i64,
    pub h: i64,
    pub kind: String,
    pub mime: String,
    pub file_name: String,
    pub phone: String,
    pub to: String,
    pub options: Vec<String>,
    pub mentions: Vec<String>,
    pub lat: f64,
    pub lng: f64,
    pub plain: bool,
    pub action: String,
    pub video: bool,
}

struct Status {
    /// "starting", "qr", "connecting", "connected" or "logged_out".
    state: &'static str,
    qr: String,
}

pub struct Account {
    pub id: String,
    pub dir: PathBuf,
    pub(crate) db: Db,
    pub(crate) rt: tokio::runtime::Handle,
    client: Mutex<Option<Arc<Client>>>,
    status: Mutex<Status>,
    emit: Emit,
    /// Whether the user is at the app; decides the presence we announce.
    pub(crate) available: std::sync::atomic::AtomicBool,
    /// Per chat, the oldest message history was last asked from, and when.
    pub(crate) history_asked: Mutex<std::collections::HashMap<String, (String, std::time::Instant)>>,
    /// Ringing calls by id: who is calling and who started the call.
    pub(crate) calls: Mutex<std::collections::HashMap<String, (Jid, Jid)>>,
    /// The user's own read receipts are off.
    pub(crate) hide_read: std::sync::atomic::AtomicBool,
    /// Messages whose media is being fetched right now.
    downloading: Mutex<std::collections::HashSet<String>>,
    /// The call in progress.
    pub(crate) call: Mutex<Option<crate::call::ActiveCall>>,
    /// Shows a frame of the other side's video (set by the app).
    pub(crate) screen: Arc<dyn Fn(&[u8], bool) + Send + Sync>,
    /// Incoming calls that are ringing and can still be answered.
    pub(crate) ringing: Mutex<std::collections::HashMap<String, whatsapp_rust::wacore::types::call::IncomingCall>>,
}

/// Takes a message off the list of running downloads when it goes out of scope.
struct Finished<'a>(&'a Mutex<std::collections::HashSet<String>>, String);

impl Drop for Finished<'_> {
    fn drop(&mut self) {
        self.0.lock().unwrap().remove(&self.1);
    }
}

/// A file that counts what is written to it, for download progress.
struct Counting {
    file: std::fs::File,
    written: Arc<std::sync::atomic::AtomicU64>,
}

impl std::io::Write for Counting {
    fn write(&mut self, data: &[u8]) -> std::io::Result<usize> {
        let n = self.file.write(data)?;
        self.written.fetch_add(n as u64, std::sync::atomic::Ordering::Relaxed);
        Ok(n)
    }

    fn flush(&mut self) -> std::io::Result<()> {
        self.file.flush()
    }
}

impl std::io::Seek for Counting {
    fn seek(&mut self, to: std::io::SeekFrom) -> std::io::Result<u64> {
        self.file.seek(to)
    }
}

impl whatsapp_rust::wacore::download::DownloadWriter for Counting {
    fn truncate(&mut self, len: u64) -> std::io::Result<()> {
        self.file.set_len(len)
    }
}

impl Account {
    /// Opens the account kept in `dir` (creating it) and starts connecting.
    pub fn start(id: &str, dir: PathBuf, rt: tokio::runtime::Handle, emit: Emit, screen: Arc<dyn Fn(&[u8], bool) + Send + Sync>) -> Result<Arc<Account>, String> {
        for sub in ["media", "avatars"] {
            std::fs::create_dir_all(dir.join(sub)).map_err(|e| e.to_string())?;
        }
        let db = Db::open(&dir.join("app.db")).map_err(|e| e.to_string())?;
        db.import_old_names(&dir.join("store.db"));
        let account = Arc::new(Account {
            id: id.to_string(),
            dir,
            db,
            rt,
            client: Mutex::new(None),
            status: Mutex::new(Status { state: "starting", qr: String::new() }),
            emit,
            available: std::sync::atomic::AtomicBool::new(false),
            history_asked: Mutex::new(Default::default()),
            calls: Mutex::new(Default::default()),
            hide_read: std::sync::atomic::AtomicBool::new(false),
            downloading: Mutex::new(Default::default()),
            call: Mutex::new(None),
            screen,
            ringing: Mutex::new(Default::default()),
        });
        let me = account.clone();
        account.rt.spawn(async move {
            if let Err(error) = me.clone().run().await {
                me.send(json!({"type": "fatal", "error": error}));
            }
        });
        Ok(account)
    }

    async fn run(self: Arc<Self>) -> Result<(), String> {
        let session = self.dir.join("session.db");
        let store = SqliteStore::new(&session.to_string_lossy()).await.map_err(|e| e.to_string())?;
        let on_qr = self.clone();
        let on_event = self.clone();
        let bot = Bot::builder()
            .with_backend(store)
            .on_qr_code(move |code, _timeout| {
                let me = on_qr.clone();
                async move { me.set_state("qr", &code.to_string()) }
            })
            .on_event(move |event, _client| {
                let me = on_event.clone();
                async move { me.handle(&event).await }
            })
            .build()
            .await
            .map_err(|e| e.to_string())?;
        *self.client.lock().unwrap() = Some(bot.client());
        if self.status.lock().unwrap().state == "starting" {
            self.set_state("connecting", "");
        }
        bot.run().await;
        Ok(())
    }

    pub(crate) fn send(&self, mut event: Value) {
        event["account"] = Value::String(self.id.clone());
        (self.emit)(event);
    }

    /// Our own phone-number id, once linked.
    pub(crate) fn me(&self) -> String {
        self.client().ok().and_then(|client| client.pn()).map(|jid| jid.to_non_ad().to_string()).unwrap_or_default()
    }

    fn state_json(&self) -> Value {
        let status = self.status.lock().unwrap();
        json!({"type": "state", "state": status.state, "qr": status.qr, "me": self.me()})
    }

    pub(crate) fn set_state(&self, state: &'static str, qr: &str) {
        {
            let mut status = self.status.lock().unwrap();
            if status.state == state && status.qr == qr {
                return;
            }
            status.state = state;
            status.qr = qr.to_string();
        }
        self.send(self.state_json());
    }

    pub(crate) fn changed(&self, chat: &str) {
        self.send(json!({"type": "messages", "chat": chat}));
        self.send(json!({"type": "chats"}));
    }

    pub(crate) fn client(&self) -> Result<Arc<Client>, String> {
        self.client.lock().unwrap().clone().ok_or_else(|| "not connected".to_string())
    }

    /// Runs one command. What is not here yet answers with an error the UI
    /// shows; nothing is silently ignored.
    pub fn dispatch(self: &Arc<Self>, r: &Request) -> Result<Value, String> {
        let list = |messages| serde_json::to_value::<Vec<crate::db::Message>>(messages).map_err(|e| e.to_string());
        match r.cmd.as_str() {
            "state" => Ok(self.state_json()),
            "chats" => serde_json::to_value(self.db.chats()).map_err(|e| e.to_string()),
            "messages" => list(self.db.messages(&r.chat, r.before_ts, &r.before_id, r.limit)),
            "starred" => list(self.db.query("chat=?1 AND starred=1 AND deleted=0 ORDER BY ts DESC LIMIT 200", &[&r.chat])),
            "pinned" => list(self.db.query("chat=?1 AND pinned=1 AND deleted=0 ORDER BY ts DESC LIMIT 20", &[&r.chat])),
            "search" | "search_all" => {
                let text = r.text.trim();
                if text.is_empty() {
                    return Ok(json!([]));
                }
                let like = format!("%{}%", text.replace('\\', "\\\\").replace('%', "\\%").replace('_', "\\_"));
                if r.cmd == "search" {
                    list(self.db.query(
                        "chat=?1 AND deleted=0 AND (text LIKE ?2 ESCAPE '\\' OR file_name LIKE ?2 ESCAPE '\\') ORDER BY ts DESC LIMIT 100",
                        &[&r.chat, &like],
                    ))
                } else {
                    list(self.db.query("deleted=0 AND type IN ('text','other') AND text LIKE ?1 ESCAPE '\\' ORDER BY ts DESC LIMIT 60", &[&like]))
                }
            }
            "count_since" => Ok(json!(self.db.count("SELECT COUNT(*) FROM messages WHERE chat=?1 AND ts>=?2", &[&r.chat, &r.ts]))),
            "count_from" => Ok(json!(self.db.count(
                "SELECT COUNT(*) FROM messages WHERE chat=?1 AND ts >= (SELECT ts FROM messages WHERE chat=?1 AND id=?2)",
                &[&r.chat, &r.id],
            ))),
            "call_start" | "call_accept" | "call_end" | "call_mute" | "call_video" => self.call_command(r),
            "send_text" => self.send_text(&r.chat, &r.text, &r.reply_to, &r.mentions),
            "react" => self.react(&r.chat, &r.id, &r.emoji),
            "revoke" => self.revoke(&r.chat, &r.id),
            "edit" => self.edit(&r.chat, &r.id, &r.text),
            "download" => self.download(&r.chat, &r.id).map(Value::String),
            "avatar" => Ok(Value::String(self.avatar(if r.jid.is_empty() { &r.chat } else { &r.jid }))),
            "archive" => self.chat_action(&r.chat, "archived", r.on),
            "pin_chat" => self.chat_action(&r.chat, "pinned", r.on),
            "mute" => self.mute(&r.chat, r.duration),
            "send_image" | "send_file" | "forward" | "pin_message" | "delete_for_me" | "fetch_history" | "group_info" | "group_update"
            | "group_rename" | "group_leave" | "group_link" | "typing" | "presence" | "subscribe" | "subscribe_presence" | "contacts"
            | "start_chat" | "logout" | "block" | "cache_size" | "cache_list" | "cache_remove" | "clear_cache" | "reject_call" | "set_ephemeral"
            | "send_poll" | "vote" | "send_contact" | "send_location" | "chat_media" | "statuses" | "stickers" | "user_info" | "export" | "send_voice"
            | "send_sticker_image" => self.more(r),
            "star" => self.star(&r.chat, &r.id, r.on),
            "mark_read" => {
                self.mark_read(&r.chat);
                Ok(Value::Null)
            }
            // Asked for constantly and harmless to leave for later.
            other => Err(format!("\"{other}\" is not available in the Rust core yet")),
        }
    }

    /// Sends a text, quoting the message it answers.
    fn send_text(self: &Arc<Self>, chat: &str, text: &str, reply_to: &str, mentions: &[String]) -> Result<Value, String> {
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err("Empty message".into());
        }
        let mut row = self.new_row(chat, "text", &text)?;
        // Shown here with names; sent with the ids the protocol wants.
        row.mentioned = mentions.to_vec();
        self.rt.block_on(self.name_mentions(&mut row));
        row.mentions_me = false;
        let mut context = self.reply_context(&mut row, reply_to);
        if !mentions.is_empty() {
            context.get_or_insert_with(Default::default).mentioned_jid = mentions.to_vec();
        }
        let message = match context {
            None => wa::Message::text(text),
            Some(context) => wa::Message {
                extended_text_message: MessageField::some(wa::message::ExtendedTextMessage {
                    text: Some(text),
                    context_info: MessageField::some(context),
                    ..Default::default()
                }),
                ..Default::default()
            },
        };
        let (db_chat, db_id, account) = (row.chat.clone(), row.id.clone(), self.clone());
        let link_text = message.text_content().unwrap_or_default().to_string();
        self.deliver(row, move |_| async move {
            // A link gets its title, description and picture, like the phone adds.
            let preview = tokio::task::spawn_blocking(move || crate::media::link_preview(&link_text)).await.ok().flatten();
            let Some(preview) = preview else { return Ok(message) };
            account.db.write(|w| {
                w.exec("UPDATE messages SET link_title=?3, link_desc=?4, thumb=COALESCE(?5, thumb) WHERE chat=?1 AND id=?2", &[&db_chat, &db_id, &preview.title, &preview.description, &preview.thumb])
            });
            let mut message = message;
            let text = message.text_content().unwrap_or_default().to_string();
            let mut extended = message.extended_text_message.take().unwrap_or_else(|| wa::message::ExtendedTextMessage { text: Some(text), ..Default::default() });
            extended.matched_text = Some(preview.url);
            extended.title = Some(preview.title);
            extended.description = Some(preview.description);
            extended.jpeg_thumbnail = preview.thumb.map(Into::into);
            message.conversation = None;
            message.extended_text_message = MessageField::some(extended);
            Ok(message)
        })
    }

    /// The key that names a stored message to the protocol.
    pub(crate) fn key(&self, chat: &str, id: &str) -> Result<(wa::MessageKey, String, bool), String> {
        let (sender, from_me) = self
            .db
            .get("SELECT sender, from_me FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id], |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?)))
            .ok_or("unknown message")?;
        let key = wa::MessageKey {
            remote_jid: Some(chat.to_string()),
            from_me: Some(from_me),
            id: Some(id.to_string()),
            participant: (chat.ends_with("@g.us") && !from_me).then(|| sender.clone()),
            ..Default::default()
        };
        Ok((key, sender, from_me))
    }

    /// Sets our reaction on a message; an empty emoji takes it back.
    fn react(&self, chat: &str, id: &str, emoji: &str) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let (key, _, _) = self.key(chat, id)?;
        self.rt.block_on(client.send_reaction(jid, key, emoji)).map_err(|e| e.to_string())?;
        self.db.write(|w| set_reaction(w, chat, id, "", emoji));
        self.send(json!({"type": "messages", "chat": chat}));
        Ok(Value::Null)
    }

    /// Deletes one of our messages for everyone.
    fn revoke(&self, chat: &str, id: &str) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let (_, _, from_me) = self.key(chat, id)?;
        if !from_me {
            return Err("only your own messages can be deleted for everyone".into());
        }
        self.rt.block_on(client.revoke_message(jid, id.to_string(), whatsapp_rust::send::RevokeType::Sender)).map_err(|e| e.to_string())?;
        self.db.write(|w| mark_deleted(w, chat, id));
        self.changed(chat);
        Ok(Value::Null)
    }

    /// Replaces the text of one of our messages (WhatsApp allows ~15 minutes).
    fn edit(&self, chat: &str, id: &str, text: &str) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        self.rt.block_on(client.edit_message(jid, id.to_string(), wa::Message::text(text.to_string()))).map_err(|e| e.to_string())?;
        self.db.write(|w| w.exec("UPDATE messages SET text=?3, edited=1 WHERE chat=?1 AND id=?2", &[&chat, &id, &text]));
        self.changed(chat);
        Ok(Value::Null)
    }

    /// Fetches a message's media file, once, and returns where it is. The
    /// file goes straight to disk, and a large one reports how far it is.
    fn download(&self, chat: &str, id: &str) -> Result<String, String> {
        use whatsapp_rust::download::Downloadable;
        let stored = |me: &Self| {
            me.db.get("SELECT raw, type, file_name, media_path FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id], |r| {
                Ok((r.get::<_, Option<Vec<u8>>>(0)?, r.get::<_, String>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?))
            })
        };
        // One download per message, however many views ask for it at once.
        while !self.downloading.lock().unwrap().insert(id.to_string()) {
            std::thread::sleep(std::time::Duration::from_millis(150));
        }
        let _guard = Finished(&self.downloading, id.to_string());
        let (raw, kind, file_name, path) = stored(self).ok_or("unknown message")?;
        if !path.is_empty() && std::path::Path::new(&path).exists() {
            return Ok(path);
        }
        let raw = raw.filter(|raw| !raw.is_empty()).ok_or("this message has no media")?;
        let message = wa::Message::decode_from_slice(&raw).map_err(|e| e.to_string())?;
        let base = message.get_base_message();
        let client = self.client()?;
        let mut ext = match kind.as_str() {
            "image" => ".jpg",
            "video" => ".mp4",
            "audio" => ".ogg",
            "sticker" => ".webp",
            _ => "",
        }
        .to_string();
        let (media, total): (&dyn Downloadable, u64) = if let Some(media) = base.image_message.as_option() {
            if media.mimetype.as_deref().is_some_and(|m| m.contains("png")) {
                ext = ".png".into();
            }
            (media, media.file_length.unwrap_or(0))
        } else if let Some(media) = base.video_message.as_option().or(base.ptv_message.as_option()) {
            (media, media.file_length.unwrap_or(0))
        } else if let Some(media) = base.audio_message.as_option() {
            (media, media.file_length.unwrap_or(0))
        } else if let Some(media) = base.document_message.as_option() {
            ext = std::path::Path::new(&file_name).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
            (media, media.file_length.unwrap_or(0))
        } else if let Some(media) = base.sticker_message.as_option() {
            (media, media.file_length.unwrap_or(0))
        } else {
            return Err("this message has no media".into());
        };
        let file = self.dir.join("media").join(format!("{}{ext}", safe_name(id)));
        let part = file.with_extension("part");
        let written = Arc::new(std::sync::atomic::AtomicU64::new(0));
        let writer = Counting { file: std::fs::File::create(&part).map_err(|e| e.to_string())?, written: written.clone() };
        let reports = total > 512 << 10;
        let progress = reports.then(|| {
            let (emit, account, chat, id, written) = (self.emit.clone(), self.id.clone(), chat.to_string(), id.to_string(), written.clone());
            self.rt.spawn(async move {
                loop {
                    tokio::time::sleep(std::time::Duration::from_millis(250)).await;
                    let done = written.load(std::sync::atomic::Ordering::Relaxed).min(total);
                    emit(json!({"account": account, "type": "download", "chat": chat, "id": id, "done": done, "total": total}));
                }
            })
        });
        let result = self.rt.block_on(client.download_to_writer(media, writer));
        if let Some(progress) = progress {
            progress.abort();
            // Tells the views the bar can go, whether or not it worked.
            self.send(json!({"type": "download", "chat": chat, "id": id, "done": total, "total": total, "finished": true}));
        }
        if let Err(error) = result {
            let _ = std::fs::remove_file(&part);
            return Err(error.to_string());
        }
        std::fs::rename(&part, &file).map_err(|e| e.to_string())?;
        let file = file.to_string_lossy().into_owned();
        self.db.write(|w| w.exec("UPDATE messages SET media_path=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &file]));
        Ok(file)
    }

    /// The profile photo of a chat as a file, fetched once; empty when there
    /// is none or it cannot be had right now.
    fn avatar(&self, jid: &str) -> String {
        let file = self.dir.join("avatars").join(format!("{}.jpg", safe_name(jid)));
        if file.exists() {
            return file.to_string_lossy().into_owned();
        }
        // Remembered as "has none", so the server is not asked on every redraw.
        let none = file.with_extension("none");
        if none.metadata().and_then(|m| m.modified()).is_ok_and(|at| at.elapsed().is_ok_and(|age| age.as_secs() < 86400)) {
            return String::new();
        }
        let (Ok(client), Ok(parsed)) = (self.client(), jid.parse::<Jid>()) else { return String::new() };
        let picture = self.rt.block_on(client.contacts().get_profile_picture(&parsed, true)).ok().flatten();
        let bytes = picture.and_then(|picture| {
            let mut body = ureq::get(&picture.url).call().ok()?.into_body();
            body.read_to_vec().ok()
        });
        match bytes {
            Some(bytes) if !bytes.is_empty() && std::fs::write(&file, &bytes).is_ok() => file.to_string_lossy().into_owned(),
            _ => {
                let _ = std::fs::write(&none, b"");
                String::new()
            }
        }
    }

    /// Archives or pins a chat, on every device.
    fn chat_action(&self, chat: &str, column: &'static str, on: bool) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let actions = client.chat_actions();
        self.rt
            .block_on(async {
                match (column, on) {
                    ("archived", true) => actions.archive_chat(&jid, None).await,
                    ("archived", false) => actions.unarchive_chat(&jid, None).await,
                    (_, true) => actions.pin_chat(&jid).await,
                    (_, false) => actions.unpin_chat(&jid).await,
                }
            })
            .map_err(|e| e.to_string())?;
        self.db.write(|w| {
            w.exec(&format!("UPDATE chats SET {column}=?2 WHERE jid=?1"), &[&chat, &on]);
            // An archived chat is not pinned, as on the phone.
            if column == "archived" && on {
                w.exec("UPDATE chats SET pinned=0 WHERE jid=?1", &[&chat]);
            }
        });
        self.send(json!({"type": "chats"}));
        Ok(Value::Null)
    }

    /// Mutes a chat for `seconds`, for good when negative, or not at all when zero.
    fn mute(&self, chat: &str, seconds: i64) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let until = if seconds > 0 { now() + seconds } else { seconds.signum() };
        let actions = client.chat_actions();
        self.rt
            .block_on(async {
                match seconds {
                    0 => actions.unmute_chat(&jid).await,
                    s if s < 0 => actions.mute_chat(&jid).await,
                    _ => actions.mute_chat_until(&jid, until * 1000).await,
                }
            })
            .map_err(|e| e.to_string())?;
        self.db.write(|w| w.exec("UPDATE chats SET muted_until=?2 WHERE jid=?1", &[&chat, &until]));
        self.send(json!({"type": "chats"}));
        Ok(Value::Null)
    }

    fn star(&self, chat: &str, id: &str, on: bool) -> Result<Value, String> {
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let (key, _, from_me) = self.key(chat, id)?;
        let participant = key.participant.as_deref().and_then(|p| p.parse::<Jid>().ok());
        let actions = client.chat_actions();
        self.rt
            .block_on(async {
                if on {
                    actions.star_message(&jid, participant.as_ref(), id, from_me).await
                } else {
                    actions.unstar_message(&jid, participant.as_ref(), id, from_me).await
                }
            })
            .map_err(|e| e.to_string())?;
        self.db.write(|w| w.exec("UPDATE messages SET starred=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &on]));
        self.send(json!({"type": "messages", "chat": chat}));
        Ok(Value::Null)
    }

    /// Marks a chat read here and tells the senders.
    fn mark_read(self: &Arc<Self>, chat: &str) {
        let unread = self.db.unread_messages(chat);
        if unread.is_empty() && self.db.count("SELECT unread FROM chats WHERE jid=?1", &[&chat]) == 0 {
            return;
        }
        self.db.write(|w| {
            w.exec("UPDATE messages SET unread=0 WHERE chat=?1 AND unread=1", &[&chat]);
            w.exec("UPDATE chats SET unread=0 WHERE jid=?1", &[&chat]);
        });
        self.send(json!({"type": "chats"}));
        let (Ok(client), Ok(jid)) = (self.client(), chat.parse::<Jid>()) else { return };
        let group = chat.ends_with("@g.us");
        self.rt.spawn(async move {
            // One receipt per sender, as the protocol wants for groups.
            let mut by_sender: std::collections::HashMap<String, Vec<String>> = Default::default();
            for (id, sender) in unread {
                by_sender.entry(sender).or_default().push(id);
            }
            for (sender, ids) in by_sender {
                let sender = sender.parse::<Jid>().ok();
                let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
                let _ = client.mark_as_read(&jid, if group { sender.as_ref() } else { None }, &ids).await;
            }
        });
    }

    /// The chat or person behind a JID, by phone number where it is known.
    /// WhatsApp addresses many people by a hidden id ("…@lid"); without this
    /// one person would show up as two chats.
    pub(crate) async fn pn(&self, jid: &Jid) -> String {
        let plain = jid.to_non_ad();
        if plain.is_lid() {
            if let Ok(client) = self.client() {
                if let Ok(Some(entry)) = client.get_lid_pn_entry(&plain).await {
                    return format!("{}@s.whatsapp.net", entry.phone_number);
                }
            }
        }
        plain.to_string()
    }

    pub(crate) async fn pn_str(&self, jid: &str) -> String {
        if !jid.ends_with("@lid") {
            return jid.to_string();
        }
        match jid.parse::<Jid>() {
            Ok(parsed) => self.pn(&parsed).await,
            Err(_) => jid.to_string(),
        }
    }

    /// Moves what was stored under hidden ids to the phone-number ids now
    /// that the mapping is known, merging with what is already there.
    async fn repair_hidden_ids(&self) {
        let hidden = self.db.hidden_ids();
        let mut known = Vec::new();
        for lid in hidden {
            let pn = self.pn_str(&lid).await;
            if pn != lid {
                known.push((lid, pn));
            }
        }
        if known.is_empty() {
            return;
        }
        self.db.write(|w| {
            for (lid, pn) in &known {
                w.exec("UPDATE OR IGNORE messages SET chat=?2 WHERE chat=?1", &[lid, pn]);
                w.exec("DELETE FROM messages WHERE chat=?1", &[lid]);
                w.exec("UPDATE messages SET sender=?2 WHERE sender=?1", &[lid, pn]);
                w.exec("UPDATE messages SET quoted_sender=?2 WHERE quoted_sender=?1", &[lid, pn]);
                w.exec("UPDATE OR IGNORE reactions SET chat=?2 WHERE chat=?1", &[lid, pn]);
                w.exec("UPDATE OR IGNORE names SET jid=?2 WHERE jid=?1", &[lid, pn]);
                w.exec("DELETE FROM names WHERE jid=?1", &[lid]);
                w.exec(
                    "INSERT INTO chats(jid,last_ts,unread,archived,pinned)
                     SELECT ?2,last_ts,unread,archived,pinned FROM chats WHERE jid=?1
                     ON CONFLICT(jid) DO UPDATE SET last_ts=MAX(last_ts, excluded.last_ts), unread=unread+excluded.unread",
                    &[lid, pn],
                );
                w.exec("DELETE FROM chats WHERE jid=?1", &[lid]);
            }
        });
        self.send(json!({"type": "chats"}));
        self.send(json!({"type": "messages", "chat": ""}));
    }

    /// Messages that change another message instead of being one: a reaction,
    /// a deletion, an edit. True if this was one of them.
    fn apply_side_effect(&self, chat: &str, sender: &str, message: &wa::Message) -> bool {
        let base = message.get_base_message();
        if let Some(reaction) = base.reaction_message.as_option() {
            if let Some(target) = reaction.key.as_option().and_then(|key| key.id.as_deref()) {
                self.db.write(|w| set_reaction(w, chat, target, sender, reaction.text.as_deref().unwrap_or("")));
                self.send(json!({"type": "messages", "chat": chat}));
            }
            return true;
        }
        if let Some(pin) = base.pin_in_chat_message.as_option() {
            use wa::message::pin_in_chat_message::Type;
            if let Some(target) = pin.key.as_option().and_then(|key| key.id.as_deref()) {
                let pinned = pin.r#type == Some(Type::PinForAll);
                self.db.write(|w| w.exec("UPDATE messages SET pinned=?3 WHERE chat=?1 AND id=?2", &[&chat, &target, &pinned]));
                self.send(json!({"type": "messages", "chat": chat}));
            }
            return true;
        }
        if let Some(protocol) = base.protocol_message.as_option() {
            use wa::message::protocol_message::Type;
            let target = protocol.key.as_option().and_then(|key| key.id.clone()).unwrap_or_default();
            match protocol.r#type {
                Some(Type::Revoke) if !target.is_empty() => {
                    self.db.write(|w| mark_deleted(w, chat, &target));
                    self.changed(chat);
                }
                Some(Type::EphemeralSetting) => {
                    // The chat's disappearing-message timer was changed.
                    let timer = protocol.ephemeral_expiration.unwrap_or(0);
                    self.db.write(|w| w.exec("UPDATE chats SET ephemeral=?2 WHERE jid=?1", &[&chat, &timer]));
                    self.send(json!({"type": "chats"}));
                }
                Some(Type::MessageEdit) if !target.is_empty() => {
                    if let Some(text) = protocol.edited_message.as_option().and_then(|edited| edited.text_content()) {
                        self.db.write(|w| w.exec("UPDATE messages SET text=?3, edited=1 WHERE chat=?1 AND id=?2", &[&chat, &target, &text]));
                        self.changed(chat);
                    }
                }
                _ => {}
            }
            return true;
        }
        false
    }

    async fn handle(self: &Arc<Self>, event: &Event) {
        match event {
            Event::Connected(_) => {
                self.set_state("connected", "");
                self.send(json!({"type": "chats"}));
                self.repair_hidden_ids().await;
                self.refresh_privacy().await;
                self.refresh_groups().await;
                self.announce_presence();
            }
            Event::PairSuccess(_) => self.set_state("connecting", ""),
            Event::LoggedOut(_) => self.set_state("logged_out", ""),
            Event::Disconnected(_) => {
                if self.status.lock().unwrap().state == "connected" {
                    self.set_state("connecting", "");
                }
            }
            Event::Messages(batch) => {
                for inbound in batch.iter() {
                    let info = &inbound.info;
                    let source = &info.source;
                    let from_me = source.is_from_me;
                    // A one-to-one chat addressed by hidden id carries the
                    // phone-number id alongside; prefer it to a lookup.
                    let chat = if source.chat.is_lid() {
                        match if from_me { &source.recipient_alt } else { &source.sender_alt } {
                            Some(alt) if !alt.is_lid() => alt.to_non_ad().to_string(),
                            _ => self.pn(&source.chat).await,
                        }
                    } else {
                        source.chat.to_non_ad().to_string()
                    };
                    if (chat.ends_with("@broadcast") && chat != crate::commands::STATUS_CHAT) || chat.ends_with("@newsletter") {
                        continue;
                    }
                    let sender = if from_me {
                        String::new()
                    } else {
                        match &source.sender_alt {
                            Some(alt) if source.sender.is_lid() && !alt.is_lid() => alt.to_non_ad().to_string(),
                            _ => self.pn(&source.sender).await,
                        }
                    };
                    if self.apply_side_effect(&chat, &sender, &inbound.message) {
                        continue;
                    }
                    if self.apply_poll_vote(&chat, &sender, from_me, &source.sender, &inbound.message).await {
                        continue;
                    }
                    let Some(mut message) = row(&chat, info.id.as_ref(), &sender, from_me, info.timestamp.timestamp(), &inbound.message) else {
                        continue;
                    };
                    // The person quoted may be named by a hidden id as well.
                    if message.quoted_sender.ends_with("@lid") {
                        message.quoted_sender = self.pn_str(&message.quoted_sender).await;
                    }
                    message.status = if from_me { status::SENT } else { 0 };
                    message.unread = !from_me;
                    self.name_mentions(&mut message).await;
                    // Statuses are kept for the status viewer, not as a chat.
                    let is_status = chat == crate::commands::STATUS_CHAT;
                    let fresh = self.db.write(|w| {
                        if !from_me {
                            w.set_name(&sender, &info.push_name);
                        }
                        if !w.insert_message(&message) {
                            return false;
                        }
                        if is_status {
                            return false;
                        }
                        w.touch_chat(&chat, message.ts);
                        if from_me {
                            // Sent from the phone or another device: the chat has been seen there.
                            w.exec("UPDATE messages SET unread=0 WHERE chat=?1 AND unread=1", &[&chat]);
                            w.exec("UPDATE chats SET unread=0 WHERE jid=?1", &[&chat]);
                        } else {
                            w.exec("UPDATE chats SET unread=unread+1 WHERE jid=?1", &[&chat]);
                        }
                        true
                    });
                    if !fresh {
                        continue;
                    }
                    let recent = now() - message.ts < 120;
                    self.send(json!({
                        "type": "message", "chat": chat, "chat_name": self.db.name_of(&chat),
                        "msg": self.db.message(&chat, &message.id),
                        "notify": !from_me && recent && !info.is_offline && !self.db.is_muted(&chat),
                    }));
                }
            }
            Event::Receipt(receipt) => {
                use whatsapp_rust::wacore::types::presence::ReceiptType;
                let chat = self.pn(&receipt.source.chat).await;
                let to = match receipt.r#type {
                    // With our own read receipts off, one-to-one chats show nobody else's.
                    ReceiptType::Read if self.hide_read.load(std::sync::atomic::Ordering::Relaxed) && !chat.ends_with("@g.us") => status::DELIVERED,
                    ReceiptType::Read => status::READ,
                    // "Played" is sent whatever the other side's read-receipt setting, and is not a blue tick.
                    ReceiptType::Delivered | ReceiptType::Played => status::DELIVERED,
                    _ => return,
                };
                if receipt.source.is_from_me {
                    return;
                }
                let changed = self.db.write(|w| {
                    receipt.message_ids.iter().fold(0, |n, id| {
                        let id: &str = id.as_ref();
                        n + w.exec("UPDATE messages SET status=?3 WHERE chat=?1 AND id=?2 AND from_me=1 AND status>=0 AND status<?3", &[&chat, &id, &to])
                    })
                });
                // Every device of every recipient sends its own receipt; most change nothing.
                if changed > 0 {
                    self.changed(&chat);
                }
            }
            Event::HistorySync(lazy) => {
                let Some(history) = lazy.get() else { return };
                // Hidden ids are resolved first: the database is written without awaiting.
                let mut resolved: std::collections::HashMap<String, String> = Default::default();
                for conversation in &history.conversations {
                    let mut ids = vec![conversation.id.clone()];
                    for entry in &conversation.messages {
                        if let Some(web) = entry.message.as_option() {
                            ids.extend(web.key.as_option().and_then(|k| k.participant.clone()));
                            ids.extend(web.participant.clone());
                        }
                    }
                    for id in ids {
                        if id.ends_with("@lid") && !resolved.contains_key(&id) {
                            let pn = match (&conversation.pn_jid, id == conversation.id) {
                                (Some(pn), true) if !pn.is_empty() => pn.split(':').next().unwrap_or(pn).to_string() + if pn.contains('@') { "" } else { "@s.whatsapp.net" },
                                _ => self.pn_str(&id).await,
                            };
                            resolved.insert(id, pn);
                        }
                    }
                }
                let plain = |id: &str| resolved.get(id).cloned().unwrap_or_else(|| id.to_string());
                // Only the first sync after linking describes a chat's settings.
                let bootstrap = lazy.sync_type() == wa::history_sync::HistorySyncType::InitialBootstrap as i32;
                // Someone quoted under a hidden id: put right after the write.
                let mut hidden_quote = false;
                self.db.write(|w| {
                    for name in &history.pushnames {
                        if let (Some(id), Some(name)) = (&name.id, &name.pushname) {
                            w.set_name(id, name);
                        }
                    }
                    for conversation in &history.conversations {
                        let chat = plain(&conversation.id);
                        let chat = chat.as_str();
                        if chat.is_empty() || chat.ends_with("@broadcast") || chat.ends_with("@newsletter") {
                            continue;
                        }
                        w.touch_chat(chat, conversation.conversation_timestamp.unwrap_or(0) as i64);
                        if let Some(name) = conversation.name.as_deref().filter(|n| !n.is_empty()) {
                            if chat.ends_with("@g.us") {
                                w.exec("UPDATE chats SET name=?2 WHERE jid=?1", &[&chat, &name]);
                            } else {
                                w.set_name(chat, name);
                            }
                        }
                        if let Some(timer) = conversation.ephemeral_expiration.filter(|t| *t > 0) {
                            w.exec("UPDATE chats SET ephemeral=?2 WHERE jid=?1", &[&chat, &timer]);
                        }
                        if bootstrap {
                            w.exec(
                                "UPDATE chats SET archived=?2, pinned=?3 WHERE jid=?1",
                                &[&chat, &conversation.archived.unwrap_or(false), &(conversation.pinned.unwrap_or(0) > 0)],
                            );
                        }
                        for entry in &conversation.messages {
                            let Some(web) = entry.message.as_option() else { continue };
                            let (Some(key), Some(body)) = (web.key.as_option(), web.message.as_option()) else { continue };
                            let from_me = key.from_me.unwrap_or(false);
                            let sender = if from_me {
                                String::new()
                            } else {
                                key.participant.as_deref().or(web.participant.as_deref()).map(plain).unwrap_or_else(|| chat.to_string())
                            };
                            let Some(mut message) = row(chat, key.id.as_deref().unwrap_or(""), &sender, from_me, web.message_timestamp.unwrap_or(0) as i64, body) else {
                                continue;
                            };
                            hidden_quote |= message.quoted_sender.ends_with("@lid");
                            if from_me {
                                // WebMessageInfo status: 1 pending, 2 server ack, 3 delivered, 4 read, 5 played
                                message.status = (web.status.map(|s| s as i32).unwrap_or(2) - 1).clamp(status::SENT, status::READ);
                            } else if let Some(name) = &web.push_name {
                                w.set_name(&sender, name);
                            }
                            if w.insert_message(&message) {
                                w.touch_chat(chat, message.ts);
                            }
                        }
                        let unread = conversation.unread_count.unwrap_or(0);
                        if unread > 0 && unread < 10000 {
                            w.exec("UPDATE chats SET unread=?2 WHERE jid=?1", &[&chat, &unread]);
                            w.exec(
                                "UPDATE messages SET unread=1 WHERE chat=?1 AND id IN (SELECT id FROM messages WHERE chat=?1 AND from_me=0 ORDER BY ts DESC LIMIT ?2)",
                                &[&chat, &unread],
                            );
                        }
                    }
                });
                if hidden_quote {
                    self.repair_hidden_ids().await;
                }
                self.send(json!({"type": "chats"}));
                self.send(json!({"type": "messages", "chat": ""}));
            }
            other => self.handle_more(other).await,
        }
    }
}

/// A protocol message as a row of ours; `None` for what is not shown
/// (protocol housekeeping, reactions, keys).
pub(crate) fn row(chat: &str, id: &str, sender: &str, from_me: bool, ts: i64, message: &wa::Message) -> Option<NewMessage> {
    if id.is_empty() {
        return None;
    }
    let base = message.get_base_message();
    let mut out = NewMessage { chat: chat.to_string(), id: id.to_string(), sender: sender.to_string(), from_me, ts, ..Default::default() };
    let mut context = None;
    if let Some(text) = base.text_content() {
        out.kind = "text".into();
        out.text = text.to_string();
        context = base.extended_text_message.as_option().and_then(|m| m.context_info.as_option());
    } else if let Some(image) = base.image_message.as_option() {
        context = image.context_info.as_option();
        out.kind = "image".into();
        out.text = image.caption.clone().unwrap_or_default();
        out.w = image.width.unwrap_or(0) as i64;
        out.h = image.height.unwrap_or(0) as i64;
        out.thumb = image.jpeg_thumbnail.as_ref().map(|t| t.to_vec());
    } else if let Some(video) = base.video_message.as_option() {
        context = video.context_info.as_option();
        out.kind = "video".into();
        out.text = video.caption.clone().unwrap_or_default();
        out.w = video.width.unwrap_or(0) as i64;
        out.h = video.height.unwrap_or(0) as i64;
        out.thumb = video.jpeg_thumbnail.as_ref().map(|t| t.to_vec());
    } else if let Some(audio) = base.audio_message.as_option() {
        context = audio.context_info.as_option();
        out.kind = "audio".into();
        // The UI reads a voice message's length from `w`.
        out.w = audio.seconds.unwrap_or(0) as i64;
    } else if let Some(document) = base.document_message.as_option() {
        context = document.context_info.as_option();
        out.kind = "document".into();
        out.text = document.caption.clone().unwrap_or_default();
        out.file_name = document.file_name.clone().or_else(|| document.title.clone()).unwrap_or_default();
    } else if let Some(sticker) = base.sticker_message.as_option() {
        context = sticker.context_info.as_option();
        out.kind = "sticker".into();
        out.w = sticker.width.unwrap_or(0) as i64;
        out.h = sticker.height.unwrap_or(0) as i64;
    } else if let Some(video) = base.ptv_message.as_option() {
        context = video.context_info.as_option();
        out.kind = "video".into();
        out.w = video.width.unwrap_or(0) as i64;
        out.h = video.height.unwrap_or(0) as i64;
        out.thumb = video.jpeg_thumbnail.as_ref().map(|t| t.to_vec());
    } else if let Some(contact) = base.contact_message.as_option() {
        out.kind = "other".into();
        out.text = format!("👤 {}: {}", crate::i18n::t("Contact"), contact.display_name.as_deref().unwrap_or(""));
    } else if base.contacts_array_message.is_set() {
        out.kind = "other".into();
        out.text = format!("👤 {}", crate::i18n::t("Contacts"));
    } else if let Some(place) = base.location_message.as_option() {
        out.kind = "other".into();
        out.text = match place.name.as_deref().filter(|name| !name.is_empty()) {
            Some(name) => format!("📍 {}: {name}", crate::i18n::t("Location")),
            None => format!("📍 {}", crate::i18n::t("Location")),
        };
        out.text += &format!("\nhttps://maps.apple.com/?ll={:.6},{:.6}", place.degrees_latitude.unwrap_or(0.0), place.degrees_longitude.unwrap_or(0.0));
    } else if base.live_location_message.is_set() {
        out.kind = "other".into();
        out.text = format!("📍 {}", crate::i18n::t("Live location"));
    } else if let Some(poll) = [&base.poll_creation_message, &base.poll_creation_message_v2, &base.poll_creation_message_v3].into_iter().find_map(|p| p.as_option()) {
        context = poll.context_info.as_option();
        out.kind = "poll".into();
        out.text = poll.name.clone().unwrap_or_default();
        let secret = message.message_context_info.as_option().and_then(|info| info.message_secret.as_ref()).map(|s| base64::Engine::encode(&base64::engine::general_purpose::STANDARD, s));
        out.poll = json!({
            "options": poll.options.iter().filter_map(|o| o.option_name.clone()).collect::<Vec<_>>(),
            "selectable": poll.selectable_options_count.unwrap_or(0),
            "secret": secret.unwrap_or_default(),
        })
        .to_string();
    } else if let Some(event) = base.event_message.as_option() {
        context = event.context_info.as_option();
        out.kind = "other".into();
        out.text = format!("📅 {}", event.name.as_deref().unwrap_or(""));
        if let Some(description) = event.description.as_deref().filter(|d| !d.is_empty()) {
            out.text += &format!("\n{description}");
        }
    } else if let Some(invite) = base.group_invite_message.as_option() {
        out.kind = "other".into();
        out.text = format!("✉️ {}: {}", crate::i18n::t("Group invite"), invite.group_name.as_deref().unwrap_or(""));
    } else if base.call.is_set() {
        out.kind = "other".into();
        out.text = format!("📞 {}", crate::i18n::t("Call"));
    } else {
        return None;
    }
    // A link's title, description and picture, as the sender attached them.
    if let Some(link) = base.extended_text_message.as_option().filter(|m| m.title.as_deref().is_some_and(|t| !t.is_empty())) {
        out.link_title = link.title.clone().unwrap_or_default();
        out.link_desc = link.description.clone().unwrap_or_default();
        if let Some(thumb) = link.jpeg_thumbnail.as_ref().filter(|t| !t.is_empty()) {
            out.thumb = Some(thumb.to_vec());
        }
    }
    if let Some(context) = context {
        if let Some(seconds) = context.expiration.filter(|s| *s > 0) {
            out.expires_at = ts + seconds as i64;
        }
        out.mentioned = context.mentioned_jid.clone();
    }
    // The message a reply quotes.
    if let Some(context) = context {
        if let Some(quoted) = context.stanza_id.as_deref().filter(|id| !id.is_empty()) {
            out.quoted_id = quoted.to_string();
            out.quoted_sender = context.participant.clone().unwrap_or_default().split(':').next().unwrap_or("").to_string();
            if let Some(original) = context.quoted_message.as_option() {
                out.quoted_text = row(chat, "quoted", "", false, 0, original)
                    .map(|q| if q.kind == "text" { q.text } else if q.text.is_empty() { q.kind } else { q.text })
                    .unwrap_or_default();
            }
        }
    }
    // Media keeps its protocol message: it holds the keys to download with.
    if matches!(out.kind.as_str(), "image" | "video" | "audio" | "document" | "sticker") {
        out.raw = Some(message.encode_to_vec());
    }
    Some(out)
}

/// Sets `sender`'s reaction on a message ("" is us); an empty emoji removes it.
pub(crate) fn set_reaction(w: &crate::db::Writer, chat: &str, id: &str, sender: &str, emoji: &str) {
    if emoji.is_empty() {
        w.exec("DELETE FROM reactions WHERE chat=?1 AND msg_id=?2 AND sender=?3", &[&chat, &id, &sender]);
    } else {
        w.exec(
            "INSERT INTO reactions(chat,msg_id,sender,emoji) VALUES(?1,?2,?3,?4) ON CONFLICT(chat,msg_id,sender) DO UPDATE SET emoji=excluded.emoji",
            &[&chat, &id, &sender, &emoji],
        );
    }
}

pub(crate) fn mark_deleted(w: &crate::db::Writer, chat: &str, id: &str) {
    w.exec("UPDATE messages SET deleted=1, text='', thumb=NULL, raw=NULL, media_path='' WHERE chat=?1 AND id=?2", &[&chat, &id]);
}

/// A string safe to use as a file name.
pub(crate) fn safe_name(text: &str) -> String {
    text.chars().map(|c| if c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' { c } else { '_' }).collect()
}

pub(crate) fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}
