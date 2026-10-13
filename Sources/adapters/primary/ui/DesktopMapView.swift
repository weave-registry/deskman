import AppKit
import SwiftUI
import DeskmanPorts

enum MapMode: String, CaseIterable, Identifiable {
    // One name with the menu's What Deskman Knows (the user, 2026-10-13); it was "Learned".
    case now = "Now", arrange = "Smart Arrange", learned = "What Deskman Knows"
    var id: String { rawValue }

    /// By its name, or its old one: `--diagnose-map … Learned` must not land on Now.
    static func named(_ name: String) -> MapMode? {
        MapMode(rawValue: name) ?? (name.lowercased() == "learned" ? .learned : nil)
    }

    var tab: MapTab {
        switch self {
        case .now: .now
        case .arrange: .arrange
        case .learned: .learned
        }
    }
}

/// The desktop to scale (ADR-2610101523 §3): the windows now, where Smart Arrange would put them,
/// and what Deskman has learned. The Map tab of the Deskman panel; it was a window of its own.
struct DesktopMapView: View {
    let model: LearningModel
    let outline: ScreenOutlineOverlay
    @State private var mode: MapMode
    /// Outline this tab on the real screen, as Hammerspoon's zone grid did.
    @State private var onScreen = false
    /// The box under the pointer; its outline on the screen turns green.
    @State private var hover: Int?

    init(model: LearningModel, outline: ScreenOutlineOverlay, initial: MapMode = .now, onScreen: Bool = false) {
        self.model = model
        self.outline = outline
        _mode = State(initialValue: initial)
        _onScreen = State(initialValue: onScreen)
    }
    /// Nil: the desktop on screen. A number: that desktop's windows.
    @State private var desktop: Int?

