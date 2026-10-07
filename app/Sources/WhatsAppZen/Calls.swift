import AVFoundation
import AppKit
import Combine
import SwiftUI

/// The voice call in progress or ringing, and the small window that shows
/// it. Calls are carried by the Rust core; with the Go core the commands
/// answer with an error and nothing here appears.
final class CallCenter: ObservableObject {
    static let shared = CallCenter()

    struct Call: Equatable {
        enum State { case ringing, calling, connecting, active, ended }

        let id: String
        let jid: String
        var name: String
        let account: String
        let incoming: Bool
        var state: State
        var muted = false
        /// When the other side's voice first arrived.
        var since: Date?
        /// Our camera is on.
        var camera = false
        /// The other side's camera is on.
        var remoteVideo = false
        /// The other side asked to add video to a voice call.
        var videoRequested = false
        /// It rang as a video call.
        var videoOffer = false

        var showsVideo: Bool { camera || remoteVideo }
    }

    @Published private(set) var call: Call?
    /// The call window fills the screen.
    @Published private(set) var fullScreen = false
    private var panel: NSPanel?
    /// Where the window was before it filled the screen.
    private var windowedFrame: NSRect?

    private static let voiceSize = NSSize(width: 300, height: 150)
    private static let videoSize = NSSize(width: 480, height: 400)
    private var ring: NSSound?

    private var store: AppStore? { AppModel.shared.accounts.first { $0.id == call?.account } }

    /// An incoming call started ringing.
    func ringing(id: String, jid: String, name: String, video: Bool, account: AppStore) {
        // One call at a time: a second caller is left to the phone.
        guard call == nil || call?.state == .ended else { return }
        call = Call(id: id, jid: jid, name: name, account: account.id, incoming: true, state: .ringing, videoOffer: video)
        ring = NSSound(named: "Submarine")
        ring?.loops = true
        ring?.play()
        show()
    }

    /// The core reported a change in a call's state.
    func update(id: String, jid: String, name: String, state: String, on: Bool?, account: AppStore) {
        if call?.id != id {
            // A call placed from here, heard about for the first time.
            guard state == "calling" else { return }
            call = Call(id: id, jid: jid, name: name, account: account.id, incoming: false, state: .calling)
            show()
        }
        switch state {
        case "camera":
            call?.camera = on ?? false
            call?.videoRequested = false
            if on == true { CameraEncoder.shared.start() } else { CameraEncoder.shared.stop() }
            resize()
        case "remote_video":
            call?.remoteVideo = on ?? false
            if on == true {
                RemoteVideo.shared.attach()
            } else {
                RemoteVideo.shared.reset()
            }
            resize()
        case "video_request":
            call?.videoRequested = true
        case "connecting": call?.state = .connecting
        case "active":
            call?.state = .active
            call?.since = Date()
        case "muted": call?.muted = on ?? false
        case "ended": finish()
        default: break
        }
        if state != "calling" { stopRinging() }
    }

    /// Asks for the microphone before the call needs it: opened without
    /// permission it would deliver silence for the whole call.
    @MainActor private func microphoneAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private static var microphoneDenied: String { L("Calls need the microphone. Allow it in System Settings › Privacy & Security › Microphone.") }

