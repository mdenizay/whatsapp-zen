import AppKit
import SwiftUI

var quickReactions: [String] { Prefs.shared.quickReactions }

/// What a message row can ask its container to do. The main window and the
/// menu bar popover each keep their own reply/edit state.
struct MessageActions {
    var reply: (Message) -> Void
    var edit: ((Message) -> Void)?
    var forward: ((Message) -> Void)?
    var jump: (String) -> Void = { _ in }
    /// Shows a downloaded document.
    var preview: (String) -> Void = { NSWorkspace.shared.open(URL(fileURLWithPath: $0)) }
    /// Opens a photo or video in the in-app viewer.
    var view: ((Message) -> Void)?
}

extension MessageRow: Equatable {
    /// A row depends only on its message and a few flags; with this the list
    /// skips every row that did not change when the store publishes anything
    /// (a typing indicator, a presence update, another chat's message).
    static func == (a: MessageRow, b: MessageRow) -> Bool {
        a.message == b.message && a.showSender == b.showSender && a.endsGroup == b.endsGroup
            && a.highlighted == b.highlighted && a.maxWidth == b.maxWidth
    }
}

struct MessageRow: View {
    /// A plain reference, not an observed one: see Equatable above.
    let store: AppStore
    let message: Message
    let showSender: Bool
    /// Last bubble of a run from the same sender; it gets the "tail" corner.
    let endsGroup: Bool
    let highlighted: Bool
    var maxWidth: CGFloat = 520
    let actions: MessageActions

    @ObservedObject private var prefs = Prefs.shared
    @State private var hovering = false
    @State private var picking = false
    @State private var confirmDelete = false
    @State private var stickerMenu = false

