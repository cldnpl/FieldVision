//
//  ObstacleTracker.swift
//  FieldVision
//
//  ★ Identity, motion and occlusion. ★
//
//  Each object is tracked as a Gaussian too: a constant-velocity Kalman filter
//  per horizontal axis, so every track carries an honest position covariance.
//
//  1. PREDICT   every track moves with its velocity; its covariance GROWS.
//  2. ASSOCIATE detections ↔ tracks by Mahalanobis distance (a 2D chi² gate
//               on track + measurement covariance), not raw metres — an
//               uncertain track accepts a wider match, a certain one doesn't.
//  3. UPDATE    matched tracks shrink their covariance.
//  4. OCCLUSION unmatched tracks are ray-tested against the splat map:
//                 ray stops short   → .hidden    keep predicting (≤ 2.5 s)
//                 ray passes through→ .vanished  drop after 3 frames, no ghost
//                 outside the view  → .outOfView static things are remembered
//                 no depth there    → .noData
//  5. HONESTY   a direction is only stated while the angular uncertainty is
//               under one sector (~15°). Past that the track is .expiring:
//               "something unresolved", no direction. This replaces a fixed
//               timeout with the uncertainty the filter actually has.
//

import Foundation
import simd

/// Constant-velocity Kalman filter on one axis. State (p, v), 2×2 covariance.
struct AxisKalman {
    var p: Float
    var v: Float = 0
    var P00: Float
    var P01: Float = 0
    var P11: Float = 1.0

    init(position: Float, variance: Float) {
        p = position
        P00 = variance
    }

    /// White-noise acceleration model with spectral density q (m²/s³).
    mutating func predict(dt: Float, q: Float) {
        p += v * dt
        let dt2 = dt * dt, dt3 = dt2 * dt
        let n00 = P00 + 2 * dt * P01 + dt2 * P11 + q * dt3 / 3
        let n01 = P01 + dt * P11 + q * dt2 / 2
        let n11 = P11 + q * dt
        P00 = n00; P01 = n01; P11 = n11
    }

    mutating func update(measurement z: Float, variance r: Float) {
        let s = P00 + r
        let k0 = P00 / s, k1 = P01 / s
        let y = z - p
        p += k0 * y
        v += k1 * y
        let n11 = P11 - k1 * P01
        P00 = (1 - k0) * P00
        P01 = (1 - k0) * P01
        P11 = max(n11, 1e-4)
    }
}

/// One person-detector result, in the raw camera image's coordinates.
struct HumanObservation {
    var timestamp: TimeInterval
    var worldToCamera: simd_float4x4
    /// Pinhole intrinsics in pixels of the raw (sensor-oriented) image.
    var fx: Float, fy: Float, cx: Float, cy: Float
    var width: Float, height: Float
    /// Normalised boxes, origin top-left of the raw image.
    var boxes: [CGRect]

    func contains(_ world: SIMD3<Float>, in box: CGRect) -> Bool {
        let p4 = worldToCamera * SIMD4<Float>(world, 1)
        guard p4.z < -0.1 else { return false }
        let z = -p4.z
        let u = (fx * p4.x / z + cx) / width
        let v = (-fy * p4.y / z + cy) / height
        let padded: CGRect = box.insetBy(dx: -0.1 * box.width, dy: -0.1 * box.height)
        return padded.contains(CGPoint(x: CGFloat(u), y: CGFloat(v)))
    }

    func depth(of world: SIMD3<Float>) -> Float {
        -(worldToCamera * SIMD4<Float>(world, 1)).z
    }
}

final class ObstacleTracker {

    private struct Track {
        let id: UUID
        var x: AxisKalman
        var z: AxisKalman
        var y: Float
        var nearestOffset: SIMD3<Float>
        /// Decaying votes over the shape class of each detection, so one
        /// partial view at the edge of the frame can't relabel a column "low".
        var kindVotes: [ObstacleKind: Float]
        var personScore: Float = 0
        var dynamicScore: Float
        /// Track-level motion evidence: a compact object whose measured
        /// centre keeps moving away from where it was is moving, whatever
        /// the splats say.
        var motionEvidence: Float = 0
        var anchor: SIMD2<Float>
        var anchorTime: TimeInterval
        var splatCount: Int
        /// Person-sized footprint (not a wall or a van). Only compact objects
        /// can be labelled "person" or be called moving from centroid drift.
        var compact = true
        var state: TrackState = .observed
        var cause: OcclusionCause = .none
        var lastObservedAt: TimeInterval
        var consecutiveHits = 1
        var totalHits = 1
        var vanishedFrames = 0

