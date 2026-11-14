//
//  TrustEstimator.swift
//  FieldVision
//
//  "Signal the loss of reliability when necessary" — computed, not faked.
//
//  Seven measurable signals, each mapped to 0...1, multiplied into one trust
//  score. The weakest factor names the reason the user hears.
//
//    coverage   share of depth samples that came back usable
//    tracking   ARKit's own pose-tracking state
//    light      scene brightness
//    motion     camera rotation speed (fast swings blur and smear depth)
//    aim        camera pitch — pointed at the ground or the sky sees no path
//    path       splat-rendered certainty of the corridor straight ahead
//    churn      confirmed moving tracks vanishing unexplained, per second
//
//  The score is smoothed asymmetrically (falls fast, rises slowly) and turned
//  into a state with hysteresis, so the system never flickers between
//  "paused" and "resumed", and never claims recovery early.
//

import Foundation
import simd

final class TrustEstimator {

    private var smoothed: Float = 0
    private var state: SystemReliability = .degraded(reason: "Starting up")
    private var aboveSince: TimeInterval?
    private var startTime: TimeInterval?
    private var lastRotation: simd_quatf?
    private var lastTime: TimeInterval = 0
    private var angularSpeed: Float = 0

    struct Result {
        var trust: Float
        var factors: [TrustFactor]
        var reliability: SystemReliability
    }

    func evaluate(frame: DepthFrame, coverage: Float, profile: SpaceProfile,
                  body: BodyFrame, churn: Float) -> Result {
        let now = frame.timestamp
        let isFirstFrame = startTime == nil
        if isFirstFrame { startTime = now }

        // Camera angular speed from consecutive orientations.
        let q = simd_quatf(frame.cameraToWorld)
        if let last = lastRotation, now > lastTime {
            let rel = q * last.inverse
            let angle = 2 * acos(min(1, abs(rel.real)))
            let speed = angle / Float(now - lastTime)
            angularSpeed = angularSpeed * 0.7 + speed * 0.3
        }
        lastRotation = q
        lastTime = now

        var factors: [TrustFactor] = []

        factors.append(TrustFactor(id: "Coverage",
                                   value: smoothstep(0.06, 0.30, coverage),
                                   reason: "The camera cannot see the path"))

        let trackingValue: Float
        var trackingReason = "Position tracking lost"
        switch frame.tracking {
        case .normal: trackingValue = 1
        case .limited(let r): trackingValue = 0.55; trackingReason = r
        case .notAvailable: trackingValue = 0
        }
        factors.append(TrustFactor(id: "Tracking", value: trackingValue, reason: trackingReason))

        factors.append(TrustFactor(id: "Light",
                                   value: frame.brightness.map { smoothstep(0.04, 0.22, $0) } ?? 1,
                                   reason: "Too dark to see"))

        factors.append(TrustFactor(id: "Motion",
                                   value: 1 - smoothstep(1.5, 4.0, angularSpeed),
                                   reason: "The phone is moving too fast"))

        let pitchDeg = body.pitch * 180 / .pi
        let aimValue = 1 - max(smoothstep(-55, -75, pitchDeg), smoothstep(40, 60, pitchDeg))
        factors.append(TrustFactor(id: "Aim",
                                   value: max(0.2, aimValue),
                                   reason: pitchDeg < 0 ? "Camera points at the ground. Raise it"
                                                        : "Camera points too high. Lower it"))

        factors.append(TrustFactor(id: "Path",
                                   value: 0.45 + 0.55 * profile.corridorCertainty,
                                   reason: "Path ahead not confirmed"))

        factors.append(TrustFactor(id: "Churn",
                                   value: 1 - 0.6 * smoothstep(0.7, 2.5, churn),
                                   reason: "Too much movement to follow"))

        let raw = factors.reduce(Float(1)) { $0 * $1.value }

        // Falls fast (bad news is urgent), rises slowly (never claim recovery early).
        let alpha: Float = isFirstFrame ? 1 : (raw < smoothed ? 0.45 : 0.06)
        smoothed = smoothed * (1 - alpha) + raw * alpha

        let weakest = factors.min { $0.value < $1.value }?.reason ?? "Reduced reliability"
        state = nextState(trust: smoothed, reason: weakest, now: now)

        // The first second: the map is empty, nothing is confirmed yet.
        if let start = startTime, now - start < 1.0, state.isUsable {
            state = .degraded(reason: "Starting up")
        }

        return Result(trust: smoothed, factors: factors, reliability: state)
    }

    private func nextState(trust: Float, reason: String, now: TimeInterval) -> SystemReliability {
        switch state {
        case .unavailable:
            // Leaving "paused" needs a clearly better score, held for 0.6 s.
            if trust > Tuning.trustRecover {
                if aboveSince == nil { aboveSince = now }
                if now - (aboveSince ?? now) > 0.6 {
                    aboveSince = nil
                    return .degraded(reason: "Recovering")
                }
            } else {
                aboveSince = nil
            }
            return .unavailable(reason: trust < Tuning.trustUnavailable ? reason : (state.reason ?? reason))

        case .degraded, .nominal:
            if trust < Tuning.trustUnavailable {
                aboveSince = nil
                return .unavailable(reason: reason)
            }
            if trust < Tuning.trustDegraded {
                aboveSince = nil
                return .degraded(reason: reason)
            }
            if state.isNominal { return .nominal }
            // Promote to nominal only after 0.5 s of good scores.
            if trust > Tuning.trustNominal {
                if aboveSince == nil { aboveSince = now }
                if now - (aboveSince ?? now) > 0.5 { aboveSince = nil; return .nominal }
            }
            return state
        }
    }

    func reset() {
        smoothed = 0
        state = .degraded(reason: "Starting up")
        aboveSince = nil
        startTime = nil
        lastRotation = nil
        lastTime = 0
        angularSpeed = 0
    }
}

@inline(__always)
func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - e0) / (e1 - e0)))
    return t * t * (3 - 2 * t)
}
