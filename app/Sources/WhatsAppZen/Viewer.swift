import AppKit
import AVKit
import SwiftUI

/// What the in-app media viewer is showing.
struct ViewerState: Equatable {
    var items: [Message]
    var index: Int
}

/// Full-window viewer for photos and videos: zoom, step through the chat's
/// media, copy or save, all without leaving the app.
struct MediaViewer: View {
    @EnvironmentObject var store: AppStore
    let state: ViewerState

    @State private var image: NSImage?
    @State private var player: AVPlayer?
    @State private var path: String?
    @State private var failed = false
    @State private var zoom: CGFloat = 1
    @State private var offset = CGSize.zero
    @State private var dragBase = CGSize.zero
    @FocusState private var focused: Bool

    private var message: Message { state.items[state.index] }

    var body: some View {
        ZStack {
            Color.black.opacity(0.93).ignoresSafeArea().onTapGesture(perform: close)
            content
            VStack {
                topBar
                Spacer()
            }
            HStack {
                arrow("chevron.left", -1)
                Spacer()
                arrow("chevron.right", 1)
            }
            .padding(.horizontal, 14)
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(.escape) { close(); return .handled }
        .onKeyPress(.space) { close(); return .handled }
        .task(id: message.id) { await load() }
        .transition(.opacity)
    }

    @ViewBuilder private var content: some View {
        if let player {
            VideoPlayer(player: player).padding(.vertical, 56).padding(.horizontal, 70)
        } else if let image {
            Image(nsImage: image).resizable().scaledToFit()
                .scaleEffect(zoom)
                .offset(offset)
                .padding(.vertical, 56).padding(.horizontal, 70)
                .gesture(MagnifyGesture().onChanged { zoom = min(max($0.magnification, 1), 6) })
                .gesture(DragGesture().onChanged { value in
                    guard zoom > 1 else { return }
                    offset = CGSize(width: dragBase.width + value.translation.width, height: dragBase.height + value.translation.height)
                }.onEnded { _ in dragBase = offset })
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        zoom = zoom > 1 ? 1 : 2.5
                        offset = .zero
                        dragBase = .zero
                    }
                }
        } else if failed {
            Label(L("Download failed"), systemImage: "exclamationmark.triangle").foregroundStyle(.white)
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(message.fromMe ? L("You") : (message.senderName.isEmpty ? (store.selectedChat?.name ?? "") : message.senderName))
                    .fontWeight(.semibold)
                Text(Format.stamp(message.ts)).font(.caption).opacity(0.7)
            }
            .foregroundStyle(.white)
            Spacer()
            if state.items.count > 1 {
                Text("\(state.index + 1) / \(state.items.count)").font(.callout).monospacedDigit().foregroundStyle(.white.opacity(0.7))
            }
            Group {
                if message.type == "image" {
                    button("doc.on.doc", L("Copy Photo")) { if let path { MessageRow.copy(imageAt: path) } }
                }
                button("square.and.arrow.down", L("Save…"), action: save)
                button("folder", L("Show in Finder")) {
                    if let path { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                }
                button("bubble.left", L("Show in Chat")) {
                    let target = message
                    close()
                    store.reveal(target)
                }
            }
            .disabled(path == nil)
            button("xmark", L("Close"), action: close)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }

    private func button(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 14, weight: .medium)).foregroundStyle(.white)
                .frame(width: 32, height: 32).background(.white.opacity(0.14), in: Circle()).contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder private func arrow(_ icon: String, _ delta: Int) -> some View {
        let target = state.index + delta
        if state.items.indices.contains(target) {
            Button { step(delta) } label: {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44).background(.white.opacity(0.14), in: Circle()).contentShape(Circle())
            }
            .buttonStyle(.plain)
        } else {
            Color.clear.frame(width: 44, height: 44)
        }
    }

    private func step(_ delta: Int) {
        let target = state.index + delta
        guard state.items.indices.contains(target) else { return }
        store.viewer = ViewerState(items: state.items, index: target)
    }

    private func close() {
        player?.pause()
        store.viewer = nil
    }

    private func load() async {
        player?.pause()
        player = nil
        image = nil
        path = nil
        failed = false
        zoom = 1
        offset = .zero
        dragBase = .zero
        let item = message
        guard let file = await mediaPath(for: item) else {
            failed = true
            return
        }
        guard item.id == message.id else { return }
        path = file
        if item.type == "video" {
            let player = AVPlayer(url: URL(fileURLWithPath: file))
            self.player = player
            player.play()
        } else if let full = await Images.load(path: file, maxPixel: 2600) {
            image = full
        } else {
            failed = true
        }
    }

    private func save() {
        guard let path else { return }
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = message.type == "video" ? "WhatsApp Video.\(source.pathExtension)" : "WhatsApp Photo.\(source.pathExtension)"
        if panel.runModal() == .OK, let target = panel.url {
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.copyItem(at: source, to: target)
        }
    }
}

extension AppStore {
    /// Opens the viewer on a photo or video, with the rest of the given
    /// messages' media (default: the open chat's) to step through.
    func view(_ message: Message, among all: [Message]? = nil) {
        let media = (all ?? messages).filter { ($0.type == "image" || $0.type == "video") && !$0.deleted }
        guard let index = media.firstIndex(where: { $0.id == message.id }) else {
            viewer = ViewerState(items: [message], index: 0)
            return
        }
        viewer = ViewerState(items: media, index: index)
    }
}
