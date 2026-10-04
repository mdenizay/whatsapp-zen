import AppKit
import Combine
import Foundation

/// The linked WhatsApp accounts. All of them stay connected and notify; the
/// windows show one, the active account.
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var accounts: [AppStore] = []
    @Published private(set) var activeID = ""
    /// Settings are shown as a sheet on the main window.
    @Published var showingSettings = false

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
    }
}
