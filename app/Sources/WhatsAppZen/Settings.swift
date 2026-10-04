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
        case general, notifications, accounts, about

        var title: String {
            switch self {
            case .general: return L("General")
            case .notifications: return L("Notifications")
            case .accounts: return L("Accounts")
            case .about: return L("About")
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Settings")).font(.headline)
                Spacer()
                Button(L("Done")) { model.showingSettings = false }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .top], 16)
            Picker(L("Settings"), selection: $pane) {
                ForEach(Pane.allCases, id: \.self) { Text($0.title) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.top, 12)
            Group {
                switch pane {
                case .general: GeneralSettings()
                case .notifications: NotificationSettings()
                case .accounts: AccountSettings()
                case .about: AboutSettings()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 430)
        .tint(Theme.accent)
    }
}

private struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Form {
            if let store = model.active {
                Toggle(L("Open at Login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
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
                        AvatarView(jid: account.me, name: account.label, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.label)
                            Text(account.me.isEmpty ? L("Not paired") : (account.state == "connected" ? L("Connected") : L("Connecting…")))
                                .font(.caption).foregroundStyle(.secondary)
                        }
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
