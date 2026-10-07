//! WhatsApp Zen for Linux: a GTK 4 / libadwaita window over the same Rust
//! core the macOS app uses.

mod bridge;
mod format;
mod i18n;
mod window;

use adw::prelude::*;
use gtk::{gio, glib};

pub const APP_ID: &str = "io.github.mdenizay.WhatsAppZen";

/// Where accounts and their messages are kept: ~/.local/share/whatsapp-zen,
/// or ZEN_DATA.
fn data_dir() -> std::path::PathBuf {
    std::env::var_os("ZEN_DATA").map(Into::into).unwrap_or_else(|| glib::user_data_dir().join("whatsapp-zen"))
}

fn main() -> glib::ExitCode {
    let app = adw::Application::builder().application_id(APP_ID).flags(gio::ApplicationFlags::default()).build();
    app.connect_startup(|_| window::load_css());
    app.connect_activate(|app| {
        // A second launch only brings the window back.
        if let Some(window) = app.active_window() {
            window.present();
            return;
        }
        let events = bridge::start(data_dir());
        window::Ui::build(app, events);
    });
    app.run()
}
