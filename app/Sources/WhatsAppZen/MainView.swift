import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared

    private var pairing: Bool {
        ["starting", "qr", "logged_out"].contains(store.state)
    }

    var body: some View {
        Group {
            if pairing {
                PairingView()
            } else {
                Group {
                    if prefs.compactWindow {
                        CompactLayout()
                    } else {
                        splitLayout
                    }
                }
                .sheet(isPresented: $model.showingNewChat) { NewChatView() }
                .sheet(isPresented: $model.showingSwitcher) { QuickSwitcher() }
                .sheet(isPresented: $model.showingStatus) { StatusSheet() }
            }
        }
        .overlay {
            if let viewer = store.viewer { MediaViewer(state: viewer) }
        }
        .animation(.easeOut(duration: 0.15), value: store.viewer != nil)
        .tint(Theme.accent)
        .sheet(isPresented: $model.showingSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.releaseNotes != nil }, set: { if !$0 { model.releaseNotes = nil } })) {
            ReleaseNotesSheet(notes: model.releaseNotes ?? "")
        }
        .sheet(isPresented: $model.showingSetup) { SetupWizard() }
        .onAppear(perform: welcome)
        .quickLookPreview($store.previewURL)
        .alert(L("Error"), isPresented: Binding(get: { store.errorText != nil && !pairing }, set: { if !$0 { store.errorText = nil } })) {
            Button(L("OK")) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }

    private var splitLayout: some View {
        NavigationSplitView(columnVisibility: $model.sidebarVisibility) {
            Sidebar(newChat: $model.showingNewChat)
                // The system's own sidebar button stays: the toolbar item it
                // brings is what ties the toolbar's split to the list's edge.
                // Without it the list snapped to the width of its buttons.
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 440)
        } detail: {
            Group {
                if let chat = store.selectedChat {
                    if let other = store.chats.first(where: { $0.jid == store.splitChat }), other.jid != chat.jid {
                        SplitChats(chat: chat, other: other)
                    } else {
                        ChatView(chat: chat)
                    }
                } else {
                    // The theme belongs to the whole window, not only to an
                    // open chat. Inside a scroll view because the toolbar is
                    // see-through only above scrolling content; over anything
                    // else it draws an opaque strip across the theme.
                    ScrollView {
                        ContentUnavailableView(L("Select a chat"), systemImage: "bubble.left.and.bubble.right",
                                               description: Text(L("Pick a chat on the left, or start a new one.")))
                            .containerRelativeFrame([.horizontal, .vertical])
                    }
                    .scrollDisabled(true)
                    .scrollEdgeEffectStyle(.soft, for: .all)
                    .background { ChatWallpaper() }
                    .toolbar(removing: .title)
                    .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                    .ignoresSafeArea(.container, edges: .top)
                }
            }
            // A fixed ideal width. Left to itself the conversation asks
            // for the width of its longest message, differently for
            // every chat, and the split view answers each time by
            // resizing the chat list.
            .frame(minWidth: 380, idealWidth: 640, maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                // With the list hidden, recent chats are one click away.
                if model.sidebarHidden {
                    ToolbarItem(placement: .navigation) { RecentChatsMenu() }
                }
            }
        }
    }

    private func welcome() {
        guard !AppStore.isDemo || ProcessInfo.processInfo.environment["WA_SETUP"] != nil else { return }
        if !Prefs.shared.onboarded {
            // A brand-new install gets the setup; someone updating from a
            // version without it already has their preferences.
            let fresh = Prefs.shared.notesShownFor.isEmpty
            Prefs.shared.onboarded = true
            Prefs.shared.notesShownFor = Links.version
            if fresh { model.showingSetup = true }
            return
        }
        // After an update, say what changed, once.
        guard Prefs.shared.notesShownFor != Links.version else { return }
        Prefs.shared.notesShownFor = Links.version
        model.releaseNotes = ReleaseNotes.current()
    }
}

/// One column, as on the phone: the chat list, and a chat opened over it with
/// a way back. For a narrow window kept beside other work.
struct CompactLayout: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        ZStack {
            if let chat = store.selectedChat {
                ChatView(chat: chat)
                    .toolbar {
                        ToolbarItem(placement: .navigation) {
                            Button { store.open(nil) } label: {
                                Label(L("Back to chats"), systemImage: "chevron.left")
                            }
                            .keyboardShortcut("[", modifiers: .command)
                            .help(L("Back to chats") + " (⌘[)")
                        }
                    }
                    .transition(.move(edge: .trailing))
            } else {
                Sidebar(newChat: $model.showingNewChat)
                    .background { ChatWallpaper() }
                    // The window is narrow; its buttons need the title's room.
                    .toolbar(removing: .title)
                    .transition(.move(edge: .leading))
            }
        }
        .animation(.snappy(duration: 0.25), value: store.selected)
    }
}

/// Two conversations side by side: the open chat, and a narrower second one.
struct SplitChats: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    let other: Chat

    var body: some View {
        GeometryReader { geo in
            // The second pane takes about two fifths, but never squeezes the
            // main conversation below a usable width.
            let pane = min(max(geo.size.width * 0.4, 280), max(geo.size.width - 340, 240))
            HStack(spacing: 0) {
                ChatView(chat: chat)
                    .frame(width: geo.size.width - pane - 1)
                    .clipped()
                Divider()
                MenuChatView(chat: other, openApp: { jid in
                    store.splitChat = nil
                    if let jid { store.openChecked(jid) }
                }, back: { store.splitChat = nil }, mode: .split, bubbleWidth: pane - 70)
                    .id(other.jid)
                    .frame(width: pane)
                    .background(.background)
                    .clipped()
            }
        }
        .onAppear {
            // Two chats need room: widen a narrow window once.
            guard let window = NSApp.mainWindow ?? NSApp.keyWindow, window.frame.width < 1150,
                  let screen = window.screen?.visibleFrame else { return }
            var frame = window.frame
            frame.size.width = min(1150, screen.width)
            frame.origin.x = min(frame.origin.x, screen.maxX - frame.width)
            window.setFrame(frame, display: true, animate: false)
        }
    }
}

