//
//  SpatialAudioEngine.swift
//  FieldVision
//
//  Puts a sound where the obstacle is.
//
//  Why spatial audio and not speech:
//    Speech is slow. "Obstacle, one point two metres, ten degrees left" takes
//    about three seconds to say, by which time you have walked into it. A beep
//    that simply *arrives from the left* is understood before it has finished
//    playing, and it leaves the user's own hearing — their primary mobility
//    sense — free the rest of the time.
//
//  Why we generate the tones in code:
//    No audio assets to ship, and the tone can be parameterised by urgency and
//    by confidence. An uncertain obstacle literally sounds blurrier than a
//    confirmed one. The ear is extremely good at this distinction; the
//    conscious mind does not have to be involved.
//
//  ⚠️ Hardware note for the team: this must be heard on OPEN-EAR hardware —
//  bone conduction (Shokz) or AirPods in Transparency mode. Occluding a blind
//  user's ears to give them navigation cues takes away more information than
//  it provides. Every piece of field research says the same thing.
//

import AVFoundation
import simd

final class SpatialAudioEngine {

    private let engine = AVAudioEngine()
    private let environment = AVAudioEnvironmentNode()

    /// A small pool so two or three obstacles can sound at once without one
    /// cutting the other off.
    private var voices: [Voice] = []
    private let voiceCount = 3

    private var isConfigured = false

    private struct Voice {
        let player: AVAudioPlayerNode
        var busyUntil: TimeInterval = 0
        var assignedTrack: UUID?
    }

