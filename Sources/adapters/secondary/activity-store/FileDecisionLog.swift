import Foundation
import DeskmanPorts

/// `DecisionLog` as a text file in ~/Library/Logs/Deskman, where Console.app finds it. One line per
/// decision, with the local time. Kept under 5 MB: the older half moves to decisions.1.log.
@MainActor public final class FileDecisionLog: DecisionLog {
    public static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Deskman/decisions.log")
    static let limit = 5_000_000

    private let url: URL
    private let time: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    public init(url: URL = FileDecisionLog.url) {
        self.url = url
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    public func record(_ line: String) {
        let text = "\(time.string(from: Date()))  \(line)\n"
        guard let data = text.data(using: .utf8) else { return }
        if let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? Int, size > Self.limit {
            let old = url.deletingPathExtension().appendingPathExtension("1.log")
            try? FileManager.default.removeItem(at: old)
            try? FileManager.default.moveItem(at: url, to: old)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
