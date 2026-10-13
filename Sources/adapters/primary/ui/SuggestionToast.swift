import AppKit
import SwiftUI
import DeskmanPorts

/// A small glass card at the top right of the main display. Like the main panel,
/// it never takes focus from the app you are using.
@MainActor public final class SuggestionToast {
    private let panel: NSPanel

    public init(model: LearningModel) {
        panel = ToastPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 96),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let glass = NSGlassEffectView()
        glass.cornerRadius = 22
        let hosting = NSHostingView(rootView: ToastView(model: model))
        hosting.sizingOptions = [.intrinsicContentSize]
        glass.contentView = hosting
        panel.contentView = glass

        model.onToastChange = { [weak self] toast in
            if toast == nil { self?.panel.orderOut(nil) } else { self?.present() }
        }
    }

    private func present() {
        guard let screen = NSScreen.screens.first else { return }
        panel.layoutIfNeeded()
        let size = panel.contentView?.fittingSize ?? panel.frame.size
        let v = screen.visibleFrame
        panel.setFrame(NSRect(x: v.maxX - size.width - 16, y: v.maxY - size.height - 12,
                              width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }
}

private final class ToastPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct ToastView: View {
    let model: LearningModel

    var body: some View {
        Group {
            switch model.toast {
            case .suggestion(let s):
                row(icon: "sparkles", title: s.summary + "?",
                    detail: "Accept this 3 times and Deskman does it by itself.") {
                    Button("Not now", action: model.dismiss).buttonStyle(.glass)
                    Button("Arrange", action: model.accept).buttonStyle(.glassProminent)
                }
            case .applied(let title, let detail):
                row(icon: "checkmark.circle.fill", title: title, detail: detail) {
                    Button("Undo", action: model.undo).buttonStyle(.glass)
                }
            case .binding(let s):
                row(icon: "link", title: "Bind \(s.names.joined(separator: " and "))?",
                    detail: "They look like one project: \(s.project). Bound windows arrange, focus, move and minimize together.") {
                    Button("Not now") { model.declineBinding(s) }.buttonStyle(.glass)
                    Button("Bind") { model.bind(s) }.buttonStyle(.glassProminent)
                }
            case .note(let text):
                row(icon: "info.circle", title: text, detail: nil) { EmptyView() }
            case nil:
                EmptyView()
            }
        }
        .padding(14)
        .frame(width: 380)
    }

    private func row(icon: String, title: String, detail: String?,
                     @ViewBuilder buttons: () -> some View) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            buttons()
        }
    }
}