    /// Mono is mandatory — AVAudioEnvironmentNode refuses to spatialise a
    /// stereo input, it just passes it through. This is the single most common
    /// reason "my spatial audio doesn't work" on iOS.
    private lazy var monoFormat = AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                                channels: 1)!

    private var toneCache: [ToneKey: AVAudioPCMBuffer] = [:]

    private struct ToneKey: Hashable {
        let frequency: Int
        let durationMs: Int
        let soft: Bool
    }

    // MARK: - Setup

    func configure() throws {
        guard !isConfigured else { return }

        let session = AVAudioSession.sharedInstance()
        // .duckOthers rather than .mixWithOthers: blind users very often have a
        // podcast or an audiobook running. We want to dip it for a cue, not
        // fight it and not kill it.
        try session.setCategory(.playback,
                                mode: .default,
                                options: [.duckOthers, .allowBluetoothA2DP])
        try session.setActive(true)

        engine.attach(environment)
        engine.connect(environment, to: engine.mainMixerNode, format: nil)

        // Listener sits at the origin facing −Z. We feed obstacle positions in
        // CAMERA-relative coordinates, which share that convention, so the
        // mapping is identity. See `play(...)` for why that is the right
        // reference frame for a body-worn phone.
        environment.listenerPosition = AVAudio3DPoint(x: 0, y: 0, z: 0)
        environment.listenerAngularOrientation = AVAudio3DAngularOrientation(yaw: 0, pitch: 0, roll: 0)

        // Distance attenuation is left shallow on purpose. Real inverse-square
        // falloff makes a 4 m obstacle inaudible outdoors. Urgency is carried
        // by pulse RATE, which is far easier to judge than loudness.
        environment.distanceAttenuationParameters.distanceAttenuationModel = .inverse
        environment.distanceAttenuationParameters.referenceDistance = 1.0
        environment.distanceAttenuationParameters.maximumDistance = 12.0
        environment.distanceAttenuationParameters.rolloffFactor = 0.4

        environment.reverbParameters.enable = false   // clarity over realism

        for _ in 0..<voiceCount {
            let player = AVAudioPlayerNode()
            engine.attach(player)
            engine.connect(player, to: environment, format: monoFormat)
            player.renderingAlgorithm = preferredRenderingAlgorithm()
            voices.append(Voice(player: player))
        }

        engine.prepare()
        try engine.start()
        for v in voices { v.player.play() }

        isConfigured = true
    }

    /// HRTF gives genuine front/back and elevation cues but only through
    /// headphones. Through the phone speaker it sounds like mush, so fall back
    /// to plain panning.
    private func preferredRenderingAlgorithm() -> AVAudio3DMixingRenderingAlgorithm {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        let onHeadphones = outputs.contains {
            $0.portType == .headphones ||
            $0.portType == .bluetoothA2DP ||
            $0.portType == .bluetoothHFP ||
            $0.portType == .bluetoothLE
        }
        return onHeadphones ? .HRTFHQ : .equalPowerPanning
    }

    func refreshRenderingAlgorithm() {
        let algo = preferredRenderingAlgorithm()
        for v in voices { v.player.renderingAlgorithm = algo }
    }

    func stop() {
        for v in voices { v.player.stop() }
        engine.stop()
        isConfigured = false
        voices.removeAll()
        try? AVAudioSession.sharedInstance().setActive(false,
                                                       options: .notifyOthersOnDeactivation)
    }

    // MARK: - Playing a cue

    /// Emit one pulse for one obstacle.
    ///
    /// The sound design, and the reasoning behind it:
    ///
    ///   pitch     ← proximity band. Higher = closer. Nearly universal idiom.
    ///   timbre    ← confidence. Observed obstacles get a clean sine;
    ///               inferred ones get a detuned, softer tone that is audibly
    ///               "fuzzy". The user hears doubt without being told about it.
    ///   position  ← direction, via HRTF.
    ///   rate      ← urgency, set by the caller (see ProximityBand.pulseInterval).
    ///
    func play(track: TrackedObstacle, now: TimeInterval) {
        guard isConfigured, track.state != .lost else { return }

        // `.expiring` means we no longer believe our own position estimate.
        // Playing a *located* sound would be a lie. The coordinator emits a
        // non-directional "unresolved" cue for these instead.
        guard track.state != .expiring else { return }

        guard let voiceIndex = claimVoice(for: track, now: now) else { return }

        let soft = (track.state == .inferred)
        let frequency = Self.frequency(for: track.band, motion: track.motion)
        let duration  = Self.duration(for: track.band)

        guard let buffer = tone(frequency: frequency, duration: duration, soft: soft) else { return }

        // --- Position.
        //
        // CAMERA-relative, deliberately. With the phone on the chest (the
        // ergonomics this app assumes — see README) the camera axis is the
        // body axis, so "sound on your left" means "obstacle on your left"
        // regardless of which way the street is pointing.
        //
        // If you later support head-tracked AirPods, compensate here with
        // CMHeadphoneMotionManager so the cue stays locked to the BODY while
        // the head turns. Without that compensation, turning your head makes
        // the obstacle appear to move, which is disorienting.
        let distance = max(0.4, min(track.distance, 10))
        let x =  sin(track.azimuth) * distance
        let y =  sin(track.elevation) * distance * 0.5   // flattened: vertical
                                                         // HRTF cues are weak,
                                                         // don't oversell them
        let z = -cos(track.azimuth) * distance           // −Z is in front

        var voice = voices[voiceIndex]
        voice.player.position = AVAudio3DPoint(x: Float(x), y: Float(y), z: Float(z))
        voice.player.volume = 0.35 + 0.65 * track.salience

        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voice.busyUntil = now + duration
        voice.assignedTrack = track.id
        voices[voiceIndex] = voice
    }

    /// A deliberately different, non-directional sound meaning:
    /// "something was there, I can no longer place it, stay alert."
    ///
    /// This is the audible form of "signal the loss of reliability". It is a
    /// low two-tone phrase placed straight ahead — distinct enough from an
    /// obstacle pulse that it can never be mistaken for one.
    func playUnresolved(now: TimeInterval) {
        guard isConfigured, let voiceIndex = freeVoice(now: now) else { return }
        guard let buffer = tone(frequency: 320, duration: 0.18, soft: true) else { return }

        var voice = voices[voiceIndex]
        voice.player.position = AVAudio3DPoint(x: 0, y: 0, z: -1.5)
        voice.player.volume = 0.45
        voice.player.scheduleBuffer(buffer, at: nil, options: .interrupts)
        voice.busyUntil = now + 0.18
        voice.assignedTrack = nil
        voices[voiceIndex] = voice
    }

    // MARK: - Voice allocation

    private func claimVoice(for track: TrackedObstacle, now: TimeInterval) -> Int? {
        // Prefer the voice that was already rendering this obstacle — keeps a
        // given object's pulses coming from a consistent place.
        if let i = voices.firstIndex(where: { $0.assignedTrack == track.id }) {
            return voices[i].busyUntil <= now ? i : nil
        }
        return freeVoice(now: now)
    }

    private func freeVoice(now: TimeInterval) -> Int? {
        voices.firstIndex { $0.busyUntil <= now }
    }

    // MARK: - Tone synthesis

    private static func frequency(for band: ProximityBand, motion: MotionClass) -> Float {
        var f: Float
        switch band {
        case .imminent: f = 1320
        case .caution:  f = 880
        case .aware:    f = 590
        case .clear:    f = 440
        }
        // A thing moving toward you gets a slightly sharper tone — enough to
        // notice, not enough to confuse the distance mapping.
        if case .approaching = motion { f *= 1.12 }
        return f
    }

    private static func duration(for band: ProximityBand) -> TimeInterval {
        switch band {
        case .imminent: return 0.07   // short and stabby
        case .caution:  return 0.10
        case .aware:    return 0.14   // longer and calmer
        case .clear:    return 0.14
        }
    }

    private func tone(frequency: Float, duration: TimeInterval, soft: Bool) -> AVAudioPCMBuffer? {
        let key = ToneKey(frequency: Int(frequency),
                          durationMs: Int(duration * 1000),
                          soft: soft)
        if let cached = toneCache[key] { return cached }

        let sampleRate = Float(monoFormat.sampleRate)
        let frameCount = AVAudioFrameCount(Double(sampleRate) * duration)
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: frameCount),
              let channel = buffer.floatChannelData?[0] else { return nil }

        buffer.frameLength = frameCount
        let n = Int(frameCount)

        // Raised-cosine envelope. A hard edge on a short tone produces an
        // audible click, and clicks are both unpleasant and hard to localise —
        // the ear needs a little sustain to place a sound in space.
        let attack  = Float(n) * (soft ? 0.30 : 0.12)
        let release = Float(n) * (soft ? 0.45 : 0.35)

        for i in 0..<n {
            let t = Float(i) / sampleRate
            let fi = Float(i)

            var env: Float = 1
            if fi < attack {
                env = 0.5 - 0.5 * cos(.pi * fi / attack)
            } else if fi > Float(n) - release {
                let k = (Float(n) - fi) / release
                env = 0.5 - 0.5 * cos(.pi * k)
            }

            var sample = sin(2 * .pi * frequency * t)

            if soft {
                // Beating between two slightly detuned partials. This is what
                // "uncertain" sounds like: wavering, not solid. Users learn it
                // in seconds without being taught.
                sample = 0.6 * sample + 0.4 * sin(2 * .pi * frequency * 1.021 * t)
                sample *= 0.75
            } else {
                // A touch of second harmonic so the tone cuts through traffic
                // noise without needing more volume.
                sample = 0.85 * sample + 0.15 * sin(4 * .pi * frequency * t)
            }

            channel[i] = sample * env * 0.55
        }

        toneCache[key] = buffer
        return buffer
    }
}
