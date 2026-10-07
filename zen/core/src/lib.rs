//! The WhatsApp Zen core: one linked account, its chats and messages, with
//! the protocol kept behind a small API the UI can call from any thread.

pub mod account;
pub mod db;
pub mod model;

pub use account::Account;
pub use model::{status, Chat, Event, Message, State};
