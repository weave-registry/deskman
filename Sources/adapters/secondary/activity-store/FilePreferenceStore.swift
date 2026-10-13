import Foundation
import DeskmanPorts

/// `PreferenceStore` as `preferences.json` beside the activity files (ADR-2610120742).
/// `FileActivityStore.eraseAll` never touches it: forgetting activity keeps what the person said.
@MainActor public final class FilePreferenceStore: PreferenceStore {
    private let file: URL

    /// `folder` defaults to the user's Application Support folder; tests may pass another.
    public init(folder: URL? = nil) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deskman", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        file = base.appendingPathComponent("preferences.json")
    }

    /// No file yet is the defaults. A file that is there but cannot be read throws: never hidden.
    public func load() throws -> Preferences {
        guard FileManager.default.fileExists(atPath: file.path) else { return Preferences() }
        return try JSONDecoder().decode(Preferences.self, from: Data(contentsOf: file))
    }

    public func save(_ preferences: Preferences) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(preferences).write(to: file, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}
