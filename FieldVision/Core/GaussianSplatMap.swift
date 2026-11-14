//
//  GaussianSplatMap.swift
//  FieldVision
//
//  ★ The core of detection: an online 3D Gaussian splat map of the space
//    around the user, built live from LiDAR depth. ★
//
//  Every depth sample is a small 3D Gaussian: its mean is the measured point
//  and its covariance is the sensor's footprint (wide across the ray at long
//  range, thin along it). Samples that land in the same 20 cm voxel are fused
//  into one persistent splat, which carries:
//
//    mean + covariance   where the surface is, and how sure we are
//    opacity             occupancy belief, 0...1
//    lastHit             when a ray last actually touched it
//    visibility          what THIS frame's rays say about it:
//                          .hit        measured right now
//                          .occluded   the ray stopped in front of it → hidden
//                          .carved     the ray went straight through → not there
//                          .outOfView  / .noData
//    dynamic             it was born in space that was empty a moment ago
//
//  This gives the rest of the app three things a per-frame detector cannot:
//
//  1. MEMORY. A wall that leaves the camera's view is still in the map.
//  2. "HIDDEN" vs "GONE". Ray tests against the splats tell us whether
//     something we can't see is behind an occluder or has actually left. That
//     is the requirement "distinguish observed from uncertain information",
//     answered with evidence instead of a timeout.
//  3. MOVING vs STATIC, without a neural network: a splat appearing in voxels
//     that the sensor saw straight through 0.2 s earlier is something moving.
//
//  Cost: a 32×24 grid (768 samples) per frame, a few thousand splats, one
//  projection per splat. Well under a millisecond of arithmetic.
//

import Foundation
import simd

struct VoxelKey: Hashable {
    var x: Int32, y: Int32, z: Int32

    init(x: Int32, y: Int32, z: Int32) { self.x = x; self.y = y; self.z = z }

    init(_ p: SIMD3<Float>) {
        let s = Tuning.voxelSize
        x = Int32((p.x / s).rounded(.down))
        y = Int32((p.y / s).rounded(.down))
        z = Int32((p.z / s).rounded(.down))
    }
}

enum SplatVisibility: UInt8 {
    case hit, occluded, carved, outOfView, noData
}

struct Splat {
    var mean: SIMD3<Float>
    var cov: simd_float3x3
    var evidence: Float
    var opacity: Float
    var born: TimeInterval
    var lastHit: TimeInterval
    var visibility: SplatVisibility
    var dynamic: Bool

    /// Isotropic 1-sigma, metres.
    var sigma: Float { sqrt(max(1e-6, trace(cov) / 3)) }
}

final class GaussianSplatMap {

    private(set) var splats: [VoxelKey: Splat] = [:]
    /// World-space height of the walking surface.
    private(set) var floorY: Float?
    /// Last ~0.6 s of frames, for "was this space empty a moment ago?".
    private var history: [DepthFrame] = []
    private var frameCount = 0

    struct Stats {
        var births = 0
        var dynamicBirths = 0
        var carved = 0
    }

    // MARK: - Integration

    @discardableResult
    func integrate(_ frame: DepthFrame) -> Stats {
        var stats = Stats()
        let now = frame.timestamp
        let camPos = frame.cameraPosition

        // ---- 1. Turn every usable sample into a measurement Gaussian and
        //         bucket them by voxel. One fused update per voxel per frame.
        struct Bucket {
            var sum = SIMD3<Float>.zero
            var outer = simd_float3x3()
            var noise = simd_float3x3()
            var n: Float = 0
        }
        var buckets: [VoxelKey: Bucket] = [:]
        buckets.reserveCapacity(512)
        var heights: [Float] = []
        heights.reserveCapacity(frame.depth.count)

        for row in 0..<frame.rows {
            for col in 0..<frame.columns {
                let i = row * frame.columns + col
                guard frame.isUsable(i) else { continue }
                let d = frame.depth[i]
                let p = frame.worldPoint(col: col, row: row, depth: d)
                heights.append(p.y)

                // Sensor footprint: thin along the ray, half a grid cell wide
                // across it. This is the "splat" of one depth sample.
                let ray = simd_normalize(p - camPos)
                let sAxial = DepthFrame.sensorSigma(depth: d)
                let sLateral = 0.5 * d / frame.fx
                let lat2 = sLateral * sLateral
                let noise = matrix_identity_float3x3 * lat2 + outer(ray, ray) * (sAxial * sAxial - lat2)

                let key = VoxelKey(p)
                var b = buckets[key] ?? Bucket()
                b.sum += p
                b.outer += outer(p, p)
                b.noise += noise
                b.n += 1
                buckets[key] = b
            }
        }

        updateFloor(heights: heights, cameraY: camPos.y)
        // A reference frame only counts if the camera could actually see
        // then (not while the lens was covered).
        let reference = referenceFrame(now: now).flatMap { $0.coverage > 0.25 ? $0 : nil }

        // ---- 2. Fuse into the persistent map.
        for (key, b) in buckets {
            let inv = 1 / b.n
            let m = b.sum * inv
            // Scatter of the samples inside the voxel + mean sensor noise.
            let measurementCov = (b.outer * inv - outer(m, m)) + b.noise * inv

            if var s = splats[key] {
                // Exponentially-weighted Gaussian fusion. Capping the evidence
                // keeps the splat able to follow a surface that moves.
                let w = min(s.evidence + 1, Tuning.maxSplatEvidence)
                let a = 1 / w
                let delta = m - s.mean
                s.mean += delta * a
                s.cov = (s.cov + outer(delta, delta) * a) * (1 - a) + measurementCov * a
                s.evidence = w
                s.opacity += (1 - s.opacity) * Tuning.opacityGain
                s.lastHit = now
                s.visibility = .hit
                // Something that has sat in the same voxel for 3 s has stopped.
                if s.dynamic && now - s.born > 3 { s.dynamic = false }
                splats[key] = s
            } else {
                let dynamic = reference.map { wasEmpty(m, in: $0) } ?? false
                splats[key] = Splat(mean: m, cov: measurementCov, evidence: 1,
                                    opacity: Tuning.initialOpacity, born: now,
                                    lastHit: now, visibility: .hit, dynamic: dynamic)
                stats.births += 1
                if dynamic { stats.dynamicBirths += 1 }
            }
        }

        // ---- 3. Ray-test every splat that was NOT hit this frame.
        //         This is where "hidden" and "gone" get told apart.
        var idx = splats.startIndex
        while idx != splats.endIndex {
            var s = splats.values[idx]
            if s.lastHit != now {
                let vis = visibility(of: s.mean, sigma: s.sigma, in: frame)
                s.visibility = vis
                switch vis {
                case .carved:
                    s.opacity *= Tuning.carveFactor
                    stats.carved += 1
                case .hit:
                    // A surface at exactly the depth we expected: consistent,
                    // just sampled into a neighbouring voxel. Keep it fresh.
                    s.lastHit = now
                    s.opacity += (1 - s.opacity) * 0.1
                default:
                    break
                }
                splats.values[idx] = s
            }
            idx = splats.index(after: idx)
        }

        // ---- 4. Forget what is no longer believable.
        frameCount += 1
        if frameCount % 10 == 0 { prune(now: now, cameraPosition: camPos) }

        history.append(frame)
        history.removeAll { now - $0.timestamp > 0.6 }
        return stats
    }

