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
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var pane = Pane.general

    private enum Pane: CaseIterable {
        case general, appearance, notifications, privacy, storage, accounts, about

        var icon: String {
            switch self {
            case .general: return "gearshape"
            case .appearance: return "paintpalette"
            case .notifications: return "bell.badge"
            case .privacy: return "lock"
            case .storage: return "internaldrive"
            case .accounts: return "person.2"
            case .about: return "info.circle"
            }
        }

        var title: String {
            switch self {
            case .general: return L("General")
            case .appearance: return L("Appearance")
            case .privacy: return L("Privacy")
            case .storage: return L("Storage")
            case .notifications: return L("Notifications")
            case .accounts: return L("Accounts")
            case .about: return L("About")
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Panes down the side: seven of them do not fit across the top.
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Settings")).font(.headline).padding(.horizontal, 10).padding(.bottom, 8)
                ForEach(Pane.allCases, id: \.self) { item in
                    Button { pane = item } label: {
                        Label(item.title, systemImage: item.icon)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(pane == item ? AnyShapeStyle(Theme.accent.opacity(0.18)) : AnyShapeStyle(.clear),
                                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button(L("Done")) { model.showingSettings = false }
                    .keyboardShortcut(.defaultAction)
                    .padding(.horizontal, 10)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 8)
            .frame(width: 170)
            .background(.quaternary.opacity(0.4))
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .appearance: AppearanceSettings()
                case .privacy: PrivacySettings()
                case .storage: StorageSettings()
                case .notifications: NotificationSettings()
                case .accounts: AccountSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 600, height: 440)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
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
            Section(L("Language")) {
                Text(L("The app follows the language set for it in System Settings.")).foregroundStyle(.secondary)
                Button(L("Open Language Settings…")) { NSWorkspace.shared.open(Links.languageSettings) }
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
                Toggle(L("Message Preview"), isOn: $notifier.preview).disabled(!notifier.enabled)
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

    var body: some View {
        Menu {
            ForEach(AppStore.icons, id: \.self) { icon in
                Button { account.icon = icon } label: { Image(systemName: icon) }
            }
        } label: {
            Image(systemName: account.icon).font(.title3).foregroundStyle(Theme.accent).frame(width: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L("Icon"))
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