/// The most recent chats as a menu, for switching while the list is hidden.
struct RecentChatsMenu: View {
    @EnvironmentObject var store: AppStore

    var body: some View {
        Menu {
            ForEach(store.chats.filter { !$0.archived }.prefix(12)) { chat in
                Button {
                    store.openChecked(chat.jid)
                } label: {
                    Text(chat.unread > 0 ? "\(chat.name)  (\(chat.unread))" : chat.name)
                }
            }
        } label: {
            Image(systemName: "bubble.left.and.bubble.right")
        }
        .menuIndicator(.hidden)
        .help(L("Recent chats"))
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel
    @Binding var newChat: Bool
    @State private var query = ""
    @State private var hits: [Message] = []
    @State private var filter = ChatFilter.all
    @State private var listEditor: ListEditorTarget?
    @ObservedObject private var prefs = Prefs.shared

    private var chats: [Chat] {
        let shown = store.chats.filter { chat in
            filter.includes(chat, lists: store.lists) && (query.isEmpty || chat.name.localizedCaseInsensitiveContains(query))
        }
        // Pinned chats stay on top, each group still newest first.
        return shown.filter(\.pinned) + shown.filter { !$0.pinned }
    }

    var body: some View {
        List(selection: Binding(get: { store.selected }, set: { store.openChecked($0) })) {
            ForEach(chats) { chat in
                ChatRow(chat: chat, typing: store.typing[chat.jid] != nil, tick: store.avatarTick,
                        draft: chat.jid == store.selected ? nil : store.drafts[chat.jid], sealed: store.isSealed(chat.jid))
                    .equatable()
                    .tag(chat.jid)
                    .contextMenu {
                        if chat.muted {
                            Button(L("Unmute"), systemImage: "bell") { store.mute(chat, seconds: 0) }
                        } else {
                            Menu(L("Mute"), systemImage: "bell.slash") {
                                Button(L("8 hours")) { store.mute(chat, seconds: 8 * 3600) }
                                Button(L("1 week")) { store.mute(chat, seconds: 7 * 86400) }
                                Button(L("Always")) { store.mute(chat, seconds: -1) }
                            }
                        }
                        if store.selected != nil, store.selected != chat.jid {
                            Button(L("Open Beside Current Chat"), systemImage: "rectangle.split.2x1") {
                                guard !store.isSealed(chat.jid) else { return }
                                store.splitChat = chat.jid
                            }
                        }
                        Button(L("Open in New Window"), systemImage: "macwindow.on.rectangle") {
                            guard !store.isSealed(chat.jid) else { return store.openChecked(chat.jid) }
                            (NSApp.delegate as? AppDelegate)?.openChatWindow(chat, in: store)
                        }
                        Button(store.isLocked(chat.jid) ? L("Remove Lock") : L("Lock"), systemImage: "lock") {
                            store.setLocked(chat.jid, !store.isLocked(chat.jid))
                        }
                        if !chat.archived {
                            Button(chat.pinned ? L("Unpin") : L("Pin"), systemImage: chat.pinned ? "pin.slash" : "pin") {
                                store.pin(chat, !chat.pinned)
                            }
                        }
                        AddToListMenu(chat: chat, editor: $listEditor)
                        Button(chat.archived ? L("Unarchive") : L("Archive"), systemImage: "archivebox") {
                            store.archive(chat, !chat.archived)
                        }
                        if chat.unread > 0 {
                            Button(L("Mark as Read"), systemImage: "checkmark.circle") { store.markRead(chat.jid) }
                        }
                    }
            }
            if !hits.isEmpty {
                Section(L("Messages")) {
                    ForEach(hits) { hit in
                        Button {
                            store.openChecked(hit.chat)
                            store.reveal(hit)
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(store.chats.first { $0.jid == hit.chat }?.name ?? "").fontWeight(.medium).lineLimit(1)
                                    Spacer()
                                    Text(Format.listStamp(hit.ts)).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(store.isSealed(hit.chat) ? "🔒" : hit.plainText).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        // A theme with a chat-list colour of its own replaces the system's material.
        .scrollContentBackground(prefs.themeSidebar >= 0 ? .hidden : .automatic)
        .background {
            if prefs.themeSidebar >= 0 { Color(hex: prefs.themeSidebar).opacity(prefs.windowOpacity).ignoresSafeArea() }
        }
        .searchable(text: $query, placement: .sidebar, prompt: L("Search"))
        .task(id: query) {
            // Search message text too, once typing pauses.
            guard query.count >= 2 else {
                hits = []
                return
            }
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            hits = await store.searchAll(query)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            FilterBar(filter: $filter, editor: $listEditor)
                .padding(.bottom, 8)
        }
        .sheet(item: $listEditor) { target in
            ListEditor(target: target).environmentObject(store)
        }
        .overlay {
            if store.chats.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("Syncing chats…")).foregroundStyle(.secondary).font(.callout)
                }
            } else if chats.isEmpty && hits.isEmpty {
                if case .list(let id) = filter, query.isEmpty, let list = store.lists.first(where: { $0.id == id }) {
                    VStack(spacing: 10) {
                        Text(L("No chats in this list yet")).foregroundStyle(.secondary)
                        Button(L("Add Chats…")) { listEditor = .edit(list) }.buttonStyle(.glass)
                    }
                } else {
                    Text(L("No results")).foregroundStyle(.secondary)
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Only worth the space when something is wrong.
            if store.state != "connected" {
                ConnectionDot(connected: false).padding(.vertical, 8)
            }
        }
        .toolbar {
            ToolbarItemGroup {
                AccountMenu()
                Button(L("Settings"), systemImage: "gearshape") { model.showingSettings = true }
                    .help(L("Settings"))
                Button(L("New Chat"), systemImage: "square.and.pencil") { newChat = true }
                    .help(L("New Chat"))
            }
        }
    }
}

extension ChatRow: Equatable {
    /// Lets the list skip rows whose chat did not change when something
    /// else in the store did.
    static func == (a: ChatRow, b: ChatRow) -> Bool {
        a.chat == b.chat && a.typing == b.typing && a.tick == b.tick && a.draft == b.draft && a.sealed == b.sealed
    }
}

struct ChatRow: View {
    let chat: Chat
    let typing: Bool
    let tick: Int
    /// Unsent text for this chat, shown in place of the last message.
    var draft: String?
    /// Locked and not opened yet: the preview stays hidden.
    var sealed = false
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        HStack(spacing: prefs.compact ? 9 : 11) {
            AvatarView(jid: chat.jid, name: chat.name, size: prefs.compact ? 30 : 44, tick: tick)
            VStack(alignment: .leading, spacing: prefs.compact ? 1 : 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(chat.name).font(.body.weight(chat.unread > 0 ? .semibold : .medium)).lineLimit(1)
                    Spacer(minLength: 4)
                    if chat.muted {
                        Image(systemName: "bell.slash.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                    if chat.pinned {
                        Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Text(Format.listStamp(chat.lastTs))
                        .font(.caption)
                        .foregroundStyle(chat.unread > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                }
                HStack(spacing: 3) {
                    if sealed {
                        Label(L("Locked"), systemImage: "lock.fill").foregroundStyle(.secondary)
                    } else if typing {
                        Text(L("typing…")).foregroundStyle(Theme.accent)
                    } else if let draft, !draft.isEmpty {
                        (Text(L("Draft") + ": ").foregroundStyle(.red) + Text(draft).foregroundStyle(.secondary))
                    } else {
                        if chat.lastFromMe, chat.lastType != "deleted" {
                            StatusTicks(status: chat.lastStatus).font(.caption2).foregroundStyle(.secondary)
                        }
                        Text(chat.preview).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    if chat.unread > 0 { UnreadBadge(count: chat.unread).opacity(chat.muted ? 0.55 : 1) }
                }
                .font(.callout)
                .lineLimit(prefs.compact ? 1 : prefs.previewLines)
            }
        }
        .padding(.vertical, prefs.compact ? 1 : 5)
    }
}

// MARK: Conversation

struct ChatView: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat

    @State private var text = ""
    @State private var highlighted: String?
    @State private var dropping = false
    @State private var farFromBottom = false
    /// Whether the first scroll to the newest message has happened.
    @State private var settled = false
    @State private var forwarding: Message?
    @State private var searching = false
    @State private var showingStarred = false
    /// WA_INFO (demo snapshots) starts with the info sheet open.
    @State private var showingInfo = ProcessInfo.processInfo.environment["WA_INFO"] != nil
    @State private var showingMembers = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.hasMore {
                        Button(L("Older messages")) {
                            let anchor = store.messages.first?.id
                            store.loadOlder {
                                // Stay on the message that was first, with the
                                // older ones now above it. Repeated because the
                                // new rows only get their real heights once they
                                // are laid out, which moves everything below.
                                guard let anchor else { return }
                                for delay in [0, 0.08, 0.3, 0.7] {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo(anchor, anchor: .top) }
                                }
                            }
                        }
                        .buttonStyle(.glass)
                        .padding(8)
                    } else if !store.messages.isEmpty {
                        // Nothing older on this Mac; the phone may have more.
                        Button(store.askedPhone ? L("Asking your phone…") : L("Get older messages from your phone")) {
                            store.askedPhone = true
                            store.requestHistory(of: chat.jid)
                            // No answer (phone offline, or nothing older): offer it again.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { store.askedPhone = false }
                        }
                        .buttonStyle(.glass)
                        .disabled(store.askedPhone)
                        .padding(8)
                    } else if store.loaded {
                        NoMessagesNote().padding(.vertical, 40)
                    }
                    MessageList(messages: store.messages, isGroup: chat.isGroup, highlighted: highlighted, unreadFrom: store.unreadFrom, actions: MessageActions(
                        reply: { store.editing = nil; store.replyTo = $0 },
                        edit: { store.clearDraftState(); store.editing = $0; text = $0.text },
                        forward: { forwarding = $0 },
                        jump: { jump(to: $0, proxy: proxy) },
                        preview: { store.previewURL = URL(fileURLWithPath: $0) },
                        view: { store.view($0) }
                    ))
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // Rows must not animate their own re-layout while the sidebar
                // slides; that shows up as the whole conversation flickering.
                .transaction { $0.animation = nil }
            }
            .id(chat.jid)
            .defaultScrollAnchor(.bottom)
            .scrollEdgeEffectStyle(.soft, for: .all)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentSize.height - geo.contentOffset.y - geo.containerSize.height > 260
            } action: { _, far in
                farFromBottom = far
            }
            .onChange(of: store.jumpTarget) { _, target in
                guard let target else { return }
                jump(to: target, proxy: proxy)
                store.jumpTarget = nil
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let pinned = store.pinnedMessages.first {
                    Button { store.reveal(pinned) } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "pin.fill").foregroundStyle(Theme.accent)
                            Text(pinned.plainText).lineLimit(1)
                            Spacer(minLength: 0)
                            if store.pinnedMessages.count > 1 {
                                Text("+\(store.pinnedMessages.count - 1)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 32)
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Capsule())
                    .padding(.horizontal, 14)
                    .padding(.top, 6)
                    .help(L("Go to pinned message"))
                }
            }
            .onChange(of: store.messages.last?.id) { _, last in
                guard last != nil else { return }
                if !settled {
                    // First load of this chat: go to the newest message. Lazy
                    // rows only learn their real height once on screen, so one
                    // jump lands short; repeat as the layout settles.
                    settled = true
                    for delay in [0, 0.08, 0.3, 0.7] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                    return
                }
                // Don't yank the view down while the user is reading older messages.
                guard !farFromBottom || store.messages.last?.fromMe == true else { return }
                proxy.scrollTo("bottom", anchor: .bottom)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .trailing, spacing: 8) {
                    if farFromBottom {
                        Button {
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Image(systemName: "chevron.down").frame(width: 18, height: 22)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .help(L("Scroll to bottom"))
                        .padding(.trailing, 16)
                        .transition(.scale.combined(with: .opacity))
                    }
                    ComposerBar(text: $text, reply: $store.replyTo, editing: $store.editing, image: $store.pendingImage,
                                file: $store.pendingFile, chatName: chat.name, panelChat: chat, members: store.members,
                                moreCount: store.pendingMore.count, onAttach: attach(_:),
                                onEditLast: {
                                    guard let last = store.messages.last(where: { $0.fromMe && $0.type == "text" && !$0.deleted }),
                                          Date().timeIntervalSince(last.date) < 15 * 60 else { return }
                                    store.clearDraftState()
                                    store.editing = last
                                    text = last.text
                                },
                                onVoice: { url, seconds in
                                    store.send(voice: url, seconds: seconds, to: chat.jid, replyTo: store.replyTo?.id)
                                    store.replyTo = nil
                                },
                                onTyping: { store.userIsTyping(in: chat.jid) }, onSend: send)
                }
            }
        }
        .background { ChatWallpaper() }
        .navigationTitle(chat.name)
        .toolbar(removing: .title)
        .toolbar {
            // The photo and name open the chat's info, as people expect.
            ToolbarItem(placement: .navigation) {
                Button { showingInfo = true } label: {
                    HStack(spacing: 9) {
                        AvatarView(jid: chat.jid, name: chat.name, size: 30, tick: store.avatarTick)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(chat.name).font(.headline).lineLimit(1)
                            let subtitle = store.subtitle(for: chat)
                            if !subtitle.isEmpty {
                                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, 6)
                .help(L("Chat info, media and settings"))
            }
            // With the title gone, keep the actions at the trailing edge.
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                Button(L("Search in Chat"), systemImage: "magnifyingglass") { searching = true }
                    .popover(isPresented: $searching, arrowEdge: .bottom) {
                        ChatSearchView(chat: chat) { searching = false }.environmentObject(store)
                    }
                    .keyboardShortcut("f")
                    .help(L("Search in Chat"))
                Button(L("Starred Messages"), systemImage: "star") { showingStarred = true }
                    .popover(isPresented: $showingStarred, arrowEdge: .bottom) {
                        StarredView(chat: chat) { showingStarred = false }.environmentObject(store)
                    }
                    .help(L("Starred Messages"))
                // In the narrow window the photo and name do this, and room is short.
                if !Prefs.shared.compactWindow {
                    Button(L("Info"), systemImage: "info.circle") { showingInfo = true }
                        .keyboardShortcut("i")
                        .help(L("Chat info, media and settings"))
                }
            }
        }
        .sheet(item: $forwarding) { ForwardSheet(message: $0) }
        .sheet(isPresented: $showingInfo) { ChatInfoSheet(chat: chat) { showingMembers = true } }
        .sheet(isPresented: $showingMembers) { GroupInfoSheet(chat: chat) }
        .sheet(isPresented: Binding(get: { !store.pendingPhotos.isEmpty }, set: { if !$0 { store.pendingPhotos = [] } })) {
            PhotoSendSheet(chat: chat)
        }
        .onAppear { text = store.drafts[chat.jid] ?? "" }
        // The view itself is kept when the chat changes: replacing it made
        // the split view lay its columns out again on every click, which
        // showed as the chat list shrinking and growing.
        .onChange(of: chat.jid) { _, jid in
            text = store.drafts[jid] ?? ""
            settled = false
            farFromBottom = false
            highlighted = nil
        }
        .onChange(of: text) { _, new in
            if store.editing == nil { store.setDraft(new, for: chat.jid) }
        }
        .onExitCommand {
            // Esc backs out of a reply, an edit or a staged attachment.
            if store.editing != nil { text = "" }
            store.clearDraftState()
        }
        .overlay {
            if dropping {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2.5, dash: [9]))
                    .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .overlay(Label(L("Drop to send"), systemImage: "arrow.down.doc").font(.title2.weight(.medium)))
                    .padding(12)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropping, perform: handleDrop)
    }

    private func send() {
        store.submit(text: text, to: chat.jid, reply: store.replyTo, editing: store.editing,
                     image: store.pendingImage, file: store.pendingFile)
        // The files queued behind the staged one follow it.
        let more = store.pendingMore
        Task { @MainActor in
            for url in more { await store.sendNow(url, to: chat.jid) }
        }
        text = ""
        store.setDraft("", for: chat.jid)
        store.clearDraftState()
    }

    private func attach(_ kind: AttachKind) {
        switch kind {
        case .media: pickFile(mediaOnly: true)
        case .file: pickFile(mediaOnly: false)
        case .location: store.sendLocation(to: chat.jid)
        case .poll, .contact, .sticker: break // handled inside the + panel
        }
    }

    private func jump(to id: String, proxy: ScrollViewProxy) {
        guard store.messages.contains(where: { $0.id == id }) else { return }
        withAnimation { proxy.scrollTo(id, anchor: .center) }
        highlighted = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if highlighted == id { withAnimation { highlighted = nil } }
        }
    }

