//
//  SimulatedScene.swift
//  FieldVision
//
//  A scripted street scene, ray-cast into the same DepthFrame format the
//  LiDAR produces, so the whole pipeline can be demonstrated in the Simulator,
//  on a phone without LiDAR, or as a backup if the live demo misbehaves.
//
//  The 30-second loop exercises every requirement of the brief:
//
//    0–8.5 s  a person crosses left → right and passes BEHIND a column
//             (occlusion: the track must survive as "hidden")
//    8.5–15 s the person turns and walks towards the user on the right
//             (moving element, approaching)
//    15–18 s  the lens is covered (trust collapses → "Guidance paused")
//    18–21 s  uncovered; the system waits before claiming recovery
//    21–30 s  the user turns left to look at a parked van and a low bin,
//             then back (static obstacles, memory of what left the view)
//
//  World: y up, user's chest-mounted phone at y = 0, floor at y = −1.4.
//

import Foundation
import simd

struct SimulatedScene {

    static let loop: Double = 30

    private enum Shape {
        case box(min: SIMD3<Float>, max: SIMD3<Float>)
        case cylinder(center: SIMD2<Float>, radius: Float, y0: Float, y1: Float)
    }

    private let floorY: Float = -1.4
    private let statics: [Shape] = [
        // Building wall on the right.
        .box(min: SIMD3(1.7, -1.4, -14), max: SIMD3(1.9, 1.6, 2)),
        // Wide column — the occluder.
        .box(min: SIMD3(-0.1, -1.4, -2.4), max: SIMD3(0.5, 1.6, -2.0)),
        // Parked van on the left.
        .box(min: SIMD3(-2.7, -1.4, -6.0), max: SIMD3(-1.4, 0.4, -3.4)),
        // Low bin: a trip hazard.
        .cylinder(center: SIMD2(-0.75, -1.6), radius: 0.22, y0: -1.4, y1: -0.85),
        // Shop sign at head height.
        .box(min: SIMD3(-0.9, 0.25, -4.7), max: SIMD3(0.0, 0.5, -4.5)),
    ]

    // Camera: 64° × 50° field of view on the 32×24 grid.
    private let cols = Tuning.gridColumns
    private let rows = Tuning.gridRows
    private var fx: Float { Float(cols) / 2 / tan(32 * .pi / 180) }
    private var fy: Float { Float(rows) / 2 / tan(25 * .pi / 180) }
    private var cx: Float { Float(cols) / 2 }
    private var cy: Float { Float(rows) / 2 }

    private var rng = SystemRandomNumberGenerator()

    // MARK: - Script

    struct Pose {
        var position: SIMD3<Float>
        var yaw: Float       // + = turned left
        var pitch: Float     // − = looking down
    }

    func cameraPose(at t: Double) -> Pose {
        let tt = Float(t.truncatingRemainder(dividingBy: Self.loop))
        var yaw: Float = 0.05 * sin(tt * 0.9)           // breathing sway
        if tt > 21 && tt < 30 {
            // Turn left ~40°, hold, come back.
            let k = (tt - 21) / 9
            yaw += 0.7 * sin(k * .pi)
        }
        let bob = 0.012 * sin(tt * 2 * .pi * 1.8)
        return Pose(position: SIMD3(0, bob, 0), yaw: yaw, pitch: -0.22)
    }

    func personPosition(at t: Double) -> SIMD2<Float>? {
        let tt = Float(t.truncatingRemainder(dividingBy: Self.loop))
        switch tt {
        case ..<8.5:
            return SIMD2(-2.0 + 3.05 * tt / 8.5, -3.0)          // crossing, behind the column ~6.3–7.6 s
        case ..<13.5:
            let k = (tt - 8.5) / 5
            return SIMD2(1.05, -3.0 + 1.7 * k)                    // approaching on the right
        case ..<18:
            return SIMD2(1.05, -1.3)                              // standing
        case ..<24:
            let k = (tt - 18) / 6
            return SIMD2(1.05, -1.3 - 3.7 * k)                    // walking away
        default:
            return nil
        }
    }

    /// What the demo is showing right now, for the on-screen caption.
    static func caption(at t: Double) -> String {
        switch t {
        case ..<8.5: return "A person crosses and passes behind a column"
        case ..<15:  return "The person turns and approaches on the right"
        case ..<18: return "The lens is covered"
        case ..<21: return "Lens uncovered: waiting before trusting again"
        default:    return "The user turns left: van, low bin, sign at head height"
        }
    }

    func lensCovered(at t: Double) -> Bool {
        let tt = t.truncatingRemainder(dividingBy: Self.loop)
        return tt >= 15 && tt < 18
    }

    // MARK: - Frame generation

    mutating func frame(at t: Double, timestamp: TimeInterval) -> DepthFrame {
        let pose = cameraPose(at: t)
        let m = Self.transform(pose)
        let covered = lensCovered(at: t)
        let person = personPosition(at: t)

        var depth = [Float](repeating: 0, count: cols * rows)
        var conf = [Float](repeating: 0, count: cols * rows)

        if !covered {
            let origin = pose.position
            for r in 0..<rows {
                for c in 0..<cols {
                    let rc = SIMD3<Float>((Float(c) + 0.5 - cx) / fx, -((Float(r) + 0.5) - cy) / fy, -1)
                    let w = m * SIMD4<Float>(rc, 0)
                    let dir = SIMD3(w.x, w.y, w.z)
                    guard let hit = cast(origin: origin, dir: dir, person: person) else { continue }
                    let i = r * cols + c
                    let sigma = DepthFrame.sensorSigma(depth: min(hit.t, 6))
                    depth[i] = min(hit.t, 8) + gaussian() * sigma
                    // Like ARKit: far returns and random dropouts come back
                    // as low-confidence values, not as "nothing".
                    if hit.t >= Tuning.maxUsefulDepth || Double.random(in: 0..<1, using: &rng) < 0.02 {
                        conf[i] = 0
                    } else {
                        conf[i] = hit.t < 3.5 ? 1 : 0.6
                    }
                }
            }
        }

        return DepthFrame(timestamp: timestamp, cameraToWorld: m,
                          columns: cols, rows: rows, fx: fx, fy: fy, cx: cx, cy: cy,
                          depth: depth, confidence: conf,
                          tracking: covered ? .limited(reason: "Not enough detail to track") : .normal,
                          brightness: covered ? 0.02 : 0.6)
    }

