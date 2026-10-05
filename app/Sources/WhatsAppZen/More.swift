import AppKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Quick switcher (⌘K)

struct QuickSwitcher: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var focused: Bool

    private var matches: [Chat] {
        let all = store.chats.filter { !$0.archived }
        return Array((query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) }).prefix(12))
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField(L("Jump to a chat"), text: $query)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(14)
                .focused($focused)
                .onSubmit { if let first = matches.first { pick(first) } }
            Divider()
            List(matches) { chat in
                Button { pick(chat) } label: {
                    HStack(spacing: 10) {
                        AvatarView(jid: chat.jid, name: chat.name, size: 28, tick: store.avatarTick)
                        Text(chat.name).lineLimit(1)
                        Spacer()
                        if chat.unread > 0 { UnreadBadge(count: chat.unread) }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)
        }
        .frame(width: 440, height: 380)
        .onAppear { focused = true }
        .onExitCommand { dismiss() }
    }

    private func pick(_ chat: Chat) {
        dismiss()
        store.openChecked(chat.jid)
    }
}

// MARK: Link preview

struct LinkCard: View {
    let message: Message
    let onBubble: Bool

    private var url: URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: message.text, range: NSRange(message.text.startIndex..., in: message.text))?.url
    }

    var body: some View {
        Button {
            if let url { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 9) {
                if let image = Images.thumbnail(base64: message.thumb) {
                    Image(nsImage: image).resizable().scaledToFill()
                        .frame(width: 54, height: 54)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(message.linkTitle ?? "").font(.callout.weight(.semibold)).lineLimit(2)
                    if let desc = message.linkDesc, !desc.isEmpty {
                        Text(desc).font(.caption).lineLimit(2).opacity(0.8)
                    }
                    if let host = url?.host() {
                        Text(host).font(.caption2).opacity(0.65)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(7)
            .frame(maxWidth: 320, alignment: .leading)
            .background(onBubble ? .black.opacity(0.14) : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: Polls

struct PollView: View {
    @EnvironmentObject var store: AppStore
    let message: Message
    let poll: Poll
    let onBubble: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(message.text, systemImage: "chart.bar.fill").font(.callout.weight(.semibold))
            ForEach(poll.options) { option in
                Button { store.vote(message, option: option.name) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Image(systemName: option.mine ? "checkmark.circle.fill" : "circle")
                            Text(option.name).lineLimit(2)
                            Spacer(minLength: 8)
                            Text("\(option.votes)").monospacedDigit().opacity(0.8)
                        }
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(onBubble ? .white.opacity(0.25) : .primary.opacity(0.12))
                                Capsule().fill(onBubble ? .white : Theme.accent)
                                    .frame(width: geo.size.width * (poll.voters > 0 ? CGFloat(option.votes) / CGFloat(poll.voters) : 0))
                            }
                        }
                        .frame(height: 4)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(width: 250, alignment: .leading)
    }
}

struct PollComposer: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat

    @State private var question = ""
    @State private var options = ["", "", ""]

    private var filled: [String] {
        options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("New Poll")).font(.headline)
            TextField(L("Question"), text: $question).textFieldStyle(.roundedBorder)
            ForEach(options.indices, id: \.self) { index in
                TextField(L("Option"), text: $options[index]).textFieldStyle(.roundedBorder)
            }
            Button(L("Add Option"), systemImage: "plus") { options.append("") }
                .buttonStyle(.link)
                .disabled(options.count >= 12)
            HStack {
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Send")) {
                    store.sendPoll(question: question, options: filled, to: chat.jid)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(question.trimmingCharacters(in: .whitespaces).isEmpty || filled.count < 2)
            }
        }
        .padding(18)
        .frame(width: 380)
    }
}

// MARK: Stickers

/// Stickers to send: favourites first, then the ones seen recently, plus a
/// way to make a new one out of any picture.
struct StickerPicker: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat
    let close: () -> Void

    @State private var stickers: [Message] = []
    @State private var loaded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Stickers")).font(.headline)
                Spacer()
                Button(L("Create from Image…"), systemImage: "plus") { create() }
            }
            .padding(10)
            Divider()
            if stickers.isEmpty {
                Text(loaded ? L("Stickers you receive show up here.") : L("Loading…"))
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
            } else {
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(72)), count: 4), spacing: 8) {
                        ForEach(stickers) { sticker in
                            StickerCell(message: sticker) {
                                store.sendSticker(sticker, to: chat.jid)
                                close()
                            }
                            .overlay(alignment: .topTrailing) {
                                if sticker.starred {
                                    Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow).shadow(radius: 1)
                                }
                            }
                            .contextMenu {
                                Button(sticker.starred ? L("Remove from Favorites") : L("Add to Favorites"),
                                       systemImage: sticker.starred ? "star.slash" : "star") {
                                    store.star(sticker, !sticker.starred)
                                    Task { @MainActor in
                                        try? await Task.sleep(for: .milliseconds(400))
                                        stickers = await store.stickers()
                                    }
                                }
                            }
                        }
                    }
                    .padding(10)
                }
            }
        }
        .frame(width: 340, height: 360)
        .task {
            stickers = await store.stickers()
            loaded = true
        }
    }

    /// Picks a picture, fits it on a transparent 512-pixel square and sends
    /// it as a sticker.
    private func create() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        guard panel.runModal() == .OK, let url = panel.url, let png = Self.squarePNG(url) else { return }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("wa-sticker-\(UUID().uuidString).png")
        guard (try? png.write(to: file)) != nil else { return }
        store.run("send_sticker_image", ["chat": chat.jid, "path": file.path])
        close()
    }

    static func squarePNG(_ url: URL, side: Int = 512) -> Data? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: side,
              ] as CFDictionary),
              let ctx = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Centred, keeping its proportions; the rest stays transparent.
        ctx.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2, width: image.width, height: image.height))
        guard let square = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: square).representation(using: .png, properties: [:])
    }
}

