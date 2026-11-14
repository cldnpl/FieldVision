//
//  FeedbackCoordinator.swift
//  FieldVision
//
//  Decides what the user actually experiences.
//
//  The perception layer is allowed to know about a dozen obstacles. The user
//  is not. Attention is the scarcest resource in this whole system, and this
//  file is the budget.
//
//  Policy, in order of precedence:
//
//    1. If the system cannot see, say so. Nothing else matters.
//    2. Sonify at most TWO obstacles at once. Three is already a chord
//       nobody can decompose while walking.
//    3. Each obstacle pulses on its own clock, set by how close it is.
//    4. Speak only on a *change of state*, never on a timer.
//    5. Confirm "clear" occasionally. Silence is ambiguous — it reads as
//       "all clear" and it also reads as "the app crashed".
//

import AVFoundation
import Foundation
import QuartzCore

@MainActor
final class FeedbackCoordinator: ObservableObject {

    private let audio = SpatialAudioEngine()
    private let haptics = HapticFeedbackEngine()
    private let speech = SpeechAnnouncer()

    @Published var isActive = false
    @Published var speechEnabled = true {
        didSet { speech.isEnabled = speechEnabled }
    }
    @Published var hapticsEnabled = true
    @Published var audioEnabled = true

    /// Last time each track was pulsed, so each can run its own rhythm.
    private var lastPulse: [UUID: TimeInterval] = [:]
    /// What we last told the user about each track, so we only speak on change.
    private var lastSpokenState: [UUID: String] = [:]
    private var lastUnresolvedCue: TimeInterval = 0
    private var lastClearConfirmation: TimeInterval = 0
    private var wasUsable = true
    private var pathBlocked = false
    private var routeObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func start() throws {
        try audio.configure()
        haptics.configure()
        speech.isEnabled = speechEnabled
        isActive = true

        // Headphones get plugged in and pulled out mid-walk; the spatial
        // rendering algorithm has to follow.
        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.audio.refreshRenderingAlgorithm() }
        }
    }

    func stop() {
        audio.stop()
        haptics.stop()
        speech.stop()
        lastPulse.removeAll()
        lastSpokenState.removeAll()
        wasUsable = true
        pathBlocked = false
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        isActive = false
    }

    /// Speak a summary of the surroundings now (user asked for it).
    func describeSurroundings(_ snapshot: PerceptionSnapshot) {
        speech.say(SceneDescriber.describe(snapshot), priority: .critical,
                   now: CACurrentMediaTime(), force: true)
    }

    // MARK: - Per-frame

    /// Called once per ARFrame with the current belief about the world.
    func process(_ snapshot: PerceptionSnapshot) {
        guard isActive else { return }
        let now = CACurrentMediaTime()

        // ---- 1. System reliability outranks everything. ---------------
        if !snapshot.reliability.isUsable {
            if wasUsable {
                // The transition is the urgent part. The user was relying on
                // us a second ago and must know, right now, that they can't.
                haptics.pulseSystemFailure()
                wasUsable = false
            }
            speech.announceReliability(snapshot.reliability, now: now)
            // Deliberately emit nothing else. Pulsing stale obstacles while
            // blind to the world is exactly the lie we are trying not to tell.
            return
        }

        if !wasUsable {
            wasUsable = true
            speech.say("Guidance resumed", priority: .critical, now: now)
        }

        if case .degraded = snapshot.reliability {
            // Keep guiding — degraded is still useful — but flag it, on the
            // slow clock so it does not nag.
            speech.announceReliability(snapshot.reliability, now: now)
        }

        // ---- 2. Pick the few that matter. ------------------------------
        let candidates = snapshot.obstacles.prefix(4)

        // Only things roughly in front of or beside the user get a located
        // sound; memory of what is behind is kept for the spoken summary.
        let locatable = candidates.filter {
            ($0.state == .observed || $0.state == .inferred) && abs($0.azimuth) < 1.4
        }
        let unresolved = candidates.filter { $0.state == .expiring }

        // Two voices maximum. This is the hard attention budget.
        for track in locatable.prefix(2) {
            let interval = track.band.pulseInterval
            let last = lastPulse[track.id] ?? 0
            guard now - last >= interval else { continue }
            lastPulse[track.id] = now

            if audioEnabled   { audio.play(track: track, now: now) }
            if hapticsEnabled { haptics.pulse(for: track) }
        }

        // ---- 3. The "I lost something" cue. ----------------------------
        // Not located — we no longer know where it is, and saying otherwise
        // would be inventing data. Low frequency so it does not nag.
        if !unresolved.isEmpty, now - lastUnresolvedCue > 1.6 {
            lastUnresolvedCue = now
            if audioEnabled   { audio.playUnresolved(now: now) }
            if hapticsEnabled { haptics.pulseUnresolved() }
        }

        // ---- 4. Speech, only on change of state. -----------------------
        if let primary = snapshot.primary, primary.band >= .caution {
            let descriptor = "\(primary.bearing.rawValue)|\(primary.band.rawValue)|\(primary.state)"
            if lastSpokenState[primary.id] != descriptor {
                lastSpokenState[primary.id] = descriptor
                let priority: SpeechAnnouncer.Priority =
                    (primary.band == .imminent && primary.state.isTrustworthy) ? .critical : .informative
                speech.say(SpeechAnnouncer.describe(primary), priority: priority, now: now)
            }
        }

        // ---- 5. Path guidance, on change only. Advice about WHERE to go is
        //         given only at full trust — at reduced trust we warn but do
        //         not steer. Guessing a direction is worse than none.
        let space = snapshot.space
        let blockedNow = space.corridorCertainty >= 0.5 && space.corridorClear < 1.8
        let clearNow = space.corridorCertainty >= 0.6 && space.corridorClear > 3.0
        if blockedNow && !pathBlocked {
            pathBlocked = true
            var sentence = "Path blocked ahead"
            if snapshot.reliability.isNominal, let side = SceneDescriber.freerSide(snapshot) {
                sentence += ". More space on your \(side)"
            }
            speech.say(sentence, priority: .informative, now: now)
        } else if clearNow && pathBlocked {
            pathBlocked = false
        }

        // ---- 6. Confirm clear. -----------------------------------------
        // Rare on purpose: every eight seconds, and only when we are genuinely
        // confident. It answers the question the user is actually asking in
        // the silence, which is "is this thing still running?"
        if snapshot.isPathClear, now - lastClearConfirmation > 8.0 {
            lastClearConfirmation = now
            if hapticsEnabled { haptics.pulseClear() }
        }

        // Housekeeping: forget tracks that no longer exist.
        let liveIDs = Set(snapshot.obstacles.map(\.id))
        lastPulse = lastPulse.filter { liveIDs.contains($0.key) }
        lastSpokenState = lastSpokenState.filter { liveIDs.contains($0.key) }
    }
}