    private func pickFile(mediaOnly: Bool) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if mediaOnly { panel.allowedContentTypes = [.image, .movie] }
        if panel.runModal() == .OK { store.attach(panel.urls) }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        Task { @MainActor in
            var urls: [URL] = []
            for item in providers {
                if let url = await Attachments.fileURL(from: item) { urls.append(url) }
            }
            if !urls.isEmpty {
                store.attach(urls)
            } else {
                Images.fromDrop(providers) { images in
                    if !images.isEmpty { store.pendingPhotos = images }
                }
            }
        }
        return true
    }
}

extension AppStore {
    /// Sends whatever the composer holds: an edit, a photo, a file or text.
    func submit(text: String, to chat: String, reply: Message?, editing: Message?, image: PendingImage?, file: PendingFile?) {
        if let editing {
            edit(editing, text: text)
        } else if let image {
            send(image: image, caption: text, to: chat, replyTo: reply?.id)
        } else if let file {
            send(file: file, caption: text, to: chat, replyTo: reply?.id)
        } else {
            send(text: text, to: chat, replyTo: reply?.id)
        }
    }
}

/// What sits behind a conversation: nothing, a wash of the accent colour, a
/// gradient, or a picture of the user's choosing.
struct ChatWallpaper: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        ZStack {
            // Less than solid: the desktop shows through, blurred.
            if prefs.windowOpacity < 0.995 { BehindWindowBlur() }
            (prefs.themeBase >= 0 ? Color(hex: prefs.themeBase) : Color(nsColor: .textBackgroundColor))
                .opacity(prefs.windowOpacity)
            switch prefs.wallpaper {
            case "tint":
                Theme.accent.opacity(0.07)
            case "gradient":
                LinearGradient(colors: [Theme.accent.opacity(0.16), Theme.accent.opacity(0.03)], startPoint: .topLeading, endPoint: .bottomTrailing)
            case "theme":
                // The theme picker's colours: one colour fading out, or two blending.
                let first = Color(hex: prefs.customAccent)
                let second = prefs.themeColor2 >= 0 ? Color(hex: prefs.themeColor2) : first.opacity(0.15)
                let third = prefs.themeColor2 >= 0 && prefs.themeColor3 >= 0 ? [Color(hex: prefs.themeColor3)] : []
                LinearGradient(colors: [first, second] + third, startPoint: .topLeading, endPoint: .bottomTrailing)
                    .opacity(prefs.themeIntensity)
            case "image":
                if let picture = prefs.wallpaperPicture() {
                    GeometryReader { geo in
                        Image(nsImage: picture).resizable().scaledToFill()
                            .frame(width: geo.size.width, height: geo.size.height).clipped()
                    }
                    // Faded toward the window colour so messages stay readable.
                    Color(nsColor: .textBackgroundColor).opacity(prefs.wallpaperDim)
                }
            default:
                EmptyView()
            }
        }
        .ignoresSafeArea()
    }
}

