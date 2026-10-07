//! The window: pairing, the chat list and the open chat.

use std::cell::RefCell;
use std::collections::HashMap;
use std::rc::Rc;

use adw::prelude::*;
use base64::Engine;
use gtk::{gdk, gio, glib};
use serde_json::{json, Value};

use crate::bridge::{self, status, Chat, Message};
use crate::format;
use crate::i18n::t;

const PAGE: i64 = 60;

pub fn load_css() {
    let provider = gtk::CssProvider::new();
    provider.load_from_string(
        "
        .bubble { border-radius: 16px; padding: 6px 10px 5px 10px; }
        .bubble.in { background-color: alpha(currentColor, 0.08); }
        .bubble.out { background-color: @accent_bg_color; color: @accent_fg_color; }
        .bubble.out link, .bubble.out label link { color: @accent_fg_color; }
        .bubble.mention { box-shadow: inset 0 0 0 1.5px @accent_color; }
        .meta { font-size: 0.78em; opacity: 0.72; }
        .sender { font-size: 0.85em; font-weight: bold; }
        .quote { border-left: 3px solid currentColor; border-radius: 6px; padding: 3px 8px; background-color: alpha(currentColor, 0.08); }
        .quote .sender { font-size: 0.82em; }
        .quote label { opacity: 0.85; }
        .day { font-size: 0.8em; padding: 3px 10px; border-radius: 999px; background-color: alpha(currentColor, 0.07); }
        .badge { background-color: @accent_bg_color; color: @accent_fg_color; border-radius: 999px; padding: 0 6px; font-size: 0.78em; font-weight: bold; min-width: 10px; }
        .photo { border-radius: 12px; }
        .composer { border-radius: 18px; padding: 6px 10px; background-color: alpha(currentColor, 0.06); }
        .composer textview, .composer text { background: transparent; }
        .reply-bar { padding: 6px 12px; border-left: 3px solid @accent_color; }
        .reactions { font-size: 0.85em; }
        .chat-row { padding: 8px 6px; }
        .preview { opacity: 0.7; }
        ",
    );
    if let Some(display) = gdk::Display::default() {
        gtk::style_context_add_provider_for_display(&display, &provider, gtk::STYLE_PROVIDER_PRIORITY_APPLICATION);
    }
}

#[derive(Default)]
struct State {
    account: String,
    connected: bool,
    chats: Vec<Chat>,
    selected: Option<String>,
    messages: Vec<Message>,
    limit: i64,
    reply: Option<Message>,
    /// A profile photo's file for each jid; None when it has none.
    avatars: HashMap<String, Option<String>>,
    chats_pending: bool,
    messages_pending: bool,
    asked_phone: bool,
}

pub struct Ui {
    app: adw::Application,
    window: adw::ApplicationWindow,
    stack: gtk::Stack,
    pair_picture: gtk::Picture,
    pair_note: gtk::Label,
    split: adw::NavigationSplitView,
    chat_list: gtk::ListBox,
    search: gtk::SearchEntry,
    title: adw::WindowTitle,
    content: gtk::Stack,
    scroller: gtk::ScrolledWindow,
    messages: gtk::Box,
    composer: gtk::TextView,
    reply_bar: gtk::Box,
    reply_label: gtk::Label,
    toasts: adw::ToastOverlay,
    state: RefCell<State>,
    /// Decoded pictures of the open chat, by file.
    textures: RefCell<HashMap<String, gdk::Texture>>,
    /// Decoded profile photos, by file: small, and all of them wanted again.
    avatar_textures: RefCell<HashMap<String, gdk::Texture>>,
}

/// The development switch ZEN_OFFLINE=1 shows the stored chats without a link
/// to WhatsApp, for working on the window.
fn offline() -> bool {
    std::env::var_os("ZEN_OFFLINE").is_some()
}

impl Ui {
    pub fn build(app: &adw::Application, events: async_channel::Receiver<Value>) -> Rc<Ui> {
        // Pairing.
        let pair_picture = gtk::Picture::builder().width_request(264).height_request(264).can_shrink(false).halign(gtk::Align::Center).build();
        pair_picture.add_css_class("card");
        let pair_note = gtk::Label::builder().wrap(true).justify(gtk::Justification::Center).max_width_chars(46).build();
        let pair_box = gtk::Box::new(gtk::Orientation::Vertical, 18);
        pair_box.set_halign(gtk::Align::Center);
        pair_box.append(&pair_picture);
        pair_box.append(&pair_note);
        let pairing = adw::StatusPage::builder()
            .title(t("Link to WhatsApp"))
            .description(t("Open WhatsApp on your phone, go to Settings → Linked Devices → Link a Device, and point your phone at this code."))
            .child(&pair_box)
            .build();

        let loading = adw::StatusPage::builder().title(t("Starting…")).build();
        let spinner = gtk::Spinner::builder().spinning(true).width_request(32).height_request(32).build();
        loading.set_child(Some(&spinner));

        // Chat list.
        let search = gtk::SearchEntry::builder().placeholder_text(t("Search")).margin_start(8).margin_end(8).margin_bottom(6).build();
        let chat_list = gtk::ListBox::builder().selection_mode(gtk::SelectionMode::Single).build();
        chat_list.add_css_class("navigation-sidebar");
        let list_scroller = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).child(&chat_list).build();
        let sidebar_box = gtk::Box::new(gtk::Orientation::Vertical, 0);
        sidebar_box.append(&search);
        sidebar_box.append(&list_scroller);
        let sidebar_view = adw::ToolbarView::new();
        let sidebar_header = adw::HeaderBar::new();
        sidebar_header.set_title_widget(Some(&adw::WindowTitle::new("WhatsApp Zen", "")));
        sidebar_view.add_top_bar(&sidebar_header);
        sidebar_view.set_content(Some(&sidebar_box));

        // The open chat.
        let title = adw::WindowTitle::new("", "");
        let header = adw::HeaderBar::new();
        header.set_title_widget(Some(&title));
        let messages = gtk::Box::new(gtk::Orientation::Vertical, 3);
        messages.set_margin_start(14);
        messages.set_margin_end(14);
        messages.set_margin_top(10);
        messages.set_margin_bottom(10);
        let clamp = adw::Clamp::builder().maximum_size(900).tightening_threshold(700).child(&messages).build();
        let scroller = gtk::ScrolledWindow::builder().hscrollbar_policy(gtk::PolicyType::Never).vexpand(true).child(&clamp).build();

