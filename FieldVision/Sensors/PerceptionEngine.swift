//
//  PerceptionEngine.swift
//  FieldVision
//
//  Owns the sensor (live ARKit LiDAR, or the simulated demo scene), runs the
//  perception pipeline on one serial queue, and publishes a snapshot to the
//  main actor at up to 30 Hz.
//

import ARKit
import Combine
import QuartzCore

@MainActor
final class PerceptionEngine: NSObject, ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case live = "Live camera"
        case demo = "Demo scene"
        var id: String { rawValue }
    }

    @Published private(set) var snapshot = PerceptionSnapshot()
    @Published private(set) var isRunning = false
    @Published var mode: Mode
    /// Seconds into the demo loop, for the on-screen caption.
    @Published private(set) var demoTime: Double = 0

    /// True on LiDAR iPhones / iPads (and never in the Simulator).
    let canRunLive: Bool

    nonisolated private let queue = DispatchQueue(label: "fieldvision.perception", qos: .userInteractive)

    // Touched only on `queue`.
    nonisolated(unsafe) private let pipeline = PerceptionPipeline()
    nonisolated(unsafe) private let humans = HumanDetector()
    nonisolated(unsafe) private var scene = SimulatedScene()
    nonisolated(unsafe) private var demoTimer: DispatchSourceTimer?
    nonisolated(unsafe) private var demoStart: CFTimeInterval = 0
    nonisolated(unsafe) private var simulatedHumans: HumanObservation?
    nonisolated(unsafe) private var lastSimulatedHumans: CFTimeInterval = 0
    nonisolated(unsafe) private var lastPublish: CFTimeInterval = 0
    nonisolated(unsafe) private var lastLog: CFTimeInterval = 0
    /// Launch with `-log` to print a one-line state summary twice a second
    /// (used to check the demo script end to end).
    nonisolated private let logging = ProcessInfo.processInfo.arguments.contains("-log")

    private var session: ARSession?

    override init() {
        canRunLive = ARWorldTrackingConfiguration.isSupported &&
                     ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
        mode = canRunLive ? .live : .demo
        super.init()
    }

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        snapshot = PerceptionSnapshot()
        switch mode {
        case .live where canRunLive: startLive()
        default:
            mode = .demo
            startDemo()
        }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        session?.pause()
        queue.async { [self] in
            demoTimer?.cancel()
            demoTimer = nil
        }
        snapshot = PerceptionSnapshot()
    }

    private func startLive() {
        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            // ARKit's temporally filtered depth: less flicker → less audio jitter.
            config.frameSemantics.insert(.smoothedSceneDepth)
        } else {
            config.frameSemantics.insert(.sceneDepth)
        }
        config.planeDetection = []
        config.environmentTexturing = .none
        config.isLightEstimationEnabled = true

        let s = session ?? ARSession()
        s.delegate = self
        s.delegateQueue = queue
        session = s
        queue.async { [self] in
            pipeline.reset()
            humans.reset()
        }
        s.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    private func startDemo() {
        let start = CACurrentMediaTime()
        queue.async { [self] in
            pipeline.reset()
            scene = SimulatedScene()
            simulatedHumans = nil
            lastSimulatedHumans = 0
            demoStart = start
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: 1.0 / 30)
            timer.setEventHandler { [weak self] in self?.demoTick() }
            timer.resume()
            demoTimer = timer
        }
    }

    // MARK: - Per frame (on `queue`)

    nonisolated private func demoTick() {
        let now = CACurrentMediaTime()
        let t = now - demoStart
        let frame = scene.frame(at: t, timestamp: now)
        if now - lastSimulatedHumans > 0.33 {
            lastSimulatedHumans = now
            simulatedHumans = scene.humanObservation(at: t, timestamp: now)
        }
        let snap = pipeline.process(frame, humans: simulatedHumans, isDemo: true)
        let loopTime = t.truncatingRemainder(dividingBy: SimulatedScene.loop)
        if logging && now - lastLog > 0.5 {
            lastLog = now
            log(snap, t: loopTime)
            let dets = pipeline.lastDetections.map {
                String(format: "%@(%.1f,%.1f n%d d%.2f h%.1f-%.1f)", $0.kind.shortName, $0.mean.x, $0.mean.z,
                       $0.splatCount, $0.dynamicFraction, $0.heightMin, $0.heightMax)
            }.joined(separator: " ")
            print("[FV]        dets: " + dets)
        }
        publish(snap, demoTime: loopTime)
    }

    nonisolated private func log(_ s: PerceptionSnapshot, t: Double) {
        let rel: String
        switch s.reliability {
        case .nominal: rel = "OK"
        case .degraded(let r): rel = "REDUCED(\(r))"
        case .unavailable(let r): rel = "PAUSED(\(r))"
        }
        let tracks = s.obstacles.map { o in
            "\(o.kind.shortName)/\(o.state)/\(o.cause)/\(o.bearing.spokenName)/\(String(format: "%.1f", o.distance))m/\(o.motion.phrase)/sd\(String(format: "%.2f", o.positionStd))"
        }.joined(separator: " | ")
        print(String(format: "[FV] t=%5.1f trust=%.2f %@ corridor=%.1f(c%.2f) splats=%d :: ",
                     t, s.trust, rel, min(9, s.space.corridorClear), s.space.corridorCertainty, s.splatCount) + tracks)
    }

    nonisolated private func publish(_ s: PerceptionSnapshot, demoTime: Double) {
        let now = CACurrentMediaTime()
        guard now - lastPublish >= 1.0 / 30 - 0.003 else { return }
        lastPublish = now
        Task { @MainActor [weak self] in
            guard let self, self.isRunning else { return }
            self.snapshot = s
            self.demoTime = demoTime
        }
    }
}

// MARK: - ARSessionDelegate

extension PerceptionEngine: ARSessionDelegate {

    nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let depth = ARKitDepthAdapter.makeFrame(from: frame) else { return }
        humans.submit(pixelBuffer: frame.capturedImage,
                      cameraToWorld: frame.camera.transform,
                      intrinsics: frame.camera.intrinsics,
                      imageSize: frame.camera.imageResolution,
                      timestamp: frame.timestamp,
                      resultQueue: queue)
        let snap = pipeline.process(depth, humans: humans.latest, isDemo: false)
        publish(snap, demoTime: 0)
    }

    nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.snapshot.reliability = .unavailable(reason: "Sensor error")
        }
    }

    nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor [weak self] in
            self?.snapshot.reliability = .unavailable(reason: "Camera interrupted")
        }
    }

    nonisolated func sessionInterruptionEnded(_ session: ARSession) {
        queue.async { [weak self] in self?.pipeline.reset() }
    }
}
