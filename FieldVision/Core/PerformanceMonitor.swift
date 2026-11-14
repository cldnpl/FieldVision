//
//  PerformanceMonitor.swift
//  FieldVision
//
//  "Low latency" and "processing efficiency" are measurable, so measure them.
//  Every stage of the pipeline is timed and the rolling numbers are shown live
//  in the metrics panel — a number on screen while the phone is running is
//  evidence; a number on a slide is a claim.
//
//  Latency budget, sensor → ear:
//
//      LiDAR capture + ARKit fusion        ~16.7 ms  (one frame, fixed)
//      splat fusion + ray tests            target ≤ 3 ms
//      splat rendering (azimuth fan)       target ≤ 1 ms
//      object detection + tracking         target ≤ 1 ms
//      audio buffer scheduling             ~5–11 ms
//      ───────────────────────────────────────────
//      total                               ~25–33 ms
//

import Foundation
import QuartzCore

struct FrameTimings: Equatable {
    var fusion: Double = 0
    var render: Double = 0
    var detection: Double = 0
    var tracking: Double = 0
    var total: Double = 0

    /// Sensor capture → decision, including ARKit's own pipeline.
    var sensorToDecision: Double = 0

    var meanTotal: Double = 0
    /// An average hides the one frame in two hundred that blew the budget —
    /// the frame where someone steps off a kerb. p95 doesn't.
    var p95Total: Double = 0
    var effectiveFPS: Double = 0
    /// Fraction of a 60 Hz frame (16.7 ms) our own code consumes.
    var budgetUsed: Double = 0
}

final class PerformanceMonitor {

    private(set) var current = FrameTimings()
    private var totals: [Double] = []
    private var intervals: [Double] = []
    private var lastWallClock: CFTimeInterval = 0
    private let window = 120

    @inline(__always)
    func measure<T>(_ body: () -> T) -> (value: T, ms: Double) {
        let t0 = CACurrentMediaTime()
        let v = body()
        return (v, (CACurrentMediaTime() - t0) * 1000)
    }

    func record(fusion: Double, render: Double, detection: Double, tracking: Double,
                frameTimestamp: TimeInterval) {
        let now = CACurrentMediaTime()
        current.fusion = fusion
        current.render = render
        current.detection = detection
        current.tracking = tracking
        current.total = fusion + render + detection + tracking
        // ARFrame.timestamp shares CACurrentMediaTime's clock.
        current.sensorToDecision = max(0, (now - frameTimestamp) * 1000)

        append(&totals, current.total)
        if lastWallClock > 0 { append(&intervals, (now - lastWallClock) * 1000) }
        lastWallClock = now

        current.meanTotal = mean(totals)
        current.p95Total = percentile(totals, 0.95)
        current.budgetUsed = min(1, current.meanTotal / 16.67)
        let iv = mean(intervals)
        current.effectiveFPS = iv > 0 ? 1000 / iv : 0
    }

    private func append(_ a: inout [Double], _ v: Double) {
        a.append(v)
        if a.count > window { a.removeFirst(a.count - window) }
    }

    private func mean(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }

    private func percentile(_ a: [Double], _ p: Double) -> Double {
        guard !a.isEmpty else { return 0 }
        let s = a.sorted()
        return s[min(s.count - 1, Int(Double(s.count) * p))]
    }

    func reset() {
        totals.removeAll(); intervals.removeAll()
        lastWallClock = 0
        current = FrameTimings()
    }
}

// MARK: - Why this is fast, written down

/// Not used at runtime. Kept so the reasoning survives the hackathon.
enum DesignNotes {

    static let efficiency = """
    PROCESSING EFFICIENCY

    1. Geometry, not inference, at frame rate. The LiDAR already measures
       depth; we turn it into Gaussian splats with arithmetic. The only neural
       network (Vision's person detector) runs at 3 Hz to attach a label, and
       the system still works — as "something moving" — if it fails.
    2. 768 samples per frame (a 32×24 grid of the 256×192 depth map, 1.6%).
       The ear quantises direction far more coarsely than the sensor does.
    3. 20 cm voxels, one splat each, fused once per frame per voxel. A few
       thousand splats, each needing one projection for its ray test.
    4. The renderer composites a 25-column fan, not a full image.
    5. The camera feed is never drawn. Tone buffers are synthesised once and
       cached.
    """

    static let continuity = """
    PERCEPTUAL CONTINUITY

    a. The splat map remembers static structure that leaves the view.
    b. Kalman tracks keep identity through occlusion; association uses
       Mahalanobis distance, so an uncertain track accepts a wider match.
    c. Everything is anchored in gravity-aligned world space and rendered
       relative to the user's heading, so turning doesn't scramble the scene.
    """

    static let safety = """
    SAFETY OF THE GUIDANCE

    · A direction is stated only while its angular uncertainty is under one
      sector (~15°). Past that: "unresolved", no direction.
    · Hidden vs gone is decided by ray tests on the splat map. If the sensor
      sees straight through where an object should be, it is dropped — no ghosts.
    · A column of space is called "clear" only if the camera is measuring it
      now. Memory can warn; it cannot clear.
    · Trust below 0.30 → guidance paused, said aloud with the reason. Recovery
      needs > 0.45 held for 0.6 s.
    · Below 0.60 the app keeps warning about obstacles but stops giving
      directional advice ("more space on your left").
    · Three consecutive detections before a first sound.
    · A supplement to a cane or a guide dog, never a replacement.
    """
}
