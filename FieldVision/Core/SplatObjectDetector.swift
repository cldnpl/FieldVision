//
//  SplatObjectDetector.swift
//  FieldVision
//
//  Groups the splats measured THIS frame into objects, and describes each
//  object as one Gaussian (a mixture of its splats collapsed to mean +
//  covariance) plus a few shape facts.
//
//  Only fresh splats are grouped: detections are measurements, and memory is
//  the tracker's job. Splats are joined across neighbouring voxels (26-
//  neighbourhood); a moving splat and a static one are joined only when they
//  practically touch, so a person walking past a wall is not swallowed by it.
//
//  The shape of the merged Gaussian is enough to tell apart the hazards that
//  matter for someone walking with a cane:
//
//    top below 70 cm above the floor            → low obstacle (trip hazard)
//    bottom above 1.2 m                         → head-height obstacle
//                                                  (the one a cane misses)
//    long and thin, taller than 0.9 m           → wall
//    mostly born in previously-empty space      → something moving
//

import Foundation
import simd

struct SplatDetection {
    var mean: SIMD3<Float>
    var cov: simd_float3x3
    var nearestPoint: SIMD3<Float>
    var splatCount: Int
    var heightMin: Float
    var heightMax: Float
    var dynamicFraction: Float
    var kind: ObstacleKind
}

final class SplatObjectDetector {

    private static let neighbours: [(Int32, Int32, Int32)] = {
        var n: [(Int32, Int32, Int32)] = []
        for dx in -1...1 { for dy in -1...1 { for dz in -1...1 where !(dx == 0 && dy == 0 && dz == 0) {
            n.append((Int32(dx), Int32(dy), Int32(dz)))
        } } }
        return n
    }()

    func detect(map: GaussianSplatMap, now: TimeInterval, body: BodyFrame) -> [SplatDetection] {
        let floor = map.floorHeight(near: body.origin.y)

        var eligible: [VoxelKey: Splat] = [:]
        for (k, s) in map.splats where s.lastHit == now && s.opacity > 0.3 {
            let h = s.mean.y - floor
            guard h > Tuning.floorTolerance, h < Tuning.maxObstacleHeight else { continue }
            let l = body.local(s.mean)
            guard l.x * l.x + l.z * l.z < Tuning.maxUsefulDepth * Tuning.maxUsefulDepth else { continue }
            eligible[k] = s
        }

        var visited = Set<VoxelKey>()
        var detections: [SplatDetection] = []

        for seed in eligible.keys where !visited.contains(seed) {
            var stack = [seed]
            var members: [Splat] = []
            var memberKeys: [VoxelKey] = []
            visited.insert(seed)
            while let k = stack.popLast() {
                guard let s = eligible[k] else { continue }
                members.append(s)
                memberKeys.append(k)
                for (dx, dy, dz) in Self.neighbours {
                    let nk = VoxelKey(x: k.x + dx, y: k.y + dy, z: k.z + dz)
                    guard !visited.contains(nk), let ns = eligible[nk] else { continue }
                    // Same motion class: join any neighbour. Different class
                    // (a person next to a wall): join only if really touching.
                    if ns.dynamic != s.dynamic && simd_distance(ns.mean, s.mean) > 0.15 { continue }
                    visited.insert(nk)
                    stack.append(nk)
                }
            }
            guard members.count >= Tuning.minClusterSplats else { continue }
            var det = merge(members, floor: floor, body: body)
            if det.kind == .headHeight && hasStructureBelow(memberKeys, map: map) {
                // The top of something taller whose lower part is hidden right
                // now (e.g. a wall behind a person). The map still remembers
                // the lower part, so this is not a free-hanging hazard.
                det.kind = det.heightMax - det.heightMin > 0.3 ? .large : .obstacle
            }
            detections.append(det)
        }
        return detections
    }

    /// True if the map holds solid splats (remembered, not necessarily seen
    /// now) up to 40 cm directly below a good share of these voxels. A real
    /// head-height hazard — a sign, a branch — has free space under it.
    private func hasStructureBelow(_ keys: [VoxelKey], map: GaussianSplatMap) -> Bool {
        let members = Set(keys)
        var supported = 0
        for k in keys {
            for dy: Int32 in 1...2 {
                let below = VoxelKey(x: k.x, y: k.y - dy, z: k.z)
                if !members.contains(below), let s = map.splats[below], s.opacity > 0.3 {
                    supported += 1
                    break
                }
            }
        }
        return Float(supported) > 0.3 * Float(keys.count)
    }

    /// Collapse a mixture of Gaussians into one:
    ///   μ = Σ wᵢ μᵢ / Σ w
    ///   Σ = Σ wᵢ (Σᵢ + (μᵢ − μ)(μᵢ − μ)ᵀ) / Σ w
    private func merge(_ members: [Splat], floor: Float, body: BodyFrame) -> SplatDetection {
        var wSum: Float = 0
        var mean = SIMD3<Float>.zero
        for s in members { wSum += s.opacity; mean += s.mean * s.opacity }
        mean /= wSum

        var cov = simd_float3x3()
        var nearest = members[0].mean
        var nearestRange = Float.infinity
        var hMin = Float.infinity, hMax = -Float.infinity
        var rMin = Float.infinity, rMax = -Float.infinity
        var fMin = Float.infinity, fMax = -Float.infinity
        var dynamic = 0

        for s in members {
            let d = s.mean - mean
            cov += (s.cov + outer(d, d)) * s.opacity
            let l = body.local(s.mean)
            let range = sqrt(l.x * l.x + l.z * l.z)
            if range < nearestRange { nearestRange = range; nearest = s.mean }
            let h = s.mean.y - floor
            hMin = min(hMin, h); hMax = max(hMax, h)
            rMin = min(rMin, l.x); rMax = max(rMax, l.x)
            fMin = min(fMin, l.z); fMax = max(fMax, l.z)
            if s.dynamic { dynamic += 1 }
        }
        cov = cov * (1 / wSum)

        // Splat centres sit inside their voxel; pad extents by one voxel.
        let pad = Tuning.voxelSize * 0.5
        hMin -= pad; hMax += pad
        let width = (rMax - rMin) + 2 * pad
        let depth = (fMax - fMin) + 2 * pad
        let dynFrac = Float(dynamic) / Float(members.count)

        let kind: ObstacleKind
        if hMax < 0.7 {
            kind = .lowObstacle
        } else if hMin > 1.2 {
            kind = .headHeight
        } else if dynFrac > 0.4 {
            kind = .moving
        } else if max(width, depth) > 1.8 && min(width, depth) < 0.7 && hMax - hMin > 0.9 {
            kind = .wall
        } else if max(width, depth) > 1.2 {
            kind = .large
        } else {
            kind = .obstacle
        }

        return SplatDetection(mean: mean, cov: cov, nearestPoint: nearest,
                              splatCount: members.count,
                              heightMin: max(0, hMin), heightMax: hMax,
                              dynamicFraction: dynFrac, kind: kind)
    }
}
