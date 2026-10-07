//! The link to the Rust core: commands go in as JSON and may block, so they
//! run on a worker thread; events come back on the core's threads and are
//! handed to the UI thread through a channel.

use std::path::PathBuf;
use std::sync::Arc;

use serde::de::DeserializeOwned;
use serde_json::{json, Value};

/// Starts the core. The returned channel carries its events.
pub fn start(base: PathBuf) -> async_channel::Receiver<Value> {
    let (tx, rx) = async_channel::unbounded::<Value>();
    zen_core::ffi::start(base, Arc::new(move |event: Value| {
        let _ = tx.send_blocking(event);
    }));
    rx
}

/// Runs a command for an account and waits for the answer off the UI thread.
pub async fn call(account: &str, cmd: &str, mut args: Value) -> Result<Value, String> {
    if let Some(map) = args.as_object_mut() {
        map.insert("cmd".into(), json!(cmd));
        map.insert("account".into(), json!(account));
    }
    let request = args.to_string();
    let reply = gtk::gio::spawn_blocking(move || zen_core::ffi::call(&request)).await.map_err(|_| "the core stopped".to_string())?;
    if let Some(error) = reply.get("error").and_then(Value::as_str) {
        return Err(error.to_string());
    }
    Ok(reply.get("data").cloned().unwrap_or(Value::Null))
}

/// `call`, with the answer read into a type.
pub async fn get<T: DeserializeOwned>(account: &str, cmd: &str, args: Value) -> Result<T, String> {
    serde_json::from_value(call(account, cmd, args).await?).map_err(|e| e.to_string())
}

/// Runs a command without waiting for it.
pub fn fire(account: &str, cmd: &str, args: Value) {
    let (account, cmd) = (account.to_string(), cmd.to_string());
    gtk::glib::spawn_future_local(async move {
        let _ = call(&account, &cmd, args).await;
    });
}

#[derive(serde::Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
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
}

#[derive(serde::Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
pub struct Reaction {
    pub emoji: String,
    pub name: String,
    pub from_me: bool,
}

#[derive(serde::Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(default)]
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
    pub thumb: String,
    pub media_path: String,
    pub file_name: String,
    pub w: i64,
    pub h: i64,
    pub quoted_id: String,
    pub quoted_text: String,
    pub quoted_sender: String,
    pub status: i32,
    pub edited: bool,
    pub deleted: bool,
    pub link_title: String,
    pub mentions_me: bool,
    pub reactions: Vec<Reaction>,
}

pub mod status {
    pub const FAILED: i32 = -1;
    pub const PENDING: i32 = 0;
    pub const SENT: i32 = 1;
    pub const READ: i32 = 3;
}
