# FieldVision

An iOS prototype (Swift + SwiftUI) for The Big Hack 2026, Challenge 03 by Mare Group:
**"FieldVision – When Sight Is Not Enough"**.

The phone's camera and LiDAR scan the space around a visually impaired person. The app
warns about obstacles and moving people through spatial audio, speech and vibration,
**keeps track of things while they are hidden**, and **says out loud when its own guidance
can't be trusted**.

```
LiDAR depth ─▶ Gaussian splat map ─▶ splat rendering ─▶ objects ─▶ Kalman tracks ─▶ trust score ─▶ audio · speech · haptics
  (32×24)       fuse + ray-test       free space +       as Gaussians   hidden vs gone     7 measured     only what it can
                                      certainty                                         signals        stand behind
```

---

## What the brief asks, and where it is answered

| Brief (Mare Group) | How FieldVision does it | Code |
|---|---|---|
| Detect **moving elements** and **obstacles** | Every depth sample becomes a 3D Gaussian. Splats born in space that was seen empty 0.3 s earlier are *moving*. Objects are classified from the shape of their Gaussian: wall, large, low (trip hazard), head-height, moving, and *person* from a 3 Hz on-device detector. | `GaussianSplatMap`, `SplatObjectDetector`, `HumanDetector` |
| **Handle interruptions of visibility** | Kalman tracks keep identity behind occluders. Ray tests against the splat map tell **hidden** (the ray stops in front) apart from **gone** (the ray passes straight through). Static structure that leaves the view is remembered. | `ObstacleTracker`, `GaussianSplatMap.visibility` |
| **Distinguish observed from uncertain** | Every track is `observed`, `inferred` (with the reason: hidden / out of view / no data) or `expiring`. A direction is given only while its angular uncertainty is under one sector (~15°). Free space is "clear" only if the camera is measuring it now. | `Models.swift`, `SplatCompositor` |
| **Clear, timely spatial feedback** | HRTF spatial tones (pitch = distance, rate = urgency, timbre = certainty), two-axis haptics, short spoken sentences with the important word first, and an on-demand "Around me" summary. | `Feedback/` |
| **Signal loss of reliability** | A 0–1 trust score from 7 measured signals (coverage, ARKit tracking, light, camera motion, aim, path certainty, track churn). Below 0.60: obstacles only, no directions. Below 0.30: "Guidance paused" with the reason, said out loud. | `TrustEstimator` |
| **Low latency, efficient processing** | No neural network at frame rate: 768 depth samples, a few thousand splats, ~1–3 ms of our own code per frame. Every stage is timed live in the metrics panel. | `PerformanceMonitor` |

---

## Gaussian splatting, used for perception

Gaussian splatting normally renders a photo-real scene from many 3D Gaussians. Here the same
two ideas do the detection work:

1. **The map is made of Gaussians.** Each LiDAR sample is a small 3D Gaussian (its covariance
   is the sensor footprint: thin along the ray, wider across it at long range). Samples in the
   same 20 cm voxel are fused into one persistent splat with mean, covariance, opacity
   (occupancy belief), last-seen time and a *moving* flag.
2. **The map is rendered by splatting.** From the user's position, each splat is projected
   onto a 120° fan of 25 azimuth columns and alpha-composited front to back
   (`Tᵢ₊₁ = Tᵢ·(1 − αᵢ)`), exactly as a 3DGS rasteriser does, but the "colour" is
   occupancy and *certainty* instead of RGB. The result is how far you can walk in each
   direction, and how sure the system is about it.

Ray tests on the same map give the occlusion logic its evidence: if the depth ray towards a
splat stops short, the splat is **hidden**; if it goes through, the splat is **carved**
(opacity drops), so nothing that has left keeps haunting the user.

---

## Run it

Requirements: Xcode 15+ (built with Xcode 27), iOS 17+.

```bash
brew install xcodegen   # only if you change project.yml
xcodegen generate       # regenerates FieldVision.xcodeproj
open FieldVision.xcodeproj
```

* **Live camera**: needs a LiDAR device (iPhone 12 Pro or newer Pro / Pro Max, iPad Pro
  2020+). Set your signing team, run on the device, tap **Start**.
* **Demo scene**: runs everywhere, including the Simulator. A scripted 30 s street scene is
  ray-cast into the same depth format the LiDAR produces, so the whole pipeline runs
  unchanged. It is also the backup for the live demo.

Launch arguments: `-autostart` starts guidance immediately; `-log` prints a state line twice
a second (trust, reliability, every track with its state, cause and uncertainty).

Use **open-ear audio** (bone-conduction or AirPods in Transparency mode). Covering a blind
user's ears to give them cues takes away more than it gives.

