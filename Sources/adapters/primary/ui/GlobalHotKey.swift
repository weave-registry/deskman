import Carbon.HIToolbox

/// System-wide shortcuts. Carbon's RegisterEventHotKey needs no permission,
/// unlike a global key monitor, which needs Input Monitoring.
@MainActor public final class GlobalHotKey {
    public static let description = "⌃⌥Space"

    // Carbon calls back through a C function pointer, which cannot capture context:
    // one handler for all keys, which finds the action by the key's id.
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    private static var nextID: UInt32 = 1
    private var hotKey: EventHotKeyRef?

    /// Registers Control-Option-Space. Returns nil when another app owns that shortcut.
    public convenience init?(action: @escaping @MainActor () -> Void) {
        self.init(keyCode: kVK_Space, modifiers: controlKey | optionKey, action: action)
    }

    /// `keyCode` is a `kVK_` constant; `modifiers` are Carbon's (`controlKey | cmdKey`).
    public init?(keyCode: Int, modifiers: Int, action: @escaping @MainActor () -> Void) {
        guard Self.installHandler() else { return nil }
        let id = Self.nextID
        Self.nextID += 1
        let ref = EventHotKeyID(signature: OSType(0x4453_4B4D), id: id)   // 'DSKM'
        guard RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), ref, GetApplicationEventTarget(), 0, &hotKey) == noErr
        else { return nil }
        Self.actions[id] = action
    }

    private static func installHandler() -> Bool {
        if handler != nil { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        return InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var key = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &key)
            // Carbon delivers application events on the main thread.
            MainActor.assumeIsolated { GlobalHotKey.actions[key.id]?() }
            return noErr
        }, 1, &spec, nil, &handler) == noErr
    }
}