    private var mine: Bool { message.fromMe }
    /// WhatsApp takes a message back from everyone for about two and a half days.
    private var canDeleteForEveryone: Bool {
        mine && !message.deleted && Date().timeIntervalSince(message.date) < 60 * 3600
    }
    private var secondary: Color { mine ? .white.opacity(0.78) : .secondary }
    /// A bare photo: the picture fills the bubble and the time sits on it.
    private var bare: Bool {
        message.isVisual && message.text.isEmpty && message.quotedId == nil && !message.deleted && !showSender
    }
    private var canEdit: Bool {
        mine && message.type == "text" && !message.deleted && actions.edit != nil
            && Date().timeIntervalSince(message.date) < 15 * 60
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            if mine {
                Spacer(minLength: 36)
                hoverActions
            }
            VStack(alignment: mine ? .trailing : .leading, spacing: 3) {
                bubble
                if !message.reactions.isEmpty { reactionChips }
            }
            if !mine {
                hoverActions
                Spacer(minLength: 36)
            }
        }
        .padding(.top, showSender ? (prefs.compact ? 3 : 6) : 0)
        .padding(.bottom, endsGroup ? (prefs.compact ? 3 : 6) : 0)
        .background(highlighted ? Theme.accent.opacity(0.16) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            if !message.deleted { actions.reply(message) }
        }
        .onHover { hovering = $0 }
        .contextMenu { menu }
        .confirmationDialog(L("Delete this message?"), isPresented: $confirmDelete) {
            if canDeleteForEveryone {
                Button(L("Delete for Everyone"), role: .destructive) { store.revoke(message) }
            }
            Button(L("Delete for Me"), role: .destructive) { store.deleteForMe(message) }
        }
    }

    private var shape: UnevenRoundedRectangle {
        let radius = CGFloat(prefs.bubbleRadius)
        let tail: CGFloat = endsGroup ? min(5, radius) : radius
        return UnevenRoundedRectangle(
            cornerRadii: .init(topLeading: radius, bottomLeading: mine ? radius : tail, bottomTrailing: mine ? tail : radius, topTrailing: radius),
            style: .continuous)
    }

    private var bubble: some View {
        BubbleStack(spacing: prefs.compact ? 3 : 5) {
            if showSender {
                Text(message.senderName)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Theme.senderColor(message.sender))
            }
            if let quotedId = message.quotedId {
                QuoteView(sender: message.quotedSender ?? "", text: message.quotedText ?? "", onBubble: mine)
                    .onTapGesture { actions.jump(quotedId) }
            }
            if message.deleted {
                HStack(alignment: .lastTextBaseline, spacing: 8) {
                    Label(L("This message was deleted"), systemImage: "nosign").italic().foregroundStyle(secondary)
                    meta
                }
            } else {
                content
            }
        }
        .padding(.horizontal, bare ? 3 : (prefs.compact ? 9 : 11))
        .padding(.vertical, bare ? 3 : (prefs.compact ? 4 : 7))
        .foregroundStyle(mine ? .white : .primary)
        .tint(mine ? .white : Theme.accent)
        .background(mine ? Theme.bubbleOut : Theme.bubbleIn, in: shape)
        // Someone mentioned you: the bubble gets an accent outline.
        .overlay(shape.strokeBorder(Theme.accent, lineWidth: message.mentionsMe ? 1.5 : 0))
        .cappedWidth(maxWidth)
    }

    @ViewBuilder private var content: some View {
        switch message.type {
        case "image", "sticker":
            MediaImageView(message: message, preview: { path in
                if message.type == "sticker" {
                    // A click on a sticker offers to keep it.
                    stickerMenu = true
                } else if let view = actions.view {
                    view(message)
                } else {
                    actions.preview(path)
                }
            })
                .popover(isPresented: $stickerMenu, arrowEdge: .bottom) {
                    VStack(alignment: .leading, spacing: 4) {
                        Button(message.starred ? L("Remove from Favorites") : L("Add to Favorites"),
                               systemImage: message.starred ? "star.slash" : "star.fill") {
                            store.star(message, !message.starred)
                            stickerMenu = false
                        }
                        if let forward = actions.forward {
                            Button(L("Forward"), systemImage: "arrowshape.turn.up.right") {
                                stickerMenu = false
                                forward(message)
                            }
                        }
                    }
                    .buttonStyle(.borderless)
                    .padding(12)
                }
                .overlay(alignment: .bottomTrailing) {
                    if bare {
                        meta.foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.black.opacity(0.45), in: Capsule())
                            .padding(6)
                    }
                }
        case "audio":
            VoiceView(message: message, onBubble: mine)
        case "video", "document":
            FileAttachmentView(message: message, onBubble: mine, preview: { path in
                if let view = actions.view, message.type == "video" { view(message) } else { actions.preview(path) }
            })
        case "poll":
            if let poll = message.poll { PollView(message: message, poll: poll, onBubble: mine) }
        default:
            if let place = LocationCard.place(in: message.text) { LocationCard(place: place, onBubble: mine) }
        }
        if message.type == "text", message.linkTitle?.isEmpty == false {
            LinkCard(message: message, onBubble: mine)
        }
        if (message.type == "poll" && message.poll != nil) || LocationCard.place(in: message.text) != nil {
            meta.frame(maxWidth: .infinity, alignment: .trailing)
        } else if !message.text.isEmpty {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text(MessageFormat.attributed(message.text)).font(.system(size: prefs.fontSize, design: prefs.design)).textSelection(.enabled)
                meta
            }
        } else if !bare {
            meta.frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var meta: some View {
        HStack(spacing: 3) {
            if message.pinned { Image(systemName: "pin.fill") }
            if message.starred { Image(systemName: "star.fill") }
            if message.edited { Text(L("edited")) }
            Text(Format.time(message.date))
            if mine { StatusTicks(status: message.status, onBubble: true) }
        }
        .font(.caption2)
        .foregroundStyle(secondary)
        .fixedSize()
    }

    private var hoverActions: some View {
        HStack(spacing: 2) {
            Button { picking = true } label: { Image(systemName: "face.smiling") }
                .help(L("React"))
                .popover(isPresented: $picking, arrowEdge: .top) {
                    HStack(spacing: 6) {
                        ForEach(quickReactions, id: \.self) { emoji in
                            Button(emoji) {
                                store.react(to: message, with: emoji)
                                picking = false
                            }
                            .buttonStyle(.plain)
                            .font(.title)
                        }
                    }
                    .padding(12)
                }
            Button { actions.reply(message) } label: { Image(systemName: "arrowshape.turn.up.left") }
                .help(L("Reply"))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity((hovering || picking) && !message.deleted ? 1 : 0)
    }

    private var reactionChips: some View {
        let groups = Dictionary(grouping: message.reactions, by: \.emoji).sorted {
            $0.value.count != $1.value.count ? $0.value.count > $1.value.count : $0.key < $1.key
        }
        return HStack(spacing: 4) {
            ForEach(groups, id: \.key) { emoji, list in
                let isMine = list.contains { $0.fromMe }
                Button { store.react(to: message, with: emoji) } label: {
                    Text(list.count > 1 ? "\(emoji) \(list.count)" : emoji)
                        .font(.callout)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(isMine ? AnyShapeStyle(Theme.accent.opacity(0.22)) : AnyShapeStyle(.quaternary), in: Capsule())
                        .overlay(Capsule().strokeBorder(isMine ? Theme.accent : .clear))
                }
                .buttonStyle(.plain)
                .help(list.map(\.name).joined(separator: ", "))
            }
        }
    }

    @ViewBuilder private var menu: some View {
        if !message.deleted {
            Button(L("Reply"), systemImage: "arrowshape.turn.up.left") { actions.reply(message) }
            Button(L("Copy"), systemImage: "doc.on.doc") { Self.copy(text: message.plainText) }
            if message.isVisual, let path = message.mediaPath, !path.isEmpty {
                Button(L("Copy Photo"), systemImage: "photo.on.rectangle") { Self.copy(imageAt: path) }
            }
            if let path = message.mediaPath, !path.isEmpty {
                Button(L("Show in Finder"), systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
            }
            if message.hasFile {
                Button(L("Save to Downloads"), systemImage: "arrow.down.circle") {
                    Task { @MainActor in
                        if await Downloads.save(message) == nil { store.errorText = L("Download failed") }
                    }
                }
                Button(L("Save As…"), systemImage: "square.and.arrow.down") {
                    Task { @MainActor in
                        if await !Downloads.saveAs(message) { store.errorText = L("Download failed") }
                    }
                }
            }
            Menu(L("React"), systemImage: "face.smiling") {
                ForEach(quickReactions, id: \.self) { emoji in
                    Button(emoji) { store.react(to: message, with: emoji) }
                }
            }
            Divider()
            if let forward = actions.forward {
                Button(L("Forward"), systemImage: "arrowshape.turn.up.right") { forward(message) }
            }
            Button(message.type == "sticker" ? (message.starred ? L("Remove from Favorites") : L("Add to Favorites"))
                       : (message.starred ? L("Unstar") : L("Star")),
                   systemImage: message.starred ? "star.slash" : "star") {
                store.star(message, !message.starred)
            }
            Button(message.pinned ? L("Unpin") : L("Pin"), systemImage: message.pinned ? "pin.slash" : "pin") {
                store.pin(message, !message.pinned)
            }
            Divider()
            if mine, canEdit {
                Button(L("Edit"), systemImage: "pencil") { actions.edit?(message) }
            }
            Button(L("Delete…"), systemImage: "trash", role: .destructive) { confirmDelete = true }
        }
    }

    static func copy(text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func copy(imageAt path: String) {
        guard let image = NSImage(contentsOfFile: path) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

struct QuoteView: View {
    let sender: String
    let text: String
    /// True on the green outgoing bubble, where everything must be white.
    var onBubble = false

    var body: some View {
        HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 2).fill(onBubble ? .white : Theme.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 1) {
                if !sender.isEmpty {
                    Text(sender).font(.caption.weight(.semibold)).foregroundStyle(onBubble ? .white : Theme.accent)
                }
                Text(text.isEmpty ? L("Message") : text).font(.callout)
                    .foregroundStyle(onBubble ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(7)
        .fixedSize(horizontal: false, vertical: true)
        .background(onBubble ? .black.opacity(0.14) : .primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

/// A photo or sticker: the embedded thumbnail first, then the real file,
/// downloaded on demand and decoded no larger than it is shown.
struct MediaImageView: View {
    let message: Message
    let preview: (String) -> Void

    @State private var image: NSImage?
    @State private var path: String?

    private static let maxPixel: CGFloat = 720

    init(message: Message, preview: @escaping (String) -> Void) {
        self.message = message
        self.preview = preview
        // A row rebuilt during a resize shows its picture at once instead of
        // flashing back to the blurred placeholder.
        if let file = message.mediaPath, !file.isEmpty, let hit = Images.cached(path: file, maxPixel: Self.maxPixel) {
            _image = State(initialValue: hit)
            _path = State(initialValue: file)
        }
    }

    /// Still uploading, or the upload failed.
    private var sending: Bool { message.fromMe && message.status == Status.pending }

    private var size: CGSize {
        if message.type == "sticker" { return CGSize(width: 130, height: 130) }
        let aspect = message.w > 0 && message.h > 0 ? CGFloat(message.w) / CGFloat(message.h) : 1
        let width = min(300, max(150, 260 * aspect))
        return CGSize(width: width, height: min(360, width / aspect))
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable()
                    .aspectRatio(contentMode: message.type == "sticker" ? .fit : .fill)
                    .blur(radius: path == nil ? 8 : 0)
            } else {
                Rectangle().fill(.quaternary)
            }
        }
        .frame(width: size.width, height: size.height)
        .overlay {
            if sending {
                SendingBadge()
            } else if message.fromMe, message.status == Status.failed {
                Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.white)
                    .padding(12).background(.black.opacity(0.5), in: Circle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            if let path { preview(path) } else { Task { await load(force: true) } }
        }
        .task(id: message.id) { await load() }
    }

    private func load(force: Bool = false) async {
        guard path == nil else { return }
        if image == nil { image = Images.thumbnail(base64: message.thumb) }
        // With automatic downloads off, only what is already on disk loads
        // by itself; a click fetches the rest.
        let onDisk = message.mediaPath.map { !$0.isEmpty && FileManager.default.fileExists(atPath: $0) } ?? false
        guard force || onDisk || Prefs.shared.autoDownload else { return }
        guard let file = await mediaPath(for: message),
              let full = await Images.load(path: file, maxPixel: Self.maxPixel) else { return }
        image = full
        path = file
    }
}

/// Shown over media that is still being uploaded.
struct SendingBadge: View {
    var body: some View {
        ProgressView().controlSize(.small).tint(.white)
            .padding(12)
            .background(.black.opacity(0.5), in: Circle())
    }
}

/// Fetches a message's media file on demand.
func mediaPath(for message: Message) async -> String? {
    if let path = message.mediaPath, !path.isEmpty, FileManager.default.fileExists(atPath: path) { return path }
    return try? await Core.call("download", ["chat": message.chat, "id": message.id])
}

/// A voice message with an in-place player.
struct VoiceView: View {
    let message: Message
    let onBubble: Bool

    @ObservedObject private var player = AudioPlayer.shared
    @State private var busy = false
    @State private var failed = false

    private var playing: Bool { player.playingID == message.id }
    private var duration: String { "\(message.w / 60):\(String(format: "%02d", message.w % 60))" }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: toggle) {
                ZStack {
                    Circle().fill(onBubble ? .white.opacity(0.22) : Theme.accent.opacity(0.18))
                    if busy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: playing ? "pause.fill" : "play.fill")
                            .foregroundStyle(onBubble ? .white : Theme.accent)
                    }
                }
                .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .help(playing ? L("Pause") : L("Play"))

            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(onBubble ? .white.opacity(0.3) : .primary.opacity(0.15))
                        Capsule().fill(onBubble ? .white : Theme.accent)
                            .frame(width: geo.size.width * (playing ? player.progress : 0))
                    }
                }
                .frame(height: 4)
                Text(failed ? L("Download failed") : L("Voice message") + " · \(duration)")
                    .font(.caption)
                    .foregroundStyle(onBubble ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
            }
        }
        .frame(width: 210)
    }

    private func toggle() {
        guard !busy else { return }
        if playing {
            player.stop()
            return
        }
        busy = true
        failed = false
        Task { @MainActor in
            defer { busy = false }
            guard let path = await mediaPath(for: message) else {
                failed = true
                return
            }
            player.toggle(id: message.id, path: path)
        }
    }
}

/// A video or document: downloaded on click and shown in Quick Look.
struct FileAttachmentView: View {
    let message: Message
    let onBubble: Bool
    let preview: (String) -> Void

    @State private var busy = false
    @State private var failed = false
    @State private var saving = false
    /// Where "save to Downloads" put the file.
    @State private var saved: URL?

    private var isVideo: Bool { message.type == "video" }
    /// Downloading, or still uploading our own file.
    private var working: Bool { busy || (message.fromMe && message.status == Status.pending) }

    var body: some View {
        HStack(spacing: 8) {
            opener
            // A document is usually wanted as a file, not only looked at.
            if !isVideo, !(message.fromMe && message.status == Status.pending) {
                Button(action: save) {
                    Group {
                        if saving {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: saved != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                                .font(.title3)
                                .foregroundStyle(onBubble ? AnyShapeStyle(.white) : AnyShapeStyle(Theme.accent))
                        }
                    }
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(saved != nil ? L("Saved to Downloads. Click to show in Finder.") : L("Save to Downloads"))
            }
        }
    }

    private var opener: some View {
        Button(action: open) {
            if isVideo, let poster = Images.thumbnail(base64: message.thumb) {
                let aspect = message.w > 0 && message.h > 0 ? CGFloat(message.w) / CGFloat(message.h) : 16 / 9
                let width = min(300, max(170, 260 * aspect))
                Image(nsImage: poster).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: width, height: min(340, width / aspect))
                    .blur(radius: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                    .overlay {
                        ZStack {
                            Circle().fill(.black.opacity(0.5)).frame(width: 52, height: 52)
                            if working {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: failed ? "exclamationmark.triangle.fill" : "play.fill")
                                    .font(.title2).foregroundStyle(.white)
                            }
                        }
                    }
            } else {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(onBubble ? .white.opacity(0.22) : Theme.accent.opacity(0.18))
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: isVideo ? "play.fill" : "doc.fill")
                                .foregroundStyle(onBubble ? .white : Theme.accent)
                        }
                    }
                    .frame(width: 36, height: 36)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(isVideo ? L("Video") : (message.fileName ?? L("Document"))).lineLimit(1).truncationMode(.middle)
                        Text(failed ? L("Download failed") : (saved != nil ? L("Saved to Downloads") : L("Click to open"))).font(.caption)
                            .foregroundStyle(onBubble ? AnyShapeStyle(.white.opacity(0.8)) : AnyShapeStyle(.secondary))
                    }
                }
                .frame(minWidth: 180, maxWidth: 260, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func save() {
        if let saved, FileManager.default.fileExists(atPath: saved.path) {
            return NSWorkspace.shared.activateFileViewerSelecting([saved])
        }
        guard !saving else { return }
        saving = true
        failed = false
        Task { @MainActor in
            defer { saving = false }
            saved = await Downloads.save(message)
            failed = saved == nil
        }
    }

    private func open() {
        guard !busy else { return }
        busy = true
        failed = false
        Task { @MainActor in
            defer { busy = false }
            guard let path = await mediaPath(for: message) else {
                failed = true
                return
            }
            preview(path)
        }
    }
}

/// Limits a view's width without making it take that width: unlike
/// frame(maxWidth:), the result is exactly as wide as the content.
struct CappedWidth: Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let view = subviews.first else { return .zero }
        return view.sizeThatFits(ProposedViewSize(width: min(proposal.width ?? max, max), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

extension View {
    func cappedWidth(_ max: CGFloat) -> some View {
        CappedWidth(max: max) { self }
    }
}

/// A vertical stack that is only as wide as its widest child wants to be, and
/// then gives every child that width. A plain VStack would let one greedy
/// child (a quote, a right-aligned timestamp) stretch the bubble to the limit.
struct BubbleStack: Layout {
    var spacing: CGFloat = 5

    private func width(_ proposal: ProposedViewSize, _ subviews: Subviews) -> CGFloat {
        let ideal = subviews.map { $0.sizeThatFits(.unspecified).width }.max() ?? 0
        return min(ideal, proposal.width ?? ideal)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = width(proposal, subviews)
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: w, height: nil)).height }
        return CGSize(width: w, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for view in subviews {
            let fit = ProposedViewSize(width: bounds.width, height: nil)
            view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: fit)
            y += view.sizeThatFits(fit).height + spacing
        }
    }
}