---

## The demo scene (30 s loop)

| Time | What happens | What to look and listen for |
|---|---|---|
| 0–8.5 s | A person crosses left → right and passes **behind a column** | Track turns amber and dashed: "Predicted · hidden behind something". Uncertainty ring grows, then snaps back when the person reappears, with the same identity. |
| 8.5–15 s | The person turns and **approaches** on the right | "Person · right · approaching", pulses get faster. |
| 15–18 s | **The lens is covered** | Trust drops to 0, red "Paused", three hard taps, *"Guidance paused. The camera cannot see the path."* |
| 18–21 s | Lens uncovered | Waits for good frames ("Recovering") before trusting itself again. |
| 21–30 s | The user turns left | Van ("Large"), low bin ("Low"), sign at head height; things that leave the view are remembered as "out of view". |

---

## Screen

* **Trust card**: Reliable / Reduced / Paused, the trust %, threshold marks and the reason.
* **Splat radar** (top-down, forward is up): green fan = free space confirmed now, grey fan =
  not verifiable; dots are splats (white = measured now, amber = memory, pink = moving);
  rings are tracks (solid = observed, dashed amber = predicted, dotted grey "?" = position
  unknown). The dashed lines are the body-width walking corridor.
* **Primary line**: the most important thing, and whether it is confirmed or predicted.
* **Start / Stop** and **Around me** (spoken summary of the surroundings).
* **Metrics** (gauge button): per-stage timings, p95, frame budget, splat count, the 7 trust
  factors.

---

## Sound and touch

| Channel | Carries | Why |
|---|---|---|
| Pitch | Distance band (higher = closer) | Near-universal idiom |
| Pulse rate | Urgency | Like a car's parking sensor, already familiar |
| Timbre | Certainty: clean = observed, detuned = predicted | Heard instantly, no words needed |
| 3D position (HRTF) | Direction | Understood before the sound ends |
| Haptic sharpness | Certainty: crisp vs soft | Works when the ears are busy |
| Haptic intensity | Proximity | |
| Speech | Changes, labels, reliability, "Around me" | Rate-limited; never repeats itself |

At most two obstacles are sonified at once. "Path blocked ahead. More space on your left" is
only said at full trust; at reduced trust the app warns but doesn't steer.

---

## Code map

```
FieldVision/
  FieldVisionApp.swift
  Core/
    Models.swift               Vocabulary: TrackState, OcclusionCause, ObstacleKind, BodyFrame, Tuning
    DepthFrame.swift           The one input format (LiDAR or simulated)
    GaussianSplatMap.swift     ★ Splat fusion, ray tests (hidden / carved), moving-splat test
    SplatCompositor.swift      ★ Splat rendering → free space + certainty per direction
    SplatObjectDetector.swift  Splats → objects as Gaussians, shape classes
    ObstacleTracker.swift      Kalman tracks, Mahalanobis association, occlusion reasoning
    TrustEstimator.swift       7-signal trust score with hysteresis
    PerceptionPipeline.swift   Frame in, snapshot out
    PerformanceMonitor.swift   Per-stage timings + design notes
  Sensors/
    PerceptionEngine.swift     ARKit session or demo scene, on one serial queue
    ARKitDepthAdapter.swift    ARFrame → DepthFrame
    HumanDetector.swift        Vision person detector at 3 Hz
    SimulatedScene.swift       Scripted, ray-cast demo street
  Feedback/
    FeedbackCoordinator.swift  The attention budget: what is heard, when
    SpatialAudioEngine.swift   HRTF tones, synthesised and cached
    HapticFeedbackEngine.swift Two-axis haptics
    SpeechAnnouncer.swift      Words, rate-limited, important word first
    SceneDescriber.swift       "Around me": confirmed / uncertain / unknown
  UI/
    ContentView.swift          Trust card, radar, controls, metrics
    SplatRadarView.swift       Top-down splat radar
project.yml                    XcodeGen spec (Info.plist keys live here)
```

---

## Known limits

* **LiDAR range** is about 5 m, and glass, puddles and rain degrade it. That shows up as low
  coverage → reduced or paused trust: honest, but not helpful.
* **Camera-relative audio.** Directions are relative to where the phone points (gravity-
  aligned, so any grip works). A chest mount is assumed; head-tracked AirPods would need
  `CMHeadphoneMotionManager` compensation.
* **Person labels** come from Apple's person detector at 3 Hz; if it misses, the object is
  still reported as "something moving".
* **Thresholds are starting points**, tuned on the simulated scene, not on real users.
  Test with a blind user before trusting any of them.
* A supplement to a cane or a guide dog, never a replacement.
