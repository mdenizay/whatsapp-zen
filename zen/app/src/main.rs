//! WhatsApp Zen, the Rust edition: one window with the chat list beside the
//! open conversation, or the pairing code while the account is not linked.

use std::sync::Arc;

use gpui_kit::component::input::{Input, InputEvent, InputState};
use gpui_kit::component::{h_flex, v_flex, ActiveTheme as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::*;
use zen_core::{status, Account, Chat, Event as Change, Message, State};

struct Zen {
    account: Arc<Account>,
    state: State,
    chats: Vec<Chat>,
    selected: Option<String>,
    messages: Vec<Message>,
    input: Entity<InputState>,
    scroll: ScrollHandle,
}

impl Zen {
    fn new(window: &mut Window, cx: &mut Context<Self>) -> Self {
        let (tx, rx) = async_channel::unbounded::<Change>();
        let sink = move |change| {
            let _ = tx.try_send(change);
        };
        // ZEN_DEMO runs on canned chats, without touching any account.
        let account = if std::env::var_os("ZEN_DEMO").is_some() {
            Account::demo(sink)
        } else {
            let dir = dirs::data_dir().unwrap_or_else(|| ".".into()).join("WhatsAppZenRust").join("main");
            Account::start(dir, sink).expect("the account's folder could not be opened")
        };
        // The core reports from its own threads; changes are applied here.
        cx.spawn(async move |this, cx| {
            while let Ok(change) = rx.recv().await {
                if this.update(cx, |this, cx| this.apply(change, cx)).is_err() {
                    break;
                }
            }
        })
        .detach();

        let input = cx.new(|cx| InputState::new(window, cx).placeholder("Message"));
        cx.subscribe_in(&input, window, |this, _, event: &InputEvent, window, cx| {
            if let InputEvent::PressEnter { shift: false, .. } = event {
                this.send(window, cx);
            }
        })
        .detach();

        let mut zen = Zen {
            state: account.state(),
            chats: account.chats(),
            account,
            selected: None,
            messages: Vec::new(),
            input,
            scroll: ScrollHandle::new(),
        };
        if std::env::var_os("ZEN_DEMO").is_some() {
            if let Some(first) = zen.chats.first().map(|c| c.jid.clone()) {
                zen.open(first, cx);
            }
        }
        zen
    }

    fn apply(&mut self, change: Change, cx: &mut Context<Self>) {
        match change {
            Change::State(state) => self.state = state,
            Change::Chats => self.chats = self.account.chats(),
            Change::Messages(chat) => {
                if let Some(open) = &self.selected {
                    if chat.is_empty() || &chat == open {
                        self.messages = self.account.messages(open, 80);
                        self.scroll.scroll_to_bottom();
                    }
                }
            }
        }
        cx.notify();
    }

    fn open(&mut self, jid: String, cx: &mut Context<Self>) {
        self.messages = self.account.messages(&jid, 80);
        self.account.mark_read(&jid);
        self.selected = Some(jid);
        self.scroll.scroll_to_bottom();
        cx.notify();
    }

    fn send(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        let Some(chat) = self.selected.clone() else { return };
        let text = self.input.read(cx).value().to_string();
        if text.trim().is_empty() {
            return;
        }
        self.account.send_text(&chat, &text);
        self.input.update(cx, |input, cx| input.set_value("", window, cx));
    }

    fn pairing(&self, code: &str, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        let modules = qrcode::QrCode::new(code.as_bytes()).map(|qr| {
            let width = qr.width();
            (width, qr.to_colors())
        });
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap_5()
            .bg(theme.background)
            .text_color(theme.foreground)
            .child(div().text_2xl().font_weight(FontWeight::BOLD).child("Link WhatsApp Zen"))
            .child(
                div().text_color(theme.muted_foreground).child("On your phone: WhatsApp › Settings › Linked Devices › Link a Device"),
            )
            .when_some(modules.ok(), |this, (width, colors)| {
                let cell = px(5.);
                this.child(
                    v_flex().p_4().bg(gpui_kit::white()).rounded_xl().children((0..width).map(|y| {
                        h_flex().children((0..width).map(|x| {
                            let dark = colors[y * width + x] == qrcode::Color::Dark;
                            div().w(cell).h(cell).bg(if dark { gpui_kit::black() } else { gpui_kit::white() })
                        }))
                    })),
                )
            })
    }

    fn notice(&self, text: &str, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme();
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .bg(theme.background)
            .text_color(theme.muted_foreground)
            .child(text.to_string())
    }

    fn sidebar(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        v_flex()
            .id("chats")
            .w(px(320.))
            .h_full()
            .flex_shrink_0()
            .overflow_y_scroll()
            .border_r_1()
            .border_color(theme.border)
            .bg(theme.sidebar)
            .p_2()
            .gap_0p5()
            .children(self.chats.iter().filter(|c| !c.archived).take(200).enumerate().map(|(index, chat)| {
                let jid = chat.jid.clone();
                let selected = self.selected.as_deref() == Some(chat.jid.as_str());
                h_flex()
                    .id(("chat", index))
                    .gap_3()
                    .px_2()
                    .py_2()
                    .rounded_lg()
                    .when(selected, |row| row.bg(theme.accent))
                    .hover(|row| row.bg(theme.accent))
                    .cursor_pointer()
                    .on_click(cx.listener(move |this, _, _, cx| this.open(jid.clone(), cx)))
                    .child(avatar(&chat.name, chat.is_group, px(42.), &theme))
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(
                                h_flex()
                                    .justify_between()
                                    .gap_2()
                                    .child(div().font_weight(FontWeight::MEDIUM).truncate().child(chat.name.clone()))
                                    .child(div().text_xs().text_color(theme.muted_foreground).flex_shrink_0().child(clock(chat.last_ts))),
                            )
                            .child(
                                h_flex()
                                    .justify_between()
                                    .gap_2()
                                    .child(div().text_sm().text_color(theme.muted_foreground).truncate().child(chat.last_text.clone()))
                                    .when(chat.unread > 0, |row| {
                                        row.child(
                                            div()
                                                .px_1p5()
                                                .rounded_full()
                                                .bg(theme.primary)
                                                .text_color(theme.primary_foreground)
                                                .text_xs()
                                                .font_weight(FontWeight::BOLD)
                                                .flex_shrink_0()
                                                .child(chat.unread.to_string()),
                                        )
                                    }),
                            ),
                    )
            }))
    }

    fn conversation(&self, cx: &mut Context<Self>) -> impl IntoElement {
        let theme = cx.theme().clone();
        let Some(chat) = self.selected.as_ref().and_then(|jid| self.chats.iter().find(|c| &c.jid == jid)) else {
            return v_flex()
                .flex_1()
                .h_full()
                .items_center()
                .justify_center()
                .bg(theme.background)
                .text_color(theme.muted_foreground)
                .child("Select a chat")
                .into_any_element();
        };
        let group = chat.is_group;
        v_flex()
            .flex_1()
            .h_full()
            .min_w_0()
            .bg(theme.background)
            .child(
                h_flex()
                    .gap_3()
                    .px_4()
                    .py_3()
                    .border_b_1()
                    .border_color(theme.border)
                    .child(avatar(&chat.name, chat.is_group, px(34.), &theme))
                    .child(div().font_weight(FontWeight::SEMIBOLD).child(chat.name.clone())),
            )
            .child(
                v_flex()
                    .id("messages")
                    .flex_1()
                    .overflow_y_scroll()
                    .track_scroll(&self.scroll)
                    .px_4()
                    .py_3()
                    .gap_1()
                    .children(self.messages.iter().map(|message| {
                        let mine = message.from_me;
                        h_flex().w_full().when(mine, |row| row.justify_end()).child(
                            v_flex()
                                .max_w(px(520.))
                                .px_3()
                                .py_1p5()
                                .rounded_2xl()
                                .bg(if mine { theme.primary } else { theme.secondary })
                                .text_color(if mine { theme.primary_foreground } else { theme.secondary_foreground })
                                .when(group && !mine, |bubble| {
                                    bubble.child(div().text_xs().font_weight(FontWeight::SEMIBOLD).child(message.sender_name.clone()))
                                })
                                .child(
                                    h_flex()
                                        .items_end()
                                        .gap_2()
                                        .child(div().child(body(message)))
                                        .child(div().text_xs().opacity(0.7).flex_shrink_0().child(format!(
                                            "{}{}",
                                            clock(message.ts),
                                            if mine { ticks(message.status) } else { "" }
                                        ))),
                                ),
                        )
                    })),
            )
            .child(h_flex().px_4().py_3().gap_2().child(div().flex_1().child(Input::new(&self.input))))
            .into_any_element()
    }
}