        let reply_label = gtk::Label::builder().xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).hexpand(true).build();
        let reply_close = gtk::Button::from_icon_name("window-close-symbolic");
        reply_close.add_css_class("flat");
        reply_close.set_tooltip_text(Some(t("Cancel")));
        let reply_bar = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        reply_bar.add_css_class("reply-bar");
        reply_bar.append(&reply_label);
        reply_bar.append(&reply_close);
        reply_bar.set_visible(false);

        let composer = gtk::TextView::builder().wrap_mode(gtk::WrapMode::WordChar).accepts_tab(false).top_margin(4).bottom_margin(4).build();
        composer.update_property(&[gtk::accessible::Property::Label(t("Message"))]);
        let composer_scroller = gtk::ScrolledWindow::builder()
            .hscrollbar_policy(gtk::PolicyType::Never)
            .propagate_natural_height(true)
            .max_content_height(160)
            .hexpand(true)
            .child(&composer)
            .build();
        composer_scroller.add_css_class("composer");
        let attach = gtk::Button::from_icon_name("mail-attachment-symbolic");
        attach.set_tooltip_text(Some(t("Attach a file")));
        attach.add_css_class("circular");
        attach.set_valign(gtk::Align::End);
        let send = gtk::Button::from_icon_name("go-up-symbolic");
        send.set_tooltip_text(Some(t("Send")));
        send.add_css_class("circular");
        send.add_css_class("suggested-action");
        send.set_valign(gtk::Align::End);
        let input = gtk::Box::new(gtk::Orientation::Horizontal, 8);
        input.set_margin_start(10);
        input.set_margin_end(10);
        input.set_margin_top(6);
        input.set_margin_bottom(10);
        input.append(&attach);
        input.append(&composer_scroller);
        input.append(&send);
        let bottom = gtk::Box::new(gtk::Orientation::Vertical, 0);
        bottom.append(&reply_bar);
        bottom.append(&input);

        let chat_view = adw::ToolbarView::new();
        chat_view.add_top_bar(&header);
        chat_view.set_content(Some(&scroller));
        chat_view.add_bottom_bar(&bottom);

        let empty = adw::StatusPage::builder()
            .icon_name("chat-message-new-symbolic")
            .title(t("Choose a chat"))
            .description(t("Your messages stay on your phone and on this computer."))
            .build();
        let empty_view = adw::ToolbarView::new();
        empty_view.add_top_bar(&adw::HeaderBar::builder().show_title(false).build());
        empty_view.set_content(Some(&empty));
        let content = gtk::Stack::new();
        content.add_named(&empty_view, Some("empty"));
        content.add_named(&chat_view, Some("chat"));

        let split = adw::NavigationSplitView::new();
        split.set_sidebar(Some(&adw::NavigationPage::new(&sidebar_view, t("Chats"))));
        split.set_content(Some(&adw::NavigationPage::new(&content, "WhatsApp Zen")));
        split.set_min_sidebar_width(280.0);
        split.set_max_sidebar_width(380.0);

        let stack = gtk::Stack::builder().transition_type(gtk::StackTransitionType::Crossfade).build();
        stack.add_named(&loading, Some("loading"));
        stack.add_named(&pairing, Some("pair"));
        stack.add_named(&split, Some("main"));

        let toasts = adw::ToastOverlay::new();
        toasts.set_child(Some(&stack));

        let window = adw::ApplicationWindow::builder().application(app).title("WhatsApp Zen").default_width(1040).default_height(720).content(&toasts).build();
        // A narrow window shows the list or the chat, one at a time.
        let narrow = adw::Breakpoint::new(adw::BreakpointCondition::parse("max-width: 620sp").expect("breakpoint"));
        narrow.add_setter(&split, "collapsed", Some(&true.to_value()));
        window.add_breakpoint(narrow);

        let ui = Rc::new(Ui {
            app: app.clone(),
            window,
            stack,
            pair_picture,
            pair_note,
            split,
            chat_list,
            search,
            title,
            content,
            scroller,
            messages,
            composer,
            reply_bar,
            reply_label,
            toasts,
            state: RefCell::new(State { limit: PAGE, ..Default::default() }),
            textures: RefCell::default(),
            avatar_textures: RefCell::default(),
        });

        // Wiring.
        let me = ui.clone();
        ui.chat_list.connect_row_activated(move |_, row| me.open(row.widget_name().as_str()));
        let me = ui.clone();
        ui.search.connect_search_changed(move |_| me.render_chats());
        let me = ui.clone();
        reply_close.connect_clicked(move |_| me.set_reply(None));
        let me = ui.clone();
        send.connect_clicked(move |_| me.send());
        let me = ui.clone();
        attach.connect_clicked(move |_| me.attach());
        let keys = gtk::EventControllerKey::new();
        keys.set_propagation_phase(gtk::PropagationPhase::Capture);
        let me = ui.clone();
        keys.connect_key_pressed(move |_, key, _, modifiers| {
            match key {
                // ↩ sends; ⇧↩ (or ⌃↩) starts a new line, as on WhatsApp.
                gdk::Key::Return | gdk::Key::KP_Enter if !modifiers.intersects(gdk::ModifierType::SHIFT_MASK | gdk::ModifierType::CONTROL_MASK | gdk::ModifierType::ALT_MASK) => {
                    me.send();
                    glib::Propagation::Stop
                }
                gdk::Key::Escape if me.state.borrow().reply.is_some() => {
                    me.set_reply(None);
                    glib::Propagation::Stop
                }
                _ => glib::Propagation::Proceed,
            }
        });
        ui.composer.add_controller(keys);
        // Ctrl+F searches the chats, as everywhere.
        let find = gtk::ShortcutController::new();
        find.set_scope(gtk::ShortcutScope::Managed);
        let me = ui.clone();
        find.add_shortcut(gtk::Shortcut::new(
            gtk::ShortcutTrigger::parse_string("<Control>f"),
            Some(gtk::CallbackAction::new(move |_, _| {
                me.split.set_show_content(false);
                me.search.grab_focus();
                glib::Propagation::Stop
            })),
        ));
        ui.window.add_controller(find);
        // Coming back to the window counts as reading the open chat.
        let me = ui.clone();
        ui.window.connect_is_active_notify(move |window| {
            if window.is_active() {
                if let Some(chat) = me.state.borrow().selected.clone() {
                    me.mark_read(&chat);
                }
            }
        });
        // Older messages load when the list is scrolled to its top.
        let me = ui.clone();
        ui.scroller.connect_edge_reached(move |_, edge| {
            if edge == gtk::PositionType::Top {
                me.load_older();
            }
        });
        // A notification's click opens its chat.
        let open_chat = gio::SimpleAction::new("open-chat", Some(glib::VariantTy::STRING));
        let me = ui.clone();
        open_chat.connect_activate(move |_, parameter| {
            me.window.present();
            if let Some(jid) = parameter.and_then(|p| p.get::<String>()) {
                me.open(&jid);
            }
        });
        app.add_action(&open_chat);

        let me = ui.clone();
        glib::spawn_future_local(async move {
            while let Ok(event) = events.recv().await {
                me.handle(&event);
            }
        });
        let me = ui.clone();
        glib::spawn_future_local(async move { me.start().await });
        ui.window.present();
        ui.snapshot_for_development();
        ui
    }

    /// ZEN_SNAPSHOT=<file.png> (development): opens the ZEN_OPEN'th chat,
    /// draws the window into the file and quits, for checking the layout
    /// without a screen capture.
    fn snapshot_for_development(self: &Rc<Self>) {
        let Some(path) = std::env::var_os("ZEN_SNAPSHOT") else { return };
        let me = self.clone();
        glib::timeout_add_local_once(std::time::Duration::from_secs(4), move || {
            if let Some(n) = std::env::var("ZEN_OPEN").ok().and_then(|n| n.parse::<usize>().ok()) {
                let jid = me.state.borrow().chats.iter().filter(|c| !c.archived).nth(n).map(|c| c.jid.clone());
                if let Some(jid) = jid {
                    me.open(&jid);
                }
            }
            glib::timeout_add_local_once(std::time::Duration::from_secs(3), move || {
                let Some(child) = me.window.content() else { return };
                let (w, h) = (child.width(), child.height());
                let paintable = gtk::WidgetPaintable::new(Some(&child));
                let snapshot = gtk::Snapshot::new();
                paintable.snapshot(&snapshot, w as f64, h as f64);
                if let (Some(node), Some(renderer)) = (snapshot.to_node(), me.window.renderer()) {
                    let texture = renderer.render_texture(&node, None);
                    if let Err(error) = texture.save_to_png(&path) {
                        eprintln!("snapshot: {error}");
                    }
                }
                me.app.quit();
            });
        });
    }

    async fn start(self: &Rc<Self>) {
        let _ = bridge::call("", "set_lang", json!({"text": crate::i18n::language()})).await;
        let ids: Vec<String> = bridge::get("", "accounts", json!({})).await.unwrap_or_default();
        let account = ids.into_iter().next().unwrap_or_else(|| "main".to_string());
        self.state.borrow_mut().account = account.clone();
        if let Err(error) = bridge::call(&account, "open_account", json!({})).await {
            eprintln!("open_account: {error}");
            self.toast(&error);
        }
        if offline() {
            self.show_main();
        } else if let Ok(state) = bridge::call(&account, "state", json!({})).await {
            self.handle(&state);
        }
    }

    fn account(&self) -> String {
        self.state.borrow().account.clone()
    }

    fn toast(&self, text: &str) {
        self.toasts.add_toast(adw::Toast::new(text));
    }

    fn handle(self: &Rc<Self>, event: &Value) {
        let text = |key: &str| event.get(key).and_then(Value::as_str).unwrap_or("").to_string();
        if !event.get("account").and_then(Value::as_str).is_none_or(|a| a == self.account()) {
            return;
        }
        match text("type").as_str() {
            "state" if !offline() => match text("state").as_str() {
                "connected" => self.show_main(),
                "qr" => self.show_pairing(&text("qr"), ""),
                "logged_out" => self.show_pairing("", t("Logged out. Link this computer again.")),
                "connecting" if !self.state.borrow().connected => self.stack.set_visible_child_name("loading"),
                _ => {}
            },
            "chats" => self.schedule_chats(),
            "messages" => {
                let chat = text("chat");
                if chat.is_empty() || Some(&chat) == self.state.borrow().selected.as_ref() {
                    self.schedule_messages();
                }
                self.schedule_chats();
            }
            "message" => {
                let chat = text("chat");
                self.schedule_chats();
                let open = Some(&chat) == self.state.borrow().selected.as_ref();
                if open {
                    self.schedule_messages();
                    if self.window.is_active() {
                        self.mark_read(&chat);
                    }
                }
                if event.get("notify").and_then(Value::as_bool) == Some(true) && !(open && self.window.is_active()) {
                    if let Ok(message) = serde_json::from_value::<Message>(event.get("msg").cloned().unwrap_or_default()) {
                        self.notify(&chat, &text("chat_name"), &message);
                    }
                }
            }
            "typing" => {
                let chat = text("chat");
                if Some(&chat) == self.state.borrow().selected.as_ref() {
                    let composing = event.get("composing").and_then(Value::as_bool) == Some(true);
                    self.title.set_subtitle(if composing { t("typing…") } else { "" });
                }
            }
            "avatar" => {
                self.state.borrow_mut().avatars.remove(&text("jid"));
            }
            _ => {}
        }
    }

    fn show_pairing(&self, code: &str, note: &str) {
        self.state.borrow_mut().connected = false;
        self.pair_note.set_label(note);
        self.pair_picture.set_paintable(qr_texture(code).as_ref());
        self.stack.set_visible_child_name("pair");
    }

    fn show_main(self: &Rc<Self>) {
        let first = !self.state.borrow().connected;
        self.state.borrow_mut().connected = true;
        self.stack.set_visible_child_name("main");
        if first {
            self.schedule_chats();
        }
    }

    // MARK: Chats

    /// Reloads the chat list soon, once however many events ask for it.
    fn schedule_chats(self: &Rc<Self>) {
        if std::mem::replace(&mut self.state.borrow_mut().chats_pending, true) {
            return;
        }
        let me = self.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(250), move || {
            glib::spawn_future_local(async move {
                me.state.borrow_mut().chats_pending = false;
                let account = me.account();
                match bridge::get::<Vec<Chat>>(&account, "chats", json!({})).await {
                    Ok(chats) => {
                        if chats != me.state.borrow().chats {
                            me.state.borrow_mut().chats = chats;
                            me.render_chats();
                        }
                    }
                    Err(error) => eprintln!("chats: {error}"),
                }
            });
        });
    }

    fn render_chats(self: &Rc<Self>) {
        let query = self.search.text().to_lowercase();
        let selected = self.state.borrow().selected.clone();
        let chats: Vec<Chat> = self
            .state
            .borrow()
            .chats
            .iter()
            // Archived chats only turn up when searched for.
            .filter(|c| if query.is_empty() { !c.archived } else { c.name.to_lowercase().contains(&query) })
            .take(300)
            .cloned()
            .collect();
        self.chat_list.remove_all();
        if chats.is_empty() && query.is_empty() {
            let label = gtk::Label::builder().label(t("No chats yet")).margin_top(30).build();
            label.add_css_class("dim-label");
            self.chat_list.append(&label);
        }
        for (index, chat) in chats.iter().enumerate() {
            let row = gtk::ListBoxRow::new();
            row.set_widget_name(&chat.jid);
            row.set_child(Some(&self.chat_row(chat, index < 40)));
            self.chat_list.append(&row);
            if selected.as_deref() == Some(chat.jid.as_str()) {
                self.chat_list.select_row(Some(&row));
            }
        }
    }

    fn chat_row(self: &Rc<Self>, chat: &Chat, with_photo: bool) -> gtk::Widget {
        let avatar = adw::Avatar::new(44, Some(&chat.name), true);
        if with_photo {
            self.load_avatar(&avatar, &chat.jid);
        }
        let name = gtk::Label::builder().label(&chat.name).xalign(0.0).hexpand(true).ellipsize(gtk::pango::EllipsizeMode::End).build();
        name.add_css_class("heading");
        let time = gtk::Label::new(Some(&short_time(chat.last_ts)));
        time.add_css_class("meta");
        let top = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        top.append(&name);
        if chat.pinned {
            let pin = gtk::Image::from_icon_name("view-pin-symbolic");
            pin.add_css_class("dim-label");
            top.append(&pin);
        }
        top.append(&time);
        let preview = gtk::Label::builder().label(chat_preview(chat)).xalign(0.0).hexpand(true).ellipsize(gtk::pango::EllipsizeMode::End).build();
        preview.add_css_class("preview");
        let bottom = gtk::Box::new(gtk::Orientation::Horizontal, 6);
        if chat.last_from_me && !chat.last_text.is_empty() {
            bottom.append(&ticks(chat.last_status));
        }
        bottom.append(&preview);
        if chat.muted {
            let muted = gtk::Image::from_icon_name("audio-volume-muted-symbolic");
            muted.add_css_class("dim-label");
            bottom.append(&muted);
        }
        if chat.unread > 0 {
            let badge = gtk::Label::new(Some(&if chat.unread > 999 { "999+".to_string() } else { chat.unread.to_string() }));
            badge.add_css_class("badge");
            badge.set_valign(gtk::Align::Center);
            bottom.append(&badge);
        }
        let text = gtk::Box::new(gtk::Orientation::Vertical, 2);
        text.set_valign(gtk::Align::Center);
        text.set_hexpand(true);
        text.append(&top);
        text.append(&bottom);
        let row = gtk::Box::new(gtk::Orientation::Horizontal, 10);
        row.add_css_class("chat-row");
        row.append(&avatar);
        row.append(&text);
        row.upcast()
    }

    /// Puts a profile photo on an avatar once it is known; the core fetches
    /// it from WhatsApp the first time.
    fn load_avatar(self: &Rc<Self>, avatar: &adw::Avatar, jid: &str) {
        let known = self.state.borrow().avatars.get(jid).cloned();
        if let Some(Some(texture)) = known.as_ref().map(|path| path.as_ref().and_then(|p| self.avatar_textures.borrow().get(p).cloned())) {
            avatar.set_custom_image(Some(&texture));
            return;
        }
        if known == Some(None) {
            return;
        }
        let (me, avatar, jid) = (self.clone(), avatar.clone(), jid.to_string());
        glib::spawn_future_local(async move {
            let path = match known {
                Some(path) => path,
                None => {
                    let account = me.account();
                    let path = bridge::call(&account, "avatar", json!({"jid": jid})).await.ok().and_then(|v| v.as_str().map(str::to_string)).filter(|p| !p.is_empty());
                    me.state.borrow_mut().avatars.insert(jid, path.clone());
                    path
                }
            };
            let Some(path) = path else { return };
            let file = path.clone();
            if let Ok(Some(picture)) = gio::spawn_blocking(move || decode(&std::fs::read(&file).ok()?, 96)).await {
                let texture = texture(picture);
                me.avatar_textures.borrow_mut().insert(path, texture.clone());
                avatar.set_custom_image(Some(&texture));
            }
        });
    }

    fn open(self: &Rc<Self>, jid: &str) {
        let Some(chat) = self.state.borrow().chats.iter().find(|c| c.jid == jid).cloned() else { return };
        {
            let mut state = self.state.borrow_mut();
            if state.selected.as_deref() != Some(jid) {
                state.selected = Some(jid.to_string());
                state.messages.clear();
                self.textures.borrow_mut().clear();
                state.limit = PAGE;
                state.reply = None;
                state.asked_phone = false;
            }
        }
        self.reply_bar.set_visible(false);
        self.title.set_title(&chat.name);
        self.title.set_subtitle("");
        self.content.set_visible_child_name("chat");
        self.split.set_show_content(true);
        while let Some(child) = self.messages.first_child() {
            self.messages.remove(&child);
        }
        self.composer.grab_focus();
        self.mark_read(jid);
        self.reload_messages(Scroll::End);
    }

    fn mark_read(&self, chat: &str) {
        let unread = self.state.borrow().chats.iter().any(|c| c.jid == chat && c.unread > 0);
        if unread {
            bridge::fire(&self.account(), "mark_read", json!({"chat": chat}));
        }
        self.app.withdraw_notification(&format!("chat-{chat}"));
    }

    // MARK: Messages

    fn schedule_messages(self: &Rc<Self>) {
        if std::mem::replace(&mut self.state.borrow_mut().messages_pending, true) {
            return;
        }
        let me = self.clone();
        glib::timeout_add_local_once(std::time::Duration::from_millis(120), move || {
            me.state.borrow_mut().messages_pending = false;
            me.reload_messages(Scroll::KeepBottom);
        });
    }

    fn load_older(self: &Rc<Self>) {
        let more = {
            let state = self.state.borrow();
            state.messages.len() as i64 >= state.limit
        };
        if more {
            self.state.borrow_mut().limit += PAGE;
            self.reload_messages(Scroll::Keep);
        }
    }

    fn reload_messages(self: &Rc<Self>, scroll: Scroll) {
        let Some(chat) = self.state.borrow().selected.clone() else { return };
        let me = self.clone();
        glib::spawn_future_local(async move {
            let (account, limit) = (me.account(), me.state.borrow().limit);
            let Ok(list) = bridge::get::<Vec<Message>>(&account, "messages", json!({"chat": chat, "limit": limit})).await else { return };
            if me.state.borrow().selected.as_ref() != Some(&chat) || list == me.state.borrow().messages {
                return;
            }
            let adjustment = me.scroller.vadjustment();
            let at_bottom = adjustment.value() + adjustment.page_size() >= adjustment.upper() - 40.0;
            let from_bottom = adjustment.upper() - adjustment.value();
            me.state.borrow_mut().messages = list;
            me.render_messages();
            let me2 = me.clone();
            // Heights are known only after layout.
            glib::idle_add_local_once(move || {
                let adjustment = me2.scroller.vadjustment();
                match scroll {
                    Scroll::End => adjustment.set_value(adjustment.upper()),
                    Scroll::KeepBottom if at_bottom => adjustment.set_value(adjustment.upper()),
                    Scroll::Keep => adjustment.set_value((adjustment.upper() - from_bottom).max(0.0)),
                    _ => {}
                }
            });
        });
    }

    fn render_messages(self: &Rc<Self>) {
        while let Some(child) = self.messages.first_child() {
            self.messages.remove(&child);
        }
        let (list, limit, is_group) = {
            let state = self.state.borrow();
            let group = state.selected.as_deref().is_some_and(|c| c.ends_with("@g.us"));
            (state.messages.clone(), state.limit, group)
        };
        if (list.len() as i64) < limit {
            // Nothing older here; the phone may have more.
            let ask = gtk::Button::with_label(t("Get older messages from your phone"));
            ask.add_css_class("pill");
            ask.set_halign(gtk::Align::Center);
            ask.set_margin_bottom(8);
            let me = self.clone();
            ask.connect_clicked(move |button| {
                if let Some(chat) = me.state.borrow().selected.clone() {
                    bridge::fire(&me.account(), "fetch_history", json!({"chat": chat}));
                }
                button.set_sensitive(false);
            });
            ask.set_sensitive(!self.state.borrow().asked_phone);
            self.messages.append(&ask);
        }
        let mut previous: Option<&Message> = None;
        for (index, message) in list.iter().enumerate() {
            let next = list.get(index + 1);
            if previous.is_none_or(|p| day(p.ts) != day(message.ts)) {
                let label = gtk::Label::new(Some(&day_title(message.ts)));
                label.add_css_class("day");
                label.set_halign(gtk::Align::Center);
                label.set_margin_top(8);
                label.set_margin_bottom(4);
                self.messages.append(&label);
            }
            let first_of_run = previous.is_none_or(|p| p.sender != message.sender || day(p.ts) != day(message.ts));
            let last_of_run = next.is_none_or(|n| n.sender != message.sender);
            let bubble = self.bubble(message, is_group && !message.from_me && first_of_run);
            bubble.set_margin_bottom(if last_of_run { 6 } else { 0 });
            self.messages.append(&bubble);
            previous = Some(message);
        }
    }

    fn bubble(self: &Rc<Self>, message: &Message, show_sender: bool) -> gtk::Widget {
        let body = gtk::Box::new(gtk::Orientation::Vertical, 4);
        body.add_css_class("bubble");
        body.add_css_class(if message.from_me { "out" } else { "in" });
        if message.mentions_me {
            body.add_css_class("mention");
        }
        if show_sender {
            let sender = gtk::Label::builder().label(&message.sender_name).xalign(0.0).build();
            sender.add_css_class("sender");
            body.append(&sender);
        }
        if !message.quoted_id.is_empty() {
            let quote = gtk::Box::new(gtk::Orientation::Vertical, 1);
            quote.add_css_class("quote");
            let who = gtk::Label::builder().label(&message.quoted_sender).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).build();
            who.add_css_class("sender");
            let what = gtk::Label::builder().label(format::plain(&message.quoted_text)).xalign(0.0).ellipsize(gtk::pango::EllipsizeMode::End).lines(2).wrap(true).build();
            quote.append(&who);
            quote.append(&what);
            body.append(&quote);
        }
        let mut text = message.text.clone();
        if message.deleted {
            let label = gtk::Label::builder().label(t("This message was deleted")).xalign(0.0).build();
            label.add_css_class("dim-label");
            body.append(&label);
            text.clear();
        } else {
            match message.kind.as_str() {
                "image" | "sticker" => body.append(&self.photo(message)),
                "video" | "document" | "audio" => body.append(&self.file_button(message)),
                "poll" => {
                    text = format!("📊 {}", message.text);
                }
                _ => {}
            }
        }
        // The text, with the time (and ticks) at the end.
        let meta = gtk::Box::new(gtk::Orientation::Horizontal, 4);
        meta.add_css_class("meta");
        meta.set_halign(gtk::Align::End);
        meta.set_valign(gtk::Align::End);
        if message.edited {
            meta.append(&gtk::Label::new(Some(t("edited"))));
        }
        meta.append(&gtk::Label::new(Some(&time(message.ts))));
        if message.from_me {
            meta.append(&ticks(message.status));
        }
        if text.is_empty() {
            body.append(&meta);
        } else {
            let label = gtk::Label::builder()
                .use_markup(true)
                .label(format::markup(&text))
                .xalign(0.0)
                .wrap(true)
                .wrap_mode(gtk::pango::WrapMode::WordChar)
                .max_width_chars(60)
                .hexpand(false)
                .build();
            let line = gtk::Box::new(gtk::Orientation::Horizontal, 8);
            line.append(&label);
            line.append(&meta);
            body.append(&line);
        }
        if !message.reactions.is_empty() {
            let mut counts: Vec<(String, usize)> = Vec::new();
            for reaction in &message.reactions {
                match counts.iter_mut().find(|(e, _)| *e == reaction.emoji) {
                    Some(entry) => entry.1 += 1,
                    None => counts.push((reaction.emoji.clone(), 1)),
                }
            }
            let words: Vec<String> = counts.iter().map(|(e, n)| if *n > 1 { format!("{e} {n}") } else { e.clone() }).collect();
            let label = gtk::Label::new(Some(&words.join("  ")));
            label.add_css_class("reactions");
            label.set_halign(gtk::Align::Start);
            body.append(&label);
        }
        body.set_halign(if message.from_me { gtk::Align::End } else { gtk::Align::Start });
        // Room on the other side, as in WhatsApp, so long texts read as speech.
        if message.from_me { body.set_margin_start(60) } else { body.set_margin_end(60) }
        let row = body.clone();

        // Right click (or a long press) offers what can be done with it.
        let menu = gtk::GestureClick::new();
        menu.set_button(3);
        let (me, msg, anchor) = (self.clone(), message.clone(), body.clone());
        menu.connect_pressed(move |_, _, x, y| me.message_menu(&anchor, &msg, x, y));
        body.add_controller(menu);
        let press = gtk::GestureLongPress::new();
        let (me, msg, anchor) = (self.clone(), message.clone(), body.clone());
        press.connect_pressed(move |_, x, y| me.message_menu(&anchor, &msg, x, y));
        body.add_controller(press);
        // Two fingers across the touchpad, or a double click, replies.
        let double = gtk::GestureClick::new();
        let (me, msg) = (self.clone(), message.clone());
        double.connect_pressed(move |_, presses, _, _| {
            if presses == 2 {
                me.set_reply(Some(msg.clone()));
            }
        });
        body.add_controller(double);
        row.upcast()
    }

    fn photo(self: &Rc<Self>, message: &Message) -> gtk::Widget {
        let (w, h) = if message.w > 0 && message.h > 0 { (message.w as f64, message.h as f64) } else { (1.0, 1.0) };
        let aspect = w / h;
        let width = if message.kind == "sticker" { 140.0 } else { (260.0 * aspect).clamp(150.0, 300.0) };
        let height = (width / aspect).min(360.0);
        let picture = gtk::Picture::new();
        let known = self.textures.borrow().get(&message.media_path).cloned();
        picture.set_paintable(known.or_else(|| thumb_texture(&message.thumb)).as_ref());
        picture.set_content_fit(if message.kind == "sticker" { gtk::ContentFit::Contain } else { gtk::ContentFit::Cover });
        picture.set_can_shrink(true);
        picture.set_size_request(width as i32, height as i32);
        picture.set_overflow(gtk::Overflow::Hidden);
        picture.add_css_class("photo");
        picture.set_cursor_from_name(Some("pointer"));
        let click = gtk::GestureClick::new();
        let (me, msg, target) = (self.clone(), message.clone(), picture.clone());
        click.connect_released(move |_, presses, _, _| {
            if presses == 1 {
                me.open_media(&msg, Some(target.clone()));
            }
        });
        picture.add_controller(click);
        // The picture itself, downloaded if need be and decoded off the UI
        // thread; the small preview shows meanwhile.
        if !self.textures.borrow().contains_key(&message.media_path) {
            let (me, msg, target) = (self.clone(), message.clone(), picture.clone());
            glib::spawn_future_local(async move {
                if let Ok(path) = me.download(&msg).await {
                    if let Some(texture) = me.texture_for(&path, 600).await {
                        target.set_paintable(Some(&texture));
                    }
                }
            });
        }
        picture.upcast()
    }

    /// A picture file as a texture, decoded on a worker thread and kept for
    /// a while: the message list is drawn again with every new message.
    async fn texture_for(&self, path: &str, max: u32) -> Option<gdk::Texture> {
        if let Some(known) = self.textures.borrow().get(path) {
            return Some(known.clone());
        }
        let file = path.to_string();
        let picture = gio::spawn_blocking(move || decode(&std::fs::read(&file).ok()?, max)).await.ok()??;
        let texture = texture(picture);
        let mut textures = self.textures.borrow_mut();
        // About as many as a chat shows at once; a crude bound, not an LRU.
        if textures.len() >= 48 {
            textures.clear();
        }
        textures.insert(path.to_string(), texture.clone());
        Some(texture)
    }

    fn file_button(self: &Rc<Self>, message: &Message) -> gtk::Widget {
        let (icon, label) = match message.kind.as_str() {
            "video" => ("video-x-generic-symbolic", t("Video").to_string()),
            "audio" => ("audio-x-generic-symbolic", t("Voice message").to_string()),
            _ => ("text-x-generic-symbolic", if message.file_name.is_empty() { t("Document").to_string() } else { message.file_name.clone() }),
        };
        let content = adw::ButtonContent::builder().icon_name(icon).label(&label).build();
        let button = gtk::Button::builder().child(&content).halign(gtk::Align::Start).build();
        button.add_css_class("flat");
        let (me, msg) = (self.clone(), message.clone());
        button.connect_clicked(move |button| {
            let content = button.child().and_downcast::<adw::ButtonContent>();
            if let Some(content) = &content {
                content.set_label(t("Downloading…"));
            }
            let (me, msg, content, label) = (me.clone(), msg.clone(), content.clone(), label.clone());
            glib::spawn_future_local(async move {
                let result = me.download(&msg).await;
                if let Some(content) = &content {
                    content.set_label(&label);
                }
                match result {
                    Ok(path) => me.launch(&path),
                    Err(_) => me.toast(t("The file could not be downloaded")),
                }
            });
        });
        button.upcast()
    }

    async fn download(&self, message: &Message) -> Result<String, String> {
        if !message.media_path.is_empty() && std::path::Path::new(&message.media_path).exists() {
            return Ok(message.media_path.clone());
        }
        let value = bridge::call(&self.account(), "download", json!({"chat": message.chat, "id": message.id})).await?;
        value.as_str().map(str::to_string).filter(|p| !p.is_empty()).ok_or_else(|| "no file".to_string())
    }

    fn open_media(self: &Rc<Self>, message: &Message, _from: Option<gtk::Picture>) {
        let (me, msg) = (self.clone(), message.clone());
        glib::spawn_future_local(async move {
            match me.download(&msg).await {
                Ok(path) => me.launch(&path),
                Err(_) => me.toast(t("The file could not be downloaded")),
            }
        });
    }

    /// Opens a file with the app the system uses for it.
    fn launch(&self, path: &str) {
        gtk::FileLauncher::new(Some(&gio::File::for_path(path))).launch(Some(&self.window), gio::Cancellable::NONE, |_| {});
    }

    fn message_menu(self: &Rc<Self>, anchor: &gtk::Box, message: &Message, x: f64, y: f64) {
        let popover = gtk::Popover::new();
        popover.set_parent(anchor);
        popover.set_pointing_to(Some(&gdk::Rectangle::new(x as i32, y as i32, 1, 1)));
        popover.set_has_arrow(false);
        let list = gtk::Box::new(gtk::Orientation::Vertical, 2);
        let emojis = gtk::Box::new(gtk::Orientation::Horizontal, 2);
        for emoji in ["👍", "❤️", "😂", "😮", "😢", "🙏"] {
            let button = gtk::Button::with_label(emoji);
            button.add_css_class("flat");
            let (me, msg, pop) = (self.clone(), message.clone(), popover.clone());
            button.connect_clicked(move |_| {
                bridge::fire(&me.account(), "react", json!({"chat": msg.chat, "id": msg.id, "emoji": emoji}));
                pop.popdown();
            });
            emojis.append(&button);
        }
        if !message.deleted {
            list.append(&emojis);
        }
        let item = |label: &str, action: Box<dyn Fn()>| {
            let button = gtk::Button::with_label(label);
            button.add_css_class("flat");
            button.child().and_downcast::<gtk::Label>().inspect(|l| l.set_xalign(0.0));
            let pop = popover.clone();
            button.connect_clicked(move |_| {
                pop.popdown();
                action();
            });
            list.append(&button);
        };
        if !message.deleted {
            let (me, msg) = (self.clone(), message.clone());
            item(t("Reply"), Box::new(move || me.set_reply(Some(msg.clone()))));
        }
        if !message.text.is_empty() && !message.deleted {
            let (me, text) = (self.clone(), format::plain(&message.text));
            item(t("Copy"), Box::new(move || me.window.clipboard().set_text(&text)));
        }
        if ["image", "video", "document", "audio", "sticker"].contains(&message.kind.as_str()) && !message.deleted {
            let (me, msg) = (self.clone(), message.clone());
            item(t("Open"), Box::new(move || me.open_media(&msg, None)));
            let (me, msg) = (self.clone(), message.clone());
            item(t("Save to Downloads"), Box::new(move || {
                let (me, msg) = (me.clone(), msg.clone());
                glib::spawn_future_local(async move {
                    match me.download(&msg).await {
                        Ok(path) => match save_to_downloads(&path, &msg.file_name) {
                            Some(_) => me.toast(t("Saved to Downloads")),
                            None => me.toast(t("The file could not be downloaded")),
                        },
                        Err(_) => me.toast(t("The file could not be downloaded")),
                    }
                });
            }));
        }
        let (me, msg) = (self.clone(), message.clone());
        item(t("Delete for Me"), Box::new(move || bridge::fire(&me.account(), "delete_for_me", json!({"chat": msg.chat, "id": msg.id}))));
        if message.from_me && !message.deleted {
            let (me, msg) = (self.clone(), message.clone());
            item(t("Delete for Everyone"), Box::new(move || bridge::fire(&me.account(), "revoke", json!({"chat": msg.chat, "id": msg.id}))));
        }
        popover.set_child(Some(&list));
        popover.connect_closed(|popover| {
            let popover = popover.clone();
            glib::idle_add_local_once(move || popover.unparent());
        });
        popover.popup();
    }

    fn set_reply(&self, message: Option<Message>) {
        match &message {
            Some(m) => {
                let who = if m.from_me { t("You").to_string() } else { m.sender_name.clone() };
                let what = if m.text.is_empty() { kind_label(&m.kind, &m.file_name) } else { format::plain(&m.text) };
                self.reply_label.set_markup(&format!("<b>{}</b>  {}", glib::markup_escape_text(&who), glib::markup_escape_text(&what)));
                self.reply_bar.set_visible(true);
                self.composer.grab_focus();
            }
            None => self.reply_bar.set_visible(false),
        }
        self.state.borrow_mut().reply = message;
    }

    fn send(self: &Rc<Self>) {
        let buffer = self.composer.buffer();
        let text = buffer.text(&buffer.start_iter(), &buffer.end_iter(), false).trim().to_string();
        let Some(chat) = self.state.borrow().selected.clone() else { return };
        if text.is_empty() {
            return;
        }
        let reply = self.state.borrow().reply.as_ref().map(|m| m.id.clone()).unwrap_or_default();
        buffer.set_text("");
        self.set_reply(None);
        let me = self.clone();
        glib::spawn_future_local(async move {
            let text = format::normalized(&text);
            if let Err(error) = bridge::call(&me.account(), "send_text", json!({"chat": chat, "text": text, "reply_to": reply})).await {
                me.toast(&format!("{}: {error}", t("Could not send")));
            }
            me.reload_messages(Scroll::End);
        });
    }

    fn attach(self: &Rc<Self>) {
        let Some(chat) = self.state.borrow().selected.clone() else { return };
        let dialog = gtk::FileDialog::builder().title(t("Attach a file")).modal(true).build();
        let me = self.clone();
        dialog.open(Some(&self.window), gio::Cancellable::NONE, move |result| {
            let Some(path) = result.ok().and_then(|file| file.path()) else { return };
            let me = me.clone();
            let chat = chat.clone();
            glib::spawn_future_local(async move {
                let name = path.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default();
                let lower = name.to_lowercase();
                let reply = me.state.borrow().reply.as_ref().map(|m| m.id.clone()).unwrap_or_default();
                let result = if [".jpg", ".jpeg", ".png", ".webp"].iter().any(|e| lower.ends_with(e)) {
                    match photo_for_sending(&path) {
                        Some((jpeg, thumb, w, h)) => {
                            let send = bridge::call(&me.account(), "send_image", json!({"chat": chat, "path": jpeg, "thumb": thumb, "w": w, "h": h, "reply_to": reply})).await;
                            let _ = std::fs::remove_file(&jpeg);
                            send
                        }
                        None => Err("unreadable picture".to_string()),
                    }
                } else {
                    let video = [".mp4", ".mov", ".m4v"].iter().any(|e| lower.ends_with(e));
                    let mime = gio::content_type_guess(Some(&path), None::<&[u8]>).0;
                    let mime = gio::content_type_get_mime_type(&mime).map(|m| m.to_string()).unwrap_or_else(|| "application/octet-stream".into());
                    bridge::call(&me.account(), "send_file", json!({"chat": chat, "path": path, "file_name": name, "mime": mime, "kind": if video { "video" } else { "document" }, "reply_to": reply})).await
                };
                me.set_reply(None);
                if let Err(error) = result {
                    me.toast(&format!("{}: {error}", t("Could not send")));
                }
                me.reload_messages(Scroll::End);
            });
        });
    }

    fn notify(&self, chat: &str, chat_name: &str, message: &Message) {
        let body = if message.text.is_empty() { kind_label(&message.kind, &message.file_name) } else { format::plain(&message.text) };
        let body = if chat.ends_with("@g.us") && !message.sender_name.is_empty() { format!("{}: {body}", message.sender_name) } else { body };
        let notification = gio::Notification::new(if chat_name.is_empty() { t("New message") } else { chat_name });
        notification.set_body(Some(&body));
        notification.set_default_action_and_target_value("app.open-chat", Some(&chat.to_variant()));
        self.app.send_notification(Some(&format!("chat-{chat}")), &notification);
    }
}

