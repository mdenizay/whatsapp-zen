import AppKit
import Combine
import SwiftUI

/// The menu bar window. Borderless panels refuse key status by default, which
/// would leave the reply field unable to take typing.
final class MenuPanel: NSPanel {
    var onCancel: () -> Void = {}

    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { onCancel() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let model = AppModel.shared
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var panel: MenuPanel!
    private var clickMonitors: [Any] = []
    private var chatWindows: [String: NSWindow] = [:]
    private var authenticating = false
    /// The main window's views are dropped while it is closed.
    private var mainContentReleased = false
    private var subscriptions = Set<AnyCancellable>()

    private static let panelSize = NSSize(width: 380, height: 560)

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMenu()
        makeWindow()
        makeStatusItem()
        installPasteMonitor()

        Notifier.shared.openChat = { [weak self] account, chat in
            self?.model.activate(account)
            self?.model.active?.open(chat)
            self?.showWindow()
        }
        Notifier.shared.setUp()

        // While Touch ID is asked for, the menu bar panel must neither cover
        // the prompt (it floats above everything) nor take the click on the
        // prompt for a click outside itself and close.
        Auth.willPrompt = { [weak self] in
            self?.authenticating = true
            self?.panel.level = .normal
        }
        Auth.didPrompt = { [weak self] in
            guard let self else { return }
            self.panel.level = .popUpMenu
            if self.panel.isVisible { self.panel.makeKeyAndOrderFront(nil) }
            // Clicks still in flight from the prompt are not "outside" clicks.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.authenticating = false }
        }

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [model] in model.totalUnread }
            .removeDuplicates()
            .sink { [weak self] unread in self?.showUnread(unread) }
            .store(in: &subscriptions)
        Prefs.shared.$appearance
            .receive(on: DispatchQueue.main)
            .sink { choice in
                // nil follows the system setting.
                NSApp.appearance = choice == "light" ? NSAppearance(named: .aqua) : choice == "dark" ? NSAppearance(named: .darkAqua) : nil
            }
            .store(in: &subscriptions)
        Prefs.shared.$menuBarCount
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.showUnread(self?.model.totalUnread ?? 0) }
            .store(in: &subscriptions)
        model.incoming
            .sink { Notifier.shared.post(account: $0.account, chat: $0.chat, chatName: $0.chatName, message: $0.message) }
            .store(in: &subscriptions)

        model.start()
        Updater.shared.start()
        // Freed memory lingers in the allocator as "used". Hand it back every
        // minute, and drop decoded pictures once the app is out of sight.
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in malloc_zone_pressure_relief(nil, 0) }
        showWindow()
        snapshotIfRequested()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow()
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        model.appActiveChanged()
        Notifier.shared.refresh()
    }

    func applicationDidResignActive(_ notification: Notification) {
        model.appActiveChanged()
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
            if !NSApp.isActive { Images.trim() }
        }
    }

    // MARK: Main window

    private func makeWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "WhatsApp"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 700, height: 460)
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .none
        window.contentView = makeMainContent()
        window.delegate = self
        window.center()
        // Snapshots use a fixed size and must not disturb the saved frame.
        if ProcessInfo.processInfo.environment["WA_SNAPSHOT"] == nil { window.setFrameAutosaveName("main") }
    }

    private func makeMainContent() -> NSView {
        let hosting = NSHostingView(rootView: RootView { MainView() }.environmentObject(model))
        // Don't let the (initially empty) SwiftUI content dictate the window size.
        hosting.sizingOptions = []
        return hosting
    }

    func showWindow() {
        closePanel()
        if mainContentReleased {
            window.contentView = makeMainContent()
            mainContentReleased = false
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = true
    }

    func windowWillClose(_ notification: Notification) {
        guard notification.object as? NSWindow === window else { return }
        model.windowVisible = false
        // Living in the menu bar only: drop the window's views so nothing is
        // redrawn (or kept in memory) for a window nobody can see.
        DispatchQueue.main.async { [self] in
            guard !window.isVisible else { return }
            window.contentView = NSView()
            mainContentReleased = true
        }
    }
    func windowDidMiniaturize(_ notification: Notification) { model.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { model.windowVisible = true }

    // MARK: Menu bar

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = Self.statusIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        panel = MenuPanel(contentRect: NSRect(origin: .zero, size: Self.panelSize),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isFloatingPanel = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The window shadow would trace the panel's square frame, visible as
        // lines below the rounded glass.
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.onCancel = { [weak self] in self?.closePanel() }

    }

    /// The panel's views exist only while it is open: a hidden chat list
    /// would otherwise keep redrawing itself with every incoming message.
    private func makePanelContent() -> NSView {
        let content = RootView {
            MenuBarView { [weak self] chat in
                if let chat { self?.model.active?.open(chat) }
                self?.showWindow()
            }
        }
        .environmentObject(model)
        if ProcessInfo.processInfo.environment["WA_SNAPSHOT"] != nil {
            // A window captured on its own has nothing behind its glass, which
            // then renders as flat grey; give snapshots a plain backing.
            let backing = NSHostingView(rootView: content.background(.background))
            backing.wantsLayer = true
            backing.layer?.cornerRadius = 24
            backing.layer?.masksToBounds = true
            return backing
        }
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        glass.cornerRadius = 24
        glass.contentView = NSHostingView(rootView: content)
        return glass
    }

    /// The WhatsApp glyph as a template image, so it follows the menu bar's
    /// light/dark appearance like the system's own items.
    private static func statusIcon(unread: Bool = false) -> NSImage? {
        guard let url = Bundle.main.url(forResource: "whatsapp", withExtension: "svg"), let glyph = NSImage(contentsOf: url) else {
            return NSImage(systemSymbolName: "message.fill", accessibilityDescription: "WhatsApp")
        }
        let size = NSSize(width: 17, height: 17)
        glyph.size = size
        guard unread else {
            glyph.isTemplate = true
            return glyph
        }
        return NSImage(size: size, flipped: false) { rect in
            glyph.draw(in: rect)
            NSColor(srgbRed: 0.15, green: 0.83, blue: 0.40, alpha: 1).set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }

    /// The menu bar shows no count; the icon turns green while something is unread.
    private func showUnread(_ unread: Int) {
        statusItem.button?.image = Self.statusIcon(unread: unread > 0)
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.title = Prefs.shared.menuBarCount && unread > 0 ? " \(unread)" : ""
        NSApp.dockTile.badgeLabel = unread > 0 ? "\(unread)" : nil
    }

    /// Left click opens the chats; right click offers the app-level actions
    /// the panel itself no longer carries.
    @objc private func statusItemClicked() {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return togglePanel() }
        closePanel()
        let menu = NSMenu()
        menu.addItem(withTitle: L("Open the app"), action: #selector(showMainWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func togglePanel() {
        if panel.isVisible { closePanel() } else { openPanel() }
    }

    private func openPanel() {
        guard let button = statusItem.button, let buttonWindow = button.window else { return }
        let anchor = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        var x = anchor.midX - Self.panelSize.width / 2
        x = min(max(x, screen.minX + 8), screen.maxX - Self.panelSize.width - 8)
        // Hang just below the menu bar, like the system's own menu bar extras.
        let y = min(anchor.minY, screen.maxY) - Self.panelSize.height - 6
        panel.contentView = makePanelContent()
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: Self.panelSize), display: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // Any click outside dismisses it: in another app (global) or in one of
        // our own windows (local).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            // Snapshots must not be closed by whatever the user is clicking meanwhile.
            guard self?.authenticating != true, ProcessInfo.processInfo.environment["WA_SNAPSHOT"] == nil else { return }
            self?.closePanel()
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self, !self.authenticating else { return event }
            if !self.belongsToPanel(event.window), event.window !== self.statusItem.button?.window { self.closePanel() }
            return event
        }) { clickMonitors.append(local) }
    }

    /// Popovers and menus opened from inside the panel are part of it.
    private func belongsToPanel(_ window: NSWindow?) -> Bool {
        var current = window
        while let w = current {
            if w === panel { return true }
            current = w.parent
        }
        // Context menus live in windows with no parent chain to us.
        return window == nil || window?.className.contains("Menu") == true
    }

    private func closePanel() {
        clickMonitors.forEach(NSEvent.removeMonitor)
        clickMonitors.removeAll()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        statusItem.button?.highlight(false)
        panel.contentView = nil
    }

    // MARK: Snapshots

    /// WA_SNAPSHOT=<dir> (with WA_DEMO) renders the main window and the menu
    /// bar views to PNG files and quits, for checking layout without a screen.
    private func snapshotIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["WA_SNAPSHOT"], let store = model.active else { return }
        if ProcessInfo.processInfo.environment["WA_DARK"] != nil { NSApp.appearance = NSAppearance(named: .darkAqua) }
        let out = URL(fileURLWithPath: dir)
        // The window server's own picture of a window: the real rendering,
        // glass included. A process may capture its own windows without the
        // Screen Recording permission. The call is gone from the SDK headers
        // but still exported, hence the lookup by name.
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let capture = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage").map { unsafeBitCast($0, to: Capture.self) }
        func save(_ view: NSView, _ name: String) {
            let url = out.appendingPathComponent(name)
            if let window = view.window, let capture,
               let image = capture(.null, 1 << 3, UInt32(window.windowNumber), 1 << 0 | 1 << 3)?.takeRetainedValue(),
               image.width > 1 {
                try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
                return
            }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        if ProcessInfo.processInfo.environment["WA_EMPTY"] == nil { store.open(store.chats.first?.jid) }
        if ProcessInfo.processInfo.environment["WA_SPLIT"] != nil { store.splitChat = store.chats.dropFirst().first?.jid }
        DispatchQueue.main.asyncAfter(deadline: .now() + (Double(ProcessInfo.processInfo.environment["WA_DELAY"] ?? "") ?? 2)) { [self] in
            if let view = window.contentView?.superview { save(view, "main.png") }
            if ProcessInfo.processInfo.environment["WA_SWITCH"] != nil {
                // Step through the chats and capture after each, to compare
                // layouts. Chained rather than looped: the main queue has to
                // run between steps for a chat to load.
                let chats = Array(store.chats.prefix(4))
                func step(_ index: Int) {
                    guard index < chats.count else { exit(0) }
                    store.open(chats[index].jid)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
                        if let view = window.contentView?.superview { save(view, "switch-\(index).png") }
                        step(index + 1)
                    }
                }
                step(1)
                return
            }
            if let photo = ProcessInfo.processInfo.environment["WA_PHOTO"] {
                // Stage a picture and capture the send screen, then the viewer.
                store.attach([URL(fileURLWithPath: photo)])
                RunLoop.current.run(until: Date().addingTimeInterval(1.5))
                if let view = window.attachedSheet?.contentView { save(view, "photo.png") }
                exit(0)
            }
            if ProcessInfo.processInfo.environment["WA_SETUP"] != nil {
                model.showingSetup = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                    if let view = window.attachedSheet?.contentView { save(view, "setup.png") }
                    exit(0)
                }
                return
            }
            if ProcessInfo.processInfo.environment["WA_ATTACH"] != nil {
                if let popover = NSApp.windows.first(where: { $0 !== window && $0.isVisible && $0.className.contains("Popover") }),
                   let view = popover.contentView { save(view, "attach.png") }
                exit(0)
            }
            if ProcessInfo.processInfo.environment["WA_INFO"] != nil {
                if let view = window.attachedSheet?.contentView { save(view, "info.png") }
                exit(0)
            }
            openPanel()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [self] in
                if let view = panel.contentView { save(view, "menu.png") }
                closePanel()
                showSettings()
                RunLoop.current.run(until: Date().addingTimeInterval(1))
                if let view = window.attachedSheet?.contentView { save(view, "settings.png") }
                // An open sheet can hold up a polite terminate; nothing here needs one.
                exit(0)
            }
        }
    }

    // MARK: Paste

    /// ⌘V with a photo or a copied file on the pasteboard attaches it to the
    /// open chat instead of pasting nothing into the text field.
    private func installPasteMonitor() {
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let store = self.model.active,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  self.window.isKeyWindow, store.selected != nil, store.editing == nil else { return event }
            let images = Images.fromPasteboard()
            if !images.isEmpty {
                store.pendingPhotos = images
                return nil
            }
            // A file copied in Finder; plain text still pastes normally.
            let files = Attachments.fileURLs()
            if !files.isEmpty {
                store.attach(files)
                return nil
            }
            return event
        }
    }

    // MARK: Menu

    /// A code-built app needs its own Edit menu for ⌘C/⌘V/⌘A to reach text views.
    private static func makeMenu() -> NSMenu {
        let main = NSMenu()

        let app = NSMenu()
        app.addItem(withTitle: L("About WhatsApp Zen"), action: #selector(AppDelegate.showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: L("Settings…"), action: #selector(AppDelegate.showSettings), keyEquivalent: ",")
        app.addItem(.separator())
        app.addItem(withTitle: L("Hide"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: L("Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let edit = NSMenu(title: L("Edit menu"))
        edit.addItem(withTitle: L("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: L("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: L("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: L("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let win = NSMenu(title: L("Window"))
        win.addItem(withTitle: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        win.addItem(withTitle: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(.separator())
        win.addItem(withTitle: "WhatsApp", action: #selector(AppDelegate.showMainWindow), keyEquivalent: "0")

        let go = NSMenu(title: L("Go"))
        go.addItem(withTitle: L("Jump to a chat"), action: #selector(AppDelegate.showSwitcher), keyEquivalent: "k")
        go.addItem(withTitle: L("New Chat"), action: #selector(AppDelegate.showNewChat), keyEquivalent: "n")
        go.addItem(withTitle: L("Status"), action: #selector(AppDelegate.showStatus), keyEquivalent: "S")
        go.addItem(.separator())
        let previous = go.addItem(withTitle: L("Previous Chat"), action: #selector(AppDelegate.previousChat), keyEquivalent: String(UnicodeScalar(NSUpArrowFunctionKey)!))
        previous.keyEquivalentModifierMask = [.command, .option]
        let next = go.addItem(withTitle: L("Next Chat"), action: #selector(AppDelegate.nextChat), keyEquivalent: String(UnicodeScalar(NSDownArrowFunctionKey)!))
        next.keyEquivalentModifierMask = [.command, .option]
        go.addItem(.separator())
        for number in 1...9 {
            let item = go.addItem(withTitle: L("Chat %lld", number), action: #selector(AppDelegate.openNumberedChat(_:)), keyEquivalent: "\(number)")
            item.tag = number - 1
        }

        for menu in [app, edit, go, win] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = win
        return main
    }

    @objc func showMainWindow() { showWindow() }

    /// Opens a chat in a window of its own, next to the main one.
    func openChatWindow(_ chat: Chat, in store: AppStore) {
        let key = "\(store.id)/\(chat.jid)"
        if let existing = chatWindows[key] {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = chat.name
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 340, height: 380)
        let view = MenuChatView(chat: chat, openApp: { [weak self] jid in
            if let jid { store.openChecked(jid) }
            self?.showWindow()
        }, back: {}, mode: .window)
            .environmentObject(store)
            .environmentObject(model)
            .tint(Theme.accent)
        let hosting = NSHostingView(rootView: view)
        hosting.sizingOptions = []
        window.contentView = hosting
        window.center()
        window.setFrameAutosaveName("chat-\(key)")
        chatWindows[key] = window
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // Let go of the window's views when it closes.
            self?.chatWindows[key]?.contentView = nil
            self?.chatWindows[key] = nil
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func showSwitcher() {
        showWindow()
        model.showingSwitcher = true
    }

    @objc func showNewChat() {
        showWindow()
        model.showingNewChat = true
    }

    @objc func showStatus() {
        showWindow()
        model.showingStatus = true
    }

    @objc func previousChat() { model.stepChat(-1) }
    @objc func nextChat() { model.stepChat(1) }
    @objc func openNumberedChat(_ sender: NSMenuItem) { model.openChat(at: sender.tag) }

    @objc func showSettings() {
        showWindow()
        model.showingSettings = true
    }

    /// The standard About panel, with who made the app and where it lives.
    @objc func showAbout() {
        let credits = NSMutableAttributedString()
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .foregroundColor: NSColor.labelColor, .paragraphStyle: center,
        ]
        func line(_ text: String, link: URL? = nil) {
            var attributes = base
            if let link { attributes[.link] = link }
            credits.append(NSAttributedString(string: text, attributes: attributes))
        }
        line(L("Made by Mehmet Deniz Aydın") + "\n")
        line("mdenizay.com", link: Links.website)
        line("  ·  ")
        line(L("Source Code"), link: Links.source)
        line("  ·  ")
        line(L("Contributors"), link: Links.contributors)
        line("\n\n" + L("Built on whatsmeow by Tulir Asokan. Icon glyph from Simple Icons.") + "\n")
        line(L("An unofficial client. Not affiliated with WhatsApp or Meta."))
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "WhatsApp Zen", .credits: credits])
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Shows `content` for the active account, rebuilt when the account changes.
struct RootView<Content: View>: View {
    @EnvironmentObject var model: AppModel
    /// Observed so a change of accent colour or text size redraws everything.
    @ObservedObject private var prefs = Prefs.shared
    @ViewBuilder let content: () -> Content

    var body: some View {
        if model.locked {
            LockView()
        } else if let store = model.active {
            content().environmentObject(store).id(store.id)
        }
    }
}
