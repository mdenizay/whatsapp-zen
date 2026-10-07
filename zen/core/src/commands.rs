//! The rest of the commands, and the events that are not messages: sending
//! media, forwarding, groups, presence, contacts, the cache, and what other
//! devices of the same account change.

use std::future::Future;
use std::sync::atomic::Ordering;
use std::sync::Arc;

use base64::Engine as _;
use serde_json::{json, Value};
use whatsapp_rust::download::MediaType;
use whatsapp_rust::prelude::*;
use whatsapp_rust::upload::UploadOptions;
use whatsapp_rust::waproto::buffa::{Message as _, MessageField};
use whatsapp_rust::waproto::whatsapp as wa;

use crate::account::{mark_deleted, now, safe_name, Account, Request};
use crate::db::{status, NewMessage};

const MAX_FILE: u64 = 100 << 20;

/// Where status updates arrive; kept for the status viewer, not shown as a chat.
pub(crate) const STATUS_CHAT: &str = "status@broadcast";

fn jid(text: &str) -> Result<Jid, String> {
    text.parse().map_err(|_| "bad chat id".to_string())
}

impl Account {
    /// A message of ours about to be sent, under the id it will keep.
    pub(crate) fn new_row(&self, chat: &str, kind: &str, text: &str) -> Result<NewMessage, String> {
        let client = self.client()?;
        Ok(NewMessage {
            chat: chat.to_string(),
            id: client.generate_message_id(),
            from_me: true,
            ts: now(),
            kind: kind.to_string(),
            text: text.to_string(),
            status: status::PENDING,
            ..Default::default()
        })
    }

