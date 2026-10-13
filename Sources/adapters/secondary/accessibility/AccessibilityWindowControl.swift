import AppKit
import ApplicationServices
import DeskmanPorts

/// `WindowControl` over the macOS Accessibility API.
///
/// Accessibility frames are already top-left, y down — the hexagon's convention, and
/// the window server's too. Only `NSScreen` frames are AppKit's bottom-left, and
/// `displays()` converts them.
///
/// Accessibility sees the current desktop only. The window server sees every desktop
/// but cannot move a window. `windows()` joins the two by `CGWindowID` (ADR-2610101429).
@MainActor public final class AccessibilityWindowControl: WindowControl {
    private struct Entry {
        /// Nil for a window seen only on another desktop: it can be focused, not moved.
        var element: AXUIElement?
        let pid: pid_t

        func reachable() throws -> AXUIElement {
            guard let element else { throw AccessibilityError("that window is on another desktop") }
            return element
        }
    }

    /// Windows seen so far. A window with a `CGWindowID` has the id `w<number>`, which
    /// stays the same across reads and desktops. One without falls back to `a<counter>`,
    /// kept stable by comparing elements with CFEqual.
    private var registry: [WindowID: Entry] = [:]
    private var nextID = 1
    /// The last title Accessibility gave each window. The window server withholds
    /// titles without Screen Recording permission, so this names off-desktop windows.
    private var titles: [CGWindowID: String] = [:]
    private var warnedNoSpaces = false
    /// The last app the person used that is not Deskman. "This window" means its window.
    private var lastExternalApp: NSRunningApplication?
    private var activationObserver: NSObjectProtocol?

    public init() {
        // Every Accessibility call waits at most 0.5 s for an app, not macOS's 6 s (ADR-2610121200).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)
        let own = NSRunningApplication.current.processIdentifier
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != own {
            lastExternalApp = front
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != own, app.activationPolicy == .regular else { return }
            MainActor.assumeIsolated { self?.lastExternalApp = app }
        }
    }

    // MARK: Reading

    /// The newest background read, ready for the main thread (ADR-2610121200).
    private var latest: (windows: [WindowSnapshot], at: Date)?
    private var reading = false
    /// When Deskman last changed each window. A read that started before that change shows the
    /// window as it was: the copy keeps Deskman's change instead (2026-10-12, false pins).
    private var edited: [WindowID: Date] = [:]
    private let queue = DispatchQueue(label: "deskman.desktop-read", qos: .userInitiated)
    /// The last background read's time in seconds, for `--diagnose-speed`.
    public private(set) var lastReadSeconds: Double?

    /// At once, from the newest background read; starts the next one. Only the first call,
    /// before any read has finished, reads on this thread.
    public func windows() -> [WindowSnapshot] {
        if let latest {
            if Date().timeIntervalSince(latest.at) > 0.8 { readInBackground() }
            return latest.windows
        }
        let read = DesktopRead.read(apps: runningApps(), knownTitles: titles)
        return take(read)
    }