private struct StickerCell: View {
    let message: Message
    let pick: () -> Void
    @State private var image: NSImage?

    var body: some View {
        Button(action: pick) {
            ZStack {
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    RoundedRectangle(cornerRadius: 8).fill(.quaternary)
                }
            }
            .frame(width: 72, height: 72)
        }
        .buttonStyle(.plain)
        .task {
            let path: String? = (message.mediaPath?.isEmpty == false) ? message.mediaPath
                : try? await Core.call("download", ["chat": message.chat, "id": message.id])
            if let path { image = await Images.load(path: path, maxPixel: 160) }
        }
    }
}

// MARK: Status

/// Status updates of the last 24 hours, grouped by person.
struct StatusSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var statuses: [Message] = []
    @State private var loaded = false

    private var people: [(jid: String, name: String, items: [Message])] {
        Dictionary(grouping: statuses, by: \.sender)
            .map { (jid: $0.key, name: $0.value.first?.fromMe == true ? L("You") : ($0.value.first?.senderName ?? ""), items: $0.value) }
            .sorted { ($0.items.last?.ts ?? 0) > ($1.items.last?.ts ?? 0) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(L("Status")).font(.headline)
                Spacer()
                Button(L("Close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
            if statuses.isEmpty {
                Text(loaded ? L("No status updates in the last 24 hours.") : L("Loading…"))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(people, id: \.jid) { person in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(spacing: 8) {
                                    AvatarView(jid: person.jid, name: person.name, size: 28, tick: store.avatarTick)
                                    Text(person.name).fontWeight(.semibold)
                                    Text(Format.time(person.items.last?.date ?? Date())).font(.caption).foregroundStyle(.secondary)
                                }
                                ForEach(person.items) { item in
                                    MessageRow(store: store, message: item, showSender: false, endsGroup: true, highlighted: false, maxWidth: 360,
                                               actions: MessageActions(reply: { _ in }, preview: { store.previewURL = URL(fileURLWithPath: $0) },
                                                       view: { item in
                                                           dismiss()
                                                           store.view(item, among: statuses)
                                                       }))
                                }
                            }
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(width: 460, height: 560)
        .task {
            statuses = await store.statuses()
            loaded = true
        }
    }
}

// MARK: Chat info

/// About a contact or group: settings for the chat and what was shared in it.
struct ChatInfoSheet: View {
    @EnvironmentObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let chat: Chat
    /// Opens member management for groups.
    let manageGroup: () -> Void

    @State private var info: UserInfo?
    @State private var kind = ProcessInfo.processInfo.environment["WA_INFO"] ?? "media"
    @State private var items: [Message] = []
    @State private var loading = true

    private var current: Chat { store.chats.first { $0.jid == chat.jid } ?? chat }

    private static let timers: [(String, Int)] = [("Off", 0), ("24 hours", 86400), ("7 days", 604_800), ("90 days", 7_776_000)]

    var body: some View {
        VStack(spacing: 0) {
            header
            actions
            Picker(L("Shared"), selection: $kind) {
                Text(L("Media")).tag("media")
                Text(L("Documents")).tag("docs")
                Text(L("Links")).tag("links")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 280)
            .padding(.bottom, 8)
            shared
        }
        .frame(width: 440, height: 580)
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                    .frame(width: 22, height: 22).background(.quaternary.opacity(0.7), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .padding(12)
            .help(L("Close"))
        }
        .task { if !chat.isGroup { info = await store.userInfo(chat.jid) } }
        .task(id: kind) {
            loading = true
            items = await store.media(chat: chat.jid, kind: kind)
            loading = false
        }
    }

    private var header: some View {
        VStack(spacing: 6) {
            AvatarView(jid: chat.jid, name: chat.name, size: 72, tick: store.avatarTick)
                .padding(.bottom, 4)
            Text(chat.name).font(.title3.weight(.semibold)).lineLimit(1)
            if !chat.isGroup {
                Text("+" + (chat.jid.split(separator: "@").first ?? "")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if let about = info?.about, !about.isEmpty {
                Text(about).font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).lineLimit(2)
            }
        }
        .padding(.top, 24)
        .padding(.horizontal, 30)
    }

    private var actions: some View {
        HStack(spacing: 18) {
            Menu {
                if current.muted {
                    Button(L("Unmute")) { store.mute(current, seconds: 0) }
                } else {
                    Button(L("8 hours")) { store.mute(current, seconds: 8 * 3600) }
                    Button(L("1 week")) { store.mute(current, seconds: 7 * 86400) }
                    Button(L("Always")) { store.mute(current, seconds: -1) }
                }
            } label: {
                InfoTile(title: current.muted ? L("Muted") : L("Mute"), icon: current.muted ? "bell.slash.fill" : "bell", active: current.muted)
            }
            .tileMenu()
            Menu {
                ForEach(Self.timers, id: \.1) { title, seconds in
                    Button {
                        store.setDisappearing(current, seconds: seconds)
                    } label: {
                        Label(L(title), systemImage: current.ephemeral == seconds ? "checkmark" : "timer")
                    }
                }
            } label: {
                InfoTile(title: L("Disappearing"), icon: "timer", active: current.ephemeral > 0)
            }
            .tileMenu()
            Button { store.setLocked(chat.jid, !store.isLocked(chat.jid)) } label: {
                InfoTile(title: store.isLocked(chat.jid) ? L("Locked") : L("Lock"),
                         icon: store.isLocked(chat.jid) ? "lock.fill" : "lock.open", active: store.isLocked(chat.jid))
            }
            .buttonStyle(.plain)
            Button { store.export(chat) } label: {
                InfoTile(title: L("Export"), icon: "square.and.arrow.up", active: false)
            }
            .buttonStyle(.plain)
            if chat.isGroup {
                Button {
                    dismiss()
                    manageGroup()
                } label: {
                    InfoTile(title: L("Members"), icon: "person.2", active: false)
                }
                .buttonStyle(.plain)
            } else if let info {
                Button {
                    Task { @MainActor in
                        await store.block(chat.jid, !info.blocked)
                        self.info = await store.userInfo(chat.jid)
                    }
                } label: {
                    InfoTile(title: info.blocked ? L("Unblock") : L("Block"), icon: "hand.raised", active: info.blocked, danger: true)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 16)
    }

    @ViewBuilder private var shared: some View {
        if items.isEmpty {
            VStack(spacing: 8) {
                if loading {
                    ProgressView()
                } else {
                    Image(systemName: kind == "media" ? "photo.on.rectangle" : kind == "docs" ? "doc" : "link")
                        .font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text(L("Nothing here yet")).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if kind == "media" {
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 4), spacing: 4) {
                    ForEach(items) { item in
                        MediaTile(message: item) {
                            // Photos and videos open in the viewer, over the chat.
                            dismiss()
                            store.view(item, among: items.reversed())
                        }
                            .contextMenu { Button(L("Show in Chat"), systemImage: "bubble.left") { reveal(item) } }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(items) { item in
                        SharedRow(message: item, isLink: kind == "links",
                                  who: item.fromMe ? L("You") : (item.senderName.isEmpty ? chat.name : item.senderName),
                                  open: { kind == "links" ? openLink(item) : open(item) }, reveal: { reveal(item) })
                        if item.id != items.last?.id { Divider().padding(.leading, 62).opacity(0.5) }
                    }
                }
                .padding(.vertical, 6)
            }
        }
    }

    /// Fetches the file if needed and shows it in Quick Look.
    private func open(_ message: Message) {
        Task { @MainActor in
            var path = message.mediaPath ?? ""
            if path.isEmpty || !FileManager.default.fileExists(atPath: path) {
                path = (try? await Core.call("download", ["chat": message.chat, "id": message.id])) ?? ""
            }
            if !path.isEmpty { store.previewURL = URL(fileURLWithPath: path) }
        }
    }

    private func openLink(_ message: Message) {
        if let url = SharedRow.firstURL(in: message.text) { NSWorkspace.shared.open(url) }
    }

    private func reveal(_ message: Message) {
        dismiss()
        store.reveal(message)
    }
}

/// One of the actions under the header: a soft round icon with a caption.
private struct InfoTile: View {
    let title: String
    let icon: String
    let active: Bool
    var danger = false

    @State private var hovering = false

    private var tint: Color { danger ? .red : Theme.accent }

    var body: some View {
        VStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium))
                .foregroundStyle(active ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
                .frame(width: 38, height: 38)
                .background(active ? AnyShapeStyle(tint) : AnyShapeStyle(tint.opacity(hovering ? 0.2 : 0.12)), in: Circle())
            Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(width: 62)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}

private extension View {
    /// A menu that looks like its label and nothing more.
    func tileMenu() -> some View {
        menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
    }
}

/// A shared document or link.
private struct SharedRow: View {
    let message: Message
    let isLink: Bool
    let who: String
    let open: () -> Void
    let reveal: () -> Void

    @State private var hovering = false

    static func firstURL(in text: String) -> URL? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) else { return nil }
        return detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))?.url
    }

    private var title: String {
        if isLink {
            if let title = message.linkTitle, !title.isEmpty { return title }
            return Self.firstURL(in: message.text)?.absoluteString ?? message.text
        }
        return message.fileName ?? L("Document")
    }

    private var detail: String {
        let when = Format.stamp(message.ts)
        if isLink, let host = Self.firstURL(in: message.text)?.host() { return "\(host) · \(who) · \(when)" }
        return "\(who) · \(when)"
    }

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Group {
                    if isLink {
                        if let image = Images.thumbnail(base64: message.thumb) {
                            Image(nsImage: image).resizable().scaledToFill()
                        } else {
                            Image(systemName: "link").font(.title3).foregroundStyle(Theme.accent)
                                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.accent.opacity(0.14))
                        }
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: UTType(filenameExtension: (title as NSString).pathExtension) ?? .data))
                            .resizable().scaledToFit()
                    }
                }
                .frame(width: 38, height: 38)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                if hovering {
                    Button(action: reveal) { Image(systemName: "bubble.left") }
                        .buttonStyle(.borderless)
                        .help(L("Show in Chat"))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(hovering ? AnyShapeStyle(.primary.opacity(0.05)) : AnyShapeStyle(.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu { Button(L("Show in Chat"), systemImage: "bubble.left", action: reveal) }
    }
}

private struct MediaTile: View {
    let message: Message
    let pick: () -> Void

    @State private var image: NSImage?

    var body: some View {
        Button(action: pick) {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if let image {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary.opacity(0.6))
                        Image(systemName: message.type == "video" ? "video" : "photo").foregroundStyle(.tertiary)
                    }
                }
                .overlay {
                    if message.type == "video", image != nil {
                        Image(systemName: "play.fill").font(.callout).foregroundStyle(.white).shadow(radius: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .task(id: message.id) {
            // Not every message carries an embedded thumbnail; a photo already
            // on disk can stand in for it.
            if let thumb = Images.thumbnail(base64: message.thumb) {
                image = thumb
            } else if message.type == "image", let path = message.mediaPath, !path.isEmpty {
                image = await Images.load(path: path, maxPixel: 200)
            }
        }
    }
}

/// One downloaded file in the storage gallery.
private struct CachedTile: View {
    let message: Message
    @State private var image: NSImage?

    private var icon: String {
        switch message.type {
        case "video": return "play.fill"
        case "audio": return "waveform"
        case "document": return "doc.fill"
        default: return "photo"
        }
    }

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Rectangle().fill(.quaternary)
                    Image(systemName: icon).foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if message.type == "video", image != nil {
                    Image(systemName: "play.fill").font(.caption).foregroundStyle(.white).shadow(radius: 2).padding(4)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .contentShape(Rectangle())
            .task {
                // The embedded thumbnail is enough at this size; fall back to
                // the file for stickers, which have none.
                if let thumb = Images.thumbnail(base64: message.thumb) {
                    image = thumb
                } else if message.isVisual, let path = message.mediaPath {
                    image = await Images.load(path: path, maxPixel: 120)
                }
            }
    }
}

// MARK: App lock

/// Covers the app until Touch ID (or the password) unlocks it.
struct LockView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "lock.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text(L("WhatsApp Zen is locked")).font(.title3.weight(.semibold))
            Button(L("Unlock")) { model.unlock() }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .onAppear { model.unlock() }
    }
}

// MARK: Release notes

struct ReleaseNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    let notes: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("What's New in %@", Links.version)).font(.title2.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(notes.components(separatedBy: "\n").enumerated()), id: \.offset) { _, line in
                        if line.hasPrefix("- ") {
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text("•").foregroundStyle(Theme.accent)
                                Text(LocalizedStringKey(String(line.dropFirst(2))))
                            }
                        } else if !line.isEmpty {
                            Text(LocalizedStringKey(line)).fontWeight(.semibold).padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(L("Done")) { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460, height: 420)
    }
}

