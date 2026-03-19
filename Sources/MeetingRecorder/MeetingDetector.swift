import Foundation

enum DetectorState: String, Sendable {
    case idle
    case recording
    case cooldown
}

@MainActor
final class MeetingDetector {
    private let config: Config
    private let log = Logger.shared

    private(set) var state: DetectorState = .idle

    // Sliding window: last time each source was active
    private var micLastActive: Date = .distantPast
    private var sysLastActive: Date = .distantPast

    // Force mode
    private var isForced = false

    init(config: Config) {
        self.config = config
    }

    /// Called every VAD tick (0.5s). Returns new state if changed.
    func check(micRMS: Double, sysRMS: Double) -> DetectorState {
        let now = Date()

        // Update last-active timestamps
        if micRMS > config.vadMicThreshold {
            micLastActive = now
        }
        if sysRMS > config.vadSystemThreshold {
            sysLastActive = now
        }

        if isForced { return state }

        let micRecent = now.timeIntervalSince(micLastActive) < config.vadActivationSeconds
        let sysRecent = now.timeIntervalSince(sysLastActive) < config.vadActivationSeconds
        let anyRecent = micRecent || sysRecent

        let micSilent = now.timeIntervalSince(micLastActive) > config.vadSilenceTimeout
        let sysSilent = now.timeIntervalSince(sysLastActive) > config.vadSilenceTimeout
        let allSilent = micSilent && sysSilent

        let oldState = state

        switch state {
        case .idle:
            // Both mic AND system must be recently active to start recording
            if micRecent && sysRecent {
                state = .recording
                log.info("State: idle → recording (mic + sys active)")
            }

        case .recording:
            if allSilent {
                state = .cooldown
                log.info("State: recording → cooldown (silence for \(Int(config.vadSilenceTimeout))s)")
            }

        case .cooldown:
            if anyRecent {
                state = .recording
                log.info("State: cooldown → recording (audio returned)")
            } else {
                let cooldownElapsed = micSilent && sysSilent &&
                    now.timeIntervalSince(micLastActive) > (config.vadSilenceTimeout + config.vadCooldownSeconds) &&
                    now.timeIntervalSince(sysLastActive) > (config.vadSilenceTimeout + config.vadCooldownSeconds)
                if cooldownElapsed {
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
        log.info("Force recording enabled")
    }

    func forceStop() {
        isForced = false
        state = .idle
        micLastActive = .distantPast
        sysLastActive = .distantPast
        log.info("Force stop — state reset to idle")
    }

    func reset() {
        isForced = false
        state = .idle
        micLastActive = .distantPast
        sysLastActive = .distantPast
    }
}
