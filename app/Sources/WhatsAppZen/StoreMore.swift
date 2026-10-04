import AppKit
import CoreLocation
import Foundation

struct Poll: Decodable, Equatable {
    struct Option: Decodable, Equatable, Identifiable {
        let name: String
        let votes: Int
        let mine: Bool
        var id: String { name }
    }

    let options: [Option]
    let selectable: Int
    let voters: Int
}

struct UserInfo: Decodable, Equatable {
    let about: String
    let blocked: Bool
}

extension AppStore {
    // MARK: Drafts

    private var draftsKey: String { "account.\(id).drafts" }

    func loadDrafts() {
        drafts = UserDefaults.standard.dictionary(forKey: draftsKey) as? [String: String] ?? [:]
    }

    func setDraft(_ text: String, for chat: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard drafts[chat] ?? "" != (trimmed.isEmpty ? "" : text) else { return }
        drafts[chat] = trimmed.isEmpty ? nil : text
        UserDefaults.standard.set(drafts, forKey: draftsKey)
    }

    // MARK: Locked chats

    private func lockKey(_ chat: String) -> String { "\(id)/\(chat)" }

    func isLocked(_ chat: String) -> Bool { Prefs.shared.lockedChats.contains(lockKey(chat)) }

    /// Locked and not yet opened with Touch ID in this session.
    func isSealed(_ chat: String) -> Bool { isLocked(chat) && !unlockedChats.contains(chat) }

    func setLocked(_ chat: String, _ on: Bool) {
        if on {
            Prefs.shared.lockedChats.insert(lockKey(chat))
            unlockedChats.insert(chat)
        } else {
            Prefs.shared.lockedChats.remove(lockKey(chat))
        }
        objectWillChange.send()
    }

    /// Opens a chat, asking for Touch ID first when it is locked.
    func openChecked(_ jid: String?) {
        guard let jid, isSealed(jid) else { return open(jid) }
        Auth.unlock(reason: L("Unlock this chat")) { ok in
            guard ok else { return }
            self.unlockedChats.insert(jid)
            self.open(jid)
        }
    }

    // MARK: Chat settings

    func mute(_ chat: Chat, seconds: Int) {
        run("mute", ["chat": chat.jid, "duration": seconds])
    }

    func setDisappearing(_ chat: Chat, seconds: Int) {
        run("set_ephemeral", ["chat": chat.jid, "duration": seconds])
    }

    func block(_ jid: String, _ on: Bool) async {
        try? await Core.run("block", ["jid": jid, "on": on], account: id)
    }

    func userInfo(_ jid: String) async -> UserInfo? {
        try? await Core.call("user_info", ["jid": jid], account: id)
    }

    func media(chat: String, kind: String) async -> [Message] {
        if Self.isDemo {
            let all = Demo.messages(for: chat) + Demo.messages(for: "x@g.us")
            return all.filter { kind == "docs" ? $0.type == "document" : kind == "links" ? $0.text.contains("http") : false }
        }
        return (try? await Core.call("chat_media", ["chat": chat, "kind": kind], account: id)) ?? []
    }

    func export(_ chat: Chat) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(chat.name).txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run("export", ["chat": chat.jid, "path": url.path])
    }

    // MARK: More kinds of message

    func sendPoll(question: String, options: [String], to chat: String) {
        run("send_poll", ["chat": chat, "text": question, "options": options])
    }

    func vote(_ message: Message, option: String) {
        guard let poll = message.poll else { return }
        // One choice per poll: picking your own choice again withdraws it.
        let mine = poll.options.first { $0.mine }?.name
        run("vote", ["chat": message.chat, "id": message.id, "options": mine == option ? [] : [option]])
    }

    func sendContact(_ contact: Contact, to chat: String) {
        run("send_contact", ["chat": chat, "jid": contact.jid, "text": contact.name])
    }

    func sendSticker(_ sticker: Message, to chat: String) {
        run("forward", ["chat": sticker.chat, "id": sticker.id, "to": chat, "plain": true])
    }

    func stickers() async -> [Message] {
        (try? await Core.call("stickers", account: id)) ?? []
    }

    func statuses() async -> [Message] {
        (try? await Core.call("statuses", account: id)) ?? []
    }

    func searchAll(_ text: String) async -> [Message] {
        if Self.isDemo { return [] }
        return (try? await Core.call("search_all", ["text": text], account: id)) ?? []
    }

    func sendLocation(to chat: String) {
        LocationOnce.shared.request { [weak self] location in
            guard let self else { return }
            guard let location else {
                self.errorText = L("Could not get your location. Allow it in System Settings → Privacy & Security → Location Services.")
                return
            }
            self.run("send_location", ["chat": chat, "lat": location.coordinate.latitude, "lng": location.coordinate.longitude])
        }
    }

    // MARK: Mentions

    /// Loads the members of the open group, for @-completion.
    func loadMembers(of chat: Chat) {
        members = []
        guard chat.isGroup, !Self.isDemo else { return }
        Task { @MainActor in
            guard let info = try? await self.groupInfo(chat.jid), chat.jid == self.selected else { return }
            self.members = info.members.filter { !$0.isMe }
        }
    }

    /// Turns the "@Name" tokens of a draft into what goes on the wire:
    /// "@<number>" in the text, plus the list of people mentioned.
    func resolveMentions(in text: String) -> (text: String, jids: [String]) {
        var out = text
        var jids: [String] = []
        for member in members.sorted(by: { $0.name.count > $1.name.count }) where out.contains("@\(member.name)") {
            let user = member.jid.split(separator: "@").first.map(String.init) ?? ""
            out = out.replacingOccurrences(of: "@\(member.name)", with: "@\(user)")
            jids.append(member.jid)
        }
        return (out, jids)
    }

    // MARK: Storage

    func cachedMedia() async -> [Message] {
        (try? await Core.call("cache_list", account: id)) ?? []
    }

    func removeCached(_ message: Message) async {
        try? await Core.run("cache_remove", ["chat": message.chat, "id": message.id], account: id)
    }

    func cacheSize() async -> Int {
        (try? await Core.call("cache_size", account: id)) ?? 0
    }

    func clearCache() async {
        try? await Core.run("clear_cache", account: id)
        reloadMessages()
    }

    /// Runs a command and reports failure in the usual error alert.
    func run(_ cmd: String, _ args: [String: Any]) {
        Task { @MainActor in
            do { try await Core.run(cmd, args, account: self.id) } catch { self.errorText = L(error.localizedDescription) }
        }
    }
}

/// One-shot "where am I", for sending a location.
final class LocationOnce: NSObject, CLLocationManagerDelegate {
    static let shared = LocationOnce()

    private let manager = CLLocationManager()
    private var done: ((CLLocation?) -> Void)?

    func request(_ done: @escaping (CLLocation?) -> Void) {
        self.done = done
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        done?(locations.last)
        done = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        done?(nil)
        done = nil
    }
}