        var isConfirmed: Bool { totalHits >= Tuning.hitsBeforeAnnouncing }
        /// Big things (walls, vans) need much stronger splat evidence to be
        /// called moving: a person brushing past them must not make them move.
        var isDynamic: Bool {
            compact ? (dynamicScore > 0.3 || motionEvidence >= 0.5 || personScore >= 0.5)
                    : dynamicScore > 0.6
        }
        var position: SIMD3<Float> { SIMD3(x.p, y, z.p) }
        var velocity: SIMD3<Float> { isDynamic ? SIMD3(x.v, 0, z.v) : .zero }
        var positionStd: Float { sqrt(max(x.P00, z.P00)) }
        var kind: ObstacleKind {
            if personScore >= 0.5 { return .person }
            let best = kindVotes.filter { $0.key != .moving }.max { $0.value < $1.value }?.key ?? .obstacle
            if isDynamic && compact && (best == .obstacle || best == .large) { return .moving }
            return best
        }
    }

    private var tracks: [Track] = []
    private var lastUpdate: TimeInterval = 0
    private var lastHumanTimestamp: TimeInterval = 0
    /// Timestamps of confirmed tracks that vanished unexplained. Feeds the
    /// trust score: a scene where tracks keep blinking out is one we can't
    /// follow.
    private var unexplainedLosses: [TimeInterval] = []

    var churnPerSecond: Float {
        Float(unexplainedLosses.count) / 3
    }

    // MARK: - Update

