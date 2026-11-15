import Foundation

/// Small diagnostics log: ~/Library/Logs/Fenestra-app.log (trimmed at 512 KB).
enum Log {
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Fenestra-app.log")
    private static let queue = DispatchQueue(label: "fenestra.log")
    private static let fmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss.SSS"; return f
    }()

    static func write(_ s: String) {
        let line = "\(fmt.string(from: Date())) \(s)\n"
        queue.async {
            if let a = try? FileManager.default.attributesOfItem(atPath: url.path),
               (a[.size] as? Int ?? 0) > 512_000 { try? FileManager.default.removeItem(at: url) }
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