// MARK: Settings panes

/// Colours and background. Everything about how messages and the chat list
/// are laid out lives in ChatSettings.
struct AppearanceSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section {
                ThemePicker().padding(.vertical, 4)
            }
            Section(L("Themes")) {
                ThemeGallery()
            }
            Section(L("Colours")) {
                ThemeColors()
            }
            Section {
                Toggle(isOn: $prefs.compactWindow) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Compact window"))
                        Text(L("A narrow window with one column, like the phone: chats open over the list, and ⌘[ goes back. ⌥⌘C switches it from anywhere."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle(isOn: $prefs.compact) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L("Dense layout"))
                        Text(L("Smaller rows and tighter messages, to see more at once."))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                Picker(L("Background"), selection: $prefs.wallpaper) {
                    Text(L("Theme")).tag("theme")
                    Text(L("Plain")).tag("none")
                    Text(L("Picture")).tag("image")
                }
                if prefs.wallpaper == "image" {
                    HStack {
                        Text(prefs.wallpaperPath.isEmpty ? L("No picture chosen") : (prefs.wallpaperPath as NSString).lastPathComponent)
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button(L("Choose…")) {
                            let panel = NSOpenPanel()
                            panel.allowedContentTypes = [.image]
                            if panel.runModal() == .OK, let url = panel.url { prefs.wallpaperPath = url.path }
                        }
                    }
                    HStack {
                        Text(L("Fade"))
                        Slider(value: $prefs.wallpaperDim, in: 0.2...0.9)
                    }
                }
            }
            if model.accounts.count > 1 {
                Section {
                    Toggle(L("A separate look for %@", model.active?.label ?? ""),
                           isOn: Binding(get: { prefs.ownLook }, set: { prefs.setOwnLook($0) }))
                } footer: {
                    Text(prefs.ownLook
                        ? L("Theme, colours, background and message style below apply to this account only.")
                        : L("All accounts share one look. Turn this on to style this account differently."))
                }
            }
        }
        .formStyle(.grouped)
    }
}

