//
//  Models.swift
//  FieldVision
//
//  The vocabulary of the whole app. Everything else speaks in these types.
//
//  The single most important idea here is `TrackState` together with
//  `OcclusionCause`. The challenge asks the system to "distinguish observed
//  information from uncertain information" — so uncertainty is not a flag
//  bolted on at the end, it is part of the type. An obstacle is never just
//  "there". It is there-and-seen, or there-and-remembered (and we know WHY we
//  can't see it), or we-have-lost-it.
//

import Foundation
import simd

// MARK: - Confidence state machine

/// How much we trust what we are saying about an obstacle *right now*.
///
///     .observed  →  .inferred  →  .expiring  →  (dropped)
///         ↑_____________|____________|
///
/// A track climbs back to `.observed` the moment the sensor sees it again.
enum TrackState: Equatable {
    /// The depth sensor is measuring this object in this frame. Full trust.
    case observed
    /// Not measured this frame, but its position uncertainty (Kalman
    /// covariance) is still small enough to state a direction.
    case inferred
    /// Uncertainty has grown past one direction sector. We stop giving a
    /// direction and only warn that something is unresolved.
    case expiring
    /// Dropped. Not reported at all.
    case lost

    var isTrustworthy: Bool { self == .observed }

    /// Multiplier applied to loudness / haptic sharpness.
    var feedbackGain: Float {
        switch self {
        case .observed:  return 1.0
        case .inferred:  return 0.55
        case .expiring:  return 0.3
        case .lost:      return 0.0
        }
    }
}

/// WHY a track is not being measured right now. This comes straight from the
/// Gaussian splat map's ray test, so it is evidence, not a guess:
/// the depth ray towards the predicted position either stopped short
/// (something in front → hidden), went straight through (it is not there any
/// more → vanished), or there was no ray at all (out of view / no data).
enum OcclusionCause: Equatable {
    case none
    case hidden
    case outOfView
    case noData
    case vanished

    var phrase: String? {
        switch self {
        case .none:      return nil
        case .hidden:    return "hidden behind something"
        case .outOfView: return "out of view"
        case .noData:    return "not measurable"
        case .vanished:  return "moved away"
        }
    }
}

/// What kind of thing it is. Derived from the SHAPE of the object's Gaussian
/// (height above the floor, horizontal extent, whether its splats were born
/// in previously empty space) plus an optional low-rate person detector.
enum ObstacleKind: Equatable {
    case person
    case moving
    case wall
    case large
    case lowObstacle
    case headHeight
    case obstacle

    var spokenName: String {
        switch self {
        case .person:      return "person"
        case .moving:      return "something moving"
        case .wall:        return "wall"
        case .large:       return "large obstacle"
        case .lowObstacle: return "low obstacle"
        case .headHeight:  return "head-height obstacle"
        case .obstacle:    return "obstacle"
        }
    }

    var shortName: String {
        switch self {
        case .person:      return "Person"
        case .moving:      return "Moving"
        case .wall:        return "Wall"
        case .large:       return "Large"
        case .lowObstacle: return "Low"
        case .headHeight:  return "Head height"
        case .obstacle:    return "Obstacle"
        }
    }

    var symbol: String {
        switch self {
        case .person:      return "figure.walk"
        case .moving:      return "arrow.left.and.right"
        case .wall:        return "rectangle.portrait"
        case .large:       return "shippingbox"
        case .lowObstacle: return "exclamationmark.triangle"
        case .headHeight:  return "arrow.up.to.line"
        case .obstacle:    return "circle.dashed"
        }
    }
}

// MARK: - Why the whole system might be unreliable

enum SystemReliability: Equatable {
    case nominal
    /// Working, but quality is reduced. Obstacle cues continue, directional
    /// advice ("more space on your left") is withheld.
    case degraded(reason: String)
    /// Not usable. The user must be told to stop relying on it.
    case unavailable(reason: String)

    var isUsable: Bool {
        if case .unavailable = self { return false }
        return true
    }

    var isNominal: Bool { self == .nominal }

    var reason: String? {
        switch self {
        case .nominal: return nil
        case .degraded(let r), .unavailable(let r): return r
        }
    }

    var spokenDescription: String? {
        switch self {
        case .nominal:                return nil
        case .degraded(let reason):   return "Reduced reliability. \(reason)."
        case .unavailable(let reason): return "Guidance paused. \(reason)."
        }
    }
}

/// One input to the trust score, shown in the HUD so the number is auditable.
struct TrustFactor: Identifiable, Equatable {
    let id: String
    var value: Float
    var reason: String
}

// MARK: - Spatial vocabulary

/// Horizontal sectors relative to the direction the user faces.
enum Bearing: Int, CaseIterable {
    case farLeft = 0, left, ahead, right, farRight

    /// Signed horizontal angle in radians (negative = left).
    init(angle: Float) {
        let deg = angle * 180 / .pi
        switch deg {
        case ..<(-30):   self = .farLeft
        case -30..<(-8): self = .left
        case -8..<8:     self = .ahead
        case 8..<30:     self = .right
        default:         self = .farRight
        }
    }

