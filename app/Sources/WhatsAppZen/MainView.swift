import AppKit
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel

    private var pairing: Bool {
        ["starting", "qr", "logged_out"].contains(store.state)
    }

    var body: some View {
        Group {
            if pairing {
                PairingView()
            } else {
                NavigationSplitView {
                    Sidebar(newChat: $model.showingNewChat).navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
                } detail: {
                    if let chat = store.selectedChat {
                        ChatView(chat: chat).id(chat.jid)
                    } else {
                        ContentUnavailableView(L("Select a chat"), systemImage: "bubble.left.and.bubble.right",
                                               description: Text(L("Pick a chat on the left, or start a new one.")))
                    }
                }
                .sheet(isPresented: $model.showingNewChat) { NewChatView() }
                .sheet(isPresented: $model.showingSwitcher) { QuickSwitcher() }
                .sheet(isPresented: $model.showingStatus) { StatusSheet() }
            }
        }
        .tint(Theme.accent)
        .sheet(isPresented: $model.showingSettings) { SettingsView().environmentObject(model) }
        .sheet(isPresented: Binding(get: { model.releaseNotes != nil }, set: { if !$0 { model.releaseNotes = nil } })) {
            ReleaseNotesSheet(notes: model.releaseNotes ?? "")
        }
        .onAppear {
            // After an update, say what changed, once.
            guard !AppStore.isDemo, Prefs.shared.notesShownFor != Links.version else { return }
            Prefs.shared.notesShownFor = Links.version
            model.releaseNotes = ReleaseNotes.current()
        }
        .quickLookPreview($store.previewURL)
        .alert(L("Error"), isPresented: Binding(get: { store.errorText != nil && !pairing }, set: { if !$0 { store.errorText = nil } })) {
            Button(L("OK")) { store.errorText = nil }
        } message: {
            Text(store.errorText ?? "")
        }
    }
}

// MARK: Sidebar

private enum ChatFilter: String, CaseIterable {
    case all, unread, groups, archived

