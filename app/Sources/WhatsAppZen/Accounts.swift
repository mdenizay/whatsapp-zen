import AppKit
import Combine
import Foundation
import SwiftUI

/// The linked WhatsApp accounts. All of them stay connected and notify; the
/// windows show one, the active account.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var accounts: [AppStore] = []
    @Published private(set) var activeID = ""
    /// Settings are shown as a sheet on the main window.
    @Published var showingSettings = false
    @Published var showingNewChat = false
    /// Bound straight to the split view. (A binding rebuilt on every redraw
    /// made the split view re-apply its ideal width, so the list kept
    /// changing size by itself.)
    @Published var sidebarVisibility = NavigationSplitViewVisibility.all
    var sidebarHidden: Bool { sidebarVisibility == .detailOnly }

    @Published var showingSwitcher = false
    @Published var showingStatus = false
    /// Release notes to show once after an update.
    @Published var releaseNotes: String?
    /// True while the app waits for Touch ID.
    @Published private(set) var locked = Prefs.shared.appLock && !AppStore.isDemo
    private var leftAt: Date?

    func unlock() {
        guard locked else { return }
        Auth.unlock(reason: L("Unlock WhatsApp Zen")) { ok in
            if ok { self.locked = false }
        }
    }

    func lock() {
        guard Prefs.shared.appLock else { return }
        accounts.forEach { $0.unlockedChats.removeAll() }
        locked = true
    }

    /// Opens the chat at a position in the list (⌘1…⌘9) or next to the open one.
    func openChat(at index: Int) {
        guard let store = active else { return }
        let chats = store.chats.filter { !$0.archived }
        if chats.indices.contains(index) { store.openChecked(chats[index].jid) }
    }

    func stepChat(_ delta: Int) {
        guard let store = active else { return }
        let chats = store.chats.filter { !$0.archived }
        let current = chats.firstIndex { $0.jid == store.selected } ?? -1
        openChat(at: min(max(current + delta, 0), chats.count - 1))
    }

    /// Fires for incoming messages that deserve a notification.
    let incoming = PassthroughSubject<(account: AppStore, chat: String, chatName: String, message: Message), Never>()

    /// Whether the main window is on screen; set by the app delegate.
    var windowVisible = false {
        didSet { active?.attentionChanged() }
    }

    private var subscriptions: [String: AnyCancellable] = [:]

    var active: AppStore? { accounts.first { $0.id == activeID } ?? accounts.first }
    var totalUnread: Int { accounts.reduce(0) { $0 + $1.totalUnread } }

    func start() {
        if AppStore.isDemo {
            add("demo")
            activate("demo")
            return
        }
        // The app was called "WhatsApp Native" at first; carry its data over.
        let old = AppStore.dataDir.deletingLastPathComponent().appendingPathComponent("WhatsAppNative")
        if !FileManager.default.fileExists(atPath: AppStore.dataDir.path) {
            try? FileManager.default.moveItem(at: old, to: AppStore.dataDir)
        }
        try? FileManager.default.createDirectory(at: AppStore.dataDir, withIntermediateDirectories: true)
        Core.start(dataDir: AppStore.dataDir.path)
        // The core words a few things itself (message-kind labels in quotes).
        Core.fire("set_lang", ["text": String((Bundle.main.preferredLocalizations.first ?? "en").prefix(2))], account: "")
        let ids = Core.accountIDs()
        for id in ids.isEmpty ? ["main"] : ids { add(id) }
        let last = UserDefaults.standard.string(forKey: "activeAccount") ?? ""
        activate(accounts.contains { $0.id == last } ? last : accounts[0].id)
    }

    private func add(_ id: String) {
        let store = AppStore(id: id)
        // Unread totals and account labels in menus depend on every store.
        subscriptions[id] = store.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        accounts.append(store)
        store.start()
    }

    /// Starts pairing a new account and shows its QR code.
    func addAccount() {
        let id = "acc-\(Int(Date().timeIntervalSince1970))"
        add(id)
        activate(id)
    }

    func activate(_ id: String) {
        guard accounts.contains(where: { $0.id == id }) else { return }
        activeID = id
        Core.active = id
        Prefs.shared.activate(account: id)
        UserDefaults.standard.set(id, forKey: "activeAccount")
        accounts.forEach { $0.attentionChanged() }
    }

    /// Drops an account and its local data; `unlink` also removes this device
    /// from the phone's linked devices.
    func remove(_ store: AppStore, unlink: Bool) {
        subscriptions[store.id] = nil
        accounts.removeAll { $0 === store }
        Core.fire("remove_account", ["unlink": unlink], account: store.id)
        if accounts.isEmpty {
            addAccount()
        } else if activeID == store.id {
            activate(accounts[0].id)
        }
    }

    func handleEvent(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["account"] as? String,
              let store = accounts.first(where: { $0.id == id }) else { return }
        store.handleEvent(data)
    }

    func appActiveChanged() {
        accounts.forEach { $0.attentionChanged() }
        if NSApp.isActive {
            if let leftAt, Date().timeIntervalSince(leftAt) >= Double(Prefs.shared.lockAfter * 60) { lock() }
            leftAt = nil
        } else {
            leftAt = Date()
            // Sealed chats close again as soon as the app is left.
            for store in accounts where store.selected.map(store.isLocked) == true {
                store.unlockedChats.removeAll()
                store.open(nil)
            }
        }
    }
}
