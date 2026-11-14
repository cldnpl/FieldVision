//
//  DepthFrame.swift
//  FieldVision
//
//  The one input format of the perception pipeline. ARKit's LiDAR frames and
//  the built-in simulated scene are both converted into this, so everything
//  downstream (splat map, renderer, tracker, trust score) runs identically on
//  a phone and in the Simulator.
//

import Foundation
import simd

enum SensorTracking: Equatable {
    case normal
    case limited(reason: String)
    case notAvailable
}

struct DepthFrame {
    var timestamp: TimeInterval
    /// Camera → world. Camera space follows ARKit: +X right, +Y up, −Z forward
    /// in the sensor's native (landscape) orientation.
    var cameraToWorld: simd_float4x4
    let worldToCamera: simd_float4x4

    var columns: Int
    var rows: Int
    /// Pinhole intrinsics in GRID units (one unit = one grid cell).
    var fx: Float, fy: Float, cx: Float, cy: Float

    /// Depth along the camera's −Z axis in metres, row-major. 0 = no return.
    var depth: [Float]
    /// 0...1 per sample. Below 0.5 the sample is ignored.
    var confidence: [Float]

    var tracking: SensorTracking
    /// 0 (black) ... 1 (well lit), if known.
    var brightness: Float?

    init(timestamp: TimeInterval, cameraToWorld: simd_float4x4,
         columns: Int, rows: Int,
         fx: Float, fy: Float, cx: Float, cy: Float,
         depth: [Float], confidence: [Float],
         tracking: SensorTracking, brightness: Float?) {
        self.timestamp = timestamp
        self.cameraToWorld = cameraToWorld
        self.worldToCamera = cameraToWorld.inverse
        self.columns = columns
        self.rows = rows
        self.fx = fx; self.fy = fy; self.cx = cx; self.cy = cy
        self.depth = depth
        self.confidence = confidence
        self.tracking = tracking
        self.brightness = brightness
    }

    var cameraPosition: SIMD3<Float> {
        SIMD3(cameraToWorld.columns.3.x, cameraToWorld.columns.3.y, cameraToWorld.columns.3.z)
    }

    /// Camera-space ray through the centre of a grid cell, scaled so z = −1.
    /// Multiply by the depth to get the 3D point.
    @inline(__always)
    func rayCamera(col: Int, row: Int) -> SIMD3<Float> {
        SIMD3((Float(col) + 0.5 - cx) / fx, -((Float(row) + 0.5) - cy) / fy, -1)
    }

    @inline(__always)
    func isUsable(_ i: Int) -> Bool {
        confidence[i] >= 0.5 && depth[i] > Tuning.minUsefulDepth && depth[i] < Tuning.maxUsefulDepth
    }

    /// Grid cell a camera-space point projects into, or nil if behind the
    /// camera or outside the field of view.
    @inline(__always)
    func gridCell(cameraPoint p: SIMD3<Float>) -> Int? {
        guard p.z < -0.05 else { return nil }
        let z = -p.z
        let u = fx * p.x / z + cx
        let v = -fy * p.y / z + cy
        guard u >= 0, v >= 0 else { return nil }
        let c = Int(u), r = Int(v)
        guard c < columns, r < rows else { return nil }
        return r * columns + c
    }

    @inline(__always)
    func cameraPoint(_ world: SIMD3<Float>) -> SIMD3<Float> {
        let p = worldToCamera * SIMD4<Float>(world, 1)
        return SIMD3(p.x, p.y, p.z)
    }

    func worldPoint(col: Int, row: Int, depth d: Float) -> SIMD3<Float> {
        let c = rayCamera(col: col, row: row) * d
        let w = cameraToWorld * SIMD4<Float>(c, 1)
        return SIMD3(w.x, w.y, w.z)
    }

    func worldDirection(col: Int, row: Int) -> SIMD3<Float> {
        let c = rayCamera(col: col, row: row)
        let w = cameraToWorld * SIMD4<Float>(c, 0)
        return SIMD3(w.x, w.y, w.z)
    }

    var coverage: Float {
        var n = 0
        for i in 0..<depth.count where isUsable(i) { n += 1 }
        return Float(n) / Float(max(1, depth.count))
    }

    @inline(__always)
    static func sensorSigma(depth d: Float) -> Float {
        Tuning.lidarNoiseBase + Tuning.lidarNoiseQuadratic * d * d
    }
}

/// Outer product a·bᵀ.
@inline(__always)
func outer(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> simd_float3x3 {
    simd_float3x3(columns: (a * b.x, a * b.y, a * b.z))
}

@inline(__always)
func trace(_ m: simd_float3x3) -> Float {
    m.columns.0.x + m.columns.1.y + m.columns.2.z
}