/// The desktop behind the window, blurred, for a see-through background.
struct BehindWindowBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.material = .underWindowBackground
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

/// The + panel. Everything opens here, anchored to the + button: the grid of
/// choices first, then stickers, emoji, a poll form or the contact list as
/// pages of the same panel, each with a way back.
struct AttachPanel: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat?
    /// Adds text (an emoji) to the message being written.
    let insert: (String) -> Void
    let close: () -> Void
    /// Choices that leave the panel: file pickers and location.
    let pick: (AttachKind) -> Void

    private enum Page { case menu, stickers, emoji, poll, contact }
    @State private var page = Page.menu

    var body: some View {
        VStack(spacing: 0) {
            if page != .menu {
                HStack {
                    Button { page = .menu } label: { Label(L("Back"), systemImage: "chevron.left") }
                        .buttonStyle(.borderless)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
            }
            switch page {
            case .menu:
                AttachGrid { kind in
                    switch kind {
                    case .sticker?: page = .stickers
                    case .poll?: page = .poll
                    case .contact?: page = .contact
                    case nil: page = .emoji
                    case let other?: pick(other)
                    }
                }
            case .stickers:
                if let chat { StickerPicker(chat: chat, close: close) }
            case .emoji:
                EmojiGrid(insert: insert)
            case .poll:
                if let chat { PollComposer(chat: chat) }
            case .contact:
                if let chat {
                    ContactPicker(title: L("Send Contact"), embedded: true) { contact in
                        store.sendContact(contact, to: chat.jid)
                        close()
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.18), value: page)
    }
}

/// A compact emoji picker: tap to add to the message; the panel stays open.
struct EmojiGrid: View {
    let insert: (String) -> Void

    private static let groups: [(String, String)] = [
        ("face.smiling", "😀 😃 😄 😁 😆 😅 🤣 😂 🙂 🙃 😉 😊 😇 🥰 😍 🤩 😘 😗 😚 😋 😛 😜 🤪 😝 🤑 🤗 🤭 🤫 🤔 🤐 🤨 😐 😑 😶 😏 😒 🙄 😬 😌 😔 😪 🤤 😴 😷 🤒 🤕 🤢 🤮 🥵 🥶 🥴 😵 🤯 🤠 🥳 😎 🤓 🧐 😕 😟 🙁 😮 😯 😲 😳 🥺 😦 😧 😨 😰 😥 😢 😭 😱 😖 😣 😞 😓 😩 😫 🥱 😤 😡 😠 🤬 😈 👿 💀 💩 🤡 👻 👽 🤖"),
        ("hand.thumbsup", "👍 👎 👌 🤌 🤏 ✌️ 🤞 🤟 🤘 🤙 👈 👉 👆 👇 ☝️ ✋ 🤚 🖐 🖖 👋 🤝 🙏 ✍️ 💪 👏 🙌 👐 🤲 🫶 🫡 🤷 🤦 🙋 🙅 🙆 💁 🧑‍💻 👀 🧠 🫂"),
        ("heart", "❤️ 🧡 💛 💚 💙 💜 🖤 🤍 🤎 💔 ❣️ 💕 💞 💓 💗 💖 💘 💝 💯 💢 💥 💫 💦 💨 🔥 ⭐️ 🌟 ✨ ⚡️ 🎉 🎊 🎁 🎂 🏆 🥇 🎯"),
        ("leaf", "🐶 🐱 🐭 🐹 🐰 🦊 🐻 🐼 🐨 🐯 🦁 🐮 🐷 🐸 🐵 🐔 🐧 🐦 🦄 🐝 🦋 🐢 🐙 🐬 🌸 🌹 🌻 🌲 🌴 🍀 🌈 ☀️ 🌙 ☁️ ❄️ 🌊"),
        ("fork.knife", "🍏 🍎 🍊 🍋 🍌 🍉 🍇 🍓 🍒 🍑 🥑 🍅 🌽 🥕 🍞 🧀 🍳 🥓 🍔 🍟 🍕 🌭 🌮 🍣 🍜 🍝 🍦 🍩 🍪 🍫 🍿 ☕️ 🍵 🥤 🍺 🍷"),
        ("car", "⚽️ 🏀 🏈 🎾 🏐 🎮 🎲 🎸 🎧 🎬 📷 💻 📱 ⌚️ 💡 🔑 🔒 💰 💳 ✉️ 📌 📎 ✂️ 🚗 🚕 🚌 🚲 ✈️ 🚀 🏠 🏢 🏖 ⏰ 📅 ✅ ❌ ❓ ❗️ ⚠️ 🚫"),
    ]

    @State private var group = 0

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 4) {
                ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, entry in
                    Button { group = index } label: {
                        Image(systemName: entry.0).font(.system(size: 13))
                            .foregroundStyle(group == index ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.secondary))
                            .frame(width: 34, height: 24)
                            .background(group == index ? AnyShapeStyle(Theme.accent.opacity(0.15)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button { NSApp.orderFrontCharacterPalette(nil) } label: { Image(systemName: "ellipsis.circle") }
                    .buttonStyle(.borderless)
                    .help(L("Emoji & Symbols"))
            }
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 2), count: 8), spacing: 2) {
                    ForEach(Self.groups[group].1.split(separator: " ").map(String.init), id: \.self) { emoji in
                        Button { insert(emoji) } label: {
                            Text(emoji).font(.system(size: 20)).frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 170)
        }
        .padding(10)
        .frame(width: 280)
    }
}