    /// Fills in what a reply quotes and returns the context to send with it.
    pub(crate) fn reply_context(&self, row: &mut NewMessage, reply_to: &str) -> Option<wa::ContextInfo> {
        if reply_to.is_empty() {
            return None;
        }
        let (sender, from_me, kind, text, file) = self.db.get(
            "SELECT sender, from_me, type, text, file_name FROM messages WHERE chat=?1 AND id=?2",
            &[&row.chat, &reply_to],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?, r.get::<_, String>(2)?, r.get::<_, String>(3)?, r.get::<_, String>(4)?)),
        )?;
        let preview = preview(&kind, &text, &file);
        let author = if from_me { self.me() } else if sender.is_empty() { row.chat.clone() } else { sender };
        row.quoted_id = reply_to.to_string();
        row.quoted_text = preview.clone();
        row.quoted_sender = author.clone();
        Some(wa::ContextInfo {
            stanza_id: Some(reply_to.to_string()),
            participant: Some(author),
            quoted_message: MessageField::some(wa::Message { conversation: Some(preview), ..Default::default() }),
            ..Default::default()
        })
    }

    /// Stores the outgoing row right away and does the slow part (media
    /// upload, then the send) in the background, so the UI shows the bubble
    /// immediately and the tick catches up. `build` produces what is sent.
    pub(crate) fn deliver<F, Fut>(self: &Arc<Self>, row: NewMessage, build: F) -> Result<Value, String>
    where
        F: FnOnce(Arc<Client>) -> Fut + Send + 'static,
        Fut: Future<Output = Result<wa::Message, String>> + Send,
    {
        let client = self.client()?;
        let to = jid(&row.chat)?;
        // A chat with a disappearing timer expects every message to carry it.
        let timer = self.db.count("SELECT ephemeral FROM chats WHERE jid=?1", &[&row.chat]) as u32;
        let mut row = row;
        if timer > 0 {
            row.expires_at = row.ts + timer as i64;
        }
        self.db.write(|w| {
            w.insert_message(&row);
            w.touch_chat(&row.chat, row.ts);
            // Writing in a chat means having read it.
            w.exec("UPDATE messages SET unread=0 WHERE chat=?1 AND unread=1", &[&row.chat]);
            w.exec("UPDATE chats SET unread=0 WHERE jid=?1", &[&row.chat]);
        });
        self.changed(&row.chat);
        let shown = self.db.message(&row.chat, &row.id);
        let me = self.clone();
        self.rt.spawn(async move {
            let sent = match build(client.clone()).await {
                Ok(message) => {
                    if row.kind != "text" {
                        // Kept so the media can be fetched again if the local copy goes.
                        let raw = message.encode_to_vec();
                        me.db.write(|w| w.exec("UPDATE messages SET raw=?3 WHERE chat=?1 AND id=?2", &[&row.chat, &row.id, &raw]));
                    }
                    let mut options = SendOptions::default().with_message_id(row.id.clone());
                    if timer > 0 {
                        options.ephemeral_expiration = Some(timer);
                    }
                    client.send_message_with_options(to, message, options).await.map(|_| ()).map_err(|e| e.to_string())
                }
                Err(error) => Err(error),
            };
            let to_status = if sent.is_ok() { status::SENT } else { status::FAILED };
            // A delivery receipt can beat this update; never move the status back.
            me.db.write(|w| w.exec("UPDATE messages SET status=?3 WHERE chat=?1 AND id=?2 AND status=?4", &[&row.chat, &row.id, &to_status, &status::PENDING]));
            me.changed(&row.chat);
        });
        serde_json::to_value(shown).map_err(|e| e.to_string())
    }

    pub(crate) fn more(self: &Arc<Self>, r: &Request) -> Result<Value, String> {
        match r.cmd.as_str() {
            "send_image" => self.send_media(r, "image"),
            "send_file" => self.send_media(r, if r.kind == "video" { "video" } else { "document" }),
            "forward" => self.forward(&r.chat, &r.id, &r.to, r.plain),
            "pin_message" => self.pin_message(&r.chat, &r.id, r.on),
            "delete_for_me" => self.delete_for_me(&r.chat, &r.id),
            "fetch_history" => self.fetch_history(&r.chat),
            "group_info" => self.group_info(&r.chat),
            "group_update" => self.group_update(&r.chat, &r.jid, &r.action),
            "group_rename" => {
                let client = self.client()?;
                let group = jid(&r.chat)?;
                self.rt.block_on(client.groups().set_subject(group, whatsapp_rust::wacore::iq::groups::GroupSubject::new(r.text.as_str()).map_err(|_| "That name is not allowed".to_string())?)).map_err(|e| e.to_string())?;
                self.db.write(|w| w.exec("UPDATE chats SET name=?2 WHERE jid=?1", &[&r.chat, &r.text]));
                self.send(json!({"type": "chats"}));
                Ok(Value::Null)
            }
            "group_leave" => {
                let client = self.client()?;
                self.rt.block_on(client.groups().leave(jid(&r.chat)?)).map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            "group_link" => {
                let client = self.client()?;
                self.rt.block_on(client.groups().get_invite_link(jid(&r.chat)?, false)).map(Value::String).map_err(|e| e.to_string())
            }
            "typing" => {
                let client = self.client()?;
                let chat = jid(&r.chat)?;
                let on = r.on;
                self.rt.spawn(async move {
                    let state = client.chatstate();
                    let _ = if on { state.send_composing(&chat).await } else { state.send_paused(&chat).await };
                });
                Ok(Value::Null)
            }
            "presence" => {
                self.available.store(r.on, Ordering::Relaxed);
                self.announce_presence();
                Ok(Value::Null)
            }
            "subscribe" | "subscribe_presence" => {
                if !r.jid.ends_with("@g.us") {
                    if let (Ok(client), Ok(who)) = (self.client(), jid(&r.jid)) {
                        self.rt.spawn(async move {
                            let _ = client.presence().subscribe(who).await;
                        });
                    }
                }
                Ok(Value::Null)
            }
            "contacts" => Ok(json!(self.db.contacts())),
            "start_chat" => self.start_chat(&r.jid, &r.phone),
            "logout" => {
                if let Ok(client) = self.client() {
                    self.rt.spawn(async move { client.logout().await });
                }
                Ok(Value::Null)
            }
            "block" => {
                let client = self.client()?;
                let who = jid(&r.jid)?;
                let blocking = client.blocking();
                self.rt.block_on(async { if r.on { blocking.block(&who).await } else { blocking.unblock(&who).await } }).map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            "cache_size" => Ok(json!(dir_size(&self.dir.join("media")))),
            "cache_list" => serde_json::to_value(self.db.query(
                "media_path != '' AND deleted=0 AND type IN ('image','video','sticker','document','audio') ORDER BY ts DESC LIMIT 400",
                &[],
            ))
            .map_err(|e| e.to_string()),
            "cache_remove" => {
                if let Some(path) = self.db.get("SELECT media_path FROM messages WHERE chat=?1 AND id=?2", &[&r.chat, &r.id], |row| row.get::<_, String>(0)) {
                    self.remove_media_file(&path);
                }
                self.db.write(|w| w.exec("UPDATE messages SET media_path='' WHERE chat=?1 AND id=?2", &[&r.chat, &r.id]));
                Ok(Value::Null)
            }
            "clear_cache" => {
                let media = self.dir.join("media");
                if let Ok(entries) = std::fs::read_dir(&media) {
                    for entry in entries.flatten() {
                        let _ = std::fs::remove_file(entry.path());
                    }
                }
                self.db.write(|w| w.exec("UPDATE messages SET media_path='' WHERE media_path != ''", &[]));
                self.send(json!({"type": "messages", "chat": ""}));
                Ok(Value::Null)
            }
            "set_ephemeral" => self.set_ephemeral(&r.chat, r.duration.max(0) as u32),
            "send_poll" => self.send_poll(&r.chat, &r.text, &r.options),
            "vote" => self.vote(&r.chat, &r.id, &r.options),
            "send_contact" => {
                let name = if r.text.is_empty() { self.db.name_of(&r.jid) } else { r.text.clone() };
                let user = jid(&r.jid)?.user.to_string();
                let row = self.new_row(&r.chat, "other", &format!("👤 {}: {name}", crate::i18n::t("Contact")))?;
                let message = wa::Message {
                    contact_message: MessageField::some(wa::message::ContactMessage {
                        display_name: Some(name.clone()),
                        vcard: Some(format!("BEGIN:VCARD\nVERSION:3.0\nFN:{name}\nTEL;type=CELL;waid={user}:+{user}\nEND:VCARD")),
                        ..Default::default()
                    }),
                    ..Default::default()
                };
                self.deliver(row, move |_| async move { Ok(message) })
            }
            "send_location" => {
                let row = self.new_row(&r.chat, "other", &format!("📍 {}\nhttps://maps.apple.com/?ll={:.6},{:.6}", crate::i18n::t("Location"), r.lat, r.lng))?;
                let message = wa::Message {
                    location_message: MessageField::some(wa::message::LocationMessage {
                        degrees_latitude: Some(r.lat),
                        degrees_longitude: Some(r.lng),
                        ..Default::default()
                    }),
                    ..Default::default()
                };
                self.deliver(row, move |_| async move { Ok(message) })
            }
            "chat_media" => {
                let which = match r.kind.as_str() {
                    "docs" => "type='document'",
                    "links" => "(text LIKE '%http://%' OR text LIKE '%https://%')",
                    _ => "type IN ('image','video')",
                };
                serde_json::to_value(self.db.query(&format!("chat=?1 AND deleted=0 AND {which} ORDER BY ts DESC LIMIT 120"), &[&r.chat])).map_err(|e| e.to_string())
            }
            "statuses" => serde_json::to_value(self.db.query("chat=?1 AND deleted=0 AND ts > strftime('%s','now') - 86400 ORDER BY ts", &[&STATUS_CHAT]))
                .map_err(|e| e.to_string()),
            // Favourites (starred stickers) first, then the most recent.
            "stickers" => serde_json::to_value(self.db.query(
                "type='sticker' AND deleted=0 AND raw IS NOT NULL AND chat != ?1 ORDER BY starred DESC, ts DESC LIMIT 72",
                &[&STATUS_CHAT],
            ))
            .map_err(|e| e.to_string()),
            "user_info" => {
                let client = self.client()?;
                let who = jid(&r.jid)?;
                let about = self.rt.block_on(client.contacts().get_user_info(&[who.clone()])).ok().and_then(|all| all.into_values().next()).and_then(|info| info.status);
                let blocked = self.rt.block_on(client.blocking().is_blocked(&who)).unwrap_or(false);
                Ok(json!({"about": about.unwrap_or_default(), "blocked": blocked}))
            }
            "export" => self.export(&r.chat, &r.path),
            "send_voice" => self.send_voice(r),
            "send_sticker_image" => self.send_sticker(&r.chat, &r.path),
            "reject_call" => {
                let client = self.client()?;
                let (peer, creator) = self.calls.lock().unwrap().get(&r.id).cloned().ok_or("That call is no longer ringing")?;
                self.rt.block_on(client.voip().reject_call(&r.id, &peer, &creator)).map_err(|e| e.to_string())?;
                Ok(Value::Null)
            }
            other => Err(format!("\"{other}\" is not available in the Rust core yet")),
        }
    }

    fn remove_media_file(&self, path: &str) {
        if !path.is_empty() && std::path::Path::new(path).starts_with(self.dir.join("media")) {
            let _ = std::fs::remove_file(path);
        }
    }

    /// Tells WhatsApp whether the user is here; "last seen" follows from it.
    pub(crate) fn announce_presence(self: &Arc<Self>) {
        let Ok(client) = self.client() else { return };
        let on = self.available.load(Ordering::Relaxed);
        self.rt.spawn(async move {
            let presence = client.presence();
            let _ = if on { presence.set_available().await } else { presence.set_unavailable().await };
        });
    }

    /// Sends a photo, a video or any file the UI prepared (path, thumbnail and
    /// size), with an optional caption.
    fn send_media(self: &Arc<Self>, r: &Request, kind: &'static str) -> Result<Value, String> {
        let size = std::fs::metadata(&r.path).map_err(|e| e.to_string())?.len();
        if size > MAX_FILE {
            return Err("The file is larger than 100 MB".into());
        }
        let data = std::fs::read(&r.path).map_err(|e| e.to_string())?;
        let thumb = base64::engine::general_purpose::STANDARD.decode(&r.thumb).unwrap_or_default();
        let mut row = self.new_row(&r.chat, kind, &r.text)?;
        row.thumb = (!thumb.is_empty()).then(|| thumb.clone());
        row.w = r.w;
        row.h = r.h;
        row.file_name = if kind == "image" { String::new() } else { r.file_name.clone() };
        let ext = if kind == "image" {
            ".jpg".to_string()
        } else {
            std::path::Path::new(&r.file_name).extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default()
        };
        // Our own copy, so the message shows without downloading it back.
        let copy = self.dir.join("media").join(format!("{}{ext}", safe_name(&row.id)));
        let media_path = std::fs::write(&copy, &data).is_ok().then(|| copy.to_string_lossy().into_owned()).unwrap_or_default();
        let context = self.reply_context(&mut row, &r.reply_to);
        let (chat, id) = (row.chat.clone(), row.id.clone());
        let caption = (!r.text.is_empty()).then(|| r.text.clone());
        let (mime, file_name, seconds, w, h) = (r.mime.clone(), r.file_name.clone(), r.seconds as u32, r.w as u32, r.h as u32);
        let out = self.deliver(row, move |client| async move {
            let media_type = match kind {
                "image" => MediaType::Image,
                "video" => MediaType::Video,
                _ => MediaType::Document,
            };
            let up = client.upload(data, media_type, UploadOptions::default()).await.map_err(|e| e.to_string())?;
            let context = context.map(MessageField::some).unwrap_or_default();
            let thumb = (!thumb.is_empty()).then(|| thumb.into());
            Ok(match kind {
                "image" => wa::Message {
                    image_message: MessageField::some(wa::message::ImageMessage {
                        url: Some(up.url),
                        direct_path: Some(up.direct_path),
                        media_key: Some(up.media_key.to_vec().into()),
                        mimetype: Some("image/jpeg".into()),
                        file_enc_sha256: Some(up.file_enc_sha256.to_vec().into()),
                        file_sha256: Some(up.file_sha256.to_vec().into()),
                        file_length: Some(up.file_length),
                        width: Some(w),
                        height: Some(h),
                        jpeg_thumbnail: thumb,
                        caption,
                        context_info: context,
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                "video" => wa::Message {
                    video_message: MessageField::some(wa::message::VideoMessage {
                        url: Some(up.url),
                        direct_path: Some(up.direct_path),
                        media_key: Some(up.media_key.to_vec().into()),
                        mimetype: Some(mime),
                        file_enc_sha256: Some(up.file_enc_sha256.to_vec().into()),
                        file_sha256: Some(up.file_sha256.to_vec().into()),
                        file_length: Some(up.file_length),
                        seconds: Some(seconds),
                        width: Some(w),
                        height: Some(h),
                        jpeg_thumbnail: thumb,
                        caption,
                        context_info: context,
                        ..Default::default()
                    }),
                    ..Default::default()
                },
                _ => wa::Message {
                    document_message: MessageField::some(wa::message::DocumentMessage {
                        url: Some(up.url),
                        direct_path: Some(up.direct_path),
                        media_key: Some(up.media_key.to_vec().into()),
                        mimetype: Some(mime),
                        file_enc_sha256: Some(up.file_enc_sha256.to_vec().into()),
                        file_sha256: Some(up.file_sha256.to_vec().into()),
                        file_length: Some(up.file_length),
                        file_name: Some(file_name.clone()),
                        title: Some(file_name),
                        jpeg_thumbnail: thumb,
                        caption,
                        context_info: context,
                        ..Default::default()
                    }),
                    ..Default::default()
                },
            })
        })?;
        if !media_path.is_empty() {
            self.db.write(|w| w.exec("UPDATE messages SET media_path=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &media_path]));
        }
        serde_json::to_value(self.db.message(&chat, &id)).map_err(|e| e.to_string()).or(Ok(out))
    }

    /// Re-sends a stored message to another chat, marked as forwarded. Media
    /// is not uploaded again: the original's encrypted file is referenced.
    fn forward(self: &Arc<Self>, chat: &str, id: &str, to: &str, plain: bool) -> Result<Value, String> {
        let (kind, text, thumb, raw, media_path, file_name, w, h) = self
            .db
            .get("SELECT type,text,thumb,raw,media_path,file_name,w,h FROM messages WHERE chat=?1 AND id=?2 AND deleted=0", &[&chat, &id], |r| {
                Ok((
                    r.get::<_, String>(0)?,
                    r.get::<_, String>(1)?,
                    r.get::<_, Option<Vec<u8>>>(2)?,
                    r.get::<_, Option<Vec<u8>>>(3)?,
                    r.get::<_, String>(4)?,
                    r.get::<_, String>(5)?,
                    r.get::<_, i64>(6)?,
                    r.get::<_, i64>(7)?,
                ))
            })
            .ok_or("unknown message")?;
        // Sending a saved sticker again is not a forward.
        let mark = || {
            if plain {
                MessageField::none()
            } else {
                MessageField::some(wa::ContextInfo { is_forwarded: Some(true), forwarding_score: Some(1), ..Default::default() })
            }
        };
        let message = match raw.filter(|raw| !raw.is_empty()) {
            Some(raw) => {
                let mut message = wa::Message::decode_from_slice(&raw).map_err(|e| e.to_string())?;
                if let Some(m) = message.image_message.as_option_mut() {
                    m.context_info = mark();
                } else if let Some(m) = message.video_message.as_option_mut() {
                    m.context_info = mark();
                } else if let Some(m) = message.audio_message.as_option_mut() {
                    m.context_info = mark();
                } else if let Some(m) = message.document_message.as_option_mut() {
                    m.context_info = mark();
                } else if let Some(m) = message.sticker_message.as_option_mut() {
                    m.context_info = mark();
                }
                message
            }
            None if kind == "text" || kind == "other" => wa::Message {
                extended_text_message: MessageField::some(wa::message::ExtendedTextMessage { text: Some(text.clone()), context_info: mark(), ..Default::default() }),
                ..Default::default()
            },
            None => return Err("This message cannot be forwarded".into()),
        };
        let mut row = self.new_row(to, if kind == "other" { "text" } else { &kind }, &text)?;
        row.thumb = thumb;
        row.file_name = file_name;
        row.w = w;
        row.h = h;
        let (dest, new_id) = (row.chat.clone(), row.id.clone());
        let out = self.deliver(row, move |_| async move { Ok(message) })?;
        if !media_path.is_empty() {
            self.db.write(|w| w.exec("UPDATE messages SET media_path=?3 WHERE chat=?1 AND id=?2", &[&dest, &new_id, &media_path]));
        }
        Ok(out)
    }

    /// Pins a message in its chat for everyone (for 7 days, WhatsApp's
    /// default) or unpins it.
    fn pin_message(&self, chat: &str, id: &str, on: bool) -> Result<Value, String> {
        use wa::message::pin_in_chat_message::Type;
        let client = self.client()?;
        let (key, _, _) = self.key(chat, id)?;
        let message = wa::Message {
            pin_in_chat_message: MessageField::some(wa::message::PinInChatMessage {
                key: MessageField::some(key),
                r#type: Some(if on { Type::PinForAll } else { Type::UnpinForAll }),
                sender_timestamp_ms: Some(now() * 1000),
                ..Default::default()
            }),
            message_context_info: if on {
                MessageField::some(wa::MessageContextInfo { message_add_on_duration_in_secs: Some(7 * 24 * 3600), ..Default::default() })
            } else {
                MessageField::none()
            },
            ..Default::default()
        };
        self.rt.block_on(client.send_message(jid(chat)?, message)).map_err(|e| e.to_string())?;
        self.db.write(|w| w.exec("UPDATE messages SET pinned=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &on]));
        self.send(json!({"type": "messages", "chat": chat}));
        Ok(Value::Null)
    }

    /// Removes a message from this chat on every one of the user's own
    /// devices; the other side keeps it.
    fn delete_for_me(&self, chat: &str, id: &str) -> Result<Value, String> {
        let client = self.client()?;
        let (key, _, from_me) = self.key(chat, id)?;
        let ts = self.db.count("SELECT ts FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id]);
        let participant = key.participant.as_deref().and_then(|p| p.parse::<Jid>().ok());
        self.rt
            .block_on(client.chat_actions().delete_message_for_me(&jid(chat)?, participant.as_ref(), id, from_me, true, Some(ts)))
            .map_err(|e| e.to_string())?;
        self.remove_message(chat, id);
        Ok(Value::Null)
    }

    /// Drops a message, its reactions and its saved media.
    pub(crate) fn remove_message(&self, chat: &str, id: &str) {
        if let Some(path) = self.db.get("SELECT media_path FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id], |r| r.get::<_, String>(0)) {
            self.remove_media_file(&path);
        }
        self.db.write(|w| {
            w.exec("DELETE FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id]);
            w.exec("DELETE FROM reactions WHERE chat=?1 AND msg_id=?2", &[&chat, &id]);
        });
        self.changed(chat);
    }

    /// Asks the phone for the messages just before the oldest one stored
    /// here. A newly linked device is only sent the recent part of each chat;
    /// the answer arrives later as an on-demand history sync. Reports whether
    /// a request went out; a chat with no message has nothing to ask from.
    fn fetch_history(self: &Arc<Self>, chat: &str) -> Result<Value, String> {
        let Ok(client) = self.client() else { return Ok(json!(false)) };
        let Some((id, from_me, ts)) = self.db.get(
            "SELECT id, from_me, ts FROM messages WHERE chat=?1 ORDER BY ts ASC, id ASC LIMIT 1",
            &[&chat],
            |r| Ok((r.get::<_, String>(0)?, r.get::<_, bool>(1)?, r.get::<_, i64>(2)?)),
        ) else {
            return Ok(json!(false));
        };
        {
            // The same page is not asked for again while the answer may still come.
            let mut asked = self.history_asked.lock().unwrap();
            if asked.get(chat).is_some_and(|(before, at)| *before == id && at.elapsed().as_secs() < 60) {
                return Ok(json!(false));
            }
            asked.insert(chat.to_string(), (id.clone(), std::time::Instant::now()));
        }
        let target = jid(chat)?;
        self.rt.block_on(client.fetch_message_history(&target, &id, from_me, ts * 1000, 50)).map_err(|e| e.to_string())?;
        Ok(json!(true))
    }

    fn group_info(&self, chat: &str) -> Result<Value, String> {
        let client = self.client()?;
        let info = self.rt.block_on(client.groups().get_metadata(&jid(chat)?)).map_err(|e| e.to_string())?;
        let me = self.me();
        let mut members = Vec::new();
        let mut i_am_admin = false;
        for participant in &info.participants {
            let id = match &participant.phone_number {
                Some(pn) => pn.to_non_ad().to_string(),
                None => self.rt.block_on(self.pn(&participant.jid)),
            };
            let is_me = id == me;
            let admin = participant.is_admin();
            if is_me {
                i_am_admin = admin;
            }
            members.push((if is_me { crate::i18n::t("You") } else { self.db.name_of(&id) }, id, admin, is_me));
        }
        // Admins first, then by name.
        members.sort_by(|a, b| (!a.2, a.0.to_lowercase()).cmp(&(!b.2, b.0.to_lowercase())));
        self.db.write(|w| w.exec("UPDATE chats SET name=?2 WHERE jid=?1", &[&chat, &info.subject]));
        Ok(json!({
            "name": info.subject,
            "topic": "",
            "created": info.creation_time.unwrap_or(0),
            "is_admin": i_am_admin,
            "members": members.iter().map(|(name, id, admin, is_me)| json!({"jid": id, "name": name, "is_admin": admin, "is_me": is_me})).collect::<Vec<_>>(),
        }))
    }

    fn group_update(&self, chat: &str, member: &str, action: &str) -> Result<Value, String> {
        let client = self.client()?;
        let (group, who) = (jid(chat)?, [jid(member)?]);
        let groups = client.groups();
        let refused = "The change was refused; the person's privacy settings may not allow it".to_string();
        self.rt.block_on(async {
            match action {
                "add" => groups.add_participants(group, &who).await.map(|_| ()).map_err(|_| refused),
                "remove" => groups.remove_participants(group, &who).await.map(|_| ()).map_err(|_| refused),
                "promote" => groups.promote_participants(group, &who).await.map(|_| ()).map_err(|_| refused),
                "demote" => groups.demote_participants(group, &who).await.map(|_| ()).map_err(|_| refused),
                _ => Err("unknown action".to_string()),
            }
        })?;
        Ok(Value::Null)
    }

    /// Makes sure a chat exists for a contact (by id) or a phone number and
    /// returns its id, so the UI can open an empty conversation.
    fn start_chat(&self, contact: &str, phone: &str) -> Result<Value, String> {
        let chat = if !contact.is_empty() {
            jid(contact)?.to_non_ad().to_string()
        } else {
            let client = self.client()?;
            let digits: String = phone.chars().filter(char::is_ascii_digit).collect();
            if digits.len() < 7 {
                return Err("Invalid phone number".into());
            }
            let found = self.rt.block_on(client.contacts().is_on_whatsapp(&[Jid::pn(digits)])).map_err(|e| e.to_string())?;
            match found.first() {
                Some(result) if result.is_registered => result.pn_jid.as_ref().unwrap_or(&result.jid).to_non_ad().to_string(),
                _ => return Err("This number is not on WhatsApp".into()),
            }
        };
        self.db.write(|w| w.touch_chat(&chat, now()));
        self.send(json!({"type": "chats"}));
        Ok(Value::String(chat))
    }

    /// Sends a recording as a voice message. The UI records Opus in a CAF
    /// file (all macOS can encode); WhatsApp wants Ogg, so it is re-wrapped.
    fn send_voice(self: &Arc<Self>, r: &Request) -> Result<Value, String> {
        let caf = std::fs::read(&r.path).map_err(|e| e.to_string())?;
        let data = crate::ogg::caf_opus_to_ogg(&caf)?;
        let mut row = self.new_row(&r.chat, "audio", "")?;
        row.w = r.seconds;
        let copy = self.dir.join("media").join(format!("{}.ogg", safe_name(&row.id)));
        let media_path = std::fs::write(&copy, &data).is_ok().then(|| copy.to_string_lossy().into_owned()).unwrap_or_default();
        let context = self.reply_context(&mut row, &r.reply_to);
        let (chat, id, seconds) = (row.chat.clone(), row.id.clone(), r.seconds as u32);
        self.deliver(row, move |client| async move {
            let up = client.upload(data, MediaType::Audio, UploadOptions::default()).await.map_err(|e| e.to_string())?;
            Ok(wa::Message {
                audio_message: MessageField::some(wa::message::AudioMessage {
                    url: Some(up.url),
                    direct_path: Some(up.direct_path),
                    media_key: Some(up.media_key.to_vec().into()),
                    mimetype: Some("audio/ogg; codecs=opus".into()),
                    file_enc_sha256: Some(up.file_enc_sha256.to_vec().into()),
                    file_sha256: Some(up.file_sha256.to_vec().into()),
                    file_length: Some(up.file_length),
                    seconds: Some(seconds),
                    ptt: Some(true),
                    context_info: context.map(MessageField::some).unwrap_or_default(),
                    ..Default::default()
                }),
                ..Default::default()
            })
        })?;
        if !media_path.is_empty() {
            self.db.write(|w| w.exec("UPDATE messages SET media_path=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &media_path]));
        }
        serde_json::to_value(self.db.message(&chat, &id)).map_err(|e| e.to_string())
    }

    /// Turns a PNG prepared by the UI (square, transparent padding) into a
    /// WebP sticker and sends it.
    fn send_sticker(self: &Arc<Self>, chat: &str, path: &str) -> Result<Value, String> {
        let (data, side) = crate::media::sticker(&std::fs::read(path).map_err(|e| e.to_string())?)?;
        let mut row = self.new_row(chat, "sticker", "")?;
        row.w = side as i64;
        row.h = side as i64;
        let copy = self.dir.join("media").join(format!("{}.webp", safe_name(&row.id)));
        let media_path = std::fs::write(&copy, &data).is_ok().then(|| copy.to_string_lossy().into_owned()).unwrap_or_default();
        let (chat, id) = (row.chat.clone(), row.id.clone());
        self.deliver(row, move |client| async move {
            let up = client.upload(data, MediaType::Sticker, UploadOptions::default()).await.map_err(|e| e.to_string())?;
            Ok(wa::Message {
                sticker_message: MessageField::some(wa::message::StickerMessage {
                    url: Some(up.url),
                    direct_path: Some(up.direct_path),
                    media_key: Some(up.media_key.to_vec().into()),
                    mimetype: Some("image/webp".into()),
                    file_enc_sha256: Some(up.file_enc_sha256.to_vec().into()),
                    file_sha256: Some(up.file_sha256.to_vec().into()),
                    file_length: Some(up.file_length),
                    width: Some(side),
                    height: Some(side),
                    ..Default::default()
                }),
                ..Default::default()
            })
        })?;
        if !media_path.is_empty() {
            self.db.write(|w| w.exec("UPDATE messages SET media_path=?3 WHERE chat=?1 AND id=?2", &[&chat, &id, &media_path]));
        }
        serde_json::to_value(self.db.message(&chat, &id)).map_err(|e| e.to_string())
    }

    /// Lists the groups the account is in, so one that has been quiet since
    /// before this device was linked still shows in the chat list.
    pub(crate) async fn refresh_groups(&self) {
        let Ok(client) = self.client() else { return };
        let Ok(groups) = client.groups().get_participating().await else { return };
        self.db.write(|w| {
            for (id, group) in &groups {
                let chat = id.to_non_ad().to_string();
                w.touch_chat(&chat, group.creation_time.unwrap_or(1) as i64);
                if !group.subject.is_empty() {
                    w.exec("UPDATE chats SET name=?2 WHERE jid=?1", &[&chat, &group.subject]);
                }
            }
        });
        self.send(json!({"type": "chats"}));
    }

    /// Whether the user's own read receipts are off. WhatsApp then shows them
    /// nobody else's in one-to-one chats, so neither does this app; turning
    /// them off also takes back the blue ticks already shown there.
    pub(crate) async fn refresh_privacy(&self) {
        use whatsapp_rust::wacore::iq::privacy::{PrivacyCategory, PrivacyValue};
        let Ok(client) = self.client() else { return };
        let Ok(settings) = client.fetch_privacy_settings().await else { return };
        let off = matches!(settings.get_value(&PrivacyCategory::ReadReceipts), Some(PrivacyValue::None));
        self.hide_read.store(off, Ordering::Relaxed);
        if off {
            let changed = self.db.write(|w| {
                w.exec("UPDATE messages SET status=?1 WHERE status=?2 AND from_me=1 AND chat NOT LIKE '%@g.us'", &[&status::DELIVERED, &status::READ])
            });
            if changed > 0 {
                self.send(json!({"type": "messages", "chat": ""}));
                self.send(json!({"type": "chats"}));
            }
        }
    }

    fn set_ephemeral(&self, chat: &str, seconds: u32) -> Result<Value, String> {
        let client = self.client()?;
        let target = jid(chat)?;
        if chat.ends_with("@g.us") {
            self.rt.block_on(client.groups().set_ephemeral(target, seconds)).map_err(|e| e.to_string())?;
        } else {
            self.rt.block_on(client.set_chat_disappearing_timer(target, seconds)).map_err(|e| e.to_string())?;
        }
        self.db.write(|w| w.exec("UPDATE chats SET ephemeral=?2 WHERE jid=?1", &[&chat, &seconds]));
        self.send(json!({"type": "chats"}));
        Ok(Value::Null)
    }

    fn send_poll(&self, chat: &str, name: &str, options: &[String]) -> Result<Value, String> {
        if name.trim().is_empty() || options.len() < 2 {
            return Err("A poll needs a question and at least two options".into());
        }
        let client = self.client()?;
        let (sent, secret) = self.rt.block_on(client.polls().create(jid(chat)?, name, options, 1)).map_err(|e| e.to_string())?;
        let id = sent.message_id.to_string();
        let def = json!({"options": options, "selectable": 1, "secret": base64::engine::general_purpose::STANDARD.encode(secret)}).to_string();
        let row = NewMessage { chat: chat.into(), id: id.clone(), from_me: true, ts: now(), kind: "poll".into(), text: name.into(), status: status::SENT, poll: def, ..Default::default() };
        self.db.write(|w| {
            w.insert_message(&row);
            w.touch_chat(chat, row.ts);
        });
        self.changed(chat);
        serde_json::to_value(self.db.message(chat, &id)).map_err(|e| e.to_string())
    }

    /// A stored poll: its options, its secret, and who made it.
    fn poll(&self, chat: &str, id: &str) -> Option<(Vec<String>, Vec<u8>, String)> {
        let (raw, sender, from_me) = self.db.get("SELECT poll, sender, from_me FROM messages WHERE chat=?1 AND id=?2", &[&chat, &id], |r| {
            Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?, r.get::<_, bool>(2)?))
        })?;
        let def: Value = serde_json::from_str(&raw).ok()?;
        let options = def["options"].as_array()?.iter().filter_map(|o| o.as_str().map(String::from)).collect();
        let secret = base64::engine::general_purpose::STANDARD.decode(def["secret"].as_str().unwrap_or("")).ok()?;
        Some((options, secret, if from_me { self.me() } else { sender }))
    }

    /// The id a poll's maker has in the poll's own chat. Votes are encrypted
    /// against it, and a group addressed by hidden ids uses those, not the
    /// phone-number ids everything is stored under here.
    async fn poll_creator(&self, chat: &str, creator: &str) -> Result<Jid, String> {
        use whatsapp_rust::wacore::types::message::AddressingMode;
        let client = self.client()?;
        let plain = jid(creator)?;
        if !chat.ends_with("@g.us") {
            return Ok(plain);
        }
        let hidden = client.groups().get_metadata(&jid(chat)?).await.map(|group| group.addressing_mode == AddressingMode::Lid).unwrap_or(false);
        if !hidden || plain.is_lid() {
            return Ok(plain);
        }
        if creator == self.me() {
            if let Some(own) = client.lid() {
                return Ok(own.to_non_ad());
            }
        }
        Ok(match client.get_lid_pn_entry(&plain).await {
            Ok(Some(entry)) => Jid::lid(entry.lid.as_ref()),
            _ => plain,
        })
    }

    fn save_vote(&self, chat: &str, id: &str, voter: &str, options: &[String]) {
        let chosen = serde_json::to_string(options).unwrap_or_else(|_| "[]".into());
        self.db.write(|w| {
            w.exec(
                "INSERT INTO poll_votes(chat,msg_id,voter,options) VALUES(?1,?2,?3,?4) ON CONFLICT(chat,msg_id,voter) DO UPDATE SET options=excluded.options",
                &[&chat, &id, &voter, &chosen],
            )
        });
        self.send(json!({"type": "messages", "chat": chat}));
    }

    /// Casts (or, with no options, withdraws) our vote in a poll.
    fn vote(&self, chat: &str, id: &str, options: &[String]) -> Result<Value, String> {
        let client = self.client()?;
        let (_, secret, creator) = self.poll(chat, id).ok_or("not a poll")?;
        if secret.is_empty() {
            return Err("This poll's key was not received, so it cannot be voted on here".into());
        }
        let creator = self.rt.block_on(self.poll_creator(chat, &creator))?;
        self.rt.block_on(client.polls().vote(jid(chat)?, id, &creator, &secret, options)).map_err(|e| e.to_string())?;
        self.save_vote(chat, id, "", options);
        Ok(Value::Null)
    }

    /// Decrypts someone's vote; it names its choices by SHA-256 hash. True if
    /// the message was a vote.
    pub(crate) async fn apply_poll_vote(&self, chat: &str, sender: &str, from_me: bool, voter_as_sent: &Jid, message: &wa::Message) -> bool {
        use sha2::Digest as _;
        let base = message.get_base_message();
        let Some(update) = base.poll_update_message.as_option() else { return false };
        let (Some(id), Some(vote)) = (update.poll_creation_message_key.as_option().and_then(|k| k.id.clone()), update.vote.as_option()) else { return true };
        let (Some((options, secret, creator)), Ok(client)) = (self.poll(chat, &id), self.client()) else { return true };
        // Both ids as the chat addresses them, which is what the vote was encrypted against.
        let Ok(creator) = self.poll_creator(chat, &creator).await else { return true };
        let voter_jid = voter_as_sent.to_non_ad();
        let ciphertext = whatsapp_rust::wacore::poll::PollVoteCiphertext {
            enc_payload: vote.enc_payload.as_deref().unwrap_or(&[]),
            enc_iv: vote.enc_iv.as_deref().unwrap_or(&[]),
        };
        let Ok(hashes) = client.polls().decrypt_vote(ciphertext, &secret, &id, &creator, &voter_jid).await else { return true };
        let chosen: Vec<String> = options.into_iter().filter(|name| hashes.iter().any(|hash| hash.as_slice() == sha2::Sha256::digest(name.as_bytes()).as_slice())).collect();
        self.save_vote(chat, &id, if from_me { "" } else { sender }, &chosen);
        true
    }

    /// Rewrites the "@1234567890" tokens of a message into "@Name" and notes
    /// whether the user is among them.
    pub(crate) async fn name_mentions(&self, row: &mut NewMessage) {
        if row.mentioned.is_empty() || row.text.is_empty() {
            return;
        }
        let me = self.me();
        for id in std::mem::take(&mut row.mentioned) {
            let Ok(parsed) = id.parse::<Jid>() else { continue };
            let who = self.pn(&parsed).await;
            let name = if who == me {
                row.mentions_me = true;
                crate::i18n::t("You")
            } else {
                self.db.name_of(&who)
            };
            row.text = row.text.replace(&format!("@{}", parsed.user), &format!("@{name}"));
        }
    }

    /// Writes a chat as plain text, oldest message first.
    fn export(&self, chat: &str, path: &str) -> Result<Value, String> {
        let mut out = String::new();
        for message in self.db.query("chat=?1 AND deleted=0 ORDER BY ts, id", &[&chat]) {
            let who = if message.from_me { crate::i18n::t("You") } else { message.sender_name.clone() };
            let label = preview(&message.kind, "", &message.file_name);
            let body = match message.kind.as_str() {
                "text" | "other" | "poll" => message.text.clone(),
                _ if message.text.is_empty() => label,
                _ => format!("{label} {}", message.text),
            };
            out += &format!("[{}] {who}: {body}\n", stamp(message.ts));
        }
        std::fs::write(path, out).map_err(|e| e.to_string())?;
        Ok(Value::Null)
    }

    /// Events that are not messages: who is typing or online, and what the
    /// user's other devices changed.
    pub(crate) async fn handle_more(&self, event: &Event) {
        match event {
            Event::ChatPresence(update) => {
                use whatsapp_rust::wacore::types::presence::ChatPresence;
                let chat = self.pn(&update.source.chat).await;
                let sender = if chat.ends_with("@g.us") { self.db.name_of(&self.pn(&update.source.sender).await) } else { String::new() };
                self.send(json!({"type": "typing", "chat": chat, "composing": update.state == ChatPresence::Composing, "sender": sender}));
            }
            Event::Presence(update) => {
                let who = self.pn(&update.from).await;
                self.send(json!({
                    "type": "presence", "jid": who, "online": !update.unavailable,
                    "last_seen": update.last_seen.map(|at| at.timestamp()).unwrap_or(0),
                }));
            }
            Event::PictureUpdate(update) => {
                let who = self.pn(&update.jid).await;
                for ext in ["jpg", "none"] {
                    let _ = std::fs::remove_file(self.dir.join("avatars").join(format!("{}.{ext}", safe_name(&who))));
                }
                self.send(json!({"type": "avatar", "jid": who}));
            }
            Event::ContactUpdate(update) => {
                let who = self.pn(&update.jid).await;
                let name = update.action.full_name.clone().or_else(|| update.action.first_name.clone()).unwrap_or_default();
                if !name.is_empty() {
                    self.db.write(|w| w.exec("INSERT INTO contacts(jid,name) VALUES(?1,?2) ON CONFLICT(jid) DO UPDATE SET name=excluded.name", &[&who, &name]));
                    if !update.from_full_sync {
                        self.send(json!({"type": "chats"}));
                    }
                }
            }
            Event::PushNameUpdate(update) => {
                let who = self.pn(&update.jid).await;
                self.db.write(|w| w.set_name(&who, &update.new_push_name));
                self.send(json!({"type": "chats"}));
            }
            Event::ArchiveUpdate(update) => {
                let chat = self.pn(&update.jid).await;
                let on = update.action.archived.unwrap_or(false);
                self.db.write(|w| {
                    w.touch_chat(&chat, 0);
                    w.exec("UPDATE chats SET archived=?2 WHERE jid=?1", &[&chat, &on]);
                    if on {
                        w.exec("UPDATE chats SET pinned=0 WHERE jid=?1", &[&chat]);
                    }
                });
                self.send(json!({"type": "chats"}));
            }
            Event::PinUpdate(update) => {
                let chat = self.pn(&update.jid).await;
                self.db.write(|w| {
                    w.touch_chat(&chat, 0);
                    w.exec("UPDATE chats SET pinned=?2 WHERE jid=?1", &[&chat, &update.action.pinned.unwrap_or(false)]);
                });
                self.send(json!({"type": "chats"}));
            }
            Event::MuteUpdate(update) => {
                let chat = self.pn(&update.jid).await;
                // -1 is "for good"; otherwise the time it ends, in seconds.
                let until = match (update.action.muted.unwrap_or(false), update.action.mute_end_timestamp.unwrap_or(0)) {
                    (false, _) => 0,
                    (true, end) if end < 0 => -1,
                    (true, end) => end / 1000,
                };
                self.db.write(|w| {
                    w.touch_chat(&chat, 0);
                    w.exec("UPDATE chats SET muted_until=?2 WHERE jid=?1", &[&chat, &until]);
                });
                self.send(json!({"type": "chats"}));
            }
            Event::StarUpdate(update) => {
                let chat = self.pn(&update.chat_jid).await;
                self.db.write(|w| w.exec("UPDATE messages SET starred=?3 WHERE chat=?1 AND id=?2", &[&chat, &update.message_id, &update.action.starred.unwrap_or(false)]));
                self.send(json!({"type": "messages", "chat": chat}));
            }
            Event::DeleteMessageForMeUpdate(update) => {
                // Deleted for me on another of the user's devices.
                let chat = self.pn(&update.chat_jid).await;
                self.remove_message(&chat, &update.message_id);
            }
            Event::IncomingCall(call) => {
                use whatsapp_rust::wacore::types::call::CallAction;
                // Calls cannot be answered here; say who is calling and let it be declined.
                let (id, creator, video) = match &call.action {
                    CallAction::Offer { call_id, call_creator, is_video, .. } => (call_id, call_creator, *is_video),
                    CallAction::OfferNotice { call_id, call_creator, is_video, .. } => (call_id, call_creator, *is_video),
                    _ => return,
                };
                if call.offline {
                    return;
                }
                self.calls.lock().unwrap().insert(id.clone(), (call.from.clone(), creator.clone()));
                self.ringing_started(id, call);
                let who = self.pn(&call.from).await;
                self.send(json!({"type": "call", "name": self.db.name_of(&who), "video": video, "raw_jid": call.from.to_string(), "jid": who, "id": id, "can_answer": true}));
            }
            Event::MissedCall(missed) => {
                let who = self.pn(&missed.from).await;
                self.ringing_stopped(&missed.call_id, &who);
            }
            Event::CallEndedElsewhere(ended) => {
                let who = self.pn(&ended.from).await;
                self.ringing_stopped(&ended.call_id, &who);
            }
            Event::UndecryptableMessage(lost) => {
                use whatsapp_rust::wacore::types::events::UnavailableType;
                // A view-once message, which only the phone can open: leave a note in its place.
                if !lost.is_unavailable || lost.unavailable_type != UnavailableType::ViewOnce {
                    return;
                }
                let info = &lost.info;
                let chat = self.pn(&info.source.chat).await;
                if chat.ends_with("@broadcast") || chat.ends_with("@newsletter") {
                    return;
                }
                let from_me = info.source.is_from_me;
                let row = NewMessage {
                    chat: chat.clone(),
                    id: info.id.to_string(),
                    sender: if from_me { String::new() } else { self.pn(&info.source.sender).await },
                    from_me,
                    ts: info.timestamp.timestamp(),
                    kind: "other".into(),
                    text: format!("👁 {}", crate::i18n::t("View-once message. Open it on your phone.")),
                    unread: !from_me,
                    status: status::SENT,
                    ..Default::default()
                };
                let fresh = self.db.write(|w| {
                    if !w.insert_message(&row) {
                        return false;
                    }
                    w.touch_chat(&chat, row.ts);
                    if !from_me {
                        w.exec("UPDATE chats SET unread=unread+1 WHERE jid=?1", &[&chat]);
                    }
                    true
                });
                if fresh {
                    self.send(json!({
                        "type": "message", "chat": chat, "chat_name": self.db.name_of(&chat), "msg": self.db.message(&chat, &row.id),
                        "notify": !from_me && now() - row.ts < 120 && !self.db.is_muted(&chat),
                    }));
                }
            }
            Event::GroupUpdate(update) => {
                // Something about a group changed (its name, its members): read its name again.
                let chat = update.group_jid.to_non_ad().to_string();
                if let Ok(client) = self.client() {
                    if let Ok(group) = client.groups().get_metadata(&update.group_jid).await {
                        if !group.subject.is_empty() {
                            self.db.write(|w| {
                                w.touch_chat(&chat, 0);
                                w.exec("UPDATE chats SET name=?2 WHERE jid=?1", &[&chat, &group.subject])
                            });
                            self.send(json!({"type": "chats"}));
                        }
                    }
                }
            }
            Event::MarkChatAsReadUpdate(update) => {
                let chat = self.pn(&update.jid).await;
                self.db.write(|w| {
                    w.exec("UPDATE messages SET unread=0 WHERE chat=?1 AND unread=1", &[&chat]);
                    w.exec("UPDATE chats SET unread=0 WHERE jid=?1", &[&chat]);
                });
                self.send(json!({"type": "chats"}));
            }
            _ => {}
        }
    }

    /// Takes a revoke that arrived for a message: shown as deleted.
    pub(crate) fn deleted(&self, chat: &str, id: &str) {
        self.db.write(|w| mark_deleted(w, chat, id));
        self.changed(chat);
    }
}

/// One line that stands for a message where its content cannot be shown.
pub(crate) fn preview(kind: &str, text: &str, file_name: &str) -> String {
    match kind {
        _ if !text.is_empty() => text.to_string(),
        "image" => format!("📷 {}", crate::i18n::t("Photo")),
        "video" => format!("🎥 {}", crate::i18n::t("Video")),
        "audio" => format!("🎤 {}", crate::i18n::t("Voice message")),
        "sticker" => crate::i18n::t("Sticker"),
        "document" => format!("📄 {file_name}"),
        _ => text.to_string(),
    }
}

/// "2026-10-07 14:05" in UTC; the export's time stamps.
fn stamp(ts: i64) -> String {
    let days = ts.div_euclid(86400);
    let secs = ts.rem_euclid(86400);
    // Civil date from days since 1970 (Howard Hinnant's algorithm).
    let z = days + 719468;
    let era = z.div_euclid(146097);
    let doe = z.rem_euclid(146097);
    let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let (day, month) = (doy - (153 * mp + 2) / 5 + 1, if mp < 10 { mp + 3 } else { mp - 9 });
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02} {:02}:{:02}", secs / 3600, secs % 3600 / 60)
}

fn dir_size(dir: &std::path::Path) -> u64 {
    std::fs::read_dir(dir)
        .map(|entries| entries.flatten().filter_map(|e| e.metadata().ok()).filter(|m| m.is_file()).map(|m| m.len()).sum())
        .unwrap_or(0)
}