    func update(detections: [SplatDetection],
                map: GaussianSplatMap,
                frame: DepthFrame,
                body: BodyFrame,
                humans: HumanObservation?) -> [TrackedObstacle] {

        let now = frame.timestamp
        let dt = Float(lastUpdate == 0 ? 1.0 / 30 : max(0.001, min(0.25, now - lastUpdate)))
        lastUpdate = now

        // 1. Predict.
        for i in tracks.indices {
            // Pedestrian-like manoeuvring for moving things, near zero for structure.
            let q: Float = tracks[i].isDynamic ? 0.3 : 0.05
            tracks[i].x.predict(dt: dt, q: q)
            tracks[i].z.predict(dt: dt, q: q)
        }

        // 2. Associate (greedy on Mahalanobis distance, best pairs first).
        var pairs: [(t: Int, d: Int, m2: Float)] = []
        for (di, det) in detections.enumerated() {
            let (rx, rz) = measurementVariance(det)
            for (ti, tr) in tracks.enumerated() {
                let dx = det.mean.x - tr.x.p, dz = det.mean.z - tr.z.p
                guard dx * dx + dz * dz < 2.25 else { continue }
                let m2 = dx * dx / (tr.x.P00 + rx) + dz * dz / (tr.z.P00 + rz)
                if m2 < Tuning.gateChi2 { pairs.append((ti, di, m2)) }
            }
        }
        pairs.sort { $0.m2 < $1.m2 }

        var usedT = Set<Int>(), usedD = Set<Int>()
        for p in pairs where !usedT.contains(p.t) && !usedD.contains(p.d) {
            usedT.insert(p.t); usedD.insert(p.d)
            let det = detections[p.d]
            let (rx, rz) = measurementVariance(det)
            var t = tracks[p.t]
            t.x.update(measurement: det.mean.x, variance: rx)
            t.z.update(measurement: det.mean.z, variance: rz)
            t.y = t.y * 0.7 + det.mean.y * 0.3
            t.nearestOffset = det.nearestPoint - det.mean
            t.dynamicScore = t.dynamicScore * 0.8 + det.dynamicFraction * 0.2
            updateMotionEvidence(&t, det: det, now: now)
            if !t.isDynamic {
                // Static structure: centroid drift as more of a wall comes
                // into view is not motion. Bleed the velocity off.
                t.x.v *= 0.85; t.z.v *= 0.85
            }
            // A partial view (few splats) votes weakly on what the object is.
            for k in t.kindVotes.keys { t.kindVotes[k]! *= 0.93 }
            if det.splatCount >= 8 {
                t.kindVotes[det.kind, default: 0] += min(1, Float(det.splatCount) / 15)
            }
            if det.splatCount >= 8 { t.compact = Self.isCompact(det) }
            t.splatCount = det.splatCount
            t.state = .observed
            t.cause = .none
            t.lastObservedAt = now
            t.consecutiveHits += 1
            t.totalHits += 1
            t.vanishedFrames = 0
            tracks[p.t] = t
        }

        // 3. Occlusion reasoning for everything we did not see.
        for i in tracks.indices where !usedT.contains(i) {
            var t = tracks[i]
            t.consecutiveHits = 0
            guard t.isConfirmed else { t.state = .lost; tracks[i] = t; continue }

            let vis = map.visibility(of: t.position, sigma: min(0.3, t.positionStd), in: frame)
            switch vis {
            case .carved:
                t.vanishedFrames += 1
                t.cause = .vanished
            case .occluded, .hit:
                t.vanishedFrames = 0
                t.cause = .hidden
            case .outOfView:
                t.cause = .outOfView
            case .noData:
                t.cause = .noData
            }

            let age = now - t.lastObservedAt
            let memory: TimeInterval
            switch t.cause {
            case .hidden:    memory = Tuning.hiddenMemory
            case .outOfView: memory = t.isDynamic ? Tuning.dynamicMemory : Tuning.staticOutOfViewMemory
            default:         memory = Tuning.dynamicMemory
            }

            let range = max(0.5, simd_length(SIMD2(t.x.p - body.origin.x, t.z.p - body.origin.z)))
            let angularStd = t.positionStd / range

            if t.vanishedFrames >= 3 {
                // The sensor saw straight through where it should be. It is
                // not there. Keeping a ghost would be inventing data.
                t.state = .lost
                if t.isDynamic { unexplainedLosses.append(now) }
            } else if age > memory {
                t.state = .lost
                if t.isDynamic && t.cause != .outOfView { unexplainedLosses.append(now) }
            } else if angularStd > Tuning.maxDirectionalAngularStd || t.positionStd > Tuning.maxDirectionalPositionStd {
                t.state = .expiring
            } else {
                t.state = .inferred
            }
            tracks[i] = t
        }

        // 4. Births.
        for (di, det) in detections.enumerated() where !usedD.contains(di) {
            let (rx, rz) = measurementVariance(det)
            var x = AxisKalman(position: det.mean.x, variance: rx + 0.02)
            var z = AxisKalman(position: det.mean.z, variance: rz + 0.02)
            x.P11 = 0.25; z.P11 = 0.25
            tracks.append(Track(id: UUID(), x: x, z: z, y: det.mean.y,
                                nearestOffset: det.nearestPoint - det.mean,
                                kindVotes: [det.kind: 1],
                                dynamicScore: det.dynamicFraction,
                                anchor: SIMD2(det.mean.x, det.mean.z),
                                anchorTime: now,
                                splatCount: det.splatCount,
                                compact: Self.isCompact(det),
                                lastObservedAt: now))
        }

        tracks.removeAll { $0.state == .lost }

        // 5. A predicted track that a CONFIRMED observed track now covers is
        //    the same object re-found: keep the observed one. (Never let a
        //    one-frame newborn — e.g. a sliver of someone peeking past an
        //    occluder — erase a confirmed hidden track.)
        let confirmedObserved = tracks.filter { $0.state == .observed && $0.isConfirmed }.map(\.position)
        tracks.removeAll { t in
            t.state != .observed && confirmedObserved.contains {
                simd_distance(SIMD2($0.x, $0.z), SIMD2(t.x.p, t.z.p)) < 0.4
            }
        }

        // 6. Person labels from the low-rate detector. Each box labels at
        //    most ONE track: the nearest compact one inside it. (The wall
        //    behind a person also projects into the person's box.)
        if let humans, humans.timestamp > lastHumanTimestamp {
            lastHumanTimestamp = humans.timestamp
            var labelled = Set<Int>()
            for box in humans.boxes {
                let candidates = tracks.indices.filter {
                    tracks[$0].state == .observed && tracks[$0].compact &&
                    humans.contains(tracks[$0].position, in: box)
                }
                if let best = candidates.min(by: {
                    humans.depth(of: tracks[$0].position) < humans.depth(of: tracks[$1].position)
                }) {
                    labelled.insert(best)
                }
            }
            for i in tracks.indices {
                if labelled.contains(i) {
                    tracks[i].personScore = min(1, tracks[i].personScore + 0.45)
                } else if !tracks[i].compact {
                    tracks[i].personScore = 0
                } else if tracks[i].state == .observed && tracks[i].splatCount >= 25 {
                    // Fully visible and still not in any box: probably not a
                    // person. (Partly hidden people keep their label.)
                    tracks[i].personScore = max(0, tracks[i].personScore - 0.05)
                }
            }
        }

        if tracks.count > 24 {
            tracks.sort { $0.lastObservedAt > $1.lastObservedAt }
            tracks.removeLast(tracks.count - 24)
        }
        unexplainedLosses.removeAll { now - $0 > 3 }

        return tracks
            .filter { $0.isConfirmed }
            .map { output(for: $0, body: body) }
            .filter { $0.band != .clear }
            .sorted { $0.salience > $1.salience }
    }

