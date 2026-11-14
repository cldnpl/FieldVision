//
//  SceneDescriber.swift
//  FieldVision
//
//  "What is around me?" — a short spoken summary of the space, on demand.
//
//  It reads the splat-rendered space profile (free distance and certainty
//  per direction) and the tracked obstacles, and it keeps three kinds of
//  statement apart, exactly as the brief asks:
//
//    confirmed   "Path ahead clear for 4 metres."
//    uncertain   "Probably a person on the right, hidden behind something."
//    unknown     "Left side not visible."
//
//  When trust is reduced it still reports obstacles but gives no advice on
//  where to go; when guidance is paused it says only that.
//

import Foundation

enum SceneDescriber {

    static func describe(_ s: PerceptionSnapshot) -> String {
        if case .unavailable(let reason) = s.reliability {
            return "Guidance paused. \(reason). Do not rely on me right now."
        }

        var sentences: [String] = []

        // 1. The path straight ahead.
        let corridor = s.space.corridorClear
        if s.space.corridorCertainty < 0.5 {
            sentences.append("Path ahead not confirmed")
        } else if corridor > 4 {
            sentences.append("Path ahead clear for 4 metres")
        } else {
            let blocker = s.obstacles.first { $0.bearing == .ahead }?.kind.spokenName ?? "an obstacle"
            sentences.append("Path ahead blocked by \(blocker) in \(SpeechAnnouncer.metres(corridor))")
        }

        // 2. Up to three obstacles, most important first.
        for o in s.obstacles.prefix(3) where o.state != .lost {
            sentences.append(SpeechAnnouncer.describe(o))
        }

        // 3. Directions we cannot vouch for.
        let left = s.space.clearance(in: .left)
        let right = s.space.clearance(in: .right)
        var unknown: [String] = []
        if left.certainty < 0.3 { unknown.append("left") }
        if right.certainty < 0.3 { unknown.append("right") }
        if !unknown.isEmpty {
            sentences.append("\(unknown.joined(separator: " and ").capitalized) side not visible")
        }

        // 4. Advice, only at full trust.
        if s.reliability.isNominal, corridor < 2.5, let side = freerSide(s) {
            sentences.append("More space on your \(side)")
        } else if case .degraded(let reason) = s.reliability {
            sentences.append("Reduced reliability: \(reason). No directions given")
        }

        if s.obstacles.isEmpty && s.space.corridorCertainty >= 0.5 && corridor > 4 {
            sentences.append("Nothing detected within 4 metres")
        }
        return sentences.joined(separator: ". ") + "."
    }

    /// The side with clearly more confirmed free space, if any.
    static func freerSide(_ s: PerceptionSnapshot) -> String? {
        let l = s.space.clearance(in: .left)
        let r = s.space.clearance(in: .right)
        let lOK = l.certainty > 0.6 && l.distance > 2.5
        let rOK = r.certainty > 0.6 && r.distance > 2.5
        switch (lOK, rOK) {
        case (true, false): return "left"
        case (false, true): return "right"
        case (true, true):  return l.distance >= r.distance ? "left" : "right"
        default:            return nil
        }
    }
}
