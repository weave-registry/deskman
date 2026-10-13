import Combine
import SwiftUI
import DeskmanPorts

/// The panel's content. The panel itself is the glass; everything here floats on it.
public struct DeskmanView: View {
    @Bindable var model: ChatModel
    let hide: () -> Void
    @FocusState private var inputFocused: Bool
    /// While permission is missing, poll for it: macOS sends no notification when it is granted.
    private let statusTimer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    public init(model: ChatModel, hide: @escaping () -> Void = {}) {
        self.model = model
        self.hide = hide
    }

    public var body: some View {
        GlassEffectContainer(spacing: 12) {
            VStack(spacing: 0) {
                if !model.status.windowControlTrusted {
                    PermissionCard(requestPermission: model.requestPermission)
                        .padding(.horizontal, 14)
                        .padding(.bottom, 6)
                }
                transcript
                inputBar
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .onAppear { inputFocused = true }
        .onReceive(statusTimer) { _ in model.refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: DeskmanPanel.didShow)) { _ in inputFocused = true }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if model.entries.isEmpty {
                        Examples(submit: model.submit)
                    }
                    ForEach(model.entries) { entry in
                        EntryRow(entry: entry).id(entry.id)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                    if model.isBusy {
                        ThinkingRow().id("busy")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .animation(.smooth(duration: 0.25), value: model.entries)
            }
            .scrollIndicators(.never)
            .onChange(of: model.entries.count) {
                withAnimation { proxy.scrollTo(model.entries.last?.id, anchor: .bottom) }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .foregroundStyle(.tint)
            TextField("Tell Deskman what to do with your windows", text: $model.input)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($inputFocused)
                .onSubmit { model.submit() }
                .disabled(model.isBusy)
            Button {
                model.submit()
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.circle)
            .disabled(model.input.trimmingCharacters(in: .whitespaces).isEmpty || model.isBusy)
            .keyboardShortcut(.defaultAction)
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .padding(.vertical, 8)
        .glassEffect(.regular.interactive(), in: .capsule)
        .padding(14)
    }
}

// MARK: - Pieces

/// The panel's top bar, over both tabs: the name, the model's state, Ask | Map, and hide.
struct PanelBar: View {
    @Bindable var chat: ChatModel
    @Binding var tab: PanelTab
    let hide: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.3.group.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.tint)
            Text("Deskman")
                .font(.system(size: 15, weight: .semibold))
            ModelBadge(availability: chat.status.assistant)
            Spacer()
            Picker("", selection: $tab) {
                ForEach(PanelTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 140)
            Spacer()
            if tab == .ask {
                Button(action: chat.clear) {
                    Image(systemName: "arrow.counterclockwise")
                }
                .buttonStyle(.glass)
                .buttonBorderShape(.circle)
                .help("Start a new conversation")
                .disabled(chat.entries.isEmpty || chat.isBusy)
            }
            Button(action: hide) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .help("Hide (Esc)")
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }
}

private struct ModelBadge: View {
    let availability: AssistantAvailability

    var body: some View {
        let ready = availability == .available
        HStack(spacing: 5) {
            Circle()
                .fill(ready ? Color.green : Color.orange)
                .frame(width: 6, height: 6)
            Text(ready ? "On-device" : "Model unavailable")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .glassEffect(.regular, in: .capsule)
        .help(reason)
    }

    private var reason: String {
        if case .unavailable(let why) = availability { return why }
        return "Apple's on-device model is ready. Nothing leaves your Mac."
    }
}

private struct PermissionCard: View {
    let requestPermission: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(.orange)
            Text("Deskman needs Accessibility permission to move windows.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Allow…", action: requestPermission)
                .buttonStyle(.glassProminent)
                .tint(.orange)
        }
        .padding(12)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 16))
    }
}

private struct Examples: View {
    let submit: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ask for a layout")
                .font(.system(size: 22, weight: .semibold))
                .padding(.top, 8)
            Text("Press ⌃⌥Space anywhere to bring me back.")
                .font(.callout)
                .foregroundStyle(.secondary)
            FlowLayout(spacing: 8) {
                ForEach(ChatModel.examples, id: \.self) { example in
                    Button(example) { submit(example) }
                        .buttonStyle(.glass)
                        .controlSize(.regular)
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EntryRow: View {
    let entry: ChatModel.Entry

    var body: some View {
        switch entry.kind {
        case .user:
            Text(entry.text)
                .font(.system(size: 14))
                .padding(.horizontal, 14).padding(.vertical, 8)
                .glassEffect(.regular.tint(.accentColor.opacity(0.35)), in: .rect(cornerRadius: 18))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(entry.text)
                .font(.system(size: 14))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .action(let succeeded):
            Label(entry.text, systemImage: succeeded ? "checkmark" : "exclamationmark")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(succeeded ? Color.secondary : Color.red)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .glassEffect(succeeded ? .regular : .regular.tint(.red.opacity(0.2)), in: .capsule)
        }
    }
}

private struct ThinkingRow: View {

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "apple.intelligence")
                .symbolEffect(.pulse, options: .repeating)
                .foregroundStyle(.tint)
            Text("Thinking on-device…")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }
}

/// Lays children out left to right, wrapping to a new line when a row is full.
private struct FlowLayout: SwiftUI.Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for i in row.indices {
                let size = subviews[i].sizeThatFits(.unspecified)
                subviews[i].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for i in subviews.indices {
            let size = subviews[i].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let last = rows.count - 1
            rows[last].width += rows[last].indices.isEmpty ? size.width : size.width + spacing
            rows[last].height = max(rows[last].height, size.height)
            rows[last].indices.append(i)
        }
        return rows
    }
}
