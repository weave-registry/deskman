import AppKit
import SwiftUI
import DeskmanPorts

/// The green button puts a grown window back in its zone (ADR-2611111100). Deskman's one *active* event tap: a
/// click it claims is taken, down and up, so macOS never sends the window to full screen. Every other click,
/// and any click with Option held, passes untouched. Each second it lets the port note where windows sit.
@MainActor public final class GreenButtonWatch {
    private let port: any SnapPort
    private let report: @MainActor (CommandOutcome) -> Void
    private var tap: CFMachPort?
    private var timer: Timer?
    /// The window whose button-down was taken; its button-up is taken too.
    private var claimed: WindowID?
    /// A ring on each green button whose click Deskman would take (the user, 2026-11-11: "where am I supposed to see that?").
    private let rings = GreenButtonRings()

    /// Nil when macOS refuses the event tap (no Accessibility permission).
    public init?(port: any SnapPort, report: @escaping @MainActor (CommandOutcome) -> Void) {
        self.port = port
        self.report = report
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: CGEventMask(mask), callback: { _, type, event, info in
            // The tap's source is on the main run loop, so this runs on the main thread.
            let watch = Unmanaged<GreenButtonWatch>.fromOpaque(info!).takeUnretainedValue()
            let take = MainActor.assumeIsolated { watch.handle(type, event) }
            return take ? nil : Unmanaged.passUnretained(event)
        }, userInfo: me) else { return nil }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        tick()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        port.observe()
        rings.show(port.greenButtonHints())
    }

    /// True takes the event away from every app.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            claimed = nil
            return false
        case .leftMouseDown:
            claimed = nil
            // A click can change which window is in front: no ring stays where it may now be wrong.
            rings.show([])
            // Option-click is macOS's zoom; a double click is the title bar's. Both stay macOS's.
            guard !event.flags.contains(.maskAlternate), event.getIntegerValueField(.mouseEventClickState) <= 1 else {
                return false
            }
            // CGEvent locations are top-left, y down: the hexagon's own convention.
            let p = Point(x: event.location.x, y: event.location.y)
            claimed = port.greenButtonClaim(at: p)
            return claimed != nil
        case .leftMouseUp:
            guard let id = claimed else { return false }
            claimed = nil
            // Move the window after the tap has returned: the click is not held while it moves.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let outcome = self.port.returnToZone(id)
                if !outcome.succeeded { self.report(outcome) }
                self.rings.show(self.port.greenButtonHints())
            }
            return true
        default:
            return false
        }
    }
}

/// Green rings drawn over green buttons, one small panel each. They take no clicks: a click on the ring is a click
/// on the button under it.
@MainActor final class GreenButtonRings {
    /// How far the ring reaches past the button, on every side, in points.
    static let margin = 6.0
    private var panels: [NSPanel] = []

    /// `buttons` top-left, y down, as the hexagon has them.
    func show(_ buttons: [Rect]) {
        guard let primary = NSScreen.screens.first else { return }
        let h = Double(primary.frame.height)
        while panels.count < buttons.count { panels.append(Self.panel()) }
        for (i, panel) in panels.enumerated() {
            guard i < buttons.count else { panel.orderOut(nil); continue }
            let b = buttons[i], m = Self.margin
            let around = Rect(x: b.x - m, y: b.y - m, width: b.width + 2 * m, height: b.height + 2 * m)
            let f = CoordinateSpace.appKit(fromTopLeft: around, primaryDisplayHeight: h)
            panel.setFrame(NSRect(x: f.x, y: f.y, width: f.width, height: f.height), display: true)
            panel.orderFrontRegardless()
        }
    }

    private static func panel() -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        p.contentView = NSHostingView(rootView: Ring())
        return p
    }

    private struct Ring: View {
        var body: some View {
            Circle()
                .strokeBorder(Color.green, lineWidth: 2.5)
                .shadow(color: .green.opacity(0.9), radius: 3)
                .padding(1)
        }
    }
}
