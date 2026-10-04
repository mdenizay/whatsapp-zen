import AppKit
import AVFoundation
import SwiftUI

// MARK: Forward

/// Picks the chats to forward a message to.
struct ForwardSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let message: Message

    @State private var query = ""
    @State private var chosen = Set<String>()

    private var chats: [Chat] {
        query.isEmpty ? store.chats : store.chats.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Forward Message")).font(.headline)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Send")) {
                    store.forward(message, to: Array(chosen))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(chosen.isEmpty)
            }
            .padding(14)
            TextField(L("Search chats"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 10)
            List(chats) { chat in
                Button {
                    if !chosen.insert(chat.jid).inserted { chosen.remove(chat.jid) }
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: chosen.contains(chat.jid) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen.contains(chat.jid) ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        AvatarView(jid: chat.jid, name: chat.name, size: 30, tick: store.avatarTick)
                        Text(chat.name).lineLimit(1)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 400, height: 500)
    }
}

// MARK: Search and starred

/// A compact list of messages (search hits, starred) that jumps to one on click.
struct MessageResults: View {
    let messages: [Message]
    let empty: String
    let pick: (Message) -> Void

    var body: some View {
        if messages.isEmpty {
            Text(empty).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(messages) { message in
                Button { pick(message) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(message.fromMe ? L("You") : message.senderName).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(Format.listStamp(message.ts)) \(Format.time(message.date))").font(.caption).foregroundStyle(.secondary)
                        }
                        Text(message.plainText).lineLimit(3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct ChatSearchView: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    let close: () -> Void

    @State private var query = ""
    @State private var results: [Message] = []
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Search this chat"), text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .padding(10)
            MessageResults(messages: results, empty: query.isEmpty ? L("Type to search") : L("No results")) {
                store.reveal($0)
                close()
            }
        }
        .frame(width: 360, height: 420)
        .onAppear { focused = true }
        .task(id: query) {
            // Wait for a pause in typing before searching.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            results = query.isEmpty ? [] : await store.search(chat: chat.jid, text: query)
        }
    }
}

struct StarredView: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    let close: () -> Void

    @State private var results: [Message] = []

    var body: some View {
        VStack(spacing: 0) {
            Text(L("Starred Messages")).font(.headline).padding(10)
            MessageResults(messages: results, empty: L("No starred messages")) {
                store.reveal($0)
                close()
            }
        }
        .frame(width: 360, height: 420)
        .task { results = await store.starred(chat: chat.jid) }
    }
}

// MARK: Group info

struct GroupInfoSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var info: GroupInfo?
    @State private var name = ""
    @State private var error: String?
    @State private var busy = false
    @State private var adding = false
    @State private var confirmLeave = false
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AvatarView(jid: chat.jid, name: chat.name, size: 48, tick: store.avatarTick)
                VStack(alignment: .leading, spacing: 3) {
                    if info?.isAdmin == true {
                        TextField(L("Group name"), text: $name)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { run { try await store.groupRename(chat.jid, name: name) } }
                    } else {
                        Text(info?.name ?? chat.name).font(.title3.weight(.semibold))
                    }
                    if let info {
                        Text(L("%lld members", info.members.count)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)

            if let topic = info?.topic, !topic.isEmpty {
                Text(topic).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            if let info {
                List(info.members) { member in
                    HStack(spacing: 10) {
                        AvatarView(jid: member.jid, name: member.name, size: 30, tick: store.avatarTick)
                        Text(member.name).lineLimit(1)
                        Spacer()
                        if member.isAdmin {
                            Text(L("Admin")).font(.caption).foregroundStyle(Theme.accent)
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Theme.accent.opacity(0.15), in: Capsule())
                        }
                    }
                    .contextMenu {
                        if !member.isMe {
                            Button(L("Send Message")) {
                                Task { @MainActor in
                                    if await store.startChat(jid: member.jid) { dismiss() }
                                }
                            }
                            if info.isAdmin {
                                Divider()
                                if member.isAdmin {
                                    Button(L("Dismiss as Admin")) { update(member, "demote") }
                                } else {
                                    Button(L("Make Admin")) { update(member, "promote") }
                                }
                                Button(L("Remove from Group"), role: .destructive) { update(member, "remove") }
                            }
                        }
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                if info?.isAdmin == true {
                    Button(L("Add Member…"), systemImage: "person.badge.plus") { adding = true }
                    Button(copied ? L("Copied") : L("Invite Link"), systemImage: "link") {
                        run {
                            let link = try await store.groupLink(chat.jid)
                            MessageRow.copy(text: link)
                            copied = true
                        }
                    }
                }
                Spacer()
                Button(L("Leave Group"), role: .destructive) { confirmLeave = true }
            }
            .padding(14)
        }
        .frame(width: 440, height: 560)
        .disabled(busy)
        .task { await load() }
        .sheet(isPresented: $adding) {
            ContactPicker(title: L("Add Member")) { contact in
                run { try await store.groupUpdate(chat.jid, member: contact.jid, action: "add") }
            }
        }
        .confirmationDialog(L("Leave the group “%@”?", chat.name), isPresented: $confirmLeave) {
            Button(L("Leave Group"), role: .destructive) {
                run {
                    try await store.groupLeave(chat.jid)
                    dismiss()
                }
            }
        }
    }

    @MainActor private func load() async {
        do {
            let fresh = try await store.groupInfo(chat.jid)
            info = fresh
            name = fresh.name
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func update(_ member: GroupMember, _ action: String) {
        run { try await store.groupUpdate(chat.jid, member: member.jid, action: action) }
    }

    /// Runs a group change, then reloads the member list.
    private func run(_ work: @escaping () async throws -> Void) {
        busy = true
        error = nil
        Task { @MainActor in
            do { try await work() } catch { self.error = error.localizedDescription }
            busy = false
            await load()
        }
    }
}

/// Picks one address-book contact.
struct ContactPicker: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let title: String
    let pick: (Contact) -> Void

    @State private var contacts: [Contact] = []
    @State private var query = ""

    private var matches: [Contact] {
        query.isEmpty ? contacts : contacts.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            TextField(L("Search contacts"), text: $query).textFieldStyle(.roundedBorder).padding(.horizontal, 14).padding(.bottom, 10)
            List(matches) { contact in
                Button {
                    pick(contact)
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        AvatarView(jid: contact.jid, name: contact.name, size: 30)
                        Text(contact.name)
                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 380, height: 460)
        .task { contacts = await store.contacts() }
    }
}

// MARK: Voice messages

/// Records a voice message as Opus in a CAF file; the core re-wraps it as the
/// Ogg file WhatsApp expects.
final class VoiceRecorder: NSObject, ObservableObject {
    @Published private(set) var recording = false
    @Published private(set) var seconds = 0
    @Published var error: String?

    private var recorder: AVAudioRecorder?
    private var timer: Timer?

    func start() {
        error = nil
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                if granted {
                    self.begin()
                } else {
                    self.error = L("No microphone access. Allow it in System Settings → Privacy & Security → Microphone.")
                }
            }
        }
    }

    private func begin() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wa-voice-\(UUID().uuidString).caf")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatOpus, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32000,
        ]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings), recorder.record() else {
            error = L("Could not start recording.")
            return
        }
        self.recorder = recorder
        recording = true
        seconds = 0
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder else { return }
            self.seconds = Int(r.currentTime)
        }
    }

    /// Stops and returns the recording, or nil if it is too short to send.
    func finish() -> (url: URL, seconds: Int)? {
        guard let recorder else { return nil }
        let length = recorder.currentTime
        let url = recorder.url
        reset()
        guard length >= 0.5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return (url, max(1, Int(length.rounded())))
    }

    func cancel() {
        let url = recorder?.url
        reset()
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func reset() {
        timer?.invalidate()
        timer = nil
        recorder?.stop()
        recorder = nil
        recording = false
        seconds = 0
    }
}
