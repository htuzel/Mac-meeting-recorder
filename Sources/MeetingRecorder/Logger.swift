import Foundation

final class Logger: Sendable {
    static let shared = Logger()

    private let logDir: URL
    private let maxFileSize: UInt64 = 10 * 1024 * 1024 // 10 MB
    private let maxBackups = 5
    private let queue = DispatchQueue(label: "com.flalingo.meeting-recorder.logger")

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.logDir = home.appendingPathComponent("MeetingRecordings/logs")
        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
    }

    private var logFile: URL {
        logDir.appendingPathComponent("app.log")
    }

    func info(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: "INFO", message: message, file: file, line: line)
    }

    func warn(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: "WARN", message: message, file: file, line: line)
    }

    func error(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: "ERROR", message: message, file: file, line: line)
    }

    func debug(_ message: String, file: String = #fileID, line: Int = #line) {
        log(level: "DEBUG", message: message, file: file, line: line)
    }

    private func log(level: String, message: String, file: String, line: Int) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let fileName = URL(fileURLWithPath: file).lastPathComponent
        let entry = "[\(timestamp)] [\(level)] [\(fileName):\(line)] \(message)\n"

        queue.async { [self] in
            rotateIfNeeded()
            let fileURL = logFile
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
            handle.seekToEndOfFile()
            if let data = entry.data(using: .utf8) {
                handle.write(data)
            }
            handle.closeFile()
        }
    }

    private func rotateIfNeeded() {
        let fileURL = logFile
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = attrs[.size] as? UInt64,
              size >= maxFileSize else { return }

        // Rotate: app.log.5 → delete, app.log.4 → .5, ... app.log → .1
        let fm = FileManager.default
        for i in stride(from: maxBackups, through: 1, by: -1) {
            let src = logDir.appendingPathComponent("app.log.\(i)")
            if i == maxBackups {
                try? fm.removeItem(at: src)
            } else {
                let dst = logDir.appendingPathComponent("app.log.\(i + 1)")
                try? fm.moveItem(at: src, to: dst)
            }
        }
        let dst = logDir.appendingPathComponent("app.log.1")
        try? fm.moveItem(at: fileURL, to: dst)
    }
}
