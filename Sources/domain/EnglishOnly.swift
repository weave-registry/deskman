// What Deskman sends the on-device model is English only (the user, 2026-10-12). The model
// judges a prompt's language by most of its text and refuses one it does not support: a window
// title in another language, for two minutes, stopped naming and layout ("Unsupported language").

public enum EnglishOnly {
    /// Printable ASCII only: other scripts, accents, emoji and invisible marks go; spaces collapse.
    public static func text(_ s: String) -> String {
        let kept = s.unicodeScalars.map { $0.isASCII && $0.value >= 32 && $0.value < 127 ? Character($0) : " " }
        return String(kept).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}
