import AppKit
import ApplicationServices

// Private SkyLight and HIServices calls (ADR-2610101429). They only read.
// yabai, AltTab, Rectangle and Hammerspoon depend on the same four symbols.
// Each "Copy" call returns a +1 reference, which the Swift calling convention
// of @_silgen_name takes ownership of.

@_silgen_name("CGSMainConnectionID")
private func CGSMainConnectionID() -> Int32

@_silgen_name("CGSCopyManagedDisplaySpaces")
private func CGSCopyManagedDisplaySpaces(_ connection: Int32) -> CFArray?

@_silgen_name("CGSCopySpacesForWindows")
private func CGSCopySpacesForWindows(_ connection: Int32, _ mask: Int32, _ windows: CFArray) -> CFArray?

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ window: UnsafeMutablePointer<CGWindowID>) -> AXError

/// The `CGWindowID` behind an Accessibility window, or nil when macOS will not say.
func windowNumber(of element: AXUIElement) -> CGWindowID? {
    var number: CGWindowID = 0
    guard _AXUIElementGetWindow(element, &number) == .success, number != 0 else { return nil }
    return number
}

/// Every Space (desktop) on every display, numbered as Mission Control numbers them.
struct Spaces {
    struct Place: Equatable {
        /// 1-based, counted across displays in display order.
        let desktop: Int
        let isCurrent: Bool
    }

    private let connection: Int32
    private let number: [UInt64: Int]
    private let current: Set<UInt64>

    /// Nil when SkyLight reports no Spaces at all: the caller must not guess.
    static func read() -> Spaces? {
        let connection = CGSMainConnectionID()
        guard let displays = CGSCopyManagedDisplaySpaces(connection) as? [[String: Any]] else { return nil }
        var number: [UInt64: Int] = [:]
        var current = Set<UInt64>()
        for display in displays {
            if let id = Self.spaceID((display["Current Space"] as? [String: Any])?["ManagedSpaceID"]) {
                current.insert(id)
            }
            for space in display["Spaces"] as? [[String: Any]] ?? [] {
                if let id = Self.spaceID(space["ManagedSpaceID"]) { number[id] = number.count + 1 }
            }
        }
        guard !number.isEmpty else { return nil }
        return Spaces(connection: connection, number: number, current: current)
    }

    /// Where a window lives, or nil for a window on no Space (menu-bar strips, offscreen helpers).
    /// A window on every Space counts as on the current one.
    func place(of window: CGWindowID) -> Place? {
        let all: Int32 = 0x7  // current | others | user
        let ids = CGSCopySpacesForWindows(connection, all, [NSNumber(value: window)] as CFArray) as? [NSNumber] ?? []
        let known = ids.map(\.uint64Value).filter { number[$0] != nil }
        if let here = known.first(where: current.contains), let n = number[here] {
            return Place(desktop: n, isCurrent: true)
        }
        guard let n = known.compactMap({ number[$0] }).min() else { return nil }
        return Place(desktop: n, isCurrent: false)
    }

    private static func spaceID(_ value: Any?) -> UInt64? {
        (value as? NSNumber)?.uint64Value
    }
}
