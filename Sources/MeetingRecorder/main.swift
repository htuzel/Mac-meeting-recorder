import AppKit
import Foundation

// MARK: - Single Instance Lock

let lockFilePath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".private-recording.lock").path

let lockFD = open(lockFilePath, O_CREAT | O_WRONLY, 0o644)
guard lockFD >= 0 else {
    print("ERROR: Cannot create lock file")
    exit(1)
}

if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    print("Another instance is already running. Exiting.")
    exit(0)
}

// MARK: - App Setup

let log = Logger.shared
log.info("MeetingRecorder starting up")

let config = Config.load()
log.info("Config loaded — recordings dir: \(config.recordingsDir.path)")

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let controller = MenuBarController(config: config)
_ = controller // retain

log.info("MeetingRecorder ready, entering run loop")
app.run()