    var spokenName: String {
        switch self {
        case .farLeft:  return "far left"
        case .left:     return "left"
        case .ahead:    return "ahead"
        case .right:    return "right"
        case .farRight: return "far right"
        }
    }

    /// Angular range covered by this sector, radians.
    var range: ClosedRange<Float> {
        let d: Float = .pi / 180
        switch self {
        case .farLeft:  return (-60 * d)...(-30 * d)
        case .left:     return (-30 * d)...(-8 * d)
        case .ahead:    return (-8 * d)...(8 * d)
        case .right:    return (8 * d)...(30 * d)
        case .farRight: return (30 * d)...(60 * d)
        }
    }
}

enum ProximityBand: Int, Comparable {
    case clear = 0      // > 4.0 m — not reported
    case aware          // 2.5–4.0 m
    case caution        // 1.2–2.5 m
    case imminent       // < 1.2 m

    init(distance: Float) {
        switch distance {
        case ..<1.2:  self = .imminent
        case ..<2.5:  self = .caution
        case ..<4.0:  self = .aware
        default:      self = .clear
        }
    }

    /// Repeat interval of the audio pulse. Closer = faster, like a car's
    /// reversing sensor.
    var pulseInterval: TimeInterval {
        switch self {
        case .clear:    return .infinity
        case .aware:    return 1.10
        case .caution:  return 0.60
        case .imminent: return 0.28
        }
    }

    static func < (a: ProximityBand, b: ProximityBand) -> Bool { a.rawValue < b.rawValue }
}

enum MotionClass: Equatable {
    case stationary
    case approaching(closingSpeed: Float)
    case crossing(lateralSpeed: Float)
    case receding

    var isDynamic: Bool { self != .stationary }

    var phrase: String {
        switch self {
        case .stationary:  return "stationary"
        case .approaching: return "approaching"
        case .crossing(let v): return v > 0 ? "crossing to the right" : "crossing to the left"
        case .receding:    return "moving away"
        }
    }
}

// MARK: - Body frame

/// A gravity-aligned frame attached to the user: `forward` is the camera's
/// heading flattened onto the ground plane, `right` is perpendicular to it.
///
/// We deliberately do NOT use the raw camera axes for left/right. ARKit's
/// camera space is fixed to the landscape sensor, so with the phone held
/// upright the camera's +X axis points at the floor. Projecting onto gravity
/// makes direction correct in any grip: portrait, landscape, chest mount.
struct BodyFrame {
    var origin: SIMD3<Float>
    var forward: SIMD3<Float>
    var right: SIMD3<Float>
    /// Camera pitch in radians (positive = looking up).
    var pitch: Float

    static let up = SIMD3<Float>(0, 1, 0)

    init(cameraToWorld m: simd_float4x4, fallbackForward: SIMD3<Float>?) {
        origin = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
        let look = -SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
        pitch = asin(max(-1, min(1, look.y)))
        let flat = SIMD3<Float>(look.x, 0, look.z)
        if simd_length(flat) > 0.2 {
            forward = simd_normalize(flat)
        } else {
            forward = fallbackForward ?? SIMD3(0, 0, -1)
        }
        right = simd_normalize(simd_cross(forward, BodyFrame.up))
    }

    /// World point → (right, up, forward) in metres, relative to the user.
    func local(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let r = p - origin
        return SIMD3(simd_dot(r, right), r.y, simd_dot(r, forward))
    }

    /// World direction → (right, up, forward).
    func localDirection(_ d: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(simd_dot(d, right), d.y, simd_dot(d, forward))
    }
}

// MARK: - The tracked obstacle

struct TrackedObstacle: Identifiable {
    let id: UUID

    /// Centre of the object's Gaussian, world space.
    var worldPosition: SIMD3<Float>
    /// Closest point of the object to the user, world space. Distance and
    /// direction are computed from this (the near edge of a wall matters,
    /// not its centre).
    var nearestPoint: SIMD3<Float>
    var worldVelocity: SIMD3<Float>
    /// One-sigma horizontal position uncertainty from the Kalman filter, m.
    var positionStd: Float
    var splatCount: Int

    var state: TrackState
    var cause: OcclusionCause
    var kind: ObstacleKind
    var lastObservedAt: TimeInterval
    var consecutiveHits: Int

    // Relative to the user, recomputed every frame.
    var distance: Float = .infinity
    var bearing: Bearing = .ahead
    /// Signed horizontal angle, radians. Negative = left.
    var azimuth: Float = 0
    var elevation: Float = 0
    var band: ProximityBand = .clear
    var motion: MotionClass = .stationary
    /// (right, forward) of the nearest point in metres, for the radar.
    var localXZ: SIMD2<Float> = .zero

    var salience: Float {
        guard state != .lost else { return 0 }
        var score: Float
        switch band {
        case .imminent: score = 1.0
        case .caution:  score = 0.7
        case .aware:    score = 0.4
        case .clear:    return 0
        }
        if case .approaching(let v) = motion, v > 0.3 { score += 0.25 }
        if bearing == .ahead { score += 0.15 }
        return min(1, score) * state.feedbackGain
    }
}

