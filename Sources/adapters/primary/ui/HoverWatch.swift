import AppKit
import DeskmanPorts

/// Expand on Hover's mouse (ADR-2611111000): a listen-only event tap for moves and the left button,
/// apart from drag-to-snap's. Every move goes to the port; a rest of `dwell` seconds is said once.
@MainActor public final class HoverWatch {
    /// How long the mouse must stay put before the window under it expands: passing over is not pointing at.
    static let dwell = 0.3
    /// Moves under this many points, in total, still count as resting (a hand on a mouse is never still).
    static let jitter = 4.0

    private let port: any HoverPort
    private var tap: CFMachPort?
    private var timer: Timer?
    private var at: Point?
    private var since = Date()
    private var said = false

    /// Nil when macOS refuses the event tap (no Accessibility permission).
    public init?(port: any HoverPort) {
        self.port = port
        let types: [CGEventType] = [.mouseMoved, .leftMouseDown, .leftMouseUp, .leftMouseDragged]
        let mask = types.reduce(0) { $0 | (1 << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .listenOnly,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            // The tap's source is on the main run loop, so this runs on the main thread.
            let watch = Unmanaged<HoverWatch>.fromOpaque(info!).takeUnretainedValue()
            MainActor.assumeIsolated { watch.handle(type, event) }
            return Unmanaged.passUnretained(event)
        }, userInfo: me) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.check() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        // CGEvent locations are top-left, y down: the hexagon's own convention.
        let p = Point(x: event.location.x, y: event.location.y)
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            port.pointerPressed()
        case .leftMouseUp:
            port.pointerReleased()
            restart(at: p)
        case .mouseMoved, .leftMouseDragged:
            port.pointerMoved(to: p)
            if let a = at, abs(a.x - p.x) + abs(a.y - p.y) <= Self.jitter { return }
            restart(at: p)
        default:
            break
        }
    }

    private func restart(at p: Point) {
        at = p
        since = Date()
        said = false
    }

    private func check() {
        guard !said, let at, Date().timeIntervalSince(since) >= Self.dwell else { return }
        said = true
        port.pointerRested(at: at)
    }
}
