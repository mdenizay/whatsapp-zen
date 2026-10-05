import AppKit
import SwiftUI

/// Where the project lives; shown in Settings → About and the About panel.
enum Links {
    static let website = URL(string: "https://mdenizay.com")!
    static let source = URL(string: "https://github.com/mdenizay/whatsapp-zen")!
    static let contributors = URL(string: "https://github.com/mdenizay/whatsapp-zen/graphs/contributors")!
    static let languageSettings = URL(string: "x-apple.systempreferences:com.apple.Localization-Settings.extension")!

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }
}

/// Settings, shown as a sheet on the main window (⌘, or the sidebar gear).
/// One short pane per subject, picked from a list at the side.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    /// WA_PANE=<index> (demo snapshots) starts on that pane.
    @State private var pane = Pane.allCases[min(Int(ProcessInfo.processInfo.environment["WA_PANE"] ?? "") ?? 0, Pane.allCases.count - 1)]

    private enum Pane: CaseIterable {
        case general, appearance, chats, notifications, privacy, storage, accounts, about

        var title: String {
            switch self {
            case .general: return L("General")
            case .appearance: return L("Appearance")
            case .chats: return L("Chats")
            case .notifications: return L("Notifications")
            case .privacy: return L("Privacy")
            case .storage: return L("Storage")
            case .accounts: return L("Accounts")
            case .about: return L("About")
            }
        }

        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .appearance: return "paintpalette.fill"
            case .chats: return "bubble.left.and.bubble.right.fill"
            case .notifications: return "bell.badge.fill"
            case .privacy: return "lock.fill"
            case .storage: return "internaldrive.fill"
            case .accounts: return "person.2.fill"
            case .about: return "info.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .general: return Color(light: 0x8E8E93, dark: 0x98989D)
            case .appearance: return Color(light: 0x8E5BE8, dark: 0xA982F5)
            case .chats: return Color(light: 0x1DAA61, dark: 0x25C46B)
            case .notifications: return Color(light: 0xEB5757, dark: 0xF07C7C)
            case .privacy: return Color(light: 0x2F80ED, dark: 0x5A9DF5)
            case .storage: return Color(light: 0xF2994A, dark: 0xF5AD6E)
            case .accounts: return Color(light: 0x00A3A3, dark: 0x2CC7C7)
            case .about: return Color(light: 0x8E8E93, dark: 0x98989D)
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Pane.allCases, id: \.self) { item in
                    Button { pane = item } label: {
                        HStack(spacing: 9) {
                            Image(systemName: item.icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                                .frame(width: 22, height: 22)
                                .background(item.color.gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            Text(item.title)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(pane == item ? AnyShapeStyle(.primary.opacity(0.1)) : AnyShapeStyle(.clear),
                                    in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(10)
            .frame(width: 176)
            .background(.quaternary.opacity(0.35))

            VStack(spacing: 0) {
                HStack {
                    Text(pane.title).font(.title3.weight(.semibold))
                    Spacer()
                    Button(L("Done")) { model.showingSettings = false }.keyboardShortcut(.defaultAction)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                .padding(.bottom, 4)
                Group {
                    switch pane {
                    case .general: GeneralSettings()
                    case .appearance: AppearanceSettings()
                    case .chats: ChatSettings()
                    case .notifications: NotificationSettings()
                    case .privacy: PrivacySettings()
                    case .storage: StorageSettings()
                    case .accounts: AccountSettings()
                    case .about: AboutSettings()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 660, height: 470)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var updater = Updater.shared

    private var updateStatus: String {
        switch updater.state {
        case .idle: return L("Version %@", Links.version)
        case .checking: return L("Checking for updates…")
        case .upToDate: return L("You're up to date.") + " " + L("Version %@", Links.version)
        case .downloading(let version): return L("Downloading %@…", version)
        case .ready(let version): return L("Version %@ is ready to install.", version)
        case .failed(let reason): return L("Update failed: %@", reason)
        }
    }

    var body: some View {
        Form {
            if let store = model.active {
                Toggle(L("Open at Login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
            if updater.available {
                Section(L("Updates")) {
                    Toggle(L("Update automatically"), isOn: $updater.automatic)
                    HStack {
                        Text(updateStatus).foregroundStyle(.secondary)
                        Spacer()
                        if case .ready = updater.state {
                            Button(L("Restart to Update")) { updater.installAndRelaunch() }
                        } else {
                            Button(L("Check Now")) { updater.check() }
                                .disabled(updater.state == .checking)
                        }
                    }
                }
            }
            Section {
                Toggle(L("Show unread count in the menu bar"), isOn: $prefs.menuBarCount)
            }
            Section(L("Language")) {
                Text(L("The app follows the language set for it in System Settings.")).foregroundStyle(.secondary)
                Button(L("Open Language Settings…")) { NSWorkspace.shared.open(Links.languageSettings) }
            }
            Section {
                Button(L("Run Setup Again…")) {
                    model.showingSettings = false
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { model.showingSetup = true }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct NotificationSettings: View {
    @ObservedObject private var notifier = Notifier.shared
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            if !notifier.permitted {
                Section {
                    Label(L("Notifications are blocked in macOS."), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Button(L("Allow in macOS…")) { notifier.openSystemSettings() }
                }
            }
            Section {
                NotificationSample(style: notifier.content, photo: notifier.photo)
                Picker(L("Banners show"), selection: $notifier.content) {
                    Text(L("Name and message")).tag("full")
                    Text(L("Name only")).tag("name")
                    Text(L("Nothing")).tag("hidden")
                }
                Toggle(L("Show profile photo"), isOn: $notifier.photo).disabled(notifier.content == "hidden")
            } header: {
                Text(L("Banner"))
            } footer: {
                Text(L("Locked chats, and every chat while the app is locked, always show nothing."))
            }
            .disabled(!notifier.enabled)
            Section {
                Toggle(L("Show Notifications"), isOn: $notifier.enabled)
                Toggle(L("Play Sound"), isOn: $notifier.sound).disabled(!notifier.enabled)
                Picker(L("Notification Sound"), selection: $notifier.soundName) {
                    Text(L("Default")).tag("")
                    Divider()
                    ForEach(Notifier.systemSounds, id: \.self) { Text($0).tag($0) }
                }
                .disabled(!notifier.enabled || !notifier.sound)
                .onChange(of: notifier.soundName) { _, name in
                    // Let the choice be heard.
                    if !name.isEmpty { NSSound(named: name)?.play() }
                }
            }
            if !notifier.chatSounds.isEmpty {
                Section {
                    ForEach(notifier.chatSounds.keys.sorted(), id: \.self) { key in
                        HStack {
                            Text(chatName(for: key)).lineLimit(1)
                            Spacer()
                            Text(notifier.chatSounds[key] == "none" ? L("Silent") : (notifier.chatSounds[key] ?? "")).foregroundStyle(.secondary)
                            Button(L("Remove")) {
                                let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
                                if parts.count == 2 { notifier.setChatSound(nil, account: parts[0], chat: parts[1]) }
                            }
                            .buttonStyle(.link)
                        }
                    }
                } header: {
                    Text(L("Chats with their own sound"))
                } footer: {
                    Text(L("Set a chat's sound from its info panel."))
                }
            }
            Section {
                permission(L("Notifications allowed"), notifier.permitted)
                row(L("Style"), notifier.system.style == "alerts" ? L("Alerts") : notifier.system.style == "banners" ? L("Banners") : L("None"),
                    ok: notifier.system.style != "none")
                permission(L("Sound"), notifier.system.sound)
                permission(L("Notification Centre"), notifier.system.center)
                permission(L("Lock Screen"), notifier.system.lockScreen)
                permission(L("Badges"), notifier.system.badge)
                row(L("Previews"), notifier.system.previews == "never" ? L("Never") : notifier.system.previews == "unlocked" ? L("When unlocked") : L("Always"),
                    ok: notifier.system.previews != "never")
                Button(L("Change in System Settings…")) { notifier.openSystemSettings() }
            } header: {
                Text(L("What macOS allows"))
            } footer: {
                Text(L("These are set in System Settings and limit everything above."))
            }
            Section(L("Do Not Disturb")) {
                if prefs.paused {
                    HStack {
                        Text(L("Notifications are paused until %@.", Format.time(prefs.pauseUntil)))
                        Spacer()
                        Button(L("Resume")) { prefs.pauseUntil = .distantPast }
                    }
                } else {
                    HStack {
                        Text(L("Pause notifications"))
                        Spacer()
                        Button(L("1 hour")) { prefs.pauseUntil = Date().addingTimeInterval(3600) }
                        Button(L("8 hours")) { prefs.pauseUntil = Date().addingTimeInterval(8 * 3600) }
                        Button(L("Until tomorrow")) {
                            prefs.pauseUntil = Calendar.current.startOfDay(for: Date().addingTimeInterval(86400)).addingTimeInterval(8 * 3600)
                        }
                    }
                }
            }
            Section {
                Button(L("Send Test Notification")) { notifier.postTest() }
                Button(L("System Notification Settings…")) { notifier.openSystemSettings() }
            }
        }
        .formStyle(.grouped)
        .onAppear { notifier.refresh() }
        // Back from System Settings: show what was changed there.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in notifier.refresh() }
    }

    private func permission(_ title: String, _ on: Bool) -> some View {
        row(title, on ? L("On") : L("Off"), ok: on)
    }

    private func row(_ title: String, _ value: String, ok: Bool) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? AnyShapeStyle(.green) : AnyShapeStyle(.orange))
            Text(title)
            Spacer()
            Text(value).foregroundStyle(.secondary)
        }
    }

    /// The chat behind an "account/jid" key, by name where it is known.
    private func chatName(for key: String) -> String {
        let parts = key.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return key }
        let chat = AppModel.shared.accounts.first { $0.id == parts[0] }?.chats.first { $0.jid == parts[1] }
        return chat?.name ?? parts[1]
    }
}

/// A small picture of a banner with the chosen options.
private struct NotificationSample: View {
    let style: String
    let photo: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(style == "hidden" ? "WhatsApp" : "Emma Wilson").font(.callout.weight(.semibold))
                Text(style == "full" ? L("Does 8 pm work for you?") : L("New message")).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if photo, style != "hidden" {
                Circle().fill(LinearGradient(colors: [.purple.opacity(0.5), .purple.opacity(0.25)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 32, height: 32)
                    .overlay(Text("EW").font(.caption.weight(.semibold)).foregroundStyle(.purple))
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AccountSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var leaving: AppStore?

    var body: some View {
        Form {
            Section {
                ForEach(model.accounts) { account in
                    HStack(spacing: 10) {
                        AccountRowEditor(account: account)
                        Spacer()
                        if account.id == model.activeID {
                            Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                        } else {
                            Button(L("Switch account")) { model.activate(account.id) }
                        }
                        Button(L("Log Out"), role: .destructive) { leaving = account }
                    }
                }
            }
            Section {
                Button(L("Add Account…"), systemImage: "plus") {
                    model.showingSettings = false
                    model.addAccount()
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(L("Log out of %@?", leaving?.label ?? ""), isPresented: Binding(get: { leaving != nil }, set: { if !$0 { leaving = nil } })) {
            Button(L("Log Out"), role: .destructive) {
                leaving?.logout()
                leaving = nil
            }
        } message: {
            Text(L("The chat history on this Mac will be deleted. Messages on your phone are not affected."))
        }
    }
}

/// Icon and name of one account, editable in place.
private struct AccountRowEditor: View {
    @ObservedObject var account: AppStore
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            Image(systemName: account.icon).font(.title3).foregroundStyle(Theme.accent)
                .frame(width: 34, height: 34)
                .background(Theme.accent.opacity(0.14), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(L("Icon"))
        .popover(isPresented: $picking, arrowEdge: .bottom) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(38), spacing: 6), count: 6), spacing: 6) {
                ForEach(AppStore.icons, id: \.self) { icon in
                    Button {
                        account.icon = icon
                        picking = false
                    } label: {
                        Image(systemName: icon).font(.system(size: 16))
                            .foregroundStyle(account.icon == icon ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                            .frame(width: 38, height: 38)
                            .background(account.icon == icon ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary),
                                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(12)
        }
        VStack(alignment: .leading, spacing: 1) {
            TextField(L("Name"), text: $account.nickname, prompt: Text(account.phone.isEmpty ? L("New account") : account.phone))
                .textFieldStyle(.plain)
                .labelsHidden()
            Text(account.me.isEmpty ? L("Not paired")
                : account.phone + " · " + (account.state == "connected" ? L("Connected") : L("Connecting…")))
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("WhatsApp Zen").font(.title2.weight(.semibold))
            Text(L("Version %@", Links.version)).foregroundStyle(.secondary)
            Text(L("Made by Mehmet Deniz Aydın"))
            HStack(spacing: 14) {
                Link("mdenizay.com", destination: Links.website)
                Link(L("Source Code"), destination: Links.source)
                Link(L("Contributors"), destination: Links.contributors)
            }
            VStack(spacing: 3) {
                Text(L("Built on whatsmeow by Tulir Asokan. Icon glyph from Simple Icons."))
                Text(L("An unofficial client. Not affiliated with WhatsApp or Meta."))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
