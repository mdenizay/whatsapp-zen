import AppKit
import Combine
import Foundation
import ServiceManagement

struct GroupMember: Decodable, Identifiable, Equatable {
    let jid: String
    let name: String
    let isAdmin: Bool
    let isMe: Bool
    var id: String { jid }
}

struct GroupInfo: Decodable, Equatable {
    let name: String
    let topic: String
    let created: Int
    /// Whether we may manage the group.
    let isAdmin: Bool
    let members: [GroupMember]
}

struct Contact: Decodable, Identifiable, Equatable {
    let jid: String
    let name: String
    var id: String { jid }
}

/// All UI state. Lives on the main thread.
final class AppStore: ObservableObject, Identifiable {
    /// The account this store belongs to; also its folder name in the core.
    let id: String

    init(id: String) {
        self.id = id
        defer { lists = loadLists() }
        nickname = UserDefaults.standard.string(forKey: "account.\(id).name") ?? ""
        drafts = UserDefaults.standard.dictionary(forKey: "account.\(id).drafts") as? [String: String] ?? [:]
        icon = UserDefaults.standard.string(forKey: "account.\(id).icon") ?? Self.icons[0]
    }

    static let dataDir: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("WhatsAppZen", isDirectory: true)
    }()

    /// WA_DEMO=1 runs the UI on canned data without touching the account.
    static let isDemo = ProcessInfo.processInfo.environment["WA_DEMO"] != nil

    private static let pageSize = 60
    /// Upper bound on messages kept on screen for one chat.
    private static let maxLoaded = 1500

    @Published var state = "starting"
    @Published var qr = ""
    /// Our own JID once paired.
    @Published var me = ""
    @Published var chats: [Chat] = []
    @Published var selected: String?
    @Published var messages: [Message] = []
    /// The user's own groupings of chats ("Work", "Clients").
    @Published var lists: [ChatList] = [] {
        didSet { if lists != oldValue { saveLists() } }
    }
    @Published var hasMore = false
    /// The open chat's messages have been read from the database at least once.
    @Published var loaded = false
    /// The user asked for this chat's older messages from the phone.
    @Published var askedPhone = false
    @Published var presence: [String: Presence] = [:]
    @Published var typing: [String: String] = [:]
    @Published var replyTo: Message?
    @Published var editing: Message?
    @Published var pendingImage: PendingImage?
    @Published var pendingFile: PendingFile?
    @Published var previewURL: URL?
    @Published var errorText: String?
    @Published var avatarTick = 0
    /// Messages pinned in the open chat, newest first.
    @Published var pinnedMessages: [Message] = []
    /// A message the conversation view should scroll to and flash.
    @Published var jumpTarget: String?
    /// Photos waiting in the send screen (crop, draw, caption).
    @Published var pendingPhotos: [PendingImage] = []
    /// The in-app photo and video viewer, when open.
    @Published var viewer: ViewerState?
    /// A second chat shown beside the open one in the main window.
    @Published var splitChat: String?
    /// The first message that was unread when the open chat was opened.
    @Published var unreadFrom: String?
    private var unreadAtOpen = 0
    /// Unsent text per chat.
    @Published var drafts: [String: String] = [:]
    /// Further files queued behind the staged attachment, sent with it.
    @Published var pendingMore: [URL] = []
    /// Members of the open group, for @-mentions.
    @Published var members: [GroupMember] = []
    /// Locked chats opened with Touch ID in this session.
    var unlockedChats = Set<String>()
    @Published var launchAtLogin = SMAppService.mainApp.status == .enabled

    /// Fires with a chat JID whenever that chat's messages changed ("" = any).
    let messagesChanged = PassthroughSubject<String, Never>()

    private var lastChats = Data()
    private var lastMessages = Data()
    private var lastMessagesKey = ""
    private var chatsReload: DispatchWorkItem?
    private var messagesReload: DispatchWorkItem?
    private var typingExpiry: [String: DispatchWorkItem] = [:]
    private var lastTypingSent = Date.distantPast

    var totalUnread: Int { chats.reduce(0) { $0 + $1.unread } }
    var selectedChat: Chat? { chats.first { $0.jid == selected } }
    /// True when the user is actually looking at the open conversation.
    var isWatching: Bool {
        NSApp.isActive && AppModel.shared.windowVisible && AppModel.shared.active === self
    }

    /// A name the user gave this account ("Personal", "Work"); empty for none.
    @Published var nickname = "" {
        didSet { UserDefaults.standard.set(nickname, forKey: "account.\(id).name") }
    }
    /// The SF Symbol that stands for this account in the toolbar.
    @Published var icon = AppStore.icons[0] {
        didSet { UserDefaults.standard.set(icon, forKey: "account.\(id).icon") }
    }

    static let icons = [
        "person.crop.circle.fill", "briefcase.fill", "house.fill", "building.2.fill", "heart.fill", "star.fill",
        "graduationcap.fill", "cart.fill", "gamecontroller.fill", "airplane", "wrench.and.screwdriver.fill", "leaf.fill",
        "bubble.left.fill", "phone.fill", "bolt.fill", "flag.fill", "moon.fill", "book.fill",
    ]

    /// The account's phone number once paired.
    var phone: String {
        guard let user = me.split(separator: "@").first, !user.isEmpty else { return "" }
        return "+\(user)"
    }

    /// How the account is named in menus: its nickname, else its number.
    var label: String {
        if !nickname.isEmpty { return nickname }
        return phone.isEmpty ? L("New account") : phone
    }

    func start() {
        if Self.isDemo {
            state = "connected"
            me = "15550123@s.whatsapp.net"
            chats = Demo.chats
            presence = Demo.presence
            return
        }
        Core.fire("open_account", account: id)
    }

    // MARK: Events

    private struct MessageEvent: Decodable {
        let chat: String
        let chatName: String
        let msg: Message?
        let notify: Bool
    }

    func handleEvent(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "state":
            state = obj["state"] as? String ?? state
            qr = obj["qr"] as? String ?? ""
            me = obj["me"] as? String ?? ""
            if state == "connected" {
                reloadChats()
                if let jid = selected { watchPresence(of: jid) }
                Core.fire("presence", ["on": NSApp.isActive && AppModel.shared.active === self], account: id)
            }
        case "chats":
            scheduleChatsReload()
        case "messages":
            let chat = obj["chat"] as? String ?? ""
            if chat.isEmpty || chat == selected { scheduleMessagesReload() }
            messagesChanged.send(chat)
        case "message":
            guard let ev = try? Core.decoder.decode(MessageEvent.self, from: data) else { return }
            scheduleChatsReload()
            typing[ev.chat] = nil
            let watching = ev.chat == selected && isWatching
            if ev.chat == selected {
                reloadMessages()
                if watching { markRead(ev.chat) }
            }
            messagesChanged.send(ev.chat)
            if ev.notify, !watching, let msg = ev.msg {
                AppModel.shared.incoming.send((self, ev.chat, ev.chatName, msg))
            }
        case "presence":
            guard let jid = obj["jid"] as? String else { return }
            presence[jid] = Presence(online: obj["online"] as? Bool ?? false, lastSeen: obj["last_seen"] as? Int ?? 0)
        case "typing":
            guard let chat = obj["chat"] as? String else { return }
            setTyping(chat: chat, name: (obj["composing"] as? Bool ?? false) ? (obj["sender"] as? String ?? "") : nil)
        case "download":
            if let id = obj["id"] as? String {
                DownloadProgress.shared.update(id: id, done: obj["done"] as? Int ?? 0, total: obj["total"] as? Int ?? 0,
                                               finished: obj["finished"] as? Bool ?? false)
            }
        case "avatar":
            if let jid = obj["jid"] as? String { Task { @MainActor in Images.forgetAvatar(jid) } }
            avatarTick += 1
        case "call":
            Notifier.shared.postCall(account: self, name: obj["name"] as? String ?? "", video: obj["video"] as? Bool ?? false,
                                     from: obj["raw_jid"] as? String ?? "", callID: obj["id"] as? String ?? "")
        case "fatal":
            errorText = obj["error"] as? String
        default:
            break
        }
    }

    private func setTyping(chat: String, name: String?) {
        typingExpiry[chat]?.cancel()
        typing[chat] = name
        guard name != nil else { return }
        // "Paused" does not always arrive; don't leave the indicator stuck.
        let item = DispatchWorkItem { [weak self] in self?.typing[chat] = nil }
        typingExpiry[chat] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: item)
    }

    // MARK: Loading

    /// History sync emits bursts of events; coalesce them into one reload.
    private func scheduleChatsReload() {
        chatsReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadChats() }
        chatsReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func reloadChats() {
        guard !Self.isDemo else { return }
        Task { @MainActor in
            // Most reloads bring back exactly what is already on screen; spot
            // that on the raw reply and skip decoding 600 chats for nothing.
            guard let data = try? await Core.reply("chats", account: self.id), data != self.lastChats,
                  let list: [Chat] = try? Core.decode(data) else { return }
            self.lastChats = data
            if list != self.chats { self.chats = list }
        }
    }

    /// One page of a chat, oldest first. `before` pages back from a message.
    func fetchMessages(chat: String, limit: Int, before: Message? = nil) async -> [Message]? {
        if Self.isDemo { return before == nil ? Demo.messages(for: chat) : [] }
        var args: [String: Any] = ["chat": chat, "limit": limit]
        if let before {
            args["before_ts"] = before.ts
            args["before_id"] = before.id
        }
        guard let data = try? await Core.reply("messages", args, account: self.id) else { return nil }
        // The open conversation is re-read after every receipt; an unchanged
        // reply is answered with what is already loaded.
        let key = "\(chat)#\(limit)"
        if before == nil, chat == selected, key == lastMessagesKey, data == lastMessages, !messages.isEmpty { return messages }
        guard let list: [Message] = try? Core.decode(data) else { return nil }
        if before == nil, chat == selected {
            lastMessagesKey = key
            lastMessages = data
        }
        return list
    }

    /// Receipts and reactions arrive in bursts; redraw the conversation once.
    func scheduleMessagesReload() {
        messagesReload?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.reloadMessages() }
        messagesReload = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: item)
    }

    func reloadMessages() {
        guard let chat = selected else { return }
        // Keep whatever older pages are already on screen.
        let limit = min(max(Self.pageSize, messages.count), Self.maxLoaded)
        Task { @MainActor in
            guard let list = await self.fetchMessages(chat: chat, limit: limit), chat == self.selected else { return }
            if list != self.messages { self.messages = list }
            if self.unreadAtOpen > 0 {
                // Mark where the unread messages begin, once per opening.
                self.unreadFrom = list.filter { !$0.fromMe }.suffix(self.unreadAtOpen).first?.id
                self.unreadAtOpen = 0
            }
            self.hasMore = list.count >= limit
            self.loaded = true
            if list.count < Self.pageSize { self.requestHistory(of: chat) }
            let pinned: [Message] = Self.isDemo ? list.filter(\.pinned)
                : ((try? await Core.call("pinned", ["chat": chat], account: self.id)) ?? [])
            if chat == self.selected, pinned != self.pinnedMessages { self.pinnedMessages = pinned }
        }
    }

    /// Asks the phone for the messages before the oldest one stored here. A
    /// linked device is only given the recent part of each chat; what comes
    /// back arrives as a "messages" event. Asking twice for the same page is
    /// ignored by the core.
    func requestHistory(of chat: String) {
        guard !Self.isDemo else { return }
        Core.fire("fetch_history", ["chat": chat], account: id)
    }

    /// Lets go of the open chat's messages while no window shows them. The
    /// chat stays selected; `reloadMessages` brings them back.
    func releaseMessages() {
        guard !messages.isEmpty else { return }
        messages = []
        pinnedMessages = []
        lastMessagesKey = ""
        lastMessages = Data()
    }

    func loadOlder(then done: @escaping () -> Void) {
        guard let chat = selected, let first = messages.first else { return }
        Task { @MainActor in
            guard let older = await self.fetchMessages(chat: chat, limit: Self.pageSize, before: first),
                  chat == self.selected else { return }
            self.hasMore = older.count >= Self.pageSize
            self.messages = older + self.messages
            done()
        }
    }

    func open(_ jid: String?) {
        guard jid != selected else { return }
        selected = jid
        lastMessagesKey = ""
        lastMessages = Data()
        messages = []
        loaded = false
        askedPhone = false
        pinnedMessages = []
        hasMore = false
        clearDraftState()
        unreadFrom = nil
        // Leaving a chat frees what it had decoded.
        malloc_zone_pressure_relief(nil, 0)
        guard let jid else { return }
        unreadAtOpen = chats.first { $0.jid == jid }?.unread ?? 0
        if let chat = chats.first(where: { $0.jid == jid }) { loadMembers(of: chat) }
        reloadMessages()
        watchPresence(of: jid)
        if isWatching { markRead(jid) }
    }

    func clearDraftState() {
        replyTo = nil
        editing = nil
        pendingImage = nil
        pendingFile = nil
        pendingMore = []
        pendingPhotos = []
    }

    func watchPresence(of jid: String) {
        Core.fire("subscribe_presence", ["jid": jid], account: self.id)
    }

    // MARK: Actions

    private func attempt(_ work: @escaping () async throws -> Void) {
        Task { @MainActor in
            do { try await work() } catch { self.errorText = L(error.localizedDescription) }
        }
    }

    func markRead(_ chat: String) {
        Core.fire("mark_read", ["chat": chat], account: self.id)
        Notifier.shared.clear(account: id, chat: chat)
    }

    func send(text: String, to chat: String, replyTo: String? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        lastTypingSent = .distantPast
        attempt {
            let resolved = self.resolveMentions(in: text)
            let _: Message = try await Core.call("send_text", [
                "chat": chat, "text": resolved.text, "reply_to": replyTo ?? "", "mentions": resolved.jids,
            ], account: self.id)
        }
    }

    func send(image: PendingImage, caption: String, to chat: String, replyTo: String? = nil) {
        attempt {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("wa-\(UUID().uuidString).jpg")
            try image.jpeg.write(to: url)
            defer { try? FileManager.default.removeItem(at: url) }
            let _: Message = try await Core.call("send_image", [
                "chat": chat, "path": url.path, "thumb": image.thumb, "w": image.width, "h": image.height,
                "text": caption.trimmingCharacters(in: .whitespacesAndNewlines), "reply_to": replyTo ?? "",
            ], account: self.id)
        }
    }

    func send(file: PendingFile, caption: String, to chat: String, replyTo: String? = nil) {
        attempt {
            let _: Message = try await Core.call("send_file", [
                "chat": chat, "path": file.url.path, "kind": file.kind, "mime": file.mime, "file_name": file.name,
                "thumb": file.thumb, "w": file.width, "h": file.height, "seconds": file.seconds,
                "text": caption.trimmingCharacters(in: .whitespacesAndNewlines), "reply_to": replyTo ?? "",
            ], account: self.id)
        }
    }

    /// Stages a file for the open chat: photos as photos, the rest as files.
    /// Stages several files: the first is shown in the composer, the rest
    /// are queued behind it and go out with the same press of Send.
    func attach(_ urls: [URL]) {
        // Photos go to the send screen together; other files are staged in
        // the composer, the first shown and the rest queued behind it.
        let photos = urls.filter(Attachments.isImage).compactMap { try? Data(contentsOf: $0) }.compactMap(Images.prepare)
        if !photos.isEmpty { pendingPhotos = photos }
        let files = urls.filter { !Attachments.isImage($0) }
        guard let first = files.first else { return }
        pendingMore = Array(files.dropFirst())
        attach(first)
    }

    /// Sends one file straight away, with no caption.
    func sendNow(_ url: URL, to chat: String) async {
        if Attachments.isImage(url), let data = try? Data(contentsOf: url), let image = Images.prepare(data) {
            send(image: image, caption: "", to: chat)
        } else if let file = await Attachments.file(at: url) {
            send(file: file, caption: "", to: chat)
        }
    }

    func attach(_ url: URL) {
        Task { @MainActor in
            if Attachments.isImage(url), let data = try? Data(contentsOf: url), let image = Images.prepare(data) {
                self.pendingPhotos = [image]
            } else if let file = await Attachments.file(at: url) {
                self.pendingImage = nil
                self.pendingFile = file
            }
        }
    }

    /// Toggles: reacting again with the same emoji removes the reaction.
    func react(to message: Message, with emoji: String) {
        let mine = message.reactions.first { $0.fromMe }?.emoji
        attempt {
            try await Core.run("react", ["chat": message.chat, "id": message.id, "emoji": mine == emoji ? "" : emoji], account: self.id)
        }
    }

    func deleteForMe(_ message: Message) {
        attempt { try await Core.run("delete_for_me", ["chat": message.chat, "id": message.id], account: self.id) }
    }

    func revoke(_ message: Message) {
        attempt { try await Core.run("revoke", ["chat": message.chat, "id": message.id], account: self.id) }
    }

    func edit(_ message: Message, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != message.text else { return }
        attempt { try await Core.run("edit", ["chat": message.chat, "id": message.id, "text": text], account: self.id) }
    }

    // MARK: Chats and messages: archive, pin, star, forward, search

    func archive(_ chat: Chat, _ on: Bool) {
        if on, selected == chat.jid { open(nil) }
        attempt { try await Core.run("archive", ["chat": chat.jid, "on": on], account: self.id) }
    }

    func pin(_ chat: Chat, _ on: Bool) {
        attempt { try await Core.run("pin_chat", ["chat": chat.jid, "on": on], account: self.id) }
    }

    func star(_ message: Message, _ on: Bool) {
        attempt { try await Core.run("star", ["chat": message.chat, "id": message.id, "on": on], account: self.id) }
    }

    func pin(_ message: Message, _ on: Bool) {
        attempt { try await Core.run("pin_message", ["chat": message.chat, "id": message.id, "on": on], account: self.id) }
    }

    func forward(_ message: Message, to chats: [String]) {
        attempt {
            for chat in chats {
                let _: Message = try await Core.call("forward", ["chat": message.chat, "id": message.id, "to": chat], account: self.id)
            }
        }
    }

    func search(chat: String, text: String) async -> [Message] {
        if Self.isDemo { return Demo.messages(for: chat).filter { $0.text.localizedCaseInsensitiveContains(text) } }
        return (try? await Core.call("search", ["chat": chat, "text": text], account: self.id)) ?? []
    }

    func starred(chat: String) async -> [Message] {
        if Self.isDemo { return Demo.messages(for: chat).filter(\.starred) }
        return (try? await Core.call("starred", ["chat": chat], account: self.id)) ?? []
    }

    /// Scrolls the open chat to a message, loading back to it first if it is
    /// older than what is on screen.
    func reveal(_ message: Message) {
        guard message.chat == selected else { return }
        if messages.contains(where: { $0.id == message.id }) {
            jumpTarget = message.id
            return
        }
        Task { @MainActor in
            let since: Int = (try? await Core.call("count_since", ["chat": message.chat, "ts": message.ts], account: self.id)) ?? 0
            let limit = min(since + 20, Self.maxLoaded)
            guard let list = await self.fetchMessages(chat: message.chat, limit: limit), message.chat == self.selected else { return }
            self.messages = list
            self.hasMore = list.count >= limit
            // Let the list lay out the newly loaded rows before scrolling.
            try? await Task.sleep(for: .milliseconds(150))
            self.jumpTarget = message.id
        }
    }

    /// Shows a message known only by its id (the one a reply quotes), loading
    /// the conversation back to it if it is older than what is on screen.
    func reveal(id: String, in chat: String) {
        guard chat == selected else { return }
        Task { @MainActor in
            let from: Int = (try? await Core.call("count_from", ["chat": chat, "id": id], account: self.id)) ?? 0
            guard from > 0 else {
                self.errorText = L("That message is not on this Mac. Use \"Get older messages from your phone\" at the top of the chat to bring earlier ones.")
                return
            }
            let limit = min(from + 20, Self.maxLoaded)
            guard let list = await self.fetchMessages(chat: chat, limit: limit), chat == self.selected else { return }
            self.messages = list
            self.hasMore = list.count >= limit
            // Let the list lay out the newly loaded rows before scrolling.
            try? await Task.sleep(for: .milliseconds(200))
            self.jumpTarget = id
        }
    }

    func send(voice url: URL, seconds: Int, to chat: String, replyTo: String? = nil) {
        attempt {
            defer { try? FileManager.default.removeItem(at: url) }
            let _: Message = try await Core.call("send_voice", [
                "chat": chat, "path": url.path, "seconds": seconds, "reply_to": replyTo ?? "",
            ], account: self.id)
        }
    }

    // MARK: Groups

    func groupInfo(_ chat: String) async throws -> GroupInfo {
        try await Core.call("group_info", ["chat": chat], account: id)
    }

    func groupUpdate(_ chat: String, member: String, action: String) async throws {
        try await Core.run("group_update", ["chat": chat, "jid": member, "action": action], account: id)
    }

    func groupRename(_ chat: String, name: String) async throws {
        try await Core.run("group_rename", ["chat": chat, "text": name], account: id)
    }

    func groupLeave(_ chat: String) async throws {
        try await Core.run("group_leave", ["chat": chat], account: id)
    }

    func groupLink(_ chat: String) async throws -> String {
        try await Core.call("group_link", ["chat": chat], account: id)
    }

    func contacts() async -> [Contact] {
        if Self.isDemo { return Demo.chats.filter { !$0.isGroup }.map { Contact(jid: $0.jid, name: $0.name) } }
        return (try? await Core.call("contacts", account: self.id)) ?? []
    }

    /// Opens (creating if needed) the chat with a contact or a phone number.
    func startChat(jid: String = "", phone: String = "") async -> Bool {
        do {
            let chat: String = try await Core.call("start_chat", ["jid": jid, "phone": phone], account: self.id)
            if let list: [Chat] = try? await Core.call("chats", account: self.id) { chats = list }
            open(chat)
            return true
        } catch {
            errorText = L(error.localizedDescription)
            return false
        }
    }

    func userIsTyping(in chat: String) {
        guard Date().timeIntervalSince(lastTypingSent) > 5 else { return }
        lastTypingSent = Date()
        Core.fire("typing", ["chat": chat, "on": true], account: self.id)
    }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            errorText = L("Could not change Open at Login: %@", error.localizedDescription)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Unlinks this device. With other accounts around the account goes away
    /// entirely; the last one drops back to the pairing screen.
    func logout() {
        if AppModel.shared.accounts.count > 1 {
            AppModel.shared.remove(self, unlink: true)
        } else {
            attempt { try await Core.run("logout", account: self.id) }
        }
    }

    /// Called when the app or this account gains or loses the user's attention.
    func attentionChanged() {
        let active = NSApp.isActive && AppModel.shared.active === self
        Core.fire("presence", ["on": active], account: id)
        if isWatching, let chat = selected { markRead(chat) }
    }

    /// Status line under a chat title: typing, online, or last seen.
    func subtitle(for chat: Chat) -> String {
        if let who = typing[chat.jid] {
            return chat.isGroup && !who.isEmpty ? L("%@ is typing…", who) : L("typing…")
        }
        guard !chat.isGroup, let p = presence[chat.jid] else { return "" }
        if p.online { return L("online") }
        return p.lastSeen > 0 ? Format.lastSeen(p.lastSeen) : ""
    }
}
