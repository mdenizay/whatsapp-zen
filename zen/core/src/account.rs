//! One linked WhatsApp account: the connection, what it writes into the
//! app's database as things arrive, and the commands the UI sends it.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use serde::Deserialize;
use serde_json::{json, Value};
use whatsapp_rust::prelude::*;
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
}

struct Status {
    /// "starting", "qr", "connecting", "connected" or "logged_out".
    state: &'static str,
    qr: String,
}

pub struct Account {
    pub id: String,
    pub dir: PathBuf,
    db: Db,
    rt: tokio::runtime::Handle,
    client: Mutex<Option<Arc<Client>>>,
    status: Mutex<Status>,
    emit: Emit,
}

impl Account {
    /// Opens the account kept in `dir` (creating it) and starts connecting.
    pub fn start(id: &str, dir: PathBuf, rt: tokio::runtime::Handle, emit: Emit) -> Result<Arc<Account>, String> {
        for sub in ["media", "avatars"] {
            std::fs::create_dir_all(dir.join(sub)).map_err(|e| e.to_string())?;
        }
        let db = Db::open(&dir.join("app.db")).map_err(|e| e.to_string())?;
        let account = Arc::new(Account {
            id: id.to_string(),
            dir,
            db,
            rt,
            client: Mutex::new(None),
            status: Mutex::new(Status { state: "starting", qr: String::new() }),
            emit,
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
                async move { me.handle(&event) }
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

    fn send(&self, mut event: Value) {
        event["account"] = Value::String(self.id.clone());
        (self.emit)(event);
    }

    fn state_json(&self) -> Value {
        let status = self.status.lock().unwrap();
        json!({"type": "state", "state": status.state, "qr": status.qr, "me": ""})
    }

    fn set_state(&self, state: &'static str, qr: &str) {
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

    fn changed(&self, chat: &str) {
        self.send(json!({"type": "messages", "chat": chat}));
        self.send(json!({"type": "chats"}));
    }

    fn client(&self) -> Result<Arc<Client>, String> {
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
            "search" => {
                let like = format!("%{}%", r.text);
                list(self.db.query("chat=?1 AND deleted=0 AND text LIKE ?2 ORDER BY ts DESC LIMIT 100", &[&r.chat, &like]))
            }
            "search_all" => {
                let like = format!("%{}%", r.text);
                list(self.db.query("deleted=0 AND type='text' AND text LIKE ?1 ORDER BY ts DESC LIMIT 40", &[&like]))
            }
            "count_since" => Ok(json!(self.db.count("SELECT COUNT(*) FROM messages WHERE chat=?1 AND ts>=?2", &[&r.chat, &r.ts]))),
            "count_from" => Ok(json!(self.db.count(
                "SELECT COUNT(*) FROM messages WHERE chat=?1 AND ts >= (SELECT ts FROM messages WHERE chat=?1 AND id=?2)",
                &[&r.chat, &r.id],
            ))),
            "send_text" => self.send_text(&r.chat, &r.text),
            "mark_read" => {
                self.mark_read(&r.chat);
                Ok(Value::Null)
            }
            // Asked for constantly and harmless to leave for later.
            "presence" | "subscribe" | "typing" | "fetch_history" => Ok(Value::Null),
            "avatar" => Ok(json!("")),
            "contacts" | "statuses" | "stickers" | "chat_media" | "cache_list" => Ok(json!([])),
            "cache_size" => Ok(json!(0)),
            other => Err(format!("\"{other}\" is not available in the Rust core yet")),
        }
    }

    /// Sends a text. It shows at once as pending and settles when the server
    /// has taken it.
    fn send_text(self: &Arc<Self>, chat: &str, text: &str) -> Result<Value, String> {
        let text = text.trim().to_string();
        if text.is_empty() {
            return Err("empty message".into());
        }
        let client = self.client()?;
        let jid: Jid = chat.parse().map_err(|_| "bad chat id".to_string())?;
        let now = now();
        let pending = format!("pending-{}", now_nanos());
        self.db.write(|w| {
            w.touch_chat(chat, now);
            w.insert_message(&NewMessage {
                chat: chat.to_string(),
                id: pending.clone(),
                from_me: true,
                ts: now,
                kind: "text".into(),
                text: text.clone(),
                status: status::PENDING,
                ..Default::default()
            });
            // Writing in a chat means having read it.
            w.exec("UPDATE messages SET unread=0 WHERE chat=?1 AND unread=1", &[&chat]);
            w.exec("UPDATE chats SET unread=0 WHERE jid=?1", &[&chat]);
        });
        self.changed(chat);
        let shown = self.db.message(chat, &pending);
        let me = self.clone();
        let chat = chat.to_string();
        self.rt.spawn(async move {
            match client.send_message(jid, wa::Message::text(text)).await {
                Ok(sent) => {
                    let id = sent.message_id.to_string();
                    me.db.write(|w| {
                        w.exec("UPDATE OR REPLACE messages SET id=?3, status=?4 WHERE chat=?1 AND id=?2", &[&chat, &pending, &id, &status::SENT]);
                    });
                }
                Err(_) => {
                    me.db.write(|w| w.exec("UPDATE messages SET status=?3 WHERE chat=?1 AND id=?2", &[&chat, &pending, &status::FAILED]));
                }
            }
            me.changed(&chat);
        });
        serde_json::to_value(shown).map_err(|e| e.to_string())
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

    fn handle(&self, event: &Event) {
        match event {
            Event::Connected(_) => {
                self.set_state("connected", "");
                self.send(json!({"type": "chats"}));
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
                    let chat = info.source.chat.to_non_ad().to_string();
                    if chat.ends_with("@broadcast") || chat.ends_with("@newsletter") {
                        continue;
                    }
                    let from_me = info.source.is_from_me;
                    let sender = if from_me { String::new() } else { info.source.sender.to_non_ad().to_string() };
                    let Some(mut message) = row(&chat, info.id.as_ref(), &sender, from_me, info.timestamp.timestamp(), &inbound.message) else {
                        continue;
                    };
                    message.status = if from_me { status::SENT } else { 0 };
                    message.unread = !from_me;
                    let fresh = self.db.write(|w| {
                        if !from_me {
                            w.set_name(&sender, &info.push_name);
                        }
                        if !w.insert_message(&message) {
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
                let chat = receipt.source.chat.to_non_ad().to_string();
                let to = match receipt.r#type {
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
                // Only the first sync after linking describes a chat's settings.
                let bootstrap = lazy.sync_type() == wa::history_sync::HistorySyncType::InitialBootstrap as i32;
                self.db.write(|w| {
                    for name in &history.pushnames {
                        if let (Some(id), Some(name)) = (&name.id, &name.pushname) {
                            w.set_name(id, name);
                        }
                    }
                    for conversation in &history.conversations {
                        let chat = conversation.id.as_str();
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
                                key.participant.clone().or_else(|| web.participant.clone()).unwrap_or_else(|| chat.to_string())
                            };
                            let Some(mut message) = row(chat, key.id.as_deref().unwrap_or(""), &sender, from_me, web.message_timestamp.unwrap_or(0) as i64, body) else {
                                continue;
                            };
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
                self.send(json!({"type": "chats"}));
                self.send(json!({"type": "messages", "chat": ""}));
            }
            _ => {}
        }
    }
}

/// A protocol message as a row of ours; `None` for what is not shown
/// (protocol housekeeping, reactions, keys).
fn row(chat: &str, id: &str, sender: &str, from_me: bool, ts: i64, message: &wa::Message) -> Option<NewMessage> {
    if id.is_empty() {
        return None;
    }
    let base = message.get_base_message();
    let mut out = NewMessage { chat: chat.to_string(), id: id.to_string(), sender: sender.to_string(), from_me, ts, ..Default::default() };
    if let Some(text) = base.text_content() {
        out.kind = "text".into();
        out.text = text.to_string();
    } else if let Some(image) = base.image_message.as_option() {
        out.kind = "image".into();
        out.text = image.caption.clone().unwrap_or_default();
        out.w = image.width.unwrap_or(0) as i64;
        out.h = image.height.unwrap_or(0) as i64;
        out.thumb = image.jpeg_thumbnail.as_ref().map(|t| t.to_vec());
    } else if let Some(video) = base.video_message.as_option() {
        out.kind = "video".into();
        out.text = video.caption.clone().unwrap_or_default();
        out.w = video.width.unwrap_or(0) as i64;
        out.h = video.height.unwrap_or(0) as i64;
        out.thumb = video.jpeg_thumbnail.as_ref().map(|t| t.to_vec());
    } else if let Some(audio) = base.audio_message.as_option() {
        out.kind = "audio".into();
        // The UI reads a voice message's length from `w`.
        out.w = audio.seconds.unwrap_or(0) as i64;
    } else if let Some(document) = base.document_message.as_option() {
        out.kind = "document".into();
        out.text = document.caption.clone().unwrap_or_default();
        out.file_name = document.file_name.clone().or_else(|| document.title.clone()).unwrap_or_default();
    } else if base.sticker_message.is_set() {
        out.kind = "sticker".into();
    } else {
        return None;
    }
    Some(out)
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}