    /// What a person detector would report: the person's box in the (virtual)
    /// raw image, only when the person is actually visible.
    func humanObservation(at t: Double, timestamp: TimeInterval) -> HumanObservation? {
        guard !lensCovered(at: t), let p = personPosition(at: t) else { return nil }
        let pose = cameraPose(at: t)
        let m = Self.transform(pose)
        let w2c = m.inverse

        // Visible only if the ray to the person's chest hits the person first.
        let chest = SIMD3<Float>(p.x, -0.5, p.y)
        let dir = chest - pose.position
        let rc = w2c * SIMD4<Float>(dir, 0)
        guard rc.z < 0 else { return nil }
        let scaled = dir / -rc.z
        guard let hit = cast(origin: pose.position, dir: scaled, person: p), hit.isPerson else { return nil }

        var minU = Float.infinity, maxU = -Float.infinity, minV = Float.infinity, maxV = -Float.infinity
        for y in [floorY, floorY + 1.75] {
            for dx in [-0.22, 0.22] as [Float] {
                for dz in [-0.22, 0.22] as [Float] {
                    let q = w2c * SIMD4<Float>(p.x + dx, y, p.y + dz, 1)
                    guard q.z < -0.05 else { continue }
                    let u = (fx * q.x / -q.z + cx) / Float(cols)
                    let v = (-fy * q.y / -q.z + cy) / Float(rows)
                    minU = min(minU, u); maxU = max(maxU, u)
                    minV = min(minV, v); maxV = max(maxV, v)
                }
            }
        }
        guard minU.isFinite else { return nil }
        let box = CGRect(x: CGFloat(minU), y: CGFloat(minV),
                         width: CGFloat(maxU - minU), height: CGFloat(maxV - minV))
        return HumanObservation(timestamp: timestamp, worldToCamera: w2c,
                                fx: fx, fy: fy, cx: cx, cy: cy,
                                width: Float(cols), height: Float(rows), boxes: [box])
    }

    // MARK: - Ray casting

    private func cast(origin o: SIMD3<Float>, dir d: SIMD3<Float>,
                      person: SIMD2<Float>?) -> (t: Float, isPerson: Bool)? {
        var best = Float.infinity
        var isPerson = false

        if d.y < -1e-4 {
            let t = (floorY - o.y) / d.y
            if t > 0 { best = t }
        }
        for s in statics {
            if let t = intersect(s, o, d), t < best { best = t }
        }
        if let p = person,
           let t = intersect(.cylinder(center: p, radius: 0.22, y0: floorY, y1: floorY + 1.75), o, d),
           t < best {
            best = t
            isPerson = true
        }
        return best.isFinite ? (best, isPerson) : nil
    }

    private func intersect(_ s: Shape, _ o: SIMD3<Float>, _ d: SIMD3<Float>) -> Float? {
        switch s {
        case .box(let lo, let hi):
            var tmin: Float = 0, tmax = Float.infinity
            for a in 0..<3 {
                if abs(d[a]) < 1e-6 {
                    if o[a] < lo[a] || o[a] > hi[a] { return nil }
                } else {
                    var t1 = (lo[a] - o[a]) / d[a]
                    var t2 = (hi[a] - o[a]) / d[a]
                    if t1 > t2 { swap(&t1, &t2) }
                    tmin = max(tmin, t1); tmax = min(tmax, t2)
                    if tmin > tmax { return nil }
                }
            }
            return tmin > 0 ? tmin : nil

        case .cylinder(let c, let r, let y0, let y1):
            let ox = o.x - c.x, oz = o.z - c.y
            let a = d.x * d.x + d.z * d.z
            guard a > 1e-8 else { return nil }
            let b = 2 * (ox * d.x + oz * d.z)
            let cc = ox * ox + oz * oz - r * r
            let disc = b * b - 4 * a * cc
            guard disc >= 0 else { return nil }
            let t = (-b - sqrt(disc)) / (2 * a)
            guard t > 0 else { return nil }
            let y = o.y + t * d.y
            return (y >= y0 && y <= y1) ? t : nil
        }
    }

    private mutating func gaussian() -> Float {
        let u1 = max(1e-7, Float.random(in: 0..<1, using: &rng))
        let u2 = Float.random(in: 0..<1, using: &rng)
        return sqrt(-2 * log(u1)) * cos(2 * .pi * u2)
    }

    static func transform(_ p: Pose) -> simd_float4x4 {
        let cy = cos(p.yaw), sy = sin(p.yaw)
        let cp = cos(p.pitch), sp = sin(p.pitch)
        let ry = simd_float4x4(columns: (SIMD4(cy, 0, -sy, 0), SIMD4(0, 1, 0, 0),
                                         SIMD4(sy, 0, cy, 0), SIMD4(0, 0, 0, 1)))
        let rx = simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, cp, sp, 0),
                                         SIMD4(0, -sp, cp, 0), SIMD4(0, 0, 0, 1)))
        var m = ry * rx
        m.columns.3 = SIMD4(p.position, 1)
        return m
    }
}