#[derive(Clone, Copy)]
enum Scroll {
    /// To the newest message.
    End,
    /// Follow new messages only if the newest was already in view.
    KeepBottom,
    /// Stay on the same message while older ones are added above.
    Keep,
}

fn ticks(status: i32) -> gtk::Widget {
    let (text, read) = match status {
        status::FAILED => ("!", false),
        status::PENDING => ("🕓", false),
        status::SENT => ("✓", false),
        status::READ => ("✓✓", true),
        _ => ("✓✓", false),
    };
    let label = gtk::Label::new(Some(text));
    label.add_css_class("meta");
    if read {
        // Read: the accent colour on the list, full strength on a bubble.
        label.add_css_class("accent");
        label.set_opacity(1.0);
    }
    label.upcast()
}

fn kind_label(kind: &str, file_name: &str) -> String {
    match kind {
        "image" => format!("📷 {}", t("Photo")),
        "video" => format!("🎥 {}", t("Video")),
        "audio" => format!("🎤 {}", t("Voice message")),
        "sticker" => format!("💟 {}", t("Sticker")),
        "document" => format!("📄 {}", if file_name.is_empty() { t("Document") } else { file_name }),
        "poll" => format!("📊 {}", t("Poll")),
        _ => String::new(),
    }
}

fn chat_preview(chat: &Chat) -> String {
    let body = if chat.last_type == "deleted" {
        t("This message was deleted").to_string()
    } else if chat.last_text.is_empty() || chat.last_type != "text" && chat.last_type != "other" {
        let label = kind_label(&chat.last_type, &chat.last_file);
        if chat.last_text.is_empty() || chat.last_type == "document" { label } else { format!("{label} {}", format::plain(&chat.last_text)) }
    } else {
        format::plain(&chat.last_text)
    };
    let body = body.lines().next().unwrap_or("").to_string();
    if chat.is_group && !chat.last_from_me && !chat.last_sender.is_empty() {
        format!("{}: {body}", chat.last_sender)
    } else {
        body
    }
}

