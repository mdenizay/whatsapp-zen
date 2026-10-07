//! One linked WhatsApp account: the connection, and what it writes into the
//! app's database as things arrive.

use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use whatsapp_rust::prelude::*;
use whatsapp_rust::waproto::whatsapp as wa;

use crate::db::Db;
use crate::model::{status, Chat, Event as Change, Message, State};

type Sink = Arc<dyn Fn(Change) + Send + Sync>;

pub struct Account {
    db: Arc<Db>,
    rt: tokio::runtime::Runtime,
    client: Mutex<Option<Arc<Client>>>,
    state: Mutex<State>,
    sink: Sink,
}

impl Account {
    /// Opens the account kept in `dir` (creating it) and starts connecting.
    /// `sink` is called, from a background thread, whenever something changed.
    pub fn start(dir: PathBuf, sink: impl Fn(Change) + Send + Sync + 'static) -> Result<Arc<Account>, String> {
        std::fs::create_dir_all(&dir).map_err(|e| e.to_string())?;
        let db = Arc::new(Db::open(&dir.join("app.db")).map_err(|e| e.to_string())?);
        let rt = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .thread_name("zen-core")
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let account = Arc::new(Account {
            db,
            rt,
            client: Mutex::new(None),
            state: Mutex::new(State::Starting),
            sink: Arc::new(sink),
        });
        let me = account.clone();
        account.rt.spawn(async move {
            if let Err(error) = me.clone().run(dir).await {
                me.set_state(State::Failed(error));
            }
        });
        Ok(account)
    }

    async fn run(self: Arc<Self>, dir: PathBuf) -> Result<(), String> {
        let session = dir.join("session.db");
        let store = SqliteStore::new(&session.to_string_lossy()).await.map_err(|e| e.to_string())?;
        let on_qr = self.clone();
        let on_event = self.clone();
        let bot = Bot::builder()
            .with_backend(store)
            .on_qr_code(move |code, _timeout| {
                let me = on_qr.clone();
                async move { me.set_state(State::Qr(code.to_string())) }
            })
            .on_event(move |event, _client| {
                let me = on_event.clone();
                async move { me.handle(&event) }
            })
            .build()
            .await
            .map_err(|e| e.to_string())?;
        *self.client.lock().unwrap() = Some(bot.client());
        self.set_state(State::Connecting);
        bot.run().await;
        Ok(())
    }

    /// An account with canned chats and no connection, for working on the UI
    /// and for screenshots.
    pub fn demo(sink: impl Fn(Change) + Send + Sync + 'static) -> Arc<Account> {
        let db = Arc::new(Db::in_memory());
        let now = now();
        let people = [
            ("900000000001@s.whatsapp.net", "Emma Wilson", 2u32),
            ("120363000000000001@g.us", "Design Team", 5),
            ("900000000002@s.whatsapp.net", "James Carter", 0),
            ("900000000003@s.whatsapp.net", "Mom", 0),
            ("120363000000000002@g.us", "Sunday Football", 0),
            ("900000000004@s.whatsapp.net", "Olivia Brown", 0),
        ];
        let lines: [(bool, &str); 6] = [
            (false, "Hey! Any plans for the weekend?"),
            (true, "Not yet, what do you have in mind?"),
            (false, "I was thinking we could see the new exhibition. Would Saturday afternoon work?"),
            (true, "Sounds great, I'm in!"),
            (false, "Does 8 pm work for you?"),
            (true, "Works for me 👌"),
        ];
        db.batch(|w| {
            for (index, (jid, name, unread)) in people.iter().enumerate() {
                let base = now - (index as i64) * 5400;
                w.touch_chat(jid, base);
                w.set_chat_name(jid, name);
                w.set_name(jid, name);
                for (n, (mine, text)) in lines.iter().enumerate() {
                    let from_me = *mine != (index % 2 == 1);
                    w.insert_message(&Message {
                        id: format!("demo-{index}-{n}"),
                        chat: jid.to_string(),
                        sender: if from_me { String::new() } else { jid.to_string() },
                        sender_name: String::new(),
                        from_me,
                        ts: base - ((lines.len() - n) as i64) * 240,
                        kind: "text".into(),
                        text: text.to_string(),
                        status: if from_me { status::READ } else { 0 },
                    });
                }
                w.set_unread(jid, *unread);
            }
            w.set_chat_flags(people[0].0, false, true);
        });
        Arc::new(Account {
            db,
            rt: tokio::runtime::Builder::new_current_thread().build().expect("runtime"),
            client: Mutex::new(None),
            state: Mutex::new(State::Connected),
            sink: Arc::new(sink),
        })
    }