/// The first page of the + panel: everything that can be added, as a grid of
/// coloured tiles. A nil choice stands for emoji.
struct AttachGrid: View {
    let pick: (AttachKind?) -> Void

    private static let items: [(kind: AttachKind?, title: String, icon: String, color: Color)] = [
        (.media, "Photo", "photo.fill.on.rectangle.fill", Color(light: 0x7C5CE0, dark: 0x9B7DF2)),
        (.file, "File", "doc.fill", Color(light: 0x2F80ED, dark: 0x5A9DF5)),
        (.sticker, "Sticker", "face.smiling.inverse", Color(light: 0xF2994A, dark: 0xF5AD6E)),
        (.poll, "Poll", "chart.bar.fill", Color(light: 0xEB5757, dark: 0xF07C7C)),
        (.contact, "Contact", "person.crop.circle.fill", Color(light: 0x1DAA61, dark: 0x25C46B)),
        (.location, "Location", "location.fill", Color(light: 0x00A3A3, dark: 0x2CC7C7)),
        (nil, "Emoji", "character.bubble.fill", Color(light: 0xE0A100, dark: 0xF2BE3A)),
    ]

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.fixed(58), spacing: 2), count: 4), spacing: 8) {
            ForEach(Self.items, id: \.title) { item in
                AttachTile(title: L(item.title), icon: item.icon, color: item.color) { pick(item.kind) }
            }
        }
        .padding(10)
    }
}