    // MARK: - Ray test

    /// What the current depth frame says about a world point:
    /// measured, hidden behind something nearer, seen straight through, or
    /// not observed at all.
    func visibility(of p: SIMD3<Float>, sigma: Float, in frame: DepthFrame) -> SplatVisibility {
        let pc = frame.cameraPoint(p)
        guard let i = frame.gridCell(cameraPoint: pc) else { return .outOfView }
        let z = -pc.z
        guard z < Tuning.maxUsefulDepth else { return .noData }
        guard frame.isUsable(i) else { return .noData }
        let d = frame.depth[i]
        let margin = 0.1 + 2.5 * sigma + 2 * DepthFrame.sensorSigma(depth: z)
        if d > z + margin { return .carved }
        if d < z - margin { return .occluded }
        return .hit
    }

    /// True if the reference frame's ray through `p` went clearly past it:
    /// the space was empty a moment ago, so whatever is there now arrived.
    /// Edge flicker of static objects can trip this for single splats; the
    /// detector only calls an object "moving" when a large share of its
    /// splats agree, and the tracker smooths that over time.
    private func wasEmpty(_ p: SIMD3<Float>, in frame: DepthFrame) -> Bool {
        let pc = frame.cameraPoint(p)
        guard let i = frame.gridCell(cameraPoint: pc) else { return false }
        let z = -pc.z
        let d = frame.depth[i]
        if frame.isUsable(i) {
            return d > z + 0.3 + 2 * DepthFrame.sensorSigma(depth: z)
        }
        // No return at all along that ray (open street, sky): nothing was
        // within sensor range there, so a close point now is new — as long
        // as the point is well inside the range the sensor measures reliably.
        return z < Tuning.maxUsefulDepth - 1 && (d == 0 || d > z + 0.3)
    }

    private func referenceFrame(now: TimeInterval) -> DepthFrame? {
        history.last { now - $0.timestamp >= Tuning.dynamicReferenceAge }
    }

    // MARK: - Floor

    private func updateFloor(heights: [Float], cameraY: Float) {
        guard heights.count > 30 else { return }
        let sorted = heights.sorted()
        let p8 = sorted[Int(Float(sorted.count) * 0.08)]
        guard p8 < cameraY - 0.3, p8 > cameraY - 2.5 else { return }
        if let f = floorY {
            floorY = f * 0.95 + p8 * 0.05
        } else {
            floorY = p8
        }
    }

    func floorHeight(near cameraY: Float) -> Float { floorY ?? (cameraY - 1.4) }

    // MARK: - Maintenance

    private func prune(now: TimeInterval, cameraPosition c: SIMD3<Float>) {
        splats = splats.filter { _, s in
            guard s.opacity >= Tuning.pruneOpacity else { return false }
            guard now - s.lastHit < Tuning.splatMemory else { return false }
            let dx = s.mean.x - c.x, dz = s.mean.z - c.z
            return dx * dx + dz * dz < 81   // 9 m
        }
        if splats.count > Tuning.maxSplats {
            let keep = splats.sorted { $0.value.lastHit > $1.value.lastHit }.prefix(Tuning.maxSplats)
            splats = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    func reset() {
        splats.removeAll()
        history.removeAll()
        floorY = nil
        frameCount = 0
    }
}