    pub fn state(&self) -> State {
        self.state.lock().unwrap().clone()
    }

    fn set_state(&self, state: State) {
        {
            let mut current = self.state.lock().unwrap();
            if *current == state {
                return;
            }
            *current = state.clone();
        }
        (self.sink)(Change::State(state));
    }

    pub fn chats(&self) -> Vec<Chat> {
        self.db.chats()
    }

    pub fn messages(&self, chat: &str, limit: usize) -> Vec<Message> {
        self.db.messages(chat, limit)
    }

    /// Sends a text. It shows at once as pending and settles when the server
    /// has taken it.
    pub fn send_text(self: &Arc<Self>, chat: &str, text: &str) {
        let text = text.trim().to_string();
        let Some(client) = self.client.lock().unwrap().clone() else { return };
        let Ok(jid) = chat.parse::<Jid>() else { return };
        if text.is_empty() {
            return;
        }
        let now = now();
        let pending = Message {
            id: format!("pending-{}", now_nanos()),
            chat: chat.to_string(),
            sender: String::new(),
            sender_name: String::new(),
            from_me: true,
            ts: now,
            kind: "text".into(),
            text: text.clone(),
            status: status::PENDING,
        };
        self.db.batch(|w| {
            w.touch_chat(chat, now);
            w.insert_message(&pending);
        });
        self.changed(chat);
        let me = self.clone();
        let chat = chat.to_string();
        self.rt.spawn(async move {
            match client.send_message(jid, wa::Message::text(text)).await {
                Ok(sent) => me.db.batch(|w| {
                    w.rename_message(&chat, &pending.id, &sent.message_id.to_string());
                    w.set_status(&chat, &sent.message_id.to_string(), status::SENT);
                }),
                Err(_) => me.db.batch(|w| w.set_status(&chat, &pending.id, status::FAILED)),
            }
            me.changed(&chat);
        });
    }

    /// Marks a chat read here and tells the sender's side.
    pub fn mark_read(self: &Arc<Self>, chat: &str) {
        let unread = self.db.unread(chat);
        if unread == 0 {
            return;
        }
        let ids = self.db.unread_ids(chat, unread);
        self.db.batch(|w| w.set_unread(chat, 0));
        (self.sink)(Change::Chats);
        let Some(client) = self.client.lock().unwrap().clone() else { return };
        let Ok(jid) = chat.parse::<Jid>() else { return };
        let group = chat.ends_with("@g.us");
        self.rt.spawn(async move {
            // One receipt per sender, as the protocol wants for groups.
            let mut by_sender: std::collections::HashMap<String, Vec<String>> = Default::default();
            for (id, sender) in ids {
                by_sender.entry(sender).or_default().push(id);
            }
            for (sender, ids) in by_sender {
                let sender = sender.parse::<Jid>().ok();
                let ids: Vec<&str> = ids.iter().map(String::as_str).collect();
                let _ = client.mark_as_read(&jid, if group { sender.as_ref() } else { None }, &ids).await;
            }
        });
    }

    fn changed(&self, chat: &str) {
        (self.sink)(Change::Messages(chat.to_string()));
        (self.sink)(Change::Chats);
    }

