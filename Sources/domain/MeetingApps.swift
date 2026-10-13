// Meeting apps are not arranged (the user, 2026-10-12: "treat zoom completely differently ...
// if we are sharing an app we dont want to change anything"). Zoom, active, had other windows
// minimized; a moved window during a screen share moves on everyone's screen.

public enum MeetingApps {
    /// As macOS names them: Zoom is "zoom.us" to the system, "Zoom" in some places.
    static let apps: Set<String> = ["zoom.us", "zoom", "microsoft teams", "teams", "webex", "cisco webex meetings",
                                    "facetime"]
    /// Words in the title of a window that is a meeting, a call or a share, not the app's home window.
    static let meetingWords = ["meeting", "webinar", "share", "sharing", "call"]

    public static func contains(_ app: String) -> Bool {
        apps.contains(app.trimmingWhitespace().lowercased())
    }

    /// True while a meeting app has a window that is a meeting, a call or a share, on any desktop.
    public static func inMeeting(_ windows: [WindowSnapshot]) -> Bool {
        windows.contains { w in
            guard contains(w.app), !w.isMinimized else { return false }
            let t = w.title.lowercased()
            return meetingWords.contains { t.contains($0) }
        }
    }
}
