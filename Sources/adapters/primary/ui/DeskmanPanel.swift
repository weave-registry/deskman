import AppKit
import SwiftUI

/// A floating glass panel that takes typing WITHOUT activating Deskman. The app
/// the person was using stays frontmost, so "this window" still means their window.
@MainActor public final class DeskmanPanel {
    public static let didShow = Notification.Name("DeskmanPanel.didShow")
    static let cornerRadius: CGFloat = 26

    private let panel: NSPanel
    private let state = PanelState()
    /// The map's outlines on the real screen (ADR-2610101523 §3).
    private let outline = ScreenOutlineOverlay()

    public init(model: ChatModel, learning: LearningModel) {
        panel = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 460),
            styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.title = "Deskman"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        // A clear window, so the glass is the only surface you see.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 420, height: 320)

        let glass = NSGlassEffectView()
        glass.cornerRadius = Self.cornerRadius
        glass.style = .regular
        let hosting = NSHostingView(rootView: PanelView(state: state, chat: model, learning: learning, outline: outline,
                                                        hide: { [weak self] in self?.hide() }))
        hosting.sizingOptions = []
        glass.contentView = hosting
        panel.contentView = glass
        panel.center()
        (panel as? KeyablePanel)?.onCancel = { [weak self] in self?.hide() }
    }

    public var isVisible: Bool { panel.isVisible }

    /// `tab`: Ask or Map; nil keeps the current one. `mapTab`: "Now", "Smart Arrange" or "What Deskman Knows" ("Learned" still works).
    /// `onScreen` starts the map with its screen outlines on, for `--diagnose-outline`.
    public func show(tab: PanelTab? = nil, mapTab: String? = nil, onScreen: Bool = false) {
        if let mapTab { state.mapMode = MapMode.named(mapTab) ?? .now }
        if onScreen { state.mapOnScreen = true }
        if mapTab != nil || onScreen { state.generation += 1 }   // a fresh map view with these settings
        if let tab { state.tab = tab }
        panel.makeKeyAndOrderFront(nil)
        NotificationCenter.default.post(name: Self.didShow, object: nil)
    }

    public func toggle() {
        if panel.isVisible && panel.isKeyWindow { hide() } else { show() }
    }

    func hide() {
        panel.orderOut(nil)
        outline.hide()
    }

    /// Draws the panel into a PNG, for `--diagnose-map`. Deskman's own window needs no Screen Recording permission.
    public func snapshot(to url: URL) -> Bool {
        // The content inside the glass: the glass itself does not draw into an offscreen picture.
        guard let view = (panel.contentView as? NSGlassEffectView)?.contentView ?? panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            return false
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return false }
        return (try? png.write(to: url)) != nil
    }

    /// What the map's screen outlines draw now, one line per display.
    public var outlineReport: [String] { outline.report }
}

public enum PanelTab: String, CaseIterable, Identifiable {
    case ask = "Ask", map = "Map"
    public var id: String { rawValue }
}

@MainActor @Observable final class PanelState {
    var tab: PanelTab = .ask
    var mapMode: MapMode = .now
    var mapOnScreen = false
    var generation = 0
}

/// Ask (the conversation) and Map (the desktop to scale), under one bar.
struct PanelView: View {
    @Bindable var state: PanelState
    let chat: ChatModel
    let learning: LearningModel
    let outline: ScreenOutlineOverlay
    let hide: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(chat: chat, tab: $state.tab, hide: hide)
            switch state.tab {
            case .ask:
                DeskmanView(model: chat, hide: hide)
            case .map:
                DesktopMapView(model: learning, outline: outline, initial: state.mapMode, onScreen: state.mapOnScreen)
                    .id(state.generation)
            }
        }
        // One size for both tabs: the map scales to the panel (the user, 2026-10-12).
        .onChange(of: state.tab) { _, tab in
            if tab == .ask { outline.hide() }
        }
    }
}

private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    // Esc hides the panel; the map's outlines go with it (`onDisappear` does not run for a hidden window).
    var onCancel: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { if let onCancel { onCancel() } else { orderOut(nil) } }
}