fn local(ts: i64) -> Option<glib::DateTime> {
    glib::DateTime::from_unix_local(ts).ok()
}

fn day(ts: i64) -> (i32, i32) {
    local(ts).map(|d| (d.year(), d.day_of_year())).unwrap_or_default()
}

fn time(ts: i64) -> String {
    local(ts).and_then(|d| d.format("%H:%M").ok()).map(|s| s.to_string()).unwrap_or_default()
}

fn day_title(ts: i64) -> String {
    let now = glib::DateTime::now_local().ok();
    let today = now.as_ref().map(|d| (d.year(), d.day_of_year())).unwrap_or_default();
    let yesterday = now.and_then(|d| d.add_days(-1).ok()).map(|d| (d.year(), d.day_of_year())).unwrap_or_default();
    match day(ts) {
        d if d == today => t("Today").to_string(),
        d if d == yesterday => t("Yesterday").to_string(),
        _ => local(ts).and_then(|d| d.format("%e %B %Y").ok()).map(|s| s.trim().to_string()).unwrap_or_default(),
    }
}

/// For the chat list: the time today, "Yesterday", or the date.
fn short_time(ts: i64) -> String {
    if ts <= 0 {
        return String::new();
    }
    match day_title(ts) {
        title if title == t("Today") => time(ts),
        title if title == t("Yesterday") => title,
        _ => local(ts).and_then(|d| d.format("%d.%m.%Y").ok()).map(|s| s.to_string()).unwrap_or_default(),
    }
}

