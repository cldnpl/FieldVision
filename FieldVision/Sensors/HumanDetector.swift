//
//  HumanDetector.swift
//  FieldVision
//
//  The semantic layer, deliberately small: Apple's on-device person detector
//  at ~3 Hz on the camera image. Its only job is to upgrade a splat track from
//  "something moving" to "person". Geometry keeps running at frame rate; if
//  this fails (bad light, odd pose) the obstacle is still reported — just
//  without the word "person".
//

import Foundation
import Vision
import CoreVideo
import simd

final class HumanDetector {

    private let visionQueue = DispatchQueue(label: "fieldvision.vision", qos: .userInitiated)
    /// Accessed only from the perception queue.
    private var busy = false
    private var lastRun: TimeInterval = 0
    private(set) var latest: HumanObservation?

    /// Call from the perception queue. Results are delivered back on it.
    func submit(pixelBuffer: CVPixelBuffer,
                cameraToWorld: simd_float4x4,
                intrinsics K: simd_float3x3,
                imageSize: CGSize,
                timestamp: TimeInterval,
                resultQueue: DispatchQueue) {
        guard !busy, timestamp - lastRun > 0.33 else { return }
        busy = true
        lastRun = timestamp
        let worldToCamera = cameraToWorld.inverse

        visionQueue.async { [weak self] in
            let request = VNDetectHumanRectanglesRequest()
            request.upperBodyOnly = false
            // The app is used in portrait: the raw sensor image must be rotated
            // 90° clockwise to be upright, which is EXIF orientation .right.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            try? handler.perform([request])
            let boxes: [CGRect] = (request.results ?? []).filter { $0.confidence > 0.5 }.map {
                Self.rawBox(fromUpright: $0.boundingBox)
            }
            let obs = HumanObservation(timestamp: timestamp, worldToCamera: worldToCamera,
                                       fx: K[0][0], fy: K[1][1], cx: K[2][0], cy: K[2][1],
                                       width: Float(imageSize.width), height: Float(imageSize.height),
                                       boxes: boxes)
            resultQueue.async {
                self?.latest = obs
                self?.busy = false
            }
        }
    }

    /// Vision box in the upright (portrait) image, origin bottom-left →
    /// box in the raw sensor image, origin top-left. With a 90° clockwise
    /// rotation, raw (rx, ry) maps to upright (1 − ry, rx), hence the inverse
    /// rx = 1 − vy, ry = 1 − vx (vy measured from the bottom).
    static func rawBox(fromUpright b: CGRect) -> CGRect {
        CGRect(x: 1 - b.maxY, y: 1 - b.maxX, width: b.height, height: b.width)
    }

    func reset() {
        latest = nil
        lastRun = 0
    }
}
