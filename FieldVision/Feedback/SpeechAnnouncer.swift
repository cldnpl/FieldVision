//
//  SpeechAnnouncer.swift
//  FieldVision
//
//  Words, used sparingly.
//
//  The dominant complaint about continuous-scanning assistive apps is that
//  they talk too much. One blind reviewer described tools like these becoming
//  "overwhelming in busy visual environments"; another said of a smart cane,
//  "after a while you just ignore it because it doesn't seem to be saying
//  anything useful. Then out of the blue a bramble goes in my face."
//
//  That failure mode — habituation, then a real hazard arriving unnoticed —
//  is the thing to design against. So:
//
//    · Tones and haptics carry the continuous stream. They are fast,
//      pre-attentive, and do not occupy language.
//    · Speech is reserved for information a tone genuinely cannot carry:
//      a category change, a semantic label, a reliability failure.
//    · Hard rate limit, plus suppression of repeats of the same message.
//
//  Rule of thumb we are encoding: if a tone can say it, a tone says it.
//

import AVFoundation

final class SpeechAnnouncer {

    private let synthesizer = AVSpeechSynthesizer()
    private var lastSpokenAt: TimeInterval = 0
    private var lastMessage: String = ""
    private var lastReliabilityAt: TimeInterval = 0

    /// Users running VoiceOver all day typically read far faster than default.
    /// Expose this; do not guess it for them.
    var speechRate: Float = AVSpeechUtteranceDefaultSpeechRate * 1.18
    var isEnabled = true

    // MARK: - Priorities

    enum Priority {
        /// Safety-critical. Interrupts anything currently being spoken.
        case critical
        /// Useful context. Subject to the rate limit, dropped if we are busy.
        case informative
    }

    // MARK: - Speaking

    func say(_ message: String,
             priority: Priority = .informative,
             now: TimeInterval,
             force: Bool = false) {
        guard (isEnabled || force), !message.isEmpty else { return }

        if priority == .informative {
            guard now - lastSpokenAt >= Tuning.minSpeechInterval else { return }
            // Saying the same sentence twice in a row is how an aid becomes
            // wallpaper. If nothing changed, say nothing.
            guard message != lastMessage else { return }
            guard !synthesizer.isSpeaking else { return }
        } else {
            // Critical messages cut the line — but we still suppress exact
            // repeats, so a persistent fault does not become a chant.
            guard force || message != lastMessage || now - lastSpokenAt > 8 else { return }
            synthesizer.stopSpeaking(at: .word)
        }

        let utterance = AVSpeechUtterance(string: message)
        utterance.rate = speechRate
        utterance.pitchMultiplier = priority == .critical ? 1.08 : 1.0
        utterance.preUtteranceDelay = 0
        utterance.postUtteranceDelay = 0
        // preferredLanguages gives BCP-47 ("en-GB"); Locale.identifier gives
        // POSIX ("en_GB"), which AVSpeechSynthesisVoice does not accept.
        // The app speaks English; use an English voice whatever the
        // device language is, or the sentences come out mispronounced.
        let preferred = Locale.preferredLanguages.first { $0.hasPrefix("en") } ?? "en-US"
        utterance.voice = AVSpeechSynthesisVoice(language: preferred)
                       ?? AVSpeechSynthesisVoice(language: "en-US")

        synthesizer.speak(utterance)
        lastSpokenAt = now
        lastMessage = message
    }

    /// Reliability messages get their own, slower clock. They are important
    /// but they are also the ones most likely to repeat (a lens stays covered
    /// for a while), so they need a longer leash than ordinary speech.
    func announceReliability(_ reliability: SystemReliability, now: TimeInterval) {
        guard let text = reliability.spokenDescription else { return }
        guard now - lastReliabilityAt >= Tuning.minReliabilityInterval else { return }
        lastReliabilityAt = now

        let priority: Priority = reliability.isUsable ? .informative : .critical
        say(text, priority: priority, now: now)
    }

    /// Build the sentence for one obstacle.
    ///
    /// Word order is chosen for interruptibility: the most important word
    /// comes first, so the message still works if the user stops listening
    /// after one syllable. "Right, person approaching" beats "There is a
    /// person approaching on your right".
    ///
    /// Certainty is part of the sentence, never implied:
    ///   observed  → stated plainly
    ///   inferred  → "probably", plus WHY we can't see it ("hidden")
    ///   expiring  → no direction at all: "Lost track of the person"
    static func describe(_ track: TrackedObstacle) -> String {
        if track.state == .expiring {
            return "Lost track of the \(track.kind.spokenName). Stay alert"
        }

        var parts: [String] = []
        parts.append(track.bearing == .ahead ? "Ahead" : track.bearing.spokenName.capitalized)

        var subject = track.kind.spokenName
        if track.state == .inferred { subject = "probably \(subject)" }
        parts.append(subject)

        if track.motion.isDynamic { parts.append(track.motion.phrase) }

        if track.band == .imminent {
            parts.append("very close")
        } else if track.band == .caution || track.band == .aware {
            parts.append(Self.metres(track.distance))
        }

        if track.state == .inferred, let why = track.cause.phrase {
            parts.append(why)
        }
        return parts.joined(separator: ", ")
    }

    static func metres(_ d: Float) -> String {
        let rounded = (d * 2).rounded() / 2
        if rounded <= 1 { return "1 metre" }
        return rounded.truncatingRemainder(dividingBy: 1) == 0
            ? String(format: "%.0f metres", rounded)
            : String(format: "%.1f metres", rounded)
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
    }
}