fn body(message: &Message) -> String {
    zen_core::db::preview(&message.kind, &message.text)
}

fn ticks(status: i32) -> &'static str {
    match status {
        status::FAILED => "  !",
        status::PENDING => "  …",
        status::SENT => "  ✓",
        _ => "  ✓✓",
    }
}

/// A round placeholder with the name's initials, until photos are loaded.
fn avatar(name: &str, group: bool, size: Pixels, theme: &gpui_kit::component::Theme) -> impl IntoElement {
    let initials: String = if group {
        "👥".into()
    } else {
        name.split_whitespace().take(2).filter_map(|word| word.chars().next()).collect::<String>().to_uppercase()
    };
    div()
        .size(size)
        .flex_shrink_0()
        .rounded_full()
        .bg(theme.muted)
        .text_color(theme.muted_foreground)
        .flex()
        .items_center()
        .justify_center()
        .text_sm()
        .font_weight(FontWeight::SEMIBOLD)
        .child(initials)
}

/// "14:05" in the local time zone.
fn clock(ts: i64) -> String {
    if ts <= 0 {
        return String::new();
    }
    let local = ts + local_offset();
    format!("{:02}:{:02}", (local.rem_euclid(86400)) / 3600, (local.rem_euclid(3600)) / 60)
}

fn local_offset() -> i64 {
    // The offset the system reports for now; good enough for a clock label.
    #[cfg(unix)]
    unsafe {
        extern "C" {
            fn time(t: *mut i64) -> i64;
            fn localtime_r(t: *const i64, out: *mut [i64; 9]) -> *mut [i64; 9];
        }
        let now = time(std::ptr::null_mut());
        let mut out = [0i64; 9];
        localtime_r(&now, &mut out);
        // tm_gmtoff is the tenth 4/8-byte field; read it from the struct tail.
        let bytes = &out as *const _ as *const u8;
        *(bytes.add(40) as *const i64)
    }
    #[cfg(not(unix))]
    0
}