/// A picture decoded at no more than `max` pixels on its long edge (the
/// full size of a camera photo would cost tens of megabytes), the right way
/// up. Done here rather than by the system's image loaders, which may not
/// read WebP (stickers).
fn decode(data: &[u8], max: u32) -> Option<image::DynamicImage> {
    use image::ImageDecoder;
    let mut decoder = image::ImageReader::new(std::io::Cursor::new(data)).with_guessed_format().ok()?.into_decoder().ok()?;
    let orientation = decoder.orientation().ok();
    let mut picture = image::DynamicImage::from_decoder(decoder).ok()?;
    if let Some(orientation) = orientation {
        picture.apply_orientation(orientation);
    }
    Some(if picture.width() > max || picture.height() > max { picture.thumbnail(max, max) } else { picture })
}

fn texture(picture: image::DynamicImage) -> gdk::Texture {
    let rgba = picture.to_rgba8();
    let (w, h) = rgba.dimensions();
    let bytes = glib::Bytes::from_owned(rgba.into_raw());
    gdk::MemoryTexture::new(w as i32, h as i32, gdk::MemoryFormat::R8g8b8a8, &bytes, w as usize * 4).upcast()
}

/// The small blurred preview WhatsApp sends with a photo.
fn thumb_texture(base64: &str) -> Option<gdk::Texture> {
    let data = base64::engine::general_purpose::STANDARD.decode(base64).ok()?;
    Some(texture(decode(&data, 400)?))
}