    @MainActor private func cameraAllowed() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .video)
        default: return false
        }
    }

    private static var cameraDenied: String { L("Video calls need the camera. Allow it in System Settings › Privacy & Security › Camera.") }

    func start(_ chat: Chat, video: Bool = false, in store: AppStore) {
        guard call == nil else { return }
        Task { @MainActor in
            guard await microphoneAllowed() else {
                store.errorText = Self.microphoneDenied
                return
            }
            if video, await !cameraAllowed() {
                store.errorText = Self.cameraDenied
                return
            }
            do {
                if video { RemoteVideo.shared.attach() }
                try await Core.run("call_start", ["jid": chat.jid, "video": video], account: store.id)
                if video {
                    self.call?.camera = true
                    CameraEncoder.shared.start()
                    self.resize()
                }
            } catch {
                store.errorText = L(error.localizedDescription)
            }
        }
    }

    /// Turns our camera on or off during the call; on also answers the other
    /// side's request for video.
    func toggleCamera() {
        guard let call, let store else { return }
        let on = !call.camera
        Task { @MainActor in
            if on, await !cameraAllowed() {
                store.errorText = Self.cameraDenied
                return
            }
            do {
                if on { RemoteVideo.shared.attach() }
                try await Core.run("call_video", ["on": on], account: store.id)
            } catch {
                store.errorText = L(error.localizedDescription)
            }
        }
    }

    func accept() {
        guard let call, let store else { return }
        stopRinging()
        self.call?.state = .connecting
        Task { @MainActor in
            guard await microphoneAllowed() else {
                store.errorText = Self.microphoneDenied
                self.decline()
                return
            }
            // A video call is answered with our camera on, if it may be used.
            let video = call.videoOffer ? await cameraAllowed() : false
            do {
                if video { RemoteVideo.shared.attach() }
                try await Core.run("call_accept", ["id": call.id, "video": video], account: store.id)
                if video {
                    self.call?.camera = true
                    self.call?.remoteVideo = true
                    CameraEncoder.shared.start()
                    self.resize()
                }
            } catch {
                store.errorText = L(error.localizedDescription)
                self.finish()
            }
        }
    }

    func decline() {
        guard let call, let store else { return }
        Core.fire("reject_call", ["id": call.id], account: store.id)
        finish()
    }

    func end() {
        guard let store else { return finish() }
        Core.fire("call_end", [:], account: store.id)
        finish()
    }

    func toggleMute() {
        guard let call, let store else { return }
        Core.fire("call_mute", ["on": !call.muted], account: store.id)
        self.call?.muted.toggle()
    }

    private func stopRinging() {
        ring?.stop()
        ring = nil
    }

    /// Shows "ended" for a moment, then closes the window.
    private func finish() {
        stopRinging()
        CameraEncoder.shared.stop()
        RemoteVideo.shared.reset()
        guard call != nil, call?.state != .ended else { return }
        call?.state = .ended
        let id = call?.id
        exitFullScreen()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            guard call?.id == id else { return }
            call = nil
            panel?.orderOut(nil)
            panel = nil
        }
    }

    /// Fills the screen with a video call, or brings it back to its window.
    /// The call window floats over other apps without taking their place, and
    /// such a window cannot use the system's full screen; it covers the
    /// screen it is on instead, menu bar included.
    func toggleFullScreen() {
        guard let panel else { return }
        if fullScreen { return exitFullScreen() }
        guard call?.showsVideo == true, let screen = panel.screen ?? NSScreen.main else { return }
        windowedFrame = panel.frame
        fullScreen = true
        panel.level = .mainMenu + 1
        panel.isMovableByWindowBackground = false
        panel.setFrame(screen.frame, display: true, animate: true)
        // So that Esc reaches it.
        panel.makeKey()
    }

    func exitFullScreen() {
        guard let panel, fullScreen else { return }
        fullScreen = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        if let windowedFrame { panel.setFrame(windowedFrame, display: true, animate: true) }
        windowedFrame = nil
    }

    /// The window grows to hold the pictures of a video call, where it can be
    /// resized and made full screen, and shrinks back for a voice call.
    private func resize() {
        guard let panel, let call else { return }
        // Video went away while full screen: come back first, then shrink.
        if fullScreen {
            guard !call.showsVideo else { return }
            exitFullScreen()
        }
        let wasVideo = panel.styleMask.contains(.resizable)
        guard wasVideo != call.showsVideo else { return }
        if call.showsVideo {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: 320, height: 260)
        } else {
            panel.styleMask.remove(.resizable)
        }
        let size = call.showsVideo ? Self.videoSize : Self.voiceSize
        var frame = panel.frame
        // Keep the top right corner where it is.
        frame.origin.x += frame.width - size.width
        frame.origin.y += frame.height - size.height
        frame.size = size
        panel.setFrame(frame, display: true, animate: true)
    }

    private func show() {
        if panel == nil {
            let panel = CallPanel(contentRect: NSRect(origin: .zero, size: Self.voiceSize),
                                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel, .hudWindow], backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.isMovableByWindowBackground = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.isReleasedWhenClosed = false
            panel.contentView = NSHostingView(rootView: CallView(center: self))
            // Top right, where the system puts its own call banners.
            if let screen = NSScreen.main?.visibleFrame {
                panel.setFrameOrigin(NSPoint(x: screen.maxX - 320, y: screen.maxY - 170))
            }
            self.panel = panel
        }
        panel?.orderFrontRegardless()
    }
}

/// The call window: it may take the keyboard (Esc, ⌃⌘F) and may cover the
/// whole screen, menu bar included, which the system denies ordinary windows.
final class CallPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

/// What the call window shows: who, what is happening, and the two or three
/// things that can be done about it.
struct CallView: View {
    @ObservedObject var center: CallCenter

