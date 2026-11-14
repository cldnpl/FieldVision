//
//  SplatRadarView.swift
//  FieldVision
//
//  Top-down view of what the system believes, for sighted helpers, low-vision
//  users and the jury. Forward is up, the user is the triangle at the bottom.
//
//    green fan        free space the camera confirms right now
//    grey fan         space we cannot vouch for (out of view / memory only)
//    dots             Gaussian splats — white = measured now, amber = memory,
//                     pink = moving
//    rings            tracked objects; solid = observed, dashed = predicted,
//                     dotted grey with "?" = position unknown
//

import SwiftUI

enum Palette {
    static let background = Color(red: 0.04, green: 0.05, blue: 0.07)
    static let surface = Color(red: 0.09, green: 0.10, blue: 0.13)
    static let confirmed = Color(red: 0.24, green: 0.86, blue: 0.59)
    static let uncertain = Color(red: 1.00, green: 0.69, blue: 0.13)
    static let danger = Color(red: 1.00, green: 0.36, blue: 0.37)
    static let moving = Color(red: 1.00, green: 0.48, blue: 0.78)
    static let unknown = Color(white: 0.55)
}

struct SplatRadarView: View {
    let snapshot: PerceptionSnapshot
    var range: Float = 5

    var body: some View {
        Canvas { ctx, size in
            let scale = CGFloat(size.height * 0.8) / CGFloat(range)
            let origin = CGPoint(x: size.width / 2, y: size.height * 0.93)

            func point(_ x: Float, _ z: Float) -> CGPoint {
                CGPoint(x: origin.x + CGFloat(x) * scale, y: origin.y - CGFloat(z) * scale)
            }

            drawRings(ctx, origin: origin, scale: scale)
            drawFreeSpace(ctx, origin: origin, scale: scale)
            drawFieldOfView(ctx, origin: origin, scale: scale)
            drawCorridor(ctx, point: point)

            for s in snapshot.radarSplats where s.z < range + 0.3 {
                let r = max(2.0, min(9, CGFloat(s.sigma) * scale * 0.7))
                let p = point(s.x, s.z)
                let color: Color = s.dynamic ? Palette.moving
                    : (s.certainty > 0.8 ? .white : Palette.uncertain)
                let alpha = Double(s.opacity) * (0.3 + 0.7 * Double(s.certainty))
                ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                         with: .color(color.opacity(alpha * 0.75)))
            }

            for o in snapshot.obstacles {
                drawTrack(ctx, o, at: point(o.localXZ.x, o.localXZ.y), scale: scale)
            }

            // The user.
            var me = Path()
            me.move(to: CGPoint(x: origin.x, y: origin.y - 11))
            me.addLine(to: CGPoint(x: origin.x - 8, y: origin.y + 6))
            me.addLine(to: CGPoint(x: origin.x + 8, y: origin.y + 6))
            me.closeSubpath()
            ctx.fill(me, with: .color(.white))
        }
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22))
        .clipShape(RoundedRectangle(cornerRadius: 22))
    }

    private func drawRings(_ ctx: GraphicsContext, origin: CGPoint, scale: CGFloat) {
        for m in 1...Int(range) {
            let r = CGFloat(m) * scale
            let ring = Path(ellipseIn: CGRect(x: origin.x - r, y: origin.y - r, width: 2 * r, height: 2 * r))
            ctx.stroke(ring, with: .color(.white.opacity(0.07)), lineWidth: 1)
            ctx.draw(Text("\(m) m").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.3)),
                     at: CGPoint(x: origin.x + 16, y: origin.y - r + 7))
        }
    }

    private func drawFreeSpace(_ ctx: GraphicsContext, origin: CGPoint, scale: CGFloat) {
        let n = SpaceProfile.columns
        let half = Double(SpaceProfile.halfFOV)
        let w = 2 * half / Double(n)
        for c in 0..<n {
            let theta = Double(SpaceProfile.angle(ofColumn: c))
            let reach = CGFloat(min(snapshot.space.nearest[c], range)) * scale
            let cert = Double(snapshot.space.certainty[c])
            var wedge = Path()
            wedge.move(to: origin)
            // Canvas angles: 0 = +x, clockwise. Forward (up) is −90°.
            wedge.addArc(center: origin, radius: reach,
                         startAngle: .radians(-Double.pi / 2 + theta - w / 2),
                         endAngle: .radians(-Double.pi / 2 + theta + w / 2),
                         clockwise: false)
            wedge.closeSubpath()
            // While guidance is paused nothing is "confirmed", whatever the
            // memory says: the radar must not look greener than the voice.
            let usable = snapshot.reliability.isUsable
            let color = (cert >= 0.5 && usable) ? Palette.confirmed.opacity(0.06 + 0.22 * cert)
                                                : Palette.unknown.opacity(0.05 + 0.08 * cert)
            ctx.fill(wedge, with: .color(color))
        }
    }

    private func drawFieldOfView(_ ctx: GraphicsContext, origin: CGPoint, scale: CGFloat) {
        let a = Double(snapshot.cameraHalfFOV)
        guard a > 0.05 else { return }
        let r = CGFloat(range) * scale
        for side in [-1.0, 1.0] {
            var p = Path()
            p.move(to: origin)
            p.addLine(to: CGPoint(x: origin.x + r * CGFloat(sin(side * a)),
                                  y: origin.y - r * CGFloat(cos(side * a))))
            ctx.stroke(p, with: .color(.white.opacity(0.22)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
        }
    }

    private func drawCorridor(_ ctx: GraphicsContext, point: (Float, Float) -> CGPoint) {
        let reach = min(snapshot.space.corridorClear, range)
        let hw = Tuning.corridorHalfWidth
        let certain = snapshot.space.corridorCertainty >= 0.5 && snapshot.reliability.isUsable
        let color = certain ? Palette.confirmed : Palette.unknown
        for x in [-hw, hw] {
            var p = Path()
            p.move(to: point(x, 0.3))
            p.addLine(to: point(x, reach))
            ctx.stroke(p, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        if snapshot.space.corridorClear < range {
            var bar = Path()
            bar.move(to: point(-hw - 0.1, reach))
            bar.addLine(to: point(hw + 0.1, reach))
            ctx.stroke(bar, with: .color(certain ? Palette.danger : Palette.unknown), lineWidth: 3)
        }
    }

    private func drawTrack(_ ctx: GraphicsContext, _ o: TrackedObstacle, at p: CGPoint, scale: CGFloat) {
        // 2-sigma ring, capped so one lost track can't swallow the radar.
        let r = max(11, min(0.8 * scale, CGFloat(o.positionStd) * 2 * scale))
        let ring = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))

        let color: Color
        let style: StrokeStyle
        switch o.state {
        case .observed:
            color = o.motion.isDynamic || o.kind == .person ? Palette.moving : Palette.confirmed
            style = StrokeStyle(lineWidth: 2.5)
        case .inferred:
            color = Palette.uncertain
            style = StrokeStyle(lineWidth: 2.5, dash: [5, 4])
        default:
            color = Palette.unknown
            style = StrokeStyle(lineWidth: 2, dash: [1.5, 4])
        }
        ctx.stroke(ring, with: .color(color), style: style)

        let label: String
        switch o.state {
        case .expiring: label = "?"
        case .inferred: label = "\(o.kind.shortName)?"
        default:        label = o.kind.shortName
        }
        ctx.draw(Text(label).font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(color),
                 at: CGPoint(x: p.x, y: p.y - r - 9))
    }
}
