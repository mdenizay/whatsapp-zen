import AppKit
import UserNotifications

/// macOS notifications for incoming messages, with reply from the banner.
final class Notifier: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    static let shared = Notifier()

    /// Whether macOS lets this app post notifications at all.
    @Published private(set) var permitted = true

    /// What macOS currently allows this app's notifications to do. These are
    /// the user's choices in System Settings; the app can only read them.
    struct SystemState: Equatable {
        var asked = false
        /// "banners", "alerts" or "none".
        var style = "banners"
        var sound = true
        var center = true
        var lockScreen = true
        var badge = true
        /// "always", "unlocked" or "never".
        var previews = "always"
    }

    @Published private(set) var system = SystemState()

    /// What a banner gives away: "full" (name and message), "name" (who, not
    /// what) or "hidden" (neither).
    @Published var content = UserDefaults.standard.string(forKey: "notifyContent")
        ?? ((UserDefaults.standard.object(forKey: "notifyPreview") as? Bool ?? true) ? "full" : "name") {
        didSet { UserDefaults.standard.set(content, forKey: "notifyContent") }
    }
    /// Whether banners carry the sender's profile photo.
    @Published var photo = UserDefaults.standard.object(forKey: "notifyPhoto") as? Bool ?? true {
        didSet { UserDefaults.standard.set(photo, forKey: "notifyPhoto") }
    }
    /// Chats with a sound of their own, keyed "account/jid": a system sound's
    /// name, or "none" for silence.
    @Published private(set) var chatSounds = UserDefaults.standard.dictionary(forKey: "notifyChatSounds") as? [String: String] ?? [:]

    func chatSound(account: String, chat: String) -> String? { chatSounds["\(account)/\(chat)"] }

    func setChatSound(_ name: String?, account: String, chat: String) {
        chatSounds["\(account)/\(chat)"] = name
        UserDefaults.standard.set(chatSounds, forKey: "notifyChatSounds")
        if let name, name != "none" { NSSound(named: name)?.play() }
    }
    @Published var enabled = UserDefaults.standard.object(forKey: "notify") as? Bool ?? true {
        didSet { UserDefaults.standard.set(enabled, forKey: "notify") }
    }
    @Published var sound = UserDefaults.standard.object(forKey: "notifySound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(sound, forKey: "notifySound") }
    }
    /// A system sound to play instead of the default one; empty means default.
    @Published var soundName = UserDefaults.standard.string(forKey: "notifySoundName") ?? "" {
        didSet { UserDefaults.standard.set(soundName, forKey: "notifySoundName") }
    }

    /// The alert sounds installed with macOS.
    static let systemSounds: [String] = ((try? FileManager.default.contentsOfDirectory(atPath: "/System/Library/Sounds")) ?? [])
        .filter { $0.hasSuffix(".aiff") }.map { String($0.dropLast(5)) }.sorted()

    /// Sets the sound on a notification. A chosen system sound is played by
    /// the app itself, which is running whenever it posts a notification.
    private func applySound(to content: UNMutableNotificationContent, custom: String? = nil) {
        guard sound else { return }
        let name = custom ?? soundName
        if name == "none" { return }
        if name.isEmpty {
            content.sound = .default
        } else {
            NSSound(named: name)?.play()
        }
    }

    /// Whether banners show the message text; the simple form of `content`.
    var preview: Bool {
        get { content == "full" }
        set { content = newValue ? "full" : "name" }
    }

    /// Opens a chat in the main window; set by the app delegate.
    var openChat: (_ account: String, _ chat: String) -> Void = { _, _ in }

    /// Notifications need a real bundle; skip them when run as a bare binary.
    private let available = Bundle.main.bundleIdentifier != nil

    func setUp() {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let reply = UNTextInputNotificationAction(identifier: "reply", title: L("Reply"), options: [],
                                                  textInputButtonTitle: L("Send"), textInputPlaceholder: L("Message"))
        let read = UNNotificationAction(identifier: "read", title: L("Mark as Read"), options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: "message", actions: [reply, read], intentIdentifiers: []),
            UNNotificationCategory(identifier: "call", actions: [
                UNNotificationAction(identifier: "decline", title: L("Decline"), options: [.destructive]),
            ], intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { [weak self] _, _ in self?.refresh() }
    }

    /// Re-reads the system setting; the user can change it at any time.
    func refresh() {
        guard available else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
            var state = SystemState()
            state.asked = settings.authorizationStatus != .notDetermined
            state.style = settings.alertSetting != .enabled || settings.alertStyle == .none ? "none"
                : (settings.alertStyle == .alert ? "alerts" : "banners")
            state.sound = settings.soundSetting == .enabled
            state.center = settings.notificationCenterSetting == .enabled
            state.lockScreen = settings.lockScreenSetting == .enabled
            state.badge = settings.badgeSetting == .enabled
            state.previews = settings.showPreviewsSetting == .never ? "never"
                : (settings.showPreviewsSetting == .whenAuthenticated ? "unlocked" : "always")
            DispatchQueue.main.async {
                self.permitted = ok
                self.system = state
            }
        }
    }

    func openSystemSettings() {
        let id = Bundle.main.bundleIdentifier ?? ""
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    func post(account: AppStore, chat: String, chatName: String, message: Message) {
        guard available, enabled, !Prefs.shared.paused else { return }
        // A locked chat, or a locked app, gives nothing away in its banner.
        let style = account.isLocked(chat) || AppModel.shared.locked ? "hidden" : self.content
        let content = UNMutableNotificationContent()
        content.title = style == "hidden" ? "WhatsApp" : chatName
        var subtitle: [String] = []
        if chat.hasSuffix("@g.us"), style != "hidden" { subtitle.append(message.senderName) }
        if AppModel.shared.accounts.count > 1 { subtitle.append(account.label) }
        content.subtitle = subtitle.joined(separator: " · ")
        content.body = style == "full" ? message.plainText : L("New message")
        applySound(to: content, custom: chatSound(account: account.id, chat: chat))
        let withPhoto = photo && style != "hidden"
        content.categoryIdentifier = "message"
        content.threadIdentifier = "\(account.id)/\(chat)"
        content.userInfo = ["chat": chat, "account": account.id]

        let accountID = account.id
        Task {
            // The sender's photo, shown on the banner. The system moves the
            // attached file away, so hand it a copy.
            if withPhoto, let path: String = try? await Core.call("avatar", ["jid": chat], account: accountID), !path.isEmpty {
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent("wa-avatar-\(UUID().uuidString).jpg")
                if (try? FileManager.default.copyItem(atPath: path, toPath: copy.path)) != nil,
                   let attachment = try? UNNotificationAttachment(identifier: "avatar", url: copy) {
                    content.attachments = [attachment]
                }
            }
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "\(accountID)/\(message.id)", content: content, trigger: nil))
        }
    }

    /// Calls cannot be answered in this app (the protocol library carries no
    /// call audio or video); say who is calling and offer to decline.
    func postCall(account: AppStore, name: String, video: Bool, from: String, callID: String) {
        guard available, enabled else { return }
        let content = UNMutableNotificationContent()
        content.title = video ? L("Incoming video call") : L("Incoming voice call")
        content.body = L("%@ is calling. Answer on your phone.", name)
        applySound(to: content)
        content.categoryIdentifier = "call"
        content.interruptionLevel = .timeSensitive
        content.userInfo = ["account": account.id, "call_from": from, "call_id": callID]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "call/\(callID)", content: content, trigger: nil))
    }

    func postTest() {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "WhatsApp"
        content.body = L("Notifications are working.")
        applySound(to: content)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "test", content: content, trigger: nil)) { _ in
            self.refresh()
        }
    }

    /// Clears delivered banners for a chat once it has been read.
    func clear(account: String, chat: String) {
        guard available else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let ids = delivered.filter { $0.request.content.threadIdentifier == "\(account)/\(chat)" }.map(\.request.identifier)
            if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler done: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let typed = (response as? UNTextInputNotificationResponse)?.userText
        let action = response.actionIdentifier
        if action == "decline", let account = info["account"] as? String,
           let from = info["call_from"] as? String, let id = info["call_id"] as? String {
            Core.fire("reject_call", ["jid": from, "id": id], account: account)
            return done()
        }
        DispatchQueue.main.async {
            guard let chat = info["chat"] as? String, let account = info["account"] as? String,
                  let store = AppModel.shared.accounts.first(where: { $0.id == account }) else { return }
            if let typed {
                store.send(text: typed, to: chat)
                store.markRead(chat)
            } else if action == "read" {
                store.markRead(chat)
            } else if action == UNNotificationDefaultActionIdentifier {
                self.openChat(account, chat)
            }
        }
        done()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        // A notification without a sound of its own (a custom one is played by
        // the app, a silenced chat has none) stays quiet either way.
        done(sound ? [.banner, .sound, .list] : [.banner, .list])
    }
}
