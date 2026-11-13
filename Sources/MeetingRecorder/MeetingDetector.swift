import Foundation

enum DetectorState: String, Sendable {
    case idle
    case recording
    case cooldown
}

/// Meeting detection state machine, fed once per VAD tick with the peak RMS
/// of each side since the previous tick.
///
/// - Start: mic AND system audio must each accumulate `vadActivationSeconds`
///   of activity inside a sliding `vadActivationWindow`. They don't have to
///   overlap, so "they talk, then I answer" counts.
/// - Stop: both sides silent for `vadSilenceTimeout` → cooldown; still silent
///   after `vadCooldownSeconds` more → idle (session closed). Any audio during
///   cooldown resumes the same session, so normal pauses don't split meetings.
@MainActor
final class MeetingDetector {
    private let config: Config
    private let log = Logger.shared

    private(set) var state: DetectorState = .idle

    private var micLastActive: Date = .distantPast
    private var sysLastActive: Date = .distantPast

    // Active-tick timestamps inside the activation window (idle → recording)
    private var micActiveTicksInWindow: [Date] = []
    private var sysActiveTicksInWindow: [Date] = []

    // Per-session activity counters (written to metadata.json)
    private var micActiveTicks = 0
    private var sysActiveTicks = 0

    /// Audio on either side within this many seconds resumes from cooldown.
    private let resumeSeconds: Double = 3.0

    private var isForced = false

    init(config: Config) {
        self.config = config
    }

    var micActiveSeconds: Double { Double(micActiveTicks) * config.vadCheckInterval }
    var sysActiveSeconds: Double { Double(sysActiveTicks) * config.vadCheckInterval }

    /// Called every VAD tick. Returns the (possibly new) state.
    func check(micLevel: Double, sysLevel: Double, now: Date = Date()) -> DetectorState {
        let micActive = micLevel > config.vadMicThreshold
        let sysActive = sysLevel > config.vadSystemThreshold

        if micActive {
            micLastActive = now
            micActiveTicksInWindow.append(now)
        }
        if sysActive {
            sysLastActive = now
            sysActiveTicksInWindow.append(now)
        }
        let windowStart = now.addingTimeInterval(-config.vadActivationWindow)
        micActiveTicksInWindow.removeAll { $0 < windowStart }
        sysActiveTicksInWindow.removeAll { $0 < windowStart }

        if state != .idle {
            if micActive { micActiveTicks += 1 }
            if sysActive { sysActiveTicks += 1 }
        }

        if isForced { return state }

        let micSilentFor = now.timeIntervalSince(micLastActive)
        let sysSilentFor = now.timeIntervalSince(sysLastActive)

        let oldState = state

        switch state {
        case .idle:
            let micSeconds = Double(micActiveTicksInWindow.count) * config.vadCheckInterval
            let sysSeconds = Double(sysActiveTicksInWindow.count) * config.vadCheckInterval
            if micSeconds >= config.vadActivationSeconds && sysSeconds >= config.vadActivationSeconds {
                state = .recording
                resetSessionCounters()
                log.info("State: idle → recording (mic \(String(format: "%.1f", micSeconds))s + sys \(String(format: "%.1f", sysSeconds))s active in last \(Int(config.vadActivationWindow))s)")
            }

        case .recording:
            if micSilentFor > config.vadSilenceTimeout && sysSilentFor > config.vadSilenceTimeout {
                state = .cooldown
                log.info("State: recording → cooldown (both sides silent for \(Int(config.vadSilenceTimeout))s)")
            }

        case .cooldown:
            if micSilentFor < resumeSeconds || sysSilentFor < resumeSeconds {
                state = .recording
                log.info("State: cooldown → recording (audio returned)")
            } else {
                let closeAfter = config.vadSilenceTimeout + config.vadCooldownSeconds
                if micSilentFor > closeAfter && sysSilentFor > closeAfter {
                    state = .idle
                    log.info("State: cooldown → idle (cooldown expired)")
                }
            }
        }

        if state != oldState {
            log.debug("Detector state changed: \(oldState.rawValue) → \(state.rawValue)")
        }

        return state
    }

    func forceRecording() {
        isForced = true
        state = .recording
        resetSessionCounters()
        log.info("Force recording enabled")
    }

    func forceStop() {
        reset()
        log.info("Force stop — state reset to idle")
    }

    func reset() {
        isForced = false
        state = .idle
        micLastActive = .distantPast
        sysLastActive = .distantPast
        micActiveTicksInWindow.removeAll()
        sysActiveTicksInWindow.removeAll()
    }

    private func resetSessionCounters() {
        micActiveTicks = 0
        sysActiveTicks = 0
    }
}
