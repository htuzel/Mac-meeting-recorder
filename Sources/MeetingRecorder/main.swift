import AppKit
import Foundation

// MARK: - One-off transcription (no recording, no menu bar, no lock)
//   MeetingRecorder --transcribe <session folder containing mixed.m4a>

if let flag = CommandLine.arguments.firstIndex(of: "--transcribe"),
   flag + 1 < CommandLine.arguments.count {
    let sessionDir = URL(fileURLWithPath: CommandLine.arguments[flag + 1])
    let transcriber = makeTranscriber(config: Config.load())
    Task.detached {
        let ok = await transcriber.transcribeSession(sessionDir: sessionDir)
        exit(ok ? 0 : 1)
    }
    dispatchMain()
}

// MARK: - Single Instance Lock

let lockFilePath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".private-recording.lock").path

let lockFD = open(lockFilePath, O_CREAT | O_WRONLY, 0o644)
guard lockFD >= 0 else {
    print("ERROR: Cannot create lock file")
    exit(1)
}

if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Under launchd (KeepAlive) exiting here would make launchd respawn us in
    // a loop, and in the old setup an exit(0) here left nothing running once
    // the other (manually opened) instance quit. So the launchd-managed copy
    // waits for the lock and takes over; a manually opened copy just exits.
    if ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == "com.flalingo.meeting-recorder" {
        print("Another instance is running — waiting to take over when it exits.")
        guard flock(lockFD, LOCK_EX) == 0 else {
            print("ERROR: Cannot acquire lock")
            exit(1)
        }
    } else {
        print("Another instance is already running. Exiting.")
        exit(0)
    }
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
