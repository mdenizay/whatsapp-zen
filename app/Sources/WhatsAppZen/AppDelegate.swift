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

        model.objectWillChange
            .receive(on: DispatchQueue.main)
            .map { [model] in model.totalUnread }
            .removeDuplicates()
            .sink { [weak self] unread in self?.showUnread(unread) }
            .store(in: &subscriptions)
        model.incoming
            .sink { Notifier.shared.post(account: $0.account, chat: $0.chat, chatName: $0.chatName, message: $0.message) }
            .store(in: &subscriptions)

        model.start()
        Updater.shared.start()
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

    func applicationDidResignActive(_ notification: Notification) { model.appActiveChanged() }

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
        let hosting = NSHostingView(rootView: RootView { MainView() }.environmentObject(model))
        // Don't let the (initially empty) SwiftUI content dictate the window size.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("main")
    }

    func showWindow() {
        closePanel()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.windowVisible = true
    }

    func windowWillClose(_ notification: Notification) { model.windowVisible = false }
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
            panel.contentView = backing
            return
        }
        let glass = NSGlassEffectView(frame: NSRect(origin: .zero, size: Self.panelSize))
        glass.cornerRadius = 24
        glass.contentView = NSHostingView(rootView: content)
        panel.contentView = glass
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
        panel.setFrame(NSRect(origin: NSPoint(x: x, y: y), size: Self.panelSize), display: true)
        panel.makeKeyAndOrderFront(nil)
        button.highlight(true)

        // Any click outside dismisses it: in another app (global) or in one of
        // our own windows (local).
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            self?.closePanel()
        }) { clickMonitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            guard let self else { return event }
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
    }

    // MARK: Snapshots

    /// WA_SNAPSHOT=<dir> (with WA_DEMO) renders the main window and the menu
    /// bar views to PNG files and quits, for checking layout without a screen.
    private func snapshotIfRequested() {
        guard let dir = ProcessInfo.processInfo.environment["WA_SNAPSHOT"], let store = model.active else { return }
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
        store.open(store.chats.first?.jid)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
            if let view = window.contentView?.superview { save(view, "main.png") }
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
            if let image = Images.fromPasteboard().first {
                store.pendingFile = nil
                store.pendingImage = image
                return nil
            }
            // A file copied in Finder; plain text still pastes normally.
            if let url = Attachments.fileURLs().first {
                store.attach(url)
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

        for menu in [app, edit, win] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.windowsMenu = win
        return main
    }

    @objc func showMainWindow() { showWindow() }

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
    @ViewBuilder let content: () -> Content

    var body: some View {
        if let store = model.active {
            content().environmentObject(store).id(store.id)
        }
    }
}