    var body: some View {
        if let call = center.call {
            if call.showsVideo, call.state != .ringing {
                video(call)
            } else {
                voice(call)
            }
        }
    }

    /// A voice call, or one still ringing: who, what is happening, the buttons.
    private func voice(_ call: CallCenter.Call) -> some View {
        VStack(spacing: 14) {
            if call.videoRequested {
                Text(L("%@ wants to turn on video", call.name)).font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                AvatarView(jid: call.jid, name: call.name, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text(call.name).font(.headline).lineLimit(1)
                    status(of: call).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 12) {
                if call.state == .ringing {
                    button("phone.down.fill", L("Decline"), .red, action: center.decline)
                    button(call.videoOffer ? "video.fill" : "phone.fill", L("Accept"), .green, action: center.accept)
                } else if call.state != .ended {
                    iconButton(call.muted ? "mic.slash.fill" : "mic.fill", call.muted ? L("Unmute") : L("Mute"),
                               call.muted ? .orange : .gray, action: center.toggleMute)
                    iconButton(call.camera ? "video.fill" : "video.slash.fill", call.camera ? L("Turn Camera Off") : L("Turn Camera On"),
                               call.camera || call.videoRequested ? .blue : .gray, action: center.toggleCamera)
                    button("phone.down.fill", L("End Call"), .red, action: center.end)
                }
            }
            .frame(height: 40)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A video call: the other side fills the window, whatever its size, with
    /// the name, ourselves and the buttons on top of the picture.
    private func video(_ call: CallCenter.Call) -> some View {
        ZStack {
            Color.black
            if call.remoteVideo {
                LayerView(layer: RemoteVideo.shared.layer)
            } else {
                Text(L("Waiting for video…")).font(.callout).foregroundStyle(.white.opacity(0.7))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2, perform: center.toggleFullScreen)
        .overlay(alignment: .topLeading) {
            VStack(alignment: .leading, spacing: 2) {
                Text(call.name).font(.headline).lineLimit(1)
                status(of: call).font(.callout).monospacedDigit().opacity(0.85)
            }
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
            // Clear of the window's own buttons.
            .padding(.top, 30).padding(.horizontal, 14)
        }
        .overlay(alignment: .bottom) {
            VStack(alignment: .trailing, spacing: 10) {
                if call.camera {
                    // Ourselves, small, in the corner.
                    LayerView(layer: CallView.preview)
                        .frame(width: center.fullScreen ? 200 : 110, height: center.fullScreen ? 150 : 82)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.5)))
                }
                HStack(spacing: 10) {
                    if call.state != .ended {
                        iconButton(call.muted ? "mic.slash.fill" : "mic.fill", call.muted ? L("Unmute") : L("Mute"),
                                   call.muted ? .orange : .gray, action: center.toggleMute)
                        iconButton(call.camera ? "video.fill" : "video.slash.fill", call.camera ? L("Turn Camera Off") : L("Turn Camera On"),
                                   call.camera ? .blue : .gray, action: center.toggleCamera)
                        iconButton(center.fullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                                   center.fullScreen ? L("Exit Full Screen") : L("Full Screen"), .gray, action: center.toggleFullScreen)
                            .keyboardShortcut("f", modifiers: [.control, .command])
                        iconButton("phone.down.fill", L("End Call"), .red, action: center.end)
                    }
                }
                .padding(8)
                .background(.ultraThinMaterial, in: Capsule())
                .frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .background {
            // Esc leaves full screen, as everywhere else.
            Button("", action: center.exitFullScreen).keyboardShortcut(.cancelAction).opacity(0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
    }

    /// The camera's own picture, straight from the capture session.
    static let preview: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: CameraEncoder.shared.session)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()

    private func iconButton(_ icon: String, _ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.callout.weight(.medium))
                .frame(width: 44, height: 36)
                .foregroundStyle(.white)
                .background(color, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(title)
    }

    @ViewBuilder private func status(of call: CallCenter.Call) -> some View {
        switch call.state {
        case .ringing: Text(call.videoOffer ? L("Incoming video call") : L("Incoming voice call"))
        case .calling: Text(L("Calling…"))
        case .connecting: Text(L("Connecting…"))
        case .ended: Text(L("Call ended"))
        case .active:
            // The clock ticks on its own; nothing else needs redrawing for it.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let seconds = max(0, Int(context.date.timeIntervalSince(call.since ?? context.date)))
                Text(String(format: "%d:%02d", seconds / 60, seconds % 60))
            }
        }
    }

    private func button(_ icon: String, _ title: String, _ color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .foregroundStyle(.white)
                .background(color, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}