    var title: String {
        switch self {
        case .all: return L("All")
        case .unread: return L("Unread")
        case .groups: return L("Groups")
        case .archived: return L("Archived")
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel
    @Binding var newChat: Bool
    @State private var query = ""
    @State private var hits: [Message] = []
    @State private var filter = ChatFilter.all

    private var chats: [Chat] {
        let shown = store.chats.filter { chat in
            guard chat.archived == (filter == .archived) else { return false }
            switch filter {
            case .all, .archived: break
            case .unread: if chat.unread == 0 { return false }
            case .groups: if !chat.isGroup { return false }
            }
            return query.isEmpty || chat.name.localizedCaseInsensitiveContains(query)
        }
        // Pinned chats stay on top, each group still newest first.
        return shown.filter(\.pinned) + shown.filter { !$0.pinned }
    }

    var body: some View {
        List(selection: Binding(get: { store.selected }, set: { store.openChecked($0) })) {
            ForEach(chats) { chat in
                ChatRow(chat: chat, typing: store.typing[chat.jid] != nil, tick: store.avatarTick,
                        draft: chat.jid == store.selected ? nil : store.drafts[chat.jid], sealed: store.isSealed(chat.jid))
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
                        Button(store.isLocked(chat.jid) ? L("Remove Lock") : L("Lock"), systemImage: "lock") {
                            store.setLocked(chat.jid, !store.isLocked(chat.jid))
                        }
                        if !chat.archived {
                            Button(chat.pinned ? L("Unpin") : L("Pin"), systemImage: chat.pinned ? "pin.slash" : "pin") {
                                store.pin(chat, !chat.pinned)
                            }
                        }
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
            Picker(L("Filter"), selection: $filter) {
                ForEach(ChatFilter.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
        .overlay {
            if store.chats.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L("Syncing chats…")).foregroundStyle(.secondary).font(.callout)
                }
            } else if chats.isEmpty && hits.isEmpty {
                Text(L("No results")).foregroundStyle(.secondary)
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
        HStack(spacing: 11) {
            AvatarView(jid: chat.jid, name: chat.name, size: prefs.compact ? 32 : 44, tick: tick)
            VStack(alignment: .leading, spacing: 3) {
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
                .lineLimit(1)
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
    @State private var forwarding: Message?
    @State private var searching = false
    @State private var showingStarred = false
    @State private var showingInfo = false
    @State private var showingMembers = false
    @State private var composingPoll = false
    @State private var pickingContact = false
    @State private var pickingSticker = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    if store.hasMore {
                        Button(L("Older messages")) {
                            let anchor = store.messages.first?.id
                            store.loadOlder {
                                if let anchor { proxy.scrollTo(anchor, anchor: .top) }
                            }
                        }
                        .buttonStyle(.glass)
                        .padding(8)
                    }
                    MessageList(messages: store.messages, isGroup: chat.isGroup, highlighted: highlighted, actions: MessageActions(
                        reply: { store.editing = nil; store.replyTo = $0 },
                        edit: { store.clearDraftState(); store.editing = $0; text = $0.text },
                        forward: { forwarding = $0 },
                        jump: { jump(to: $0, proxy: proxy) },
                        preview: { store.previewURL = URL(fileURLWithPath: $0) }
                    ))
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                // Rows must not animate their own re-layout while the sidebar
                // slides; that shows up as the whole conversation flickering.
                .transaction { $0.animation = nil }
            }
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
                // Don't yank the view down while the user is reading older messages.
                guard let last, !farFromBottom || store.messages.last?.fromMe == true else { return }
                proxy.scrollTo(last, anchor: .bottom)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(alignment: .trailing, spacing: 8) {
                    if farFromBottom {
                        Button {
                            if let last = store.messages.last?.id { withAnimation { proxy.scrollTo(last, anchor: .bottom) } }
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
                                file: $store.pendingFile, chatName: chat.name, members: store.members,
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
        .background(.background)
        .navigationTitle(chat.name)
        .navigationSubtitle(store.subtitle(for: chat))
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AvatarView(jid: chat.jid, name: chat.name, size: 30, tick: store.avatarTick)
            }
            .sharedBackgroundVisibility(.hidden)
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
                Button(L("Info"), systemImage: "info.circle") { showingInfo = true }
                    .keyboardShortcut("i")
                    .help(L("Chat info, media and settings"))
            }
        }
        .sheet(item: $forwarding) { ForwardSheet(message: $0) }
        .sheet(isPresented: $showingInfo) { ChatInfoSheet(chat: chat) { showingMembers = true } }
        .sheet(isPresented: $showingMembers) { GroupInfoSheet(chat: chat) }
        .sheet(isPresented: $composingPoll) { PollComposer(chat: chat) }
        .sheet(isPresented: $pickingContact) {
            ContactPicker(title: L("Send Contact")) { store.sendContact($0, to: chat.jid) }
        }
        .popover(isPresented: $pickingSticker, arrowEdge: .bottom) {
            StickerPicker(chat: chat) { pickingSticker = false }.environmentObject(store)
        }
        .onAppear { text = store.drafts[chat.jid] ?? "" }
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
        case .poll: composingPoll = true
        case .contact: pickingContact = true
        case .sticker: pickingSticker = true
        case .location: store.sendLocation(to: chat.jid)
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
                Images.fromDrop([provider]) { images in
                    guard let image = images.first else { return }
                    store.pendingFile = nil
                    store.pendingImage = image
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

    @FocusState private var focused: Bool
    @State private var cropping = false
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
                    Menu {
                        Button(L("Photo or Video…"), systemImage: "photo.on.rectangle") { onAttach(.media) }
                        Button(L("File…"), systemImage: "doc") { onAttach(.file) }
                        Divider()
                        Button(L("Sticker…"), systemImage: "face.smiling") { onAttach(.sticker) }
                        Button(L("Poll…"), systemImage: "chart.bar") { onAttach(.poll) }
                        Button(L("Contact…"), systemImage: "person.crop.circle") { onAttach(.contact) }
                        Button(L("My Location"), systemImage: "location") { onAttach(.location) }
                        Divider()
                        Button(L("Emoji & Symbols"), systemImage: "smiley") {
                            focused = true
                            NSApp.orderFrontCharacterPalette(nil)
                        }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 15, weight: .medium))
                            .frame(width: Self.height, height: Self.height)
                            .contentShape(Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .glassEffect(.regular.interactive(), in: Circle())
                    .help(L("Attach a photo, video or file"))
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
                    TextField(placeholder, text: $text, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(1...8)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minHeight: Self.height)
                        .focused($focused)
                        .onSubmit { if canSend { onSend() } }
                        .onKeyPress(.upArrow) {
                            guard text.isEmpty, editing == nil, let onEditLast else { return .ignored }
                            onEditLast()
                            return .handled
                        }
                        .onChange(of: text) { _, new in
                            if !new.isEmpty { onTyping() }
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
        .onAppear { focused = true }
        .onChange(of: reply?.id) { _, _ in focused = true }
        .onChange(of: editing?.id) { _, _ in focused = true }
        .onChange(of: image?.id) { _, _ in focused = true }
        .onChange(of: file?.id) { _, _ in focused = true }
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
            onSend()
        }
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
                Button(L("Crop"), systemImage: "crop") { cropping = true }
                    .buttonStyle(.glass)
                    .sheet(isPresented: $cropping) {
                        CropSheet(image: image) { self.image = $0 }
                    }
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
