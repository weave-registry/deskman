import AppKit
import SwiftUI
import DeskmanPorts

/// Outlines drawn over the real screen, chosen in the desktop map (ADR-2610101523,
/// amendment 2026-10-12): Hammerspoon's zone grid, with the map as its switch.
/// One click-through panel per display; the outline under the map's pointer is green.
@MainActor final class ScreenOutlineOverlay {
    @Observable final class State {
        /// Frames local to the panel, top-left, y down.
        var items: [(index: Int, frame: CGRect, label: String, kind: ScreenOutline.Kind)] = []
        var active: Int?
    }

    private var panels: [(display: Display, panel: NSPanel, state: State)] = []

    func show(_ outlines: [ScreenOutline], on displays: [Display], highlight: Int?) {
        guard let primary = NSScreen.screens.first else { return }
        if panels.map(\.display) != displays {
            hide()
            panels = displays.map { d in
                let state = State()
                // A new panel already has an empty content view: replace it now, not "if none".
                return (d, Self.panel(drawing: state), state)
            }
        }
        for (display, panel, state) in panels {
            let v = display.visibleFrame
            // Each outline goes on the display that holds its center.
            state.items = outlines.enumerated().compactMap { i, o in
                guard v.contains(Point(x: o.frame.x + o.frame.width / 2, y: o.frame.y + o.frame.height / 2)) else { return nil }
                return (i, CGRect(x: o.frame.x - v.x, y: o.frame.y - v.y, width: o.frame.width, height: o.frame.height),
                        o.label, o.kind)
            }
            if state.active != highlight { state.active = highlight }
            let f = CoordinateSpace.appKit(fromTopLeft: v, primaryDisplayHeight: Double(primary.frame.height))
            panel.setFrame(NSRect(x: f.x, y: f.y, width: f.width, height: f.height), display: false)
            panel.orderFrontRegardless()
        }
    }

    func hide() {
        for p in panels { p.panel.orderOut(nil) }
        panels = []
    }

    /// For `--diagnose-outline`: each panel's frame, whether it is on screen, and what it draws.
    var report: [String] {
        panels.map { "display \($0.display.index): \($0.panel.isVisible ? "on screen" : "hidden") "
            + "\(Int($0.panel.frame.width))×\(Int($0.panel.frame.height)) "
            + "drawing=\($0.panel.contentView is NSHostingView<OutlineView>) "
            + "outlines=\($0.state.items.map(\.label))" }
    }

    private static func panel(drawing state: State) -> NSPanel {
        let p = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.ignoresMouseEvents = true
        // Under the drag-to-snap overlay, over every app window.
        p.level = .floating
        p.hasShadow = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // An NSPanel hides when its app is not in front; these must stay while you work in another app.
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: OutlineView(state: state))
        return p
    }
}

struct OutlineView: View {
    let state: ScreenOutlineOverlay.State

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(state.items, id: \.index) { item in
                let on = item.index == state.active
                let tint = on ? Color.green : Self.tint(item.kind)
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(on ? 0.25 : 0.08))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.9), lineWidth: on ? 4 : 2))
                    .overlay(Text(item.label)
                        .font(.system(size: on ? 28 : 22, weight: .semibold))
                        .foregroundStyle(tint.opacity(0.95))
                        .shadow(color: .black.opacity(0.6), radius: 3)
                        .lineLimit(2).multilineTextAlignment(.center).padding(10))
                    .frame(width: max(item.frame.width - 8, 1), height: max(item.frame.height - 8, 1))
                    .position(x: item.frame.midX, y: item.frame.midY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func tint(_ kind: ScreenOutline.Kind) -> Color {
        switch kind {
        case .zone: Color(red: 0.45, green: 0.6, blue: 0.85)   // Hammerspoon's muted blue
        case .main: .teal
        case .learned: .green
        case .learning: .red
        }
    }
}
