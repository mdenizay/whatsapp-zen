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
    }

    @Published private(set) var call: Call?
    private var panel: NSPanel?
    private var ring: NSSound?

    private var store: AppStore? { AppModel.shared.accounts.first { $0.id == call?.account } }

    /// An incoming call started ringing.
    func ringing(id: String, jid: String, name: String, account: AppStore) {
        // One call at a time: a second caller is left to the phone.
        guard call == nil || call?.state == .ended else { return }
        call = Call(id: id, jid: jid, name: name, account: account.id, incoming: true, state: .ringing)
        ring = NSSound(named: "Submarine")
        ring?.loops = true
        ring?.play()
        show()
    }

    /// The core reported a change in a call's state.
    func update(id: String, jid: String, name: String, state: String, muted: Bool?, account: AppStore) {
        if call?.id != id {
            // A call placed from here, heard about for the first time.
            guard state == "calling" else { return }
            call = Call(id: id, jid: jid, name: name, account: account.id, incoming: false, state: .calling)
            show()
        }
        switch state {
        case "connecting": call?.state = .connecting
        case "active":
            call?.state = .active
            call?.since = Date()
        case "muted": call?.muted = muted ?? false
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

    func start(_ chat: Chat, in store: AppStore) {
        guard call == nil else { return }
        Task { @MainActor in
            guard await microphoneAllowed() else {
                store.errorText = Self.microphoneDenied
                return
            }
            do {
                try await Core.run("call_start", ["jid": chat.jid], account: store.id)
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
            do {
                try await Core.run("call_accept", ["id": call.id], account: store.id)
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
        guard call != nil, call?.state != .ended else { return }
        call?.state = .ended
        let id = call?.id
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [self] in
            guard call?.id == id else { return }
            call = nil
            panel?.orderOut(nil)
            panel = nil
        }
    }

    private func show() {
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 150),
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

/// What the call window shows: who, what is happening, and the two or three
/// things that can be done about it.
struct CallView: View {
    @ObservedObject var center: CallCenter

    var body: some View {
        if let call = center.call {
            VStack(spacing: 14) {
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
                        button("phone.fill", L("Accept"), .green, action: center.accept)
                    } else if call.state != .ended {
                        button(call.muted ? "mic.slash.fill" : "mic.fill", call.muted ? L("Unmute") : L("Mute"),
                               call.muted ? .orange : .gray, action: center.toggleMute)
                        button("phone.down.fill", L("End Call"), .red, action: center.end)
                    }
                }
                .frame(height: 40)
            }
            .padding(16)
            .frame(width: 300)
        }
    }

    @ViewBuilder private func status(of call: CallCenter.Call) -> some View {
        switch call.state {
        case .ringing: Text(L("Incoming voice call"))
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
