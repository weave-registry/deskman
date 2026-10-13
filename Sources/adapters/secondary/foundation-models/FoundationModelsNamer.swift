import FoundationModels
import DeskmanPorts

/// `WindowNamer` over Apple's on-device model (ADR-2610101542). A fresh session per
/// request: names must not depend on the conversation, and the context stays small.
@MainActor public final class FoundationModelsNamer: WindowNamer {
    private let model = SystemLanguageModel.default

    public init() {}

    @Generable struct Named {
        @Guide(description: "The window's number in the list.")
        var number: Int
        @Guide(description: "2 to 5 words that say what the window is for.")
        var name: String
        @Guide(description: "The project the window belongs to, one or two lowercase words, or none.")
        var project: String
    }

    @Generable struct Names {
        @Guide(description: "One entry per window, in the same order as the list.")
        var windows: [Named]
    }

    static let instructions = """
        You name windows on a Mac so a person can find them. For each window, write 2 to 5 words \
        that say what the window is for, using the project, page or task in its title. \
        A folder or file, when given, says which project the window belongs to: use its last part. \
        "runs claude in deskman" means the window runs the program claude in the project deskman. \
        Every name must be different from the others. \
        Do not start with the app name; use it only when nothing else is known. No quotes. \
        Also give each window its project: the product, repository or folder it is about, \
        in one or two lowercase words, the same word for every window of that project. \
        A browser page and a terminal about one product share its project. \
        Write none when the window belongs to no project, as mail, music or settings do.
        Each window's name and project come from that window's own line only. \
        Never take a project from these instructions: only from the window's own title, folder or job. \
        A terminal that runs a program in a folder is named for the folder and the program, \
        and its project is the folder. A web page is named for what its title shows, \
        and its project is the product or repository in the title. \
        Mail, music, calendars and settings have no project. \
        Never copy words from these instructions into a name.
        """

    public func names(for subjects: [NamingSubject]) async throws -> [NamedWindow] {
        guard case .available = model.availability else { throw NamerError("the on-device model is not available") }
        // English only (EnglishOnly). Should the model still call it another language, ask again
        // without the titles: the app, folder and job still say what each window is.
        do {
            return try await ask(subjects, titles: true)
        } catch LanguageModelSession.GenerationError.unsupportedLanguageOrLocale {
            return try await ask(subjects, titles: false)
        }
    }

    private func ask(_ subjects: [NamingSubject], titles: Bool) async throws -> [NamedWindow] {
        let e = EnglishOnly.text
        let list = subjects.enumerated().map { i, s in
            let w = s.window
            return "\(i + 1). \(e(w.app)): \(titles ? e(String(w.title.prefix(80))) : "")"
                + (w.document.map { " (in \(e(Self.short($0))))" } ?? "")
                + (s.jobs.isEmpty ? "" : " (runs \(e(s.jobs.joined(separator: ", "))))")
                + (s.jobs.isEmpty && !s.appJobs.isEmpty
                   ? " (one of its app's windows runs \(e(s.appJobs.joined(separator: ", "))))" : "")
        }.joined(separator: "\n")
        let session = LanguageModelSession(model: model, instructions: Self.instructions)
        let response = try await session.respond(
            to: "Name these \(subjects.count) windows, in English:\n\(list)", generating: Names.self,
            options: GenerationOptions(temperature: 0.1))
        return Self.ordered(response.content.windows, count: subjects.count)
    }

    /// The answers in list order, matched by the number each one gives (`NamedWindow.match`): the
    /// model has given them out of order (Firefox got the terminal's name) and given one window
    /// two answers (2026-10-12). Unmatched, they are returned as given; the caller checks the count.
    static func ordered(_ got: [Named], count: Int) -> [NamedWindow] {
        let picked = NamedWindow.match(numbers: got.map(\.number), count: count).map { $0.map { got[$0] } } ?? got
        return picked.map { NamedWindow(name: $0.name, project: $0.project) }
    }

    /// The last two parts of a path: "/Volumes/Crucial/projects/deskman" → "projects/deskman".
    static func short(_ path: String) -> String {
        path.split(separator: "/").suffix(2).joined(separator: "/")
    }
}

struct NamerError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