/// Lays out a conversation: day dividers, sender runs and bubble tails.
struct MessageList: View {
    @EnvironmentObject var store: AppStore
    let messages: [Message]
    let isGroup: Bool
    var highlighted: String?
    /// The first message that was unread when the chat was opened.
    var unreadFrom: String?
    var maxWidth: CGFloat = 520
    let actions: MessageActions

    var body: some View {
        ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
            let previous = index > 0 ? messages[index - 1] : nil
            let next = index + 1 < messages.count ? messages[index + 1] : nil
            let newDay = previous.map { !Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? true
            let nextDay = next.map { !Calendar.current.isDate($0.date, inSameDayAs: message.date) } ?? true
            if newDay { DayDivider(date: message.date) }
            if message.id == unreadFrom {
                HStack(spacing: 8) {
                    VStack { Divider() }
                    Text(L("Unread messages")).font(.caption.weight(.medium)).foregroundStyle(Theme.accent).fixedSize()
                    VStack { Divider() }
                }
                .padding(.vertical, 6)
            }
            MessageRow(
                store: store,
                message: message,
                showSender: isGroup && !message.fromMe && (newDay || previous?.sender != message.sender),
                endsGroup: nextDay || next?.sender != message.sender,
                highlighted: highlighted == message.id,
                maxWidth: maxWidth,
                actions: actions
            )
            .equatable()
            .id(message.id)
        }
    }
}

struct DayDivider: View {
    let date: Date
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        Text(Format.day(date))
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .glassEffect(.regular, in: Capsule())
            .padding(.vertical, prefs.compact ? 4 : 8)
    }
}

/// Shown in a chat this Mac holds no messages of.
struct NoMessagesNote: View {
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "iphone.gen3").font(.title2).foregroundStyle(.secondary)
            Text(L("No messages on this Mac yet")).fontWeight(.medium)
            Text(L("Messages from before this Mac was linked stay on your phone. New ones will show up here."))
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 260)
        .frame(maxWidth: .infinity)
    }
}
