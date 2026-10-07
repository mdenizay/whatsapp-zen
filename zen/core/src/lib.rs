//! The WhatsApp Zen core: linked accounts, their chats and messages, with the
//! protocol kept behind a small JSON-over-C interface every native app uses.

pub mod account;
mod call;
mod commands;
pub mod db;
pub mod ffi;
pub mod i18n;
mod logfile;
mod media;
pub mod ogg;
