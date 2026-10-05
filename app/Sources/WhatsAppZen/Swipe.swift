import AppKit
import Combine

/// Two fingers moved sideways on the trackpad, reported to whichever message
/// is under the pointer so it can slide and be replied to, as on the phone.
final class SwipeMonitor {
    static let shared = SwipeMonitor()

    enum Event {
        /// How far the fingers have travelled to the right, in points.
        case moved(CGFloat)
        case ended(CGFloat)
    }

    let events = PassthroughSubject<Event, Never>()

    private var horizontal: Bool?
    private var dx: CGFloat = 0
    private var dy: CGFloat = 0
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    private func handle(_ event: NSEvent) {
        // A trackpad gesture, not a mouse wheel and not the glide after lifting.
        guard event.hasPreciseScrollingDeltas, event.momentumPhase.isEmpty else { return }
        switch event.phase {
        case .began:
            horizontal = nil
            dx = 0
            dy = 0
        case .changed:
            // With "natural" scrolling the content follows the fingers, so the
            // delta already points their way; otherwise it is reversed.
            dx += event.isDirectionInvertedFromDevice ? event.scrollingDeltaX : -event.scrollingDeltaX
            dy += event.scrollingDeltaY
            if horizontal == nil, abs(dx) + abs(dy) > 6 {
                // Decided once per gesture, so scrolling the chat never tips into a reply.
                horizontal = abs(dx) > abs(dy) * 2
            }
            if horizontal == true { events.send(.moved(dx)) }
        case .ended, .cancelled:
            if horizontal == true { events.send(.ended(event.phase == .cancelled ? 0 : dx)) }
            horizontal = nil
        default:
            break
        }
    }
}