/// The pairing code as a black-on-white picture.
fn qr_texture(code: &str) -> Option<gdk::Texture> {
    if code.is_empty() {
        return None;
    }
    let qr = qrcode::QrCode::with_error_correction_level(code.as_bytes(), qrcode::EcLevel::L).ok()?;
    let (modules, colors) = (qr.width(), qr.to_colors());
    // The picture shows at its own size, about 300 points.
    let (scale, border) = (4usize, 4usize);
    let size = (modules + border * 2) * scale;
    let mut pixels = vec![255u8; size * size * 4];
    for (index, color) in colors.iter().enumerate() {
        if *color != qrcode::Color::Dark {
            continue;
        }
        let (mx, my) = (index % modules + border, index / modules + border);
        for y in my * scale..(my + 1) * scale {
            for x in mx * scale..(mx + 1) * scale {
                let at = (y * size + x) * 4;
                pixels[at..at + 3].copy_from_slice(&[0, 0, 0]);
            }
        }
    }
    let bytes = glib::Bytes::from_owned(pixels);
    Some(gdk::MemoryTexture::new(size as i32, size as i32, gdk::MemoryFormat::R8g8b8a8, &bytes, size * 4).upcast())
}

/// A photo as WhatsApp wants it: a JPEG of at most 1600 pixels, a small
/// preview, and its size. The JPEG is written next to the system's temp files.
fn photo_for_sending(path: &std::path::Path) -> Option<(String, String, u32, u32)> {
    let picture = decode(&std::fs::read(path).ok()?, 1600)?;
    let jpeg = |picture: &image::DynamicImage, quality: u8| -> Option<Vec<u8>> {
        let mut out = Vec::new();
        picture.to_rgb8().write_with_encoder(image::codecs::jpeg::JpegEncoder::new_with_quality(&mut out, quality)).ok()?;
        Some(out)
    };
    let out = glib::tmp_dir().join(format!("zen-photo-{}.jpg", glib::monotonic_time()));
    std::fs::write(&out, jpeg(&picture, 82)?).ok()?;
    let thumb = jpeg(&picture.thumbnail(72, 72), 60)?;
    Some((out.to_string_lossy().into_owned(), base64::engine::general_purpose::STANDARD.encode(thumb), picture.width(), picture.height()))
}

/// Copies a downloaded file into the Downloads folder under a free name.
fn save_to_downloads(path: &str, name: &str) -> Option<std::path::PathBuf> {
    let folder = glib::user_special_dir(glib::UserDirectory::Downloads).unwrap_or_else(|| glib::home_dir().join("Downloads"));
    let source = std::path::Path::new(path);
    let name = if name.is_empty() { source.file_name()?.to_string_lossy().into_owned() } else { name.replace('/', "_") };
    let (stem, ext) = match name.rsplit_once('.') {
        Some((stem, ext)) => (stem.to_string(), format!(".{ext}")),
        None => (name.clone(), String::new()),
    };
    let mut target = folder.join(&name);
    let mut n = 2;
    while target.exists() {
        target = folder.join(format!("{stem} ({n}){ext}"));
        n += 1;
    }
    std::fs::create_dir_all(&folder).ok()?;
    std::fs::copy(source, &target).ok()?;
    Some(target)
}