private struct AttachTile: View {
    let title: String
    let icon: String
    let color: Color
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(color.gradient, in: Circle())
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(width: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.15), value: hovering)
    }
}

/// What the + menu of the composer can add.
enum AttachKind {
    case media, file, poll, contact, sticker, location
}

/// The floating message field, shared by the main window and the menu bar.
struct ComposerBar: View {
    @Binding var text: String
    @Binding var reply: Message?
    @Binding var editing: Message?
    @Binding var image: PendingImage?
    @Binding var file: PendingFile?
    let chatName: String
    /// The chat the + panel's own pages (stickers, poll, contact) send to.
    var panelChat: Chat?
    /// Opens a file picker; the flag limits it to photos and videos.
    /// People who can be @-mentioned (the open group's members).
    var members: [GroupMember] = []
    /// How many more files are queued behind the staged attachment.
    var moreCount = 0
    var onAttach: ((AttachKind) -> Void)?
    /// ↑ in an empty field: edit the last message sent.
    var onEditLast: (() -> Void)?
    /// Sends a finished voice recording; nil hides the microphone.
    var onVoice: ((_ url: URL, _ seconds: Int) -> Void)?

    /// Every control in the bottom bar, here and in the sidebar, is this tall.
    static let height: CGFloat = 36
    var onTyping: () -> Void = {}
    let onSend: () -> Void

