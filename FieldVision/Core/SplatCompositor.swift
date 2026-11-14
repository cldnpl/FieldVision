//
//  SplatCompositor.swift
//  FieldVision
//
//  Renders the Gaussian splat map from the user's position — Gaussian
//  splatting, but the "image" is a 120° fan of 25 azimuth columns and the
//  "colour" is occupancy and certainty instead of RGB.
//
//  For every splat:
//    · project its 3D Gaussian onto the horizontal azimuth axis → a 1D
//      Gaussian with mean θ and std σθ (wide when close or uncertain),
//    · contribute alpha = opacity · exp(−½ k²) to each column it covers.
//  For every column, sort contributions front to back and composite:
//
//      T₀ = 1,   wᵢ = Tᵢ·αᵢ,   Tᵢ₊₁ = Tᵢ·(1 − αᵢ)
//
//  exactly as a 3DGS rasteriser does. From that we read:
//    nearest    the range where accumulated opacity crosses 0.5
//    occupancy  1 − T at the end of the ray
//    certainty  Σ wᵢ·freshnessᵢ  +  T·(is the camera seeing this column now?)
//
//  The certainty term is the key output. A column whose answer comes from
//  splats measured this frame is "confirmed"; one whose answer comes from
//  memory — or from nothing, because the camera isn't pointed there — is
//  "uncertain", and the feedback layer is not allowed to call it clear.
//

import Foundation
import simd

final class SplatCompositor {

    struct Output {
        var profile = SpaceProfile()
        var radar: [RadarSplat] = []
        var cameraHalfFOV: Float = 0.5
    }

    func render(map: GaussianSplatMap, frame: DepthFrame, body: BodyFrame) -> Output {
        let n = SpaceProfile.columns
        let half = SpaceProfile.halfFOV
        let colWidth = 2 * half / Float(n)
        let now = frame.timestamp
        let floor = map.floorHeight(near: body.origin.y)

        var entries = [[(range: Float, alpha: Float, cert: Float)]](repeating: [], count: n)
        var corridorEntries: [(z: Float, alpha: Float)] = []
        let hw = Tuning.corridorHalfWidth
        var radar: [RadarSplat] = []
        radar.reserveCapacity(1024)

        for s in map.splats.values {
            guard s.opacity >= 0.15 else { continue }
            let h = s.mean.y - floor
            guard h > Tuning.floorTolerance, h < Tuning.maxObstacleHeight else { continue }

            let l = body.local(s.mean)
            let range = sqrt(l.x * l.x + l.z * l.z)
            guard range < Tuning.maxUsefulDepth + 0.5 else { continue }

            let cert = Self.certainty(of: s, now: now)
            let latVar = simd_dot(body.right, s.cov * body.right)
            let sigmaH = sqrt(max(latVar, 0.0025))
            radar.append(RadarSplat(x: l.x, z: l.z, sigma: sigmaH,
                                    opacity: s.opacity, certainty: cert, dynamic: s.dynamic))

            guard l.z > 0.05 else { continue }

            // Corridor: the share of this splat's lateral Gaussian that falls
            // inside the body-width corridor, P(|x| < hw) for x ~ N(l.x, σ).
            if abs(l.x) < hw + 3 * sigmaH {
                let k = 1 / (sigmaH * sqrt(2))
                let inside = 0.5 * (erf((hw - l.x) * k) - erf((-hw - l.x) * k))
                let a = min(0.95, s.opacity) * inside
                if a > 0.02 { corridorEntries.append((l.z, a)) }
            }

            let theta = atan2(l.x, l.z)
            // Projected angular footprint, padded by half a voxel.
            let sigmaTheta = max(0.015, sqrt(latVar + 0.0025) / max(range, 0.3))
            guard abs(theta) - 3 * sigmaTheta < half else { continue }

            let a0 = min(0.95, s.opacity)
            let lo = max(0, Int(((theta - 3 * sigmaTheta) + half) / colWidth))
            let hi = min(n - 1, Int(((theta + 3 * sigmaTheta) + half) / colWidth))
            guard lo <= hi else { continue }
            for c in lo...hi {
                let k = (SpaceProfile.angle(ofColumn: c) - theta) / sigmaTheta
                let a = a0 * exp(-0.5 * k * k)
                if a > 0.02 { entries[c].append((range, a, cert)) }
            }
        }

        // ---- What the camera itself is looking at right now, per column.
        var seen = [Float](repeating: 0, count: n)
        var usable = [Float](repeating: 0, count: n)
        var halfFOV: Float = 0
        for row in 0..<frame.rows {
            for col in 0..<frame.columns {
                let dir = body.localDirection(frame.worldDirection(col: col, row: row))
                guard dir.z > 0.01 else { continue }
                let theta = atan2(dir.x, dir.z)
                halfFOV = max(halfFOV, abs(theta))
                let c = Int((theta + half) / colWidth)
                guard c >= 0, c < n else { continue }
                seen[c] += 1
                if frame.isUsable(row * frame.columns + col) { usable[c] += 1 }
            }
        }

        // ---- Front-to-back compositing.
        var profile = SpaceProfile()
        for c in 0..<n {
            let list = entries[c].sorted { $0.range < $1.range }
            var T: Float = 1
            var certAcc: Float = 0
            var nearest = Float.infinity
            for e in list {
                let w = T * e.alpha
                certAcc += w * e.cert
                T *= (1 - e.alpha)
                if nearest == .infinity && T <= 0.5 { nearest = e.range }
                if T < 0.02 { break }
            }
            let freeCert = seen[c] > 0 ? usable[c] / seen[c] : 0
            profile.nearest[c] = nearest
            profile.occupancy[c] = 1 - T
            profile.certainty[c] = min(1, certAcc + T * freeCert)
        }

        // ---- Body-width corridor straight ahead: composite the corridor
        //      entries front to back along the walking direction.
        var corridor = Float.infinity
        var T: Float = 1
        for e in corridorEntries.sorted(by: { $0.z < $1.z }) {
            T *= (1 - e.alpha)
            if T <= 0.5 { corridor = e.z; break }
        }
        var corridorCert: Float = 0, corridorN: Float = 0
        for c in 0..<n where abs(SpaceProfile.angle(ofColumn: c)) < 0.21 {
            corridorCert += profile.certainty[c]; corridorN += 1
        }
        profile.corridorClear = corridor
        profile.corridorCertainty = corridorN > 0 ? corridorCert / corridorN : 0

        // Keep the radar light: at most ~900 splats drawn.
        if radar.count > 900 {
            let step = radar.count / 900 + 1
            radar = stride(from: 0, to: radar.count, by: step).map { radar[$0] }
        }

        return Output(profile: profile, radar: radar, cameraHalfFOV: halfFOV)
    }

    /// How fresh a splat's evidence is. Measured this frame = 1. Remembered
    /// splats fade — moving things fast, static structure slowly.
    static func certainty(of s: Splat, now: TimeInterval) -> Float {
        if s.lastHit == now { return 1 }
        let age = Float(now - s.lastHit)
        let tau: Float = s.dynamic ? 0.8 : 3.0
        var c = exp(-age / tau)
        if s.visibility == .occluded { c *= 0.85 }
        return c
    }
}