    /// Start a read on the background queue, unless one is running.
    public func readInBackground() {
        guard !reading else { return }
        reading = true
        let apps = runningApps(), known = titles, started = Date()
        queue.async { [weak self] in
            let read = DesktopRead.read(apps: apps, knownTitles: known)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.reading = false
                    _ = self.take(read, startedAt: started)
                }
            }
        }
    }

    /// Wait for a fresh background read; for `--diagnose-speed`.
    public func readFresh() async -> [WindowSnapshot] {
        let apps = runningApps(), known = titles, started = Date()
        let read = await withCheckedContinuation { (c: CheckedContinuation<DesktopRead, Never>) in
            queue.async { c.resume(returning: DesktopRead.read(apps: apps, knownTitles: known)) }
        }
        return take(read, startedAt: started)
    }

    /// The apps to read, on the main thread: NSWorkspace is cheap and local.
    private func runningApps() -> [DesktopRead.App] {
        let own = NSRunningApplication.current.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.processIdentifier != own && !$0.isTerminated }
            .map { DesktopRead.App(pid: $0.processIdentifier, name: $0.localizedName ?? "App \($0.processIdentifier)",
                                   isFinder: $0.bundleIdentifier == "com.apple.finder") }
    }

    /// Give each window its stable ID and keep the read. Local work only.
    private func take(_ read: DesktopRead, startedAt: Date? = nil) -> [WindowSnapshot] {
        if read.noSpaces, !warnedNoSpaces {
            warnedNoSpaces = true
            NSLog("Deskman: macOS reported no Spaces; listing the current desktop only.")
        }
        titles.merge(read.titles) { _, new in new }
        // Deskman's changes made while this read ran are newer than what it saw.
        let newer = startedAt.map { s in Set(edited.filter { $0.value >= s }.keys) } ?? []
        let kept = Dictionary((latest?.windows ?? []).filter { newer.contains($0.id) }.map { ($0.id, $0) },
                              uniquingKeysWith: { a, _ in a })
        edited = edited.filter { Date().timeIntervalSince($0.value) < 10 }
        let windows = read.items.map { item -> WindowSnapshot in
            let id: WindowID
            switch item.source {
            case .ax(let element, _): id = register(element, pid: item.pid).id
            case .server(let number): id = register(number: number, pid: item.pid)
            }
            if let mine = kept[id] {
                return WindowSnapshot(id: id, app: item.app, title: item.title, frame: mine.frame,
                                      isMinimized: mine.isMinimized, desktop: item.desktop,
                                      isOnCurrentDesktop: item.isOnCurrentDesktop, document: item.document)
            }
            return WindowSnapshot(id: id, app: item.app, title: item.title, frame: item.frame,
                                  isMinimized: item.isMinimized, desktop: item.desktop,
                                  isOnCurrentDesktop: item.isOnCurrentDesktop, document: item.document)
        }
        lastReadSeconds = read.seconds
        latest = (windows, Date())
        return windows
    }

    /// Deskman's own change, kept in the copy at once so the next plan sees it.
    private func update(_ id: WindowID, _ change: (WindowSnapshot) -> WindowSnapshot) {
        edited[id] = Date()
        guard var l = latest, let i = l.windows.firstIndex(where: { $0.id == id }) else { return }
        l.windows[i] = change(l.windows[i])
        latest = l
    }

    public func frame(of id: WindowID) -> Rect? {
        guard let element = registry[id]?.element else { return latest?.windows.first { $0.id == id }?.frame }
        return Self.frame(of: element)
    }

    public func displays() -> [Display] {
        let screens = NSScreen.screens
        guard let primary = screens.first else { return [] }
        let h = Double(primary.frame.height)
        return screens.enumerated().map { i, screen in
            let v = screen.visibleFrame
            let appKit = Rect(x: v.origin.x, y: v.origin.y, width: v.width, height: v.height)
            return Display(index: i, visibleFrame: CoordinateSpace.topLeft(fromAppKit: appKit, primaryDisplayHeight: h))
        }
    }

    public func frontmostWindowID() -> WindowID? {
        guard let app = lastExternalApp, !app.isTerminated else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        let element: AXUIElement? = Self.copy(axApp, kAXFocusedWindowAttribute) ?? Self.copy(axApp, kAXMainWindowAttribute)
        return element.map { register($0, pid: app.processIdentifier).id }
    }

    // MARK: Acting

    public func setFrame(_ frame: Rect, of id: WindowID) throws {
        let entry = try lookup(id)
        let element = try entry.reachable()
        // Firefox and Chromium turn on AXEnhancedUserInterface when an assistive app
        // talks to them, and then animate a move and apply it late, to the wrong place
        // (seen 2026-10-10: Firefox asked for 52,735, found at 87,171 three seconds later).
        // Off for the move, back on after, as Rectangle does.
        let axApp = AXUIElementCreateApplication(entry.pid)
        let enhanced: Bool = Self.copy(axApp, "AXEnhancedUserInterface") ?? false
        if enhanced { AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse) }
        defer { if enhanced { AXUIElementSetAttributeValue(axApp, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) } }
        var origin = CGPoint(x: frame.x, y: frame.y)
        var size = CGSize(width: frame.width, height: frame.height)
        guard let pos = AXValueCreate(.cgPoint, &origin), let dim = AXValueCreate(.cgSize, &size) else {
            throw AccessibilityError("could not build the frame")
        }
        // Size, then position, then size again: an app that clamps a window to its
        // display rejects a large size at the old position but accepts it at the new one.
        // Then read it back: some apps (Firefox) apply a frame late or only in part, and
        // "the call succeeded" is not "the window is there". Two tries, then say where it is.
        var landed: Rect?
        for _ in 0..<2 {
            _ = AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dim)
            try Self.check(AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, pos), "move")
            try Self.check(AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, dim), "resize")
            for _ in 0..<6 {
                landed = Self.frame(of: element)
                if let landed, Self.matches(landed, frame) { keep(landed, id); return }
                usleep(25_000)
            }
        }
        // A window that refuses to shrink keeps its own size; where it sits is what matters.
        if let landed, abs(landed.x - frame.x) <= 10, abs(landed.y - frame.y) <= 10 { keep(landed, id); return }
        throw AccessibilityError("it stayed at \(landed.map { "\(Int($0.x)),\(Int($0.y)) \(Int($0.width))×\(Int($0.height))" } ?? "an unknown place")")
    }

    private func keep(_ frame: Rect, _ id: WindowID) {
        update(id) { w in
            WindowSnapshot(id: w.id, app: w.app, title: w.title, frame: frame, isMinimized: w.isMinimized,
                           desktop: w.desktop, isOnCurrentDesktop: w.isOnCurrentDesktop, document: w.document)
        }
    }

    private func keep(minimized: Bool, _ id: WindowID) {
        update(id) { w in
            WindowSnapshot(id: w.id, app: w.app, title: w.title, frame: w.frame, isMinimized: minimized,
                           desktop: w.desktop, isOnCurrentDesktop: w.isOnCurrentDesktop, document: w.document)
        }
    }

    private static func matches(_ a: Rect, _ b: Rect) -> Bool {
        abs(a.x - b.x) <= 10 && abs(a.y - b.y) <= 10 && abs(a.width - b.width) <= 10 && abs(a.height - b.height) <= 10
    }

    public func perform(_ action: WindowAction, on id: WindowID) throws {
        let entry = try lookup(id)
        let app = NSRunningApplication(processIdentifier: entry.pid)
        switch action {
        case .focus:
            app?.unhide()
            app?.activate()
            // On another desktop there is no element: activating the app switches there.
            guard let element = entry.element else { return }
            _ = AXUIElementSetAttributeValue(element, kAXMainAttribute as CFString, kCFBooleanTrue)
            try Self.check(AXUIElementPerformAction(element, kAXRaiseAction as CFString), "raise")
        case .minimize:
            try Self.check(AXUIElementSetAttributeValue(entry.reachable(), kAXMinimizedAttribute as CFString, kCFBooleanTrue), "minimize")
            keep(minimized: true, id)
        case .restore:
            app?.unhide()
            try Self.check(AXUIElementSetAttributeValue(entry.reachable(), kAXMinimizedAttribute as CFString, kCFBooleanFalse), "restore")
            keep(minimized: false, id)
        case .close:
            guard let button: AXUIElement = try Self.copy(entry.reachable(), kAXCloseButtonAttribute) else {
                throw AccessibilityError("this window has no close button")
            }
            try Self.check(AXUIElementPerformAction(button, kAXPressAction as CFString), "close")
        case .hideApp:
            guard app?.hide() == true else { throw AccessibilityError("the app refused to hide") }
        case .fullScreen:
            try Self.check(AXUIElementSetAttributeValue(entry.reachable(), "AXFullScreen" as CFString, kCFBooleanTrue), "enter full screen")
        }
    }

    public func launch(app name: String) throws {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.activationPolicy == .regular && $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame
        }) {
            running.unhide()
            running.activate()
            return
        }
        guard let url = Self.findApplication(named: name) else {
            throw AccessibilityError("no app named \(name) in the Applications folders")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }

    // MARK: Permission

    public var isTrusted: Bool { AXIsProcessTrusted() }

    public func requestTrust() {
        // The string value of kAXTrustedCheckOptionPrompt; the global is not concurrency-safe.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options),
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Internals

    private func register(_ element: AXUIElement, pid: pid_t) -> (id: WindowID, number: CGWindowID?) {
        if let number = windowNumber(of: element) {
            let id = WindowID("w\(number)")
            registry[id] = Entry(element: element, pid: pid)
            prune()
            return (id, number)
        }
        if let known = registry.first(where: { $0.value.element.map { CFEqual($0, element) } ?? false }) {
            return (known.key, nil)
        }
        let id = WindowID("a\(nextID)")
        nextID += 1
        registry[id] = Entry(element: element, pid: pid)
        prune()
        return (id, nil)
    }

    /// A window seen only by the window server. An element Accessibility gave
    /// earlier is kept: the window may come back to this desktop.
    private func register(number: CGWindowID, pid: pid_t) -> WindowID {
        let id = WindowID("w\(number)")
        if registry[id] == nil { registry[id] = Entry(element: nil, pid: pid) }
        prune()
        return id
    }

    /// Forget windows of apps that quit, so the registry does not grow forever.
    private func prune() {
        guard registry.count > 400 else { return }
        registry = registry.filter { NSRunningApplication(processIdentifier: $0.value.pid) != nil }
        titles = titles.filter { number, _ in registry[WindowID("w\(number)")] != nil }
    }

    private func lookup(_ id: WindowID) throws -> Entry {
        guard let entry = registry[id] else { throw AccessibilityError("that window is gone") }
        return entry
    }

    private static func frame(of element: AXUIElement) -> Rect? { DesktopRead.frame(of: element) }

    private static func copy<T>(_ element: AXUIElement, _ attribute: String) -> T? { DesktopRead.copy(element, attribute) }

    private static func check(_ error: AXError, _ verb: String) throws {
        guard error == .success else { throw AccessibilityError("could not \(verb) the window (AXError \(error.rawValue))") }
    }

    private static func findApplication(named name: String) -> URL? {
        let fm = FileManager.default
        var folders = fm.urls(for: .applicationDirectory, in: .allDomainsMask)
        folders.append(URL(fileURLWithPath: "/System/Applications"))
        folders += folders.map { $0.appendingPathComponent("Utilities") }

        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        var prefixMatch: URL?
        for folder in folders {
            guard let items = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) else { continue }
            for item in items where item.pathExtension == "app" {
                let base = item.deletingPathExtension().lastPathComponent.lowercased()
                if base == wanted { return item }
                if prefixMatch == nil, base.hasPrefix(wanted) { prefixMatch = item }
            }
        }
        return prefixMatch
    }
}

struct AccessibilityError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