    var body: some View {
        VStack(spacing: 8) {
            // Laid out for the panel's standard size, 540 pt wide: the tabs, then this tab's controls.
            Picker("", selection: $mode) {
                ForEach(MapMode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            HStack(spacing: 10) {
                if mode == .now, let numbers = model.map?.otherDesktopNumbers, !numbers.isEmpty {
                    Picker("", selection: $desktop) {
                        Text("This desktop").tag(Int?.none)
                        ForEach(numbers, id: \.self) { Text("Desktop \($0)").tag(Int?.some($0)) }
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                // Pins are shown here, so they are removed here (menu review, 2026-10-12).
                if mode == .now, desktop == nil, !(model.map?.pinned.isEmpty ?? true) {
                    Button("Unpin All") { model.unpinAll(); model.refreshMap() }
                        .help("📌 windows stay where they are for 30 minutes. Unpin them so Smart Arrange may move them again.")
                }
                if mode == .arrange {
                    Toggle("Keep Arranged", isOn: Binding(get: { model.keepArranged }, set: { model.setKeepArranged($0) }))
                        .toggleStyle(.switch)
                        .help("Smart Arrange each time a window opens, closes, minimizes or you switch desktop.")
                }
                Spacer(minLength: 0)
                Toggle("On Screen", isOn: $onScreen)
                    .toggleStyle(.switch)
                    .help("Outline this tab's zones on your real screen. Point at a box here to light it up there.")
                if mode == .arrange {
                    Button("Apply") { model.smartArrange(); model.refreshMap() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.map?.plan.isEmpty ?? true)
                }
            }
            .controlSize(.small)
            if let map = model.map {
                // Learned is words only: the habit strip overlapped its labels (the user, 2026-10-13).
                if mode != .learned {
                    MapCanvas(map: map, mode: mode, desktop: mode == .now ? desktop : nil, hover: { hover = $0 })
                        .clipped()
                }
                Text(caption(map))
                    .font(.caption)
                    .lineLimit(3)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if mode == .learned {
                    KnowledgeList(knowledge: map.knowledge, confirm: { model.confirm($0); model.refreshMap() })
                }
            } else {
                ContentUnavailableView("Reading your desktop…", systemImage: "rectangle.3.group")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Live while shown: windows move, activity changes the plan.
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in model.refreshMap() }
        .onChange(of: onScreen) { syncOutline() }
        .onChange(of: mode) { hover = nil; syncOutline() }
        .onChange(of: hover) { syncOutline() }
        .onChange(of: model.map) { syncOutline() }
        .onAppear { model.refreshMap(); syncOutline() }
        .onDisappear { outline.hide() }
    }

    /// What the screen shows follows the map: its tab, its data, its pointer.
    private func syncOutline() {
        guard onScreen, let map = model.map else { return outline.hide() }
        outline.show(map.outlines(mode.tab), on: map.displays, highlight: hover)
    }

    private func caption(_ m: DesktopMap) -> String {
        switch mode {
        case .now where desktop != nil:
            let n = m.otherDesktops.filter { $0.desktop == desktop }.count
            return "\(n) windows on desktop \(desktop!). Focus one to go there; Deskman moves windows only on the desktop on screen."
        case .now:
            let pinned = m.pinned.isEmpty ? "" : " 📌 marks a window you placed: Smart Arrange keeps it for 30 minutes, or until Unpin All."
            let projects = Set(m.bound.values).sorted()
            let bound = projects.isEmpty ? "" : " 🔗 bound: \(projects.joined(separator: ", "))."
            let naming = m.namingProblem.map { " Naming paused: \($0)." } ?? ""
            return "\(m.windows.count) windows here. \(m.hiddenCount) minimized or on other desktops." + pinned + bound + naming
        case .arrange:
            if m.plan.isEmpty { return "Nothing to arrange on this desktop." }
            let away = m.parked.isEmpty ? "" : " No room, left where they are: \(m.parked.joined(separator: ", "))."
            return "★ marks the main zone, for the most active window." + away + (m.planNote.map { " " + $0 } ?? "")
        case .learned:
            if m.habits.isEmpty { return "What Deskman knows. Habits come from arrangements that stay put for 30 seconds." }
            return "What Deskman knows. A habit still learning can be confirmed: it then counts as learned."
        }
    }
}

private struct MapCanvas: View {
    let map: DesktopMap
    let mode: MapMode
    let desktop: Int?
    /// The index of the box under the pointer, as `DesktopMap.outlines` counts them.
    let hover: (Int?) -> Void

    var body: some View {
        GeometryReader { geo in
            let b = map.bounds
            let scale = min(geo.size.width / b.width, geo.size.height / b.height)
            let ox = (geo.size.width - b.width * scale) / 2, oy = (geo.size.height - b.height * scale) / 2
            let place = { (r: Rect) -> CGRect in
                CGRect(x: ox + (r.x - b.x) * scale, y: oy + (r.y - b.y) * scale,
                       width: r.width * scale, height: r.height * scale)
            }
            ZStack {
                ForEach(map.displays, id: \.index) { d in
                    // A solid screen, so the windows read on the glass whatever is behind the panel.
                    box(place(d.visibleFrame), fill: Color(nsColor: .windowBackgroundColor).opacity(0.85),
                        stroke: Color.primary.opacity(0.45), radius: 10)
                }
                switch mode {
                case .now:
                    // Back to front, so the frontmost window is drawn last, on top.
                    let shown = desktop.map { d in map.otherDesktops.filter { $0.desktop == d } } ?? map.windows
                    ForEach(Array(shown.reversed().enumerated()), id: \.offset) { _, w in
                        let pin = (map.pinned.contains(w.id) ? "📌 " : "") + (map.bound[w.id] != nil ? "🔗 " : "")
                        // The model's name first, when it has one; the app and title under it.
                        let name = map.names[w.id]
                        let runs = (map.jobs[w.id] ?? []).isEmpty ? "" : " · runs " + map.jobs[w.id]!.joined(separator: ", ")
                        labeled(place(w.frame), pin + (name ?? w.app), (name.map { _ in "\(w.app) · \(w.title)" } ?? w.title) + runs,
                                fill: Color.accentColor.opacity(0.16), stroke: Color.accentColor)
                    }
                case .arrange:
                    ForEach(Array(map.plan.enumerated()), id: \.offset) { i, z in
                        let name = z.window.flatMap { map.names[$0] } ?? z.app
                        labeled(place(z.frame), (z.isMain ? "★ " : "") + name, name == z.app ? nil : z.app,
                                fill: Color.teal.opacity(z.isMain ? 0.28 : 0.16), stroke: .teal, dashed: true)
                            .onHover { hover($0 ? i : nil) }
                    }
                case .learned:
                    EmptyView()   // What Deskman Knows shows words, not boxes (KnowledgeList)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    // `.position` moves a view's layout and its hit area together; `.offset` would
    // move only the drawing, and clicks would land on the old place.
    private func box(_ r: CGRect, fill: Color, stroke: Color, radius: CGFloat = 6, dashed: Bool = false) -> some View {
        shape(r.size, fill: fill, stroke: stroke, radius: radius, dashed: dashed)
            .position(x: r.midX, y: r.midY)
    }

    private func shape(_ size: CGSize, fill: Color, stroke: Color, radius: CGFloat = 6, dashed: Bool = false) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(fill)
            .overlay(RoundedRectangle(cornerRadius: radius)
                .strokeBorder(stroke, style: StrokeStyle(lineWidth: 1.5, dash: dashed ? [5, 4] : [])))
            .frame(width: max(size.width, 1), height: max(size.height, 1))
    }

    private func labeled(_ r: CGRect, _ title: String, _ detail: String?, fill: Color, stroke: Color,
                         dashed: Bool = false) -> some View {
        shape(r.size, fill: fill, stroke: stroke, dashed: dashed)
            .overlay(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                    if let detail, !detail.isEmpty, r.height > 34 {
                        Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(5)
            }
            .contentShape(RoundedRectangle(cornerRadius: 6))
            .position(x: r.midX, y: r.midY)
    }
}

/// What Deskman knows, in words: a title per section, a line per fact. Text only; nothing here acts.
private struct KnowledgeList: View {
    let knowledge: DesktopMap.Knowledge
    /// A habit still learning, confirmed by the person: "it belongs there".
    let confirm: (Habit) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(knowledge.sections, id: \.title) { section in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(section.title)
                            .font(.caption.weight(.semibold))
                        ForEach(Array(section.lines.enumerated()), id: \.offset) { i, line in
                            HStack(spacing: 6) {
                                Text(line)
                                    .font(.caption)
                                    .foregroundStyle(line == DesktopMap.Knowledge.nothingYet ? .tertiary : .secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if let habit = section.confirmable[i] {
                                    Button("Confirm") { confirm(habit) }
                                        .controlSize(.mini)
                                        .help("Tell Deskman that \(habit.app) belongs there")
                                }
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }
}
