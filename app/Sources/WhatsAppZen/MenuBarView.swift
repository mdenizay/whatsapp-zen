import SwiftUI

/// The menu bar popover: a chat list that pushes into a conversation, with a
/// back button to return.
struct MenuBarView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel
    /// Opens the main window, optionally on a chat.
    let openApp: (String?) -> Void

    /// WA_MENU_CHAT (demo snapshots) starts inside the first conversation.
    @State private var opened: String? = ProcessInfo.processInfo.environment["WA_MENU_CHAT"] != nil ? Demo.chats.first?.jid : nil

    private var openedChat: Chat? { store.chats.first { $0.jid == opened } }

    var body: some View {
        ZStack {
            if let chat = openedChat {
                MenuChatView(chat: chat, openApp: openApp) { opened = nil }
                    .id(chat.jid)
                    .transition(.move(edge: .trailing))
            } else {
                list.transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: opened)
        .frame(width: 380, height: 560)
        .clipped()
        .tint(Theme.accent)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("Chats")).font(.title3.weight(.semibold))
                if model.totalUnread > 0 { UnreadBadge(count: model.totalUnread) }
                Spacer()
                if model.accounts.count > 1 { AccountMenu() }
                GlassIconButton(icon: "macwindow", help: L("Open the app")) { openApp(nil) }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if store.state == "qr" || store.state == "logged_out" {
                notice(L("Open the app and scan the QR code to connect."))
            } else if store.chats.isEmpty {
                notice(L("No chats yet."))
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.chats.filter { !$0.archived }.prefix(60)) { chat in
                            MenuChatRow(chat: chat, typing: store.typing[chat.jid] != nil, tick: store.avatarTick) {
                                if store.isSealed(chat.jid) {
                                    Auth.unlock(reason: L("Unlock this chat")) { ok in
                                        guard ok else { return }
                                        store.unlockedChats.insert(chat.jid)
                                        opened = chat.jid
                                    }
                                } else {
                                    opened = chat.jid
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.bottom, 8)
                }
            }
            // Only worth the space when something is wrong.
            if store.state == "connecting" {
                ConnectionDot(connected: false).padding(.vertical, 6)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }
}

struct MenuChatRow: View {
    let chat: Chat
    let typing: Bool
    let tick: Int
    let open: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                AvatarView(jid: chat.jid, name: chat.name, size: 38, tick: tick)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(chat.name).fontWeight(chat.unread > 0 ? .semibold : .medium).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(Format.listStamp(chat.lastTs)).font(.caption)
                            .foregroundStyle(chat.unread > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                    }
                    HStack(spacing: 3) {
                        if typing {
                            Text(L("typing…")).foregroundStyle(Theme.accent)
                        } else {
                            if chat.lastFromMe, chat.lastType != "deleted" {
                                StatusTicks(status: chat.lastStatus).font(.caption2).foregroundStyle(.secondary)
                            }
                            Text(chat.preview).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        if chat.unread > 0 { UnreadBadge(count: chat.unread) }
                    }
                    .font(.callout)
                    .lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(hovering ? AnyShapeStyle(.primary.opacity(0.07)) : AnyShapeStyle(.clear),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// One conversation inside the popover.
struct MenuChatView: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    let openApp: (String?) -> Void
    let back: () -> Void
    /// Where this conversation is shown.
    enum Mode { case panel, window, split }
    var mode = Mode.panel
    /// Widest a bubble may be; set by a pane that knows its own width.
    var bubbleWidth: CGFloat?
    private var detached: Bool { mode != .panel }

    @State private var messages: [Message] = []
    @State private var text = ""
    @State private var reply: Message?
    @State private var editing: Message?

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        MessageList(messages: messages, isGroup: chat.isGroup, maxWidth: bubbleWidth ?? (detached ? 360 : 250), actions: MessageActions(
                            reply: { editing = nil; reply = $0 },
                            edit: { reply = nil; editing = $0; text = $0.text },
                            // Media opens in the main window's viewer.
                            view: { item in
                                openApp(chat.jid)
                                store.view(item, among: messages)
                            }
                        ))
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onChange(of: messages.last?.id) { _, last in
                    guard last != nil else { return }
                    for delay in [0, 0.1, 0.4] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    ComposerBar(text: $text, reply: $reply, editing: $editing, image: .constant(nil), file: .constant(nil),
                                chatName: chat.name, onAttach: nil, onTyping: { store.userIsTyping(in: chat.jid) }, onSend: send)
                }
            }
        }
        .task {
            await load()
            store.watchPresence(of: chat.jid)
            store.markRead(chat.jid)
        }
        .onReceive(store.messagesChanged) { changed in
            guard changed.isEmpty || changed == chat.jid else { return }
            Task {
                await load()
                // The conversation is on screen, so what arrives is read.
                store.markRead(chat.jid)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            if mode == .window {
                // Room for the window's close and minimise buttons.
                Color.clear.frame(width: 58, height: 1)
            } else if mode == .split {
                GlassIconButton(icon: "xmark", help: L("Close"), action: back)
            } else {
                GlassIconButton(icon: "chevron.left", help: L("Back to chats"), action: back)
                    .keyboardShortcut(.cancelAction)
            }
            AvatarView(jid: chat.jid, name: chat.name, size: 32, tick: store.avatarTick)
            VStack(alignment: .leading, spacing: 0) {
                Text(chat.name).fontWeight(.semibold).lineLimit(1)
                let subtitle = store.subtitle(for: chat)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption)
                        .foregroundStyle(store.typing[chat.jid] != nil || store.presence[chat.jid]?.online == true
                            ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            GlassIconButton(icon: "arrow.up.forward.app", help: L("Open chat in the app")) { openApp(chat.jid) }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @MainActor private func load() async {
        if let list = await store.fetchMessages(chat: chat.jid, limit: 40), list != messages { messages = list }
    }

    private func send() {
        store.submit(text: text, to: chat.jid, reply: reply, editing: editing, image: nil, file: nil)
        text = ""
        reply = nil
        editing = nil
    }
}