    fn handle(&self, event: &Event) {
        match event {
            Event::Connected(_) => self.set_state(State::Connected),
            Event::PairSuccess(_) => self.set_state(State::Connecting),
            Event::LoggedOut(_) => self.set_state(State::LoggedOut),
            Event::Disconnected(_) => {
                if self.state() == State::Connected {
                    self.set_state(State::Connecting);
                }
            }
            Event::Messages(batch) => {
                let mut touched = Vec::new();
                self.db.batch(|w| {
                    for inbound in batch.iter() {
                        let info = &inbound.info;
                        let chat = info.source.chat.to_non_ad().to_string();
                        let Some(message) = row(
                            &chat,
                            info.id.as_ref(),
                            &info.source.sender.to_non_ad().to_string(),
                            info.source.is_from_me,
                            info.timestamp.timestamp(),
                            &inbound.message,
                            if info.source.is_from_me { status::SENT } else { 0 },
                        ) else {
                            continue;
                        };
                        if !info.push_name.is_empty() && !info.source.is_from_me {
                            w.set_name(&message.sender, &info.push_name);
                        }
                        w.touch_chat(&chat, message.ts);
                        if w.insert_message(&message) && !message.from_me {
                            w.add_unread(&chat);
                        }
                        if !touched.contains(&chat) {
                            touched.push(chat);
                        }
                    }
                });
                for chat in &touched {
                    (self.sink)(Change::Messages(chat.clone()));
                }
                if !touched.is_empty() {
                    (self.sink)(Change::Chats);
                }
            }
            Event::Receipt(receipt) => {
                use whatsapp_rust::wacore::types::presence::ReceiptType;
                let to = match receipt.r#type {
                    ReceiptType::Read => status::READ,
                    ReceiptType::Delivered | ReceiptType::Played => status::DELIVERED,
                    _ => return,
                };
                if receipt.source.is_from_me {
                    return;
                }
                let chat = receipt.source.chat.to_non_ad().to_string();
                let any = self.db.batch(|w| {
                    receipt.message_ids.iter().fold(false, |any, id| w.raise_status(&chat, id.as_ref(), to) || any)
                });
                if any {
                    self.changed(&chat);
                }
            }
            Event::HistorySync(lazy) => {
                let Some(history) = lazy.get() else { return };
                self.db.batch(|w| {
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
                        if let Some(name) = &conversation.name {
                            w.set_chat_name(chat, name);
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
                            // WebMessageInfo status: 1 pending, 2 server ack, 3 delivered, 4 read, 5 played
                            let sent = (web.status.map(|s| s as i32).unwrap_or(2) - 1).clamp(status::SENT, status::READ);
                            let Some(message) = row(
                                chat,
                                key.id.as_deref().unwrap_or(""),
                                &sender,
                                from_me,
                                web.message_timestamp.unwrap_or(0) as i64,
                                body,
                                if from_me { sent } else { 0 },
                            ) else {
                                continue;
                            };
                            if let Some(name) = &web.push_name {
                                if !from_me {
                                    w.set_name(&message.sender, name);
                                }
                            }
                            if w.insert_message(&message) {
                                w.touch_chat(chat, message.ts);
                            }
                        }
                        w.set_unread(chat, conversation.unread_count.unwrap_or(0));
                        if conversation.archived.unwrap_or(false) {
                            w.set_chat_flags(chat, true, false);
                        }
                    }
                });
                (self.sink)(Change::Chats);
                (self.sink)(Change::Messages(String::new()));
            }
            _ => {}
        }
    }
}

/// A protocol message as a row of ours; `None` for what is not shown
/// (protocol housekeeping, reactions, keys).
fn row(chat: &str, id: &str, sender: &str, from_me: bool, ts: i64, message: &wa::Message, sent_status: i32) -> Option<Message> {
    if id.is_empty() {
        return None;
    }
    let base = message.get_base_message();
    let (kind, text) = if let Some(text) = base.text_content() {
        ("text", text.to_string())
    } else if let Some(image) = base.image_message.as_option() {
        ("image", image.caption.clone().unwrap_or_default())
    } else if let Some(video) = base.video_message.as_option() {
        ("video", video.caption.clone().unwrap_or_default())
    } else if base.audio_message.is_set() {
        ("audio", String::new())
    } else if let Some(document) = base.document_message.as_option() {
        ("document", document.file_name.clone().or_else(|| document.caption.clone()).unwrap_or_default())
    } else if base.sticker_message.is_set() {
        ("sticker", String::new())
    } else {
        return None;
    };
    Some(Message {
        id: id.to_string(),
        chat: chat.to_string(),
        sender: sender.to_string(),
        sender_name: String::new(),
        from_me,
        ts,
        kind: kind.to_string(),
        text,
        status: sent_status,
    })
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn now_nanos() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}