    /// Bumped to put the caret in the message field.
    @State private var focusRequest = 0
    @State private var fieldHeight: CGFloat = 16
    /// WA_ATTACH (demo snapshots) starts with the + panel open.
    @State private var attaching = ProcessInfo.processInfo.environment["WA_ATTACH"] != nil
    @StateObject private var recorder = VoiceRecorder()

    /// With nothing typed or attached, the send button records instead.
    private var offersVoice: Bool {
        onVoice != nil && !canSend && editing == nil && !recorder.recording
    }

    private var canSend: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (editing == nil && (image != nil || file != nil))
    }

    private var placeholder: String {
        if editing != nil { return L("Edit message") }
        return image != nil || file != nil ? L("Add a caption") : L("Message")
    }

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(alignment: .bottom, spacing: 8) {
                if let onAttach {
                    Button { attaching.toggle() } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                            .rotationEffect(.degrees(attaching ? 45 : 0))
                            .frame(width: Self.height, height: Self.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .animation(.snappy(duration: 0.2), value: attaching)
                    .help(L("Attach a photo, video or file"))
                    .popover(isPresented: $attaching, arrowEdge: .top) {
                        AttachPanel(chat: panelChat, insert: { text += $0 }, close: { attaching = false }) { kind in
                            attaching = false
                            onAttach(kind)
                        }
                    }
                }
                if recorder.recording {
                    Button { recorder.cancel() } label: {
                        Image(systemName: "trash").font(.system(size: 14, weight: .medium)).foregroundStyle(.red)
                            .frame(width: Self.height, height: Self.height)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help(L("Discard recording"))
                    HStack(spacing: 8) {
                        Circle().fill(.red).frame(width: 9, height: 9)
                        Text(L("Recording") + "  \(recorder.seconds / 60):\(String(format: "%02d", recorder.seconds % 60))")
                            .monospacedDigit()
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: Self.height)
                    .glassEffect(.regular, in: Capsule())
                } else {
                VStack(alignment: .leading, spacing: 0) {
                    context
                    mentionSuggestions
                    if moreCount > 0 {
                        Text(L("+%lld more files", moreCount)).font(.caption).foregroundStyle(.secondary)
                            .padding(.horizontal, 14).padding(.top, 6)
                    }
                    if let error = recorder.error {
                        Text(error).font(.caption).foregroundStyle(.red).padding(.horizontal, 14).padding(.top, 8)
                    }
                    ComposerTextView(
                        text: $text, placeholder: placeholder, height: $fieldHeight, focusRequest: focusRequest,
                        onSubmit: { if canSend { submit() } },
                        // Esc drops the reply or the edit being written.
                        onEscape: {
                            if editing != nil {
                                editing = nil
                                text = ""
                            } else if reply != nil {
                                reply = nil
                            } else {
                                return false
                            }
                            return true
                        },
                        onUpArrow: {
                            guard text.isEmpty, editing == nil, let onEditLast else { return false }
                            onEditLast()
                            return true
                        })
                        .frame(height: fieldHeight)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .frame(minHeight: Self.height)
                        .onChange(of: text) { old, new in
                            if !new.isEmpty { onTyping() }
                            // ":)" then a space becomes 🙂. Only when a character
                            // was just added, so deleting the space does not redo it.
                            if new.count == old.count + 1, let converted = Emoticons.convertLastWord(new) { text = converted }
                        }
                }
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
                }
                Button(action: primaryAction) {
                    Image(systemName: offersVoice ? "mic.fill" : (editing != nil ? "checkmark" : "arrow.up"))
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canSend || recorder.recording ? AnyShapeStyle(.white) : AnyShapeStyle(offersVoice ? .primary : .secondary))
                        .frame(width: Self.height, height: Self.height)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(canSend || recorder.recording ? .regular.tint(Theme.accent).interactive() : .regular.interactive(), in: Circle())
                .disabled(!canSend && !offersVoice && !recorder.recording)
                .help(offersVoice ? L("Record a voice message") : (editing != nil ? L("Save") : L("Send")))
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .padding(.top, 4)
        .onAppear { focusSoon() }
        // The composer outlives a change of chat, so it has to ask for the
        // keyboard again each time; the click that picked the chat left the
        // focus in the chat list.
        .onChange(of: panelChat?.jid) { _, _ in focusSoon() }
        .onChange(of: reply?.id) { _, _ in focusRequest += 1 }
        .onChange(of: editing?.id) { _, _ in focusRequest += 1 }
        .onChange(of: image?.id) { _, _ in focusRequest += 1 }
        .onChange(of: file?.id) { _, _ in focusRequest += 1 }
    }

    /// The name being typed after an "@" at the end of the text, if any.
    private var mentionQuery: String? {
        guard !members.isEmpty, let at = text.lastIndex(of: "@") else { return nil }
        let typed = text[text.index(after: at)...]
        let startsWord = at == text.startIndex || text[text.index(before: at)].isWhitespace
        guard startsWord, !typed.contains(where: \.isNewline), typed.count < 24 else { return nil }
        return String(typed)
    }

    @ViewBuilder private var mentionSuggestions: some View {
        if let query = mentionQuery {
            let matches = members.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) }.prefix(5)
            if !matches.isEmpty, !matches.contains(where: { $0.name == query }) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(matches)) { member in
                        Button {
                            if let at = text.lastIndex(of: "@") {
                                text = String(text[..<at]) + "@\(member.name) "
                            }
                        } label: {
                            HStack(spacing: 8) {
                                AvatarView(jid: member.jid, name: member.name, size: 20)
                                Text(member.name).lineLimit(1)
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 6)
            }
        }
    }

    private func primaryAction() {
        if recorder.recording {
            if let clip = recorder.finish() { onVoice?(clip.url, clip.seconds) }
        } else if offersVoice {
            recorder.start()
        } else {
            submit()
        }
    }

    /// Takes the keyboard once the click that led here has finished.
    private func focusSoon() {
        focusRequest += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusRequest += 1 }
    }

    /// Sends, converting an emoticon that was typed last and never followed by a space.
    private func submit() {
        if editing == nil || !text.isEmpty { text = MessageFormat.normalized(Emoticons.convert(text)) }
        onSend()
    }

    /// What the message being written refers to or carries.
    @ViewBuilder private var context: some View {
        if let editing {
            contextRow {
                Label(L("Edit message"), systemImage: "pencil").font(.callout.weight(.medium)).foregroundStyle(Theme.accent)
                Spacer()
            } onClose: {
                self.editing = nil
                text = ""
            }
        } else if let reply {
            contextRow {
                QuoteView(sender: reply.fromMe ? L("You") : (reply.senderName.isEmpty ? chatName : reply.senderName),
                          text: reply.plainText)
            } onClose: {
                self.reply = nil
            }
        }
        if let image {
            contextRow {
                Image(nsImage: image.preview).resizable().scaledToFit()
                    .frame(maxHeight: 130)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Spacer()
            } onClose: {
                self.image = nil
            }
        } else if let file {
            contextRow {
                if let preview = file.preview {
                    Image(nsImage: preview).resizable().scaledToFill()
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                } else {
                    Image(systemName: "doc.fill").font(.title2).foregroundStyle(Theme.accent).frame(width: 44, height: 44)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.name).lineLimit(1).truncationMode(.middle)
                    Text(file.sizeText).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            } onClose: {
                self.file = nil
            }
        }
    }

    private func contextRow(@ViewBuilder _ content: () -> some View, onClose: @escaping () -> Void) -> some View {
        HStack(alignment: .center, spacing: 8) {
            content()
            Button(action: onClose) { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                .buttonStyle(.plain)
                .help(L("Remove"))
        }
        .padding(.horizontal, 10)
        .padding(.top, 9)
    }
}

