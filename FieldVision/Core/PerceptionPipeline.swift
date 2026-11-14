//
//  PerceptionPipeline.swift
//  FieldVision
//
//  One depth frame in, one PerceptionSnapshot out.
//
//      DepthFrame ─▶ GaussianSplatMap.integrate      (fuse + ray-test)
//                 ─▶ SplatCompositor.render          (free space + certainty)
//                 ─▶ SplatObjectDetector.detect      (objects as Gaussians)
//                 ─▶ ObstacleTracker.update          (identity, occlusion)
//                 ─▶ TrustEstimator.evaluate         (is any of this reliable?)
//
//  Not thread-safe by design: the engine calls it from one serial queue.
//

import Foundation
import simd

final class PerceptionPipeline {

    private let map = GaussianSplatMap()
    private let compositor = SplatCompositor()
    private let detector = SplatObjectDetector()
    private let tracker = ObstacleTracker()
    private let trust = TrustEstimator()
    private let performance = PerformanceMonitor()
    private var lastForward: SIMD3<Float>?
    /// Last frame's raw detections, for the debug log only.
    private(set) var lastDetections: [SplatDetection] = []

    func process(_ frame: DepthFrame, humans: HumanObservation?, isDemo: Bool) -> PerceptionSnapshot {
        let body = BodyFrame(cameraToWorld: frame.cameraToWorld, fallbackForward: lastForward)
        lastForward = body.forward

        let (_, fusionMs) = performance.measure { map.integrate(frame) }
        let (rendered, renderMs) = performance.measure {
            compositor.render(map: map, frame: frame, body: body)
        }
        let (detections, detectMs) = performance.measure {
            detector.detect(map: map, now: frame.timestamp, body: body)
        }
        lastDetections = detections
        let (obstacles, trackMs) = performance.measure {
            tracker.update(detections: detections, map: map, frame: frame, body: body, humans: humans)
        }

        let coverage = frame.coverage
        let assessment = trust.evaluate(frame: frame, coverage: coverage, profile: rendered.profile,
                                        body: body, churn: tracker.churnPerSecond)

        performance.record(fusion: fusionMs, render: renderMs, detection: detectMs,
                           tracking: trackMs, frameTimestamp: frame.timestamp)

        var s = PerceptionSnapshot()
        s.obstacles = obstacles
        s.reliability = assessment.reliability
        s.trust = assessment.trust
        s.trustFactors = assessment.factors
        s.depthCoverage = coverage
        s.space = rendered.profile
        s.radarSplats = rendered.radar
        s.splatCount = map.splats.count
        s.cameraHalfFOV = rendered.cameraHalfFOV
        s.timestamp = frame.timestamp
        s.timings = performance.current
        s.isDemo = isDemo
        return s
    }

    func reset() {
        map.reset()
        tracker.reset()
        trust.reset()
        performance.reset()
        lastForward = nil
    }
}