// MARK: - Splat-rendered free space

/// The Gaussian map rendered from the user's position into a 120° fan of
/// azimuth columns, front-to-back alpha compositing — the same equation a
/// Gaussian-splatting renderer uses for colour, used here for occupancy.
struct SpaceProfile {
    static let columns = 25
    static let halfFOV: Float = 60 * .pi / 180

    /// Distance at which accumulated opacity crosses 0.5. `.infinity` = free.
    var nearest = [Float](repeating: .infinity, count: SpaceProfile.columns)
    /// 1 − transmittance at max range.
    var occupancy = [Float](repeating: 0, count: SpaceProfile.columns)
    /// 0...1: how much of this column's answer comes from fresh measurement.
    var certainty = [Float](repeating: 0, count: SpaceProfile.columns)

    /// Free walking distance in a body-width corridor straight ahead.
    var corridorClear: Float = .infinity
    var corridorCertainty: Float = 0

    static func angle(ofColumn c: Int) -> Float {
        -halfFOV + (Float(c) + 0.5) * (2 * halfFOV / Float(columns))
    }

    /// Smallest free distance and mean certainty inside one sector.
    func clearance(in bearing: Bearing) -> (distance: Float, certainty: Float) {
        var dist = Float.infinity, cert: Float = 0, n: Float = 0
        for c in 0..<Self.columns where bearing.range.contains(Self.angle(ofColumn: c)) {
            dist = min(dist, nearest[c])
            cert += certainty[c]; n += 1
        }
        return (dist, n > 0 ? cert / n : 0)
    }
}

/// One splat, flattened for drawing on the top-down radar.
struct RadarSplat {
    var x: Float          // metres to the right
    var z: Float          // metres forward
    var sigma: Float      // horizontal 1-sigma radius, metres
    var opacity: Float
    var certainty: Float
    var dynamic: Bool
}

// MARK: - What the UI and the feedback layer consume

struct PerceptionSnapshot {
    var obstacles: [TrackedObstacle] = []
    var reliability: SystemReliability = .degraded(reason: "Starting up")
    /// 0...1 composite trust score, computed from measurable signals.
    var trust: Float = 0
    var trustFactors: [TrustFactor] = []
    /// Fraction of depth samples that came back usable this frame.
    var depthCoverage: Float = 0
    var space = SpaceProfile()
    var radarSplats: [RadarSplat] = []
    var splatCount: Int = 0
    /// Horizontal half-angle of what the camera currently sees, radians.
    var cameraHalfFOV: Float = 0.5
    var timestamp: TimeInterval = 0
    var timings = FrameTimings()
    var isDemo = false

    var primary: TrackedObstacle? {
        obstacles.max { $0.salience < $1.salience }
    }

    /// True only when we are confident the path straight ahead is walkable.
    var isPathClear: Bool {
        reliability.isUsable &&
        space.corridorCertainty > 0.6 &&
        space.corridorClear > 2.5 &&
        !obstacles.contains { $0.bearing == .ahead && $0.band >= .caution && $0.state.isTrustworthy }
    }
}

// MARK: - Tuning

enum Tuning {
    // Sensor
    static let maxUsefulDepth: Float = 5.0
    static let minUsefulDepth: Float = 0.25
    static let gridColumns = 32
    static let gridRows = 24
    /// LiDAR depth noise model: sigma = base + quadratic * d².
    static let lidarNoiseBase: Float = 0.01
    static let lidarNoiseQuadratic: Float = 0.002

    // Gaussian splat map
    static let voxelSize: Float = 0.2
    static let maxSplatEvidence: Float = 10
    static let initialOpacity: Float = 0.45
    static let opacityGain: Float = 0.4
    /// Opacity multiplier when a depth ray passes straight through a splat.
    static let carveFactor: Float = 0.6
    static let pruneOpacity: Float = 0.1
    static let maxSplats = 6000
    static let splatMemory: TimeInterval = 30
    /// How far back we look to decide "this space was empty a moment ago".
    static let dynamicReferenceAge: TimeInterval = 0.3

    // Geometry
    static let floorTolerance: Float = 0.15
    static let maxObstacleHeight: Float = 2.1
    static let corridorHalfWidth: Float = 0.45
    static let minClusterSplats = 3

    // Tracking
    static let gateChi2: Float = 13.8   // 99.9% for 2 DOF
    static let hitsBeforeAnnouncing = 3
    static let maxDirectionalAngularStd: Float = 0.26   // ≈ one sector
    static let maxDirectionalPositionStd: Float = 0.7
    static let hiddenMemory: TimeInterval = 2.5
    static let dynamicMemory: TimeInterval = 1.5
    static let staticOutOfViewMemory: TimeInterval = 6.0

    // Speech
    static let minSpeechInterval: TimeInterval = 2.6
    static let minReliabilityInterval: TimeInterval = 6.0

    // Trust thresholds (with hysteresis)
    static let trustUnavailable: Float = 0.30
    static let trustRecover: Float = 0.45
    static let trustDegraded: Float = 0.60
    static let trustNominal: Float = 0.65
}
