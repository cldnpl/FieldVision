//
//  ARKitDepthAdapter.swift
//  FieldVision
//
//  ARFrame (LiDAR) → DepthFrame. Samples the 256×192 depth map on a 32×24
//  grid and converts ARKit's confidence levels to 0...1.
//
//  Called on the ARSession's delegate queue; copies what it needs and lets the
//  ARFrame go immediately (ARKit stalls if frames are retained).
//

import ARKit
import simd

enum ARKitDepthAdapter {

    static func makeFrame(from frame: ARFrame) -> DepthFrame? {
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return nil }
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let c = confidenceMap { CVPixelBufferLockBaseAddress(c, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let c = confidenceMap { CVPixelBufferUnlockBaseAddress(c, .readOnly) }
        }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthStride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let depthPtr = base.assumingMemoryBound(to: Float32.self)

        var confPtr: UnsafeMutablePointer<UInt8>?
        var confStride = 0
        if let c = confidenceMap, let cb = CVPixelBufferGetBaseAddress(c) {
            confPtr = cb.assumingMemoryBound(to: UInt8.self)
            confStride = CVPixelBufferGetBytesPerRow(c)
        }

        let cols = Tuning.gridColumns, rows = Tuning.gridRows
        var depth = [Float](repeating: 0, count: cols * rows)
        var confidence = [Float](repeating: 0, count: cols * rows)

        for r in 0..<rows {
            let v = min(height - 1, Int((Float(r) + 0.5) / Float(rows) * Float(height)))
            for c in 0..<cols {
                let u = min(width - 1, Int((Float(c) + 0.5) / Float(cols) * Float(width)))
                let i = r * cols + c
                let d = depthPtr[v * depthStride + u]
                depth[i] = d.isFinite ? d : 0
                if let cp = confPtr {
                    switch cp[v * confStride + u] {
                    case 2:  confidence[i] = 1.0    // high
                    case 1:  confidence[i] = 0.6    // medium
                    default: confidence[i] = 0.0    // low: rejected
                    }
                } else {
                    confidence[i] = 1
                }
            }
        }

        // Intrinsics are given for the captured image; rescale to grid units.
        let res = frame.camera.imageResolution
        let K = frame.camera.intrinsics
        let sx = Float(cols) / Float(res.width)
        let sy = Float(rows) / Float(res.height)

        let tracking: SensorTracking
        switch frame.camera.trackingState {
        case .normal: tracking = .normal
        case .notAvailable: tracking = .notAvailable
        case .limited(let reason):
            switch reason {
            case .initializing:         tracking = .limited(reason: "Starting up")
            case .relocalizing:         tracking = .limited(reason: "Re-orienting")
            case .excessiveMotion:      tracking = .limited(reason: "The phone is moving too fast")
            case .insufficientFeatures: tracking = .limited(reason: "Not enough detail to track")
            @unknown default:           tracking = .limited(reason: "Reduced tracking")
            }
        }

        // ambientIntensity: ~1000 lumen is a well-lit room, < 100 is dark.
        let brightness = frame.lightEstimate.map { Float(min(1, $0.ambientIntensity / 1000)) }

        return DepthFrame(timestamp: frame.timestamp,
                          cameraToWorld: frame.camera.transform,
                          columns: cols, rows: rows,
                          fx: K[0][0] * sx, fy: K[1][1] * sy,
                          cx: K[2][0] * sx, cy: K[2][1] * sy,
                          depth: depth, confidence: confidence,
                          tracking: tracking, brightness: brightness)
    }
}
