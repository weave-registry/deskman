import AppKit
import ApplicationServices
import DeskmanPorts

/// One look at the desktop, made off the main thread (ADR-2610121200): Accessibility,
/// the window server and Spaces. Everything but the stable window IDs, which the main
/// thread gives out, because only it holds the registry.
struct DesktopRead: @unchecked Sendable {
    /// What an app is, read on the main thread before the read starts.
    struct App: Sendable {
        let pid: pid_t
        let name: String
        let isFinder: Bool
    }

    enum Source {
        /// Seen by Accessibility: it can be moved.
        case ax(AXUIElement, CGWindowID?)
        /// Seen only by the window server, on another desktop: it can be focused, not moved.
        case server(CGWindowID)
    }

    struct Item {
        let source: Source
        let pid: pid_t
        let app: String
        let title: String
        let frame: Rect
        let isMinimized: Bool
        let document: String?
        let desktop: Int?
        let isOnCurrentDesktop: Bool
    }

    /// In the order `windows()` lists them: this desktop front to back, then the others.
    var items: [Item] = []
    /// Titles Accessibility gave, by window number, to name a window later seen only on another desktop.
    var titles: [CGWindowID: String] = [:]
    var noSpaces = false
    var seconds = 0.0

    static func read(apps: [App], knownTitles: [CGWindowID: String]) -> DesktopRead {
        let start = Date()
        var out = DesktopRead()
        let names = Dictionary(apps.map { ($0.pid, $0.name) }, uniquingKeysWith: { a, _ in a })

        // 1. Accessibility: the windows Deskman can act on, in app order.
        var listed: [(number: CGWindowID?, item: Item)] = []
        for app in apps {
            let axApp = AXUIElementCreateApplication(app.pid)
            let elements: [AXUIElement] = copy(axApp, kAXWindowsAttribute) ?? []
            for element in elements {
                let subrole: String? = copy(element, kAXSubroleAttribute)
                guard subrole == nil || subrole == kAXStandardWindowSubrole as String else { continue }
                guard let frame = frame(of: element) else { continue }
                let title: String = copy(element, kAXTitleAttribute) ?? ""
                // Finder reports the desktop as an untitled window larger than the screen.
                if app.isFinder, title.isEmpty { continue }
                let number = windowNumber(of: element)
                let document: String? = copy(element, kAXDocumentAttribute)
                if let number { out.titles[number] = title }
                listed.append((number, Item(
                    source: .ax(element, number), pid: app.pid, app: app.name, title: title, frame: frame,
                    isMinimized: copy(element, kAXMinimizedAttribute) ?? false,
                    document: document.flatMap { URL(string: $0)?.path ?? $0 }.flatMap { $0.isEmpty ? nil : $0 },
                    desktop: nil, isOnCurrentDesktop: true)))
            }
        }

        // 2. The window server: every window on every desktop, front to back.
        guard let spaces = Spaces.read() else {
            out.noSpaces = true
            out.items = listed.map(\.item)
            out.seconds = Date().timeIntervalSince(start)
            return out
        }
        var byNumber = Dictionary(listed.compactMap { l in l.number.map { ($0, l.item) } }, uniquingKeysWith: { a, _ in a })
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var here: [Item] = []
        var away: [Item] = []
        for entry in info {
            guard let pid = entry[kCGWindowOwnerPID as String] as? pid_t, let app = names[pid],
                  (entry[kCGWindowLayer as String] as? Int) == 0,
                  let number = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value else { continue }
            if let w = byNumber.removeValue(forKey: number) {
                // Accessibility listed it; the Space says whether it is on screen.
                let place = spaces.place(of: number)
                let placed = Item(source: w.source, pid: w.pid, app: w.app, title: w.title, frame: w.frame,
                                  isMinimized: w.isMinimized, document: w.document, desktop: place?.desktop,
                                  isOnCurrentDesktop: place?.isCurrent ?? true)
                if placed.isOnCurrentDesktop { here.append(placed) } else { away.append(placed) }
                continue
            }
            // Not listed by Accessibility. On the current desktop that means it is not
            // a standard window (a panel, a popover). Elsewhere, it is a window to list.
            // The cheap checks first: most entries are menu-bar strips with no Space.
            guard (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let frame = bounds(entry), frame.width >= 100, frame.height >= 100,
                  let place = spaces.place(of: number), !place.isCurrent else { continue }
            let title = entry[kCGWindowName as String] as? String ?? knownTitles[number] ?? ""
            away.append(Item(source: .server(number), pid: pid, app: app, title: title, frame: frame, isMinimized: false,
                             document: nil, desktop: place.desktop, isOnCurrentDesktop: false))
        }
        // Accessibility windows the window server did not list stay on the current desktop.
        here += listed.filter { $0.number.map { byNumber[$0] != nil } ?? true }.map(\.item)
        // Stable sort: by desktop, then front to back within it.
        out.items = here + away.enumerated()
            .sorted { ($0.element.desktop ?? .max, $0.offset) < ($1.element.desktop ?? .max, $1.offset) }
            .map(\.element)
        out.seconds = Date().timeIntervalSince(start)
        return out
    }

    /// The window server's bounds are top-left, y down, like Accessibility's.
    static func bounds(_ entry: [String: Any]) -> Rect? {
        guard let dict = entry[kCGWindowBounds as String] as? NSDictionary,
              let r = CGRect(dictionaryRepresentation: dict) else { return nil }
        return Rect(x: r.origin.x, y: r.origin.y, width: r.width, height: r.height)
    }

    static func frame(of element: AXUIElement) -> Rect? {
        guard let pos: AXValue = copy(element, kAXPositionAttribute),
              let dim: AXValue = copy(element, kAXSizeAttribute) else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos, .cgPoint, &p), AXValueGetValue(dim, .cgSize, &s) else { return nil }
        return Rect(x: p.x, y: p.y, width: s.width, height: s.height)
    }

    static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success, let value else {
            return nil
        }
        return value as? T
    }
}