impl Render for Zen {
    fn render(&mut self, _: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        match self.state.clone() {
            State::Qr(code) => self.pairing(&code, cx).into_any_element(),
            State::Starting => self.notice("Starting…", cx).into_any_element(),
            State::LoggedOut => self.notice("This device was unlinked. Restart to link it again.", cx).into_any_element(),
            State::Failed(error) => self.notice(&format!("Could not start: {error}"), cx).into_any_element(),
            State::Connecting | State::Connected => {
                let theme = cx.theme();
                h_flex()
                    .size_full()
                    .text_color(theme.foreground)
                    .child(self.sidebar(cx))
                    .child(self.conversation(cx))
                    .into_any_element()
            }
        }
    }
}

fn main() {
    gpui_kit::application().run(|cx| {
        gpui_kit::init(cx);
        let bounds = Bounds::centered(None, size(px(1040.), px(720.)), cx);
        let options = WindowOptions {
            window_bounds: Some(WindowBounds::Windowed(bounds)),
            titlebar: Some(TitlebarOptions { title: Some("WhatsApp Zen".into()), ..Default::default() }),
            ..Default::default()
        };
        gpui_kit::open_window(options, cx, |window, cx| cx.new(|cx| Zen::new(window, cx))).expect("failed to open the window");
        cx.activate(true);
    });
}
