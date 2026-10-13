import Foundation
import Testing
import DeskmanPorts

// The on-device model refuses a prompt whose text is mostly a language it does not support
// ("Unsupported language", 2026-10-12, a window title for two minutes). Deskman sends English only.

@Suite struct EnglishOnlyTests {
    @Test func plainEnglishIsUnchanged() {
        #expect(EnglishOnly.text("Example Corp - Calendar - Monday") == "Example Corp - Calendar - Monday")
    }

    @Test func otherScriptsAreRemoved() {
        #expect(EnglishOnly.text("Привет всем - Forward Enterprise") == "- Forward Enterprise")
        #expect(EnglishOnly.text("שלום לכולם") == "")
    }

    @Test func invisibleMarksAreRemoved() {
        // WhatsApp's name starts with a left-to-right mark, U+200E.
        #expect(EnglishOnly.text("\u{200E}WhatsApp") == "WhatsApp")
    }

    @Test func accentsAndEmojiGoAndSpacesCollapse() {
        #expect(EnglishOnly.text("Café  🚀 deploy\tnow\n") == "Caf deploy now")
    }

    @Test func everythingLeftIsPrintableASCII() {
        let samples = ["Cześć wszystkim", "日本語のタイトル", "a\u{0}b\u{7F}c", "  ", "naïve résumé ✅"]
        for s in samples {
            let out = EnglishOnly.text(s)
            #expect(out.unicodeScalars.allSatisfy { $0.isASCII && $0.value >= 32 && $0.value < 127 })
            #expect(out == out.trimmingCharacters(in: .whitespaces))
            #expect(!out.contains("  "))
        }
    }
}