    // MARK: - Helpers

    private static func isCompact(_ d: SplatDetection) -> Bool {
        sqrt(d.cov.columns.0.x + d.cov.columns.2.z) < 0.45
    }

    private func updateMotionEvidence(_ t: inout Track, det: SplatDetection, now: TimeInterval) {
        let m = SIMD2(det.mean.x, det.mean.z)
        // Centroid drift alone is not motion: a wall segment partly hidden by
        // a passer-by "moves" too. Require some splat-level evidence as well.
        if Self.isCompact(det) && det.splatCount >= 8 && det.dynamicFraction > 0.15
            && simd_distance(m, t.anchor) > 0.3 {
            t.motionEvidence = min(1, t.motionEvidence + 0.5)
            t.anchor = m; t.anchorTime = now
        } else if now - t.anchorTime > 2.0 {
            t.motionEvidence *= 0.5
            t.anchor = m; t.anchorTime = now
        }
    }

    /// How noisy a cluster centroid is as a measurement of the object's
    /// position: a fixed floor plus a fraction of its spatial spread (partial
    /// views of big objects shift the centroid).
    private func measurementVariance(_ d: SplatDetection) -> (Float, Float) {
        // Few splats = a partial view whose centre is biased: trust it less.
        let partial: Float = d.splatCount < 10 ? 0.04 : 0
        return (0.004 + partial + 0.15 * d.cov.columns.0.x,
                0.004 + partial + 0.15 * d.cov.columns.2.z)
    }

    private func output(for t: Track, body: BodyFrame) -> TrackedObstacle {
        let nearest = t.position + t.nearestOffset
        let l = body.local(nearest)
        let horizontal = sqrt(l.x * l.x + l.z * l.z)
        let azimuth = atan2(l.x, max(0.01, l.z))
        let elevation = atan2(l.y, max(0.3, horizontal))

        var o = TrackedObstacle(
            id: t.id,
            worldPosition: t.position,
            nearestPoint: nearest,
            worldVelocity: t.velocity,
            positionStd: t.positionStd,
            splatCount: t.splatCount,
            state: t.state,
            cause: t.cause,
            kind: t.kind,
            lastObservedAt: t.lastObservedAt,
            consecutiveHits: t.consecutiveHits
        )
        o.distance = horizontal
        o.azimuth = l.z > 0 ? azimuth : (l.x >= 0 ? .pi / 2 : -.pi / 2)
        o.elevation = elevation
        o.bearing = Bearing(angle: o.azimuth)
        o.band = ProximityBand(distance: horizontal)
        o.localXZ = SIMD2(l.x, l.z)
        o.motion = classifyMotion(t, body: body)
        return o
    }

    private func classifyMotion(_ t: Track, body: BodyFrame) -> MotionClass {
        guard t.isDynamic else { return .stationary }
        let v = SIMD3<Float>(t.x.v, 0, t.z.v)
        guard simd_length(v) > 0.25 else { return .stationary }
        let toUser = body.origin - t.position
        let radial = simd_normalize(SIMD3(toUser.x, 0, toUser.z))
        let closing = simd_dot(v, radial)
        let lateral = simd_dot(v, body.right)
        if closing > 0.3 && closing > abs(lateral) { return .approaching(closingSpeed: closing) }
        if abs(lateral) > 0.3 { return .crossing(lateralSpeed: lateral) }
        if closing < -0.3 { return .receding }
        return .stationary
    }

    func reset() {
        tracks.removeAll()
        lastUpdate = 0
        lastHumanTimestamp = 0
        unexplainedLosses.removeAll()
    }
}
