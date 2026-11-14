//
//  HapticFeedbackEngine.swift
//  FieldVision
//
//  The silent channel.
//
//  Audio is the obvious output, and it is wrong on its own. Two reasons, both
//  straight from users:
//
//    · A meaningful number of blind people are also hard of hearing, and
//      almost nobody designs for that overlap. "Very few apps maximize, or
//      even use, haptics effectively" is a direct quote from a user review.
//
//    · Even with perfect hearing, hearing is the mobility sense. A blind
//      traveller listens to traffic, to the echo of a wall, to a crowd
//      thinning out ahead. Anything we put in that channel competes with
//      information they need more than ours.
//
//  So: haptics carry the same message, in parallel, and can carry it alone.
//
//  The mapping, chosen so the two channels reinforce rather than compete:
//      sharpness ← confidence  (crisp = observed, soft = inferred)
//      intensity ← proximity   (stronger = closer)
//      rhythm    ← urgency     (same pulse rate as the audio)
//
//  Note we vary sharpness AND intensity, not intensity alone. A user review
//  of a competing app: "it uses different intensity but the same frequency;
//  intensity can be harder to discern". Two dimensions are discriminable
//  where one is not.
//

import CoreHaptics
import UIKit

final class HapticFeedbackEngine {

    private var engine: CHHapticEngine?
    private var isSupported = false

    /// Fallback for devices without the Taptic Engine API (and for simulator).
    private let fallbackGenerator = UIImpactFeedbackGenerator(style: .medium)

    // MARK: - Setup

    func configure() {
        isSupported = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        guard isSupported else { return }

        do {
            let engine = try CHHapticEngine()

            // The system stops the haptic engine aggressively — on app
            // backgrounding, on audio session changes, on thermal pressure.
            // If we do not restart it, haptics silently stop working and the
            // user never finds out. For a safety app, a channel that dies
            // quietly is worse than one that was never there.
            engine.stoppedHandler = { [weak self] reason in
                print("[Haptics] stopped: \(reason.rawValue) — restarting")
                self?.restart()
            }
            engine.resetHandler = { [weak self] in
                print("[Haptics] reset — restarting")
                self?.restart()
            }

            // Keeps the engine warm so the first pulse is not late. Costs a
            // little power; worth it when the first pulse is the one warning
            // you about a kerb.
            engine.playsHapticsOnly = true
            engine.isAutoShutdownEnabled = false

            try engine.start()
            self.engine = engine
        } catch {
            print("[Haptics] unavailable: \(error)")
            isSupported = false
        }
    }

    private func restart() {
        do { try engine?.start() }
        catch { print("[Haptics] restart failed: \(error)") }
    }

    func stop() {
        engine?.stop()
        engine = nil
    }

    // MARK: - Cues

    /// One pulse for one obstacle, matched to the audio cue for the same thing.
    func pulse(for track: TrackedObstacle) {
        guard isSupported, let engine else {
            fallbackGenerator.impactOccurred(intensity: CGFloat(track.salience))
            return
        }

        // Sharpness is the confidence axis. A crisp tap reads as a fact; a
        // soft, rounded buzz reads as a maybe. People pick this up without
        // being told, the same way they pick up the detuned tone.
        let sharpness: Float = track.state.isTrustworthy ? 0.85 : 0.25

        let intensity: Float = {
            switch track.band {
            case .imminent: return 1.0
            case .caution:  return 0.7
            case .aware:    return 0.42
            case .clear:    return 0.2
            }
        }() * track.state.feedbackGain

        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch {
            // Never let a haptic failure interrupt the audio path.
        }
    }

    /// "Something is out there and I have lost it."
    /// A long, low, deliberately unsatisfying rumble — it does not resolve the
    /// way a located pulse does, and that is the point.
    func pulseUnresolved() {
        guard isSupported, let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticContinuous,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.45),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.05)
                ],
                relativeTime: 0,
                duration: 0.32
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch { }
    }

    /// The system has stopped being able to see. Three hard taps — a pattern
    /// reserved exclusively for this, so it can never be read as an obstacle.
    func pulseSystemFailure() {
        guard isSupported, let engine else {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            return
        }
        do {
            let events = (0..<3).map { i in
                CHHapticEvent(
                    eventType: .hapticTransient,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1.0),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: 1.0)
                    ],
                    relativeTime: Double(i) * 0.12
                )
            }
            let pattern = try CHHapticPattern(events: events, parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch { }
    }

    /// Path ahead is clear and confirmed. Deliberately gentle and infrequent —
    /// reassurance, not an interruption.
    func pulseClear() {
        guard isSupported, let engine else { return }
        do {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.22),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5)
                ],
                relativeTime: 0
            )
            let pattern = try CHHapticPattern(events: [event], parameters: [])
            try engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        } catch { }
    }
}