/// Switches between linked accounts and adds new ones.
struct AccountMenu: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        Menu {
            ForEach(model.accounts) { account in
                Button {
                    model.activate(account.id)
                } label: {
                    let unread = account.totalUnread > 0 ? "  (\(account.totalUnread))" : ""
                    Label(account.label + unread, systemImage: account.icon)
                }
                .disabled(account.id == store.id)
            }
            Divider()
            Button(L("Add Account…"), systemImage: "plus") { model.addAccount() }
        } label: {
            // Just the account's icon; a dot marks a connection in progress.
            Image(systemName: store.icon)
                .overlay(alignment: .bottomTrailing) {
                    if store.state != "connected" {
                        Circle().fill(.orange).frame(width: 6, height: 6).offset(x: 2, y: 2)
                    }
                }
        }
        .menuIndicator(.hidden)
        .help(store.label)
    }
}

// MARK: New chat

struct NewChatView: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var contacts: [Contact] = []
    @State private var query = ""
    @State private var busy = false

    private var matches: [Contact] {
        query.isEmpty ? contacts : contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    /// The query read as a phone number, when it plausibly is one.
    private var phone: String? {
        let digits = query.filter(\.isNumber)
        let allowed = query.allSatisfy { $0.isNumber || " +-()".contains($0) }
        return allowed && digits.count >= 7 ? digits : nil
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("New Chat")).font(.headline)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            TextField(L("Contact name, or phone number with country code"), text: $query)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            List {
                if let phone {
                    Button { start(phone: phone) } label: {
                        Label(L("Message +%@", phone), systemImage: "phone.badge.plus")
                    }
                    .buttonStyle(.plain)
                }
                ForEach(matches) { contact in
                    Button { start(jid: contact.jid) } label: {
                        HStack(spacing: 10) {
                            AvatarView(jid: contact.jid, name: contact.name, size: 30)
                            Text(contact.name)
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .overlay {
                if matches.isEmpty && phone == nil {
                    Text(contacts.isEmpty ? L("Loading contacts…") : L("No contacts found")).foregroundStyle(.secondary)
                }
            }
        }
        .frame(width: 400, height: 500)
        .disabled(busy)
        .task { contacts = await store.contacts() }
    }

    private func start(jid: String = "", phone: String = "") {
        busy = true
        Task { @MainActor in
            let ok = await store.startChat(jid: jid, phone: phone)
            busy = false
            if ok { dismiss() }
        }
    }
}