/// How messages and the chat list look and behave.
struct ChatSettings: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Form {
            Section(L("Messages")) {
                HStack {
                    Text(L("Text Size"))
                    Slider(value: $prefs.fontSize, in: 11...18, step: 1)
                    Text("\(Int(prefs.fontSize))").monospacedDigit().foregroundStyle(.secondary).frame(width: 22)
                }
                Picker(L("Font"), selection: $prefs.fontDesign) {
                    Text(L("Standard")).tag("default")
                    Text(L("Rounded")).tag("rounded")
                    Text(L("Serif")).tag("serif")
                    Text(L("Monospaced")).tag("monospaced")
                }
                HStack {
                    Text(L("Bubble Corners"))
                    Slider(value: $prefs.bubbleRadius, in: 4...22, step: 1)
                }
                Toggle(L("12-hour clock"), isOn: $prefs.hour12)
            }
            Section(L("Writing")) {
                Toggle(L("Turn emoticons like :) into emoji"), isOn: $prefs.emoticons)
                HStack {
                    Text(L("Quick Reactions"))
                    TextField(L("Quick Reactions"), text: $prefs.reactions).labelsHidden().multilineTextAlignment(.trailing)
                }
            }
            Section(L("Chat List")) {
                Picker(L("Preview lines"), selection: $prefs.previewLines) {
                    Text("1").tag(1)
                    Text("2").tag(2)
                }
                .disabled(prefs.compact)
                Toggle(L("Square profile photos"), isOn: $prefs.squareAvatars)
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacySettings: View {
    @ObservedObject private var prefs = Prefs.shared
    /// Whether the disk is encrypted; nil when macOS will not say.
    @State private var fileVault: Bool? = PrivacySettings.fileVaultStatus()

    /// Asks macOS whether FileVault protects the startup disk.
    static func fileVaultStatus() -> Bool? {
        let task = Process()
        let pipe = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/fdesetup")
        task.arguments = ["status"]
        task.standardOutput = pipe
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return nil }
        task.waitUntilExit()
        let text = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if text.contains("FileVault is On") { return true }
        if text.contains("FileVault is Off") { return false }
        return nil
    }

    var body: some View {
        Form {
            Section {
                Toggle(L("Lock the app with Touch ID"), isOn: $prefs.appLock)
                Picker(L("Lock after"), selection: $prefs.lockAfter) {
                    Text(L("Immediately")).tag(0)
                    Text(L("1 minute")).tag(1)
                    Text(L("5 minutes")).tag(5)
                    Text(L("15 minutes")).tag(15)
                    Text(L("1 hour")).tag(60)
                }
                .disabled(!prefs.appLock)
            } footer: {
                Text(L("Single chats can be locked from their info panel. Locked chats hide their previews and need Touch ID to open."))
            }
            Section(L("Disk Encryption")) {
                switch fileVault {
                case true?:
                    Label(L("FileVault is on. Everything this app stores is encrypted on disk."), systemImage: "lock.shield.fill")
                        .foregroundStyle(Theme.accent)
                case false?:
                    Label(L("FileVault is off. Messages on this Mac are stored unencrypted."), systemImage: "exclamationmark.shield.fill")
                        .foregroundStyle(.orange)
                    Button(L("Open FileVault Settings…")) {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?FileVault") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                case nil:
                    Text(L("Messages are stored unencrypted in your Library folder. Turn on FileVault in System Settings to encrypt the disk they are on."))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared
    @State private var bytes = 0
    @State private var busy = false
    @State private var items: [Message] = []

    var body: some View {
        Form {
            Section {
                Toggle(L("Download photos automatically"), isOn: $prefs.autoDownload)
            } footer: {
                Text(L("When off, a photo is downloaded when you click it."))
            }
            Section {
                HStack {
                    Text(L("Downloaded media"))
                    Spacer()
                    Text(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)).foregroundStyle(.secondary)
                    Button(L("Clear")) {
                        busy = true
                        Task { @MainActor in
                            for account in model.accounts { await account.clearCache() }
                            await measure()
                            items = []
                            busy = false
                        }
                    }
                    .disabled(busy || bytes == 0)
                }
            } footer: {
                Text(L("Media still on WhatsApp's servers is downloaded again when you look at it."))
            }
            if !items.isEmpty {
                Section(L("Downloaded media")) {
                    // Lazy: tiles are built, and their pictures decoded, only
                    // as they scroll into view.
                    ScrollView {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 5), spacing: 4) {
                            ForEach(items) { item in
                                CachedTile(message: item)
                                    .onTapGesture {
                                        guard item.type == "image" || item.type == "video" else { return }
                                        model.showingSettings = false
                                        model.active?.viewer = ViewerState(items: items.filter { $0.type == "image" || $0.type == "video" },
                                                                           index: items.filter { $0.type == "image" || $0.type == "video" }.firstIndex { $0.id == item.id } ?? 0)
                                    }
                                    .contextMenu {
                                        Button(L("Show in Finder"), systemImage: "folder") {
                                            if let path = item.mediaPath { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                                        }
                                        Button(L("Remove"), systemImage: "trash", role: .destructive) {
                                            Task { @MainActor in
                                                await model.active?.removeCached(item)
                                                items.removeAll { $0.id == item.id }
                                                await measure()
                                            }
                                        }
                                    }
                            }
                        }
                    }
                    .frame(height: 190)
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await measure()
            items = await model.active?.cachedMedia() ?? []
        }
    }

    @MainActor private func measure() async {
        var total = 0
        for account in model.accounts { total += await account.cacheSize() }
        bytes = total
    }
}
