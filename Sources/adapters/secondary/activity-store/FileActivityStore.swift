import Foundation
import DeskmanPorts

/// `ActivityStore` as two files in ~/Library/Application Support/Deskman/:
/// `activity.jsonl` (one settled arrangement per line) and `trust.json`.
/// The records hold window titles, so the folder and files are owner-only.
@MainActor public final class FileActivityStore: ActivityStore {
    public static let maxRecords = 5_000
    public static let maxAgeSeconds = 90.0 * 24 * 3600

    private let folder: URL
    private var activityFile: URL { folder.appendingPathComponent("activity.jsonl") }
    private var trustFile: URL { folder.appendingPathComponent("trust.json") }
    private var cache: [DeskSnapshot]

    /// `folder` defaults to the user's Application Support folder; tests may pass another.
    public init(folder: URL? = nil, now: Double = Date().timeIntervalSince1970) {
        let base = folder ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Deskman", isDirectory: true)
        self.folder = base
        self.cache = []
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        cache = load(now: now)
    }

    public func append(_ snapshot: DeskSnapshot) throws {
        var line = try JSONEncoder().encode(snapshot)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: activityFile.path) {
            FileManager.default.createFile(atPath: activityFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        let handle = try FileHandle(forWritingTo: activityFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        cache.append(snapshot)
        if cache.count > Self.maxRecords + 500 { try rewrite(Array(cache.suffix(Self.maxRecords))) }
    }

    public func snapshots() -> [DeskSnapshot] { cache }

    public func ledger() -> TrustLedger {
        guard let data = try? Data(contentsOf: trustFile),
              let ledger = try? JSONDecoder().decode(TrustLedger.self, from: data) else { return TrustLedger() }
        return ledger
    }

    public func save(_ ledger: TrustLedger) throws {
        try JSONEncoder().encode(ledger).write(to: trustFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: trustFile.path)
    }

    public func eraseAll() throws {
        for file in [activityFile, trustFile] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
        cache = []
    }

    // MARK: -

    /// Reads every line it can; a damaged line is skipped, not fatal. Drops records
    /// past the age and count limits, and rewrites the file when it dropped any.
    private func load(now: Double) -> [DeskSnapshot] {
        guard let text = try? String(contentsOf: activityFile, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        let all = text.split(separator: "\n").compactMap { try? decoder.decode(DeskSnapshot.self, from: Data($0.utf8)) }
        let kept = Array(all.filter { now - $0.time <= Self.maxAgeSeconds }.suffix(Self.maxRecords))
        if kept.count != all.count { try? rewrite(kept) }
        return kept
    }

    private func rewrite(_ records: [DeskSnapshot]) throws {
        let encoder = JSONEncoder()
        var data = Data()
        for r in records {
            data.append(try encoder.encode(r))
            data.append(0x0A)
        }
        try data.write(to: activityFile, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: activityFile.path)
        cache = records
    }
}

/// The wall clock, for `TimeSource`.
@MainActor public final class SystemTimeSource: TimeSource {
    public init() {}
    public func now() -> Double { Date().timeIntervalSince1970 }
}
