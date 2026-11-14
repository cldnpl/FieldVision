//
//  ContentView.swift
//  FieldVision
//
//  The screen is the least important channel of this app — guidance is sound,
//  speech and vibration — but it is the one the jury, a sighted helper or a
//  low-vision user sees. Rules:
//
//   · Two huge controls at the bottom: Start/Stop and "What's around me?".
//     Hittable without aiming.
//   · Trust is always on screen, as a word, a number and a colour — the
//     same information the user HEARS when it changes.
//   · Confirmed vs uncertain is drawn differently everywhere: solid vs dashed,
//     green vs amber, "confirmed" vs "predicted".
//   · Everything visual has a VoiceOver equivalent.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var engine = PerceptionEngine()
    @StateObject private var feedback = FeedbackCoordinator()

    @State private var showMetrics = false
    @State private var startupError: String?

    private var s: PerceptionSnapshot { engine.snapshot }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()

            VStack(spacing: 14) {
                header
                trustCard
                SplatRadarView(snapshot: s)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(alignment: .topLeading) { radarLegend }
                    .overlay(alignment: .bottom) { if engine.isRunning && s.isDemo { demoCaption } }
                    .accessibilityElement()
                    .accessibilityLabel(engine.isRunning ? SceneDescriber.describe(s) : "Map of surroundings. Not running.")
                primaryLine
                controls
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 12)

            if showMetrics { metricsPanel }
        }
        .preferredColorScheme(.dark)
        .onReceive(engine.$snapshot) { snapshot in
            if engine.isRunning { feedback.process(snapshot) }
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if ProcessInfo.processInfo.arguments.contains("-autostart") { start() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            stop()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FieldVision")
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                Text("Gaussian-splat obstacle guidance")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)

            Spacer()

            Menu {
                ForEach(PerceptionEngine.Mode.allCases) { m in
                    Button {
                        let wasRunning = engine.isRunning
                        if wasRunning { stop() }
                        engine.mode = m
                        if wasRunning { start() }
                    } label: {
                        Label(m.rawValue, systemImage: m == .live ? "camera.fill" : "play.rectangle.fill")
                    }
                    .disabled(m == .live && !engine.canRunLive)
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: engine.mode == .live ? "camera.fill" : "play.rectangle.fill")
                    Text(engine.mode == .live ? "LIVE" : "DEMO")
                }
                .font(.system(size: 13, weight: .bold))
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(.white.opacity(0.1), in: Capsule())
            }
            .accessibilityLabel("Source: \(engine.mode.rawValue). Double tap to change.")
        }
        .foregroundStyle(.white)
    }

    // MARK: - Trust

    private var trustColor: Color {
        guard engine.isRunning else { return Palette.unknown }
        switch s.reliability {
        case .nominal:     return Palette.confirmed
        case .degraded:    return Palette.uncertain
        case .unavailable: return Palette.danger
        }
    }

    private var trustWord: String {
        guard engine.isRunning else { return "Ready" }
        switch s.reliability {
        case .nominal:     return "Reliable"
        case .degraded:    return "Reduced"
        case .unavailable: return "Paused"
        }
    }

    private var trustCard: some View {
        HStack(spacing: 14) {
            Image(systemName: reliabilitySymbol)
                .font(.system(size: 30, weight: .bold))
                .foregroundStyle(trustColor)
                .frame(width: 40)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trustWord)
                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                    Spacer()
                    if engine.isRunning {
                        Text("trust \(Int((s.trust * 100).rounded()))%")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.12))
                        Capsule().fill(trustColor)
                            .frame(width: geo.size.width * CGFloat(engine.isRunning ? s.trust : 0))
                        // Threshold marks: paused / reduced.
                        ForEach([Tuning.trustUnavailable, Tuning.trustDegraded], id: \.self) { t in
                            Rectangle().fill(.white.opacity(0.5))
                                .frame(width: 2, height: 12)
                                .offset(x: geo.size.width * CGFloat(t) - 1)
                        }
                    }
                }
                .frame(height: 8)
                Text(trustDetail)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(trustColor.opacity(0.6), lineWidth: 1.5))
        .animation(.easeInOut(duration: 0.25), value: trustWord)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Guidance \(trustWord). \(trustDetail)")
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var reliabilitySymbol: String {
        guard engine.isRunning else { return "pause.circle" }
        switch s.reliability {
        case .nominal:     return "checkmark.shield.fill"
        case .degraded:    return "exclamationmark.triangle.fill"
        case .unavailable: return "eye.slash.fill"
        }
    }

    private var trustDetail: String {
        guard engine.isRunning else {
            return engine.canRunLive ? "LiDAR ready" : "No LiDAR here — demo scene"
        }
        switch s.reliability {
        case .nominal:
            return s.space.corridorClear > 4 ? "Path ahead clear for 4 m"
                : String(format: "Path ahead free for %.1f m", s.space.corridorClear)
        case .degraded(let r):    return "\(r) · no directions"
        case .unavailable(let r): return r
        }
    }

    // MARK: - Radar extras

    private var radarLegend: some View {
        VStack(alignment: .leading, spacing: 4) {
            legendRow(Palette.confirmed, "confirmed")
            legendRow(Palette.uncertain, "predicted / memory")
            legendRow(Palette.moving, "moving")
            legendRow(Palette.unknown, "unknown")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(.white.opacity(0.75))
        .padding(8)
        .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        .padding(8)
        .accessibilityHidden(true)
    }

    private func legendRow(_ c: Color, _ t: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(c).frame(width: 7, height: 7)
            Text(t)
        }
    }

    private var demoCaption: some View {
        Text(SimulatedScene.caption(at: engine.demoTime))
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.black.opacity(0.55), in: Capsule())
            .padding(.bottom, 10)
            .accessibilityHidden(true)
    }

    // MARK: - Primary obstacle

    private var primaryLine: some View {
        HStack(spacing: 12) {
            Image(systemName: primarySymbol)
                .font(.system(size: 22, weight: .bold))
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(primaryTitle)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Text(primarySubtitle)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(primaryColor)
                    .lineLimit(1).minimumScaleFactor(0.7)
            }
            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .frame(minHeight: 62)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private var primarySymbol: String {
        guard engine.isRunning, s.reliability.isUsable else { return "eye.slash" }
        return s.primary?.kind.symbol ?? "checkmark.circle"
    }

    private var primaryTitle: String {
        guard engine.isRunning else { return "Not running" }
        guard s.reliability.isUsable else { return "Guidance paused" }
        guard let p = s.primary else { return s.isPathClear ? "Path clear" : "Scanning…" }
        if p.state == .expiring { return "Lost track of \(p.kind.spokenName)" }
        let dir = p.bearing == .ahead ? "ahead" : p.bearing.spokenName
        return "\(p.kind.shortName) · \(dir) · \(String(format: "%.1f m", p.distance))"
    }

    private var primarySubtitle: String {
        guard engine.isRunning else { return "Tap Start" }
        guard s.reliability.isUsable else { return "Not sure what is around you" }
        guard let p = s.primary else { return "Nothing within 4 m" }
        switch p.state {
        case .observed: return "Confirmed" + (p.motion.isDynamic ? " · \(p.motion.phrase)" : "")
        case .inferred: return "Predicted · \(p.cause.phrase ?? "not measured")"
        default:        return "Position unknown — no direction given"
        }
    }

    private var primaryColor: Color {
        guard let p = s.primary, engine.isRunning else { return .white.opacity(0.6) }
        switch p.state {
        case .observed: return Palette.confirmed
        case .inferred: return Palette.uncertain
        default:        return Palette.unknown
        }
    }

    // MARK: - Controls

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 12) {
                Button(action: toggle) {
                    Label(engine.isRunning ? "Stop" : "Start",
                          systemImage: engine.isRunning ? "stop.fill" : "play.fill")
                        .font(.system(size: 20, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(engine.isRunning ? Palette.danger : Palette.confirmed,
                                    in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.black)
                }
                .accessibilityLabel(engine.isRunning ? "Stop guidance" : "Start guidance")

                Button {
                    feedback.describeSurroundings(s)
                } label: {
                    Label("Around me", systemImage: "speaker.wave.2.fill")
                        .font(.system(size: 18, weight: .bold))
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(.white.opacity(engine.isRunning ? 0.16 : 0.06),
                                    in: RoundedRectangle(cornerRadius: 18))
                        .foregroundStyle(.white)
                }
                .disabled(!engine.isRunning)
                .accessibilityLabel("Describe my surroundings")
            }

            HStack(spacing: 8) {
                chip("Speech", "text.bubble", $feedback.speechEnabled)
                chip("Tones", "waveform", $feedback.audioEnabled)
                chip("Haptics", "hand.tap", $feedback.hapticsEnabled)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { showMetrics.toggle() }
                } label: {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 44, height: 36)
                        .background(.white.opacity(0.08), in: Capsule())
                        .foregroundStyle(.white.opacity(0.8))
                }
                .accessibilityLabel("Show metrics")
            }
            if let startupError {
                Text(startupError).font(.footnote).foregroundStyle(Palette.danger)
            }
        }
    }

    private func chip(_ title: String, _ icon: String, _ isOn: Binding<Bool>) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                Text(title)
            }
            .font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, minHeight: 36)
            .background(.white.opacity(isOn.wrappedValue ? 0.16 : 0.04), in: Capsule())
            .foregroundStyle(.white.opacity(isOn.wrappedValue ? 1 : 0.4))
        }
        .accessibilityLabel(title)
        .accessibilityValue(isOn.wrappedValue ? "on" : "off")
    }

    // MARK: - Metrics

    private var metricsPanel: some View {
        let t = s.timings
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Metrics").font(.system(size: 17, weight: .bold))
                Spacer()
                Button { withAnimation { showMetrics = false } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 22))
                }
                .accessibilityLabel("Close metrics")
            }
            Group {
                row("sensor → decision", String(format: "%.1f ms", t.sensorToDecision))
                row("splat fusion", String(format: "%.2f ms", t.fusion))
                row("splat render", String(format: "%.2f ms", t.render))
                row("detection", String(format: "%.2f ms", t.detection))
                row("tracking", String(format: "%.2f ms", t.tracking))
                row("our code p95", String(format: "%.2f ms", t.p95Total))
                row("frame budget used", String(format: "%.0f%%", t.budgetUsed * 100))
                row("fps", String(format: "%.0f", t.effectiveFPS))
                row("splats in map", "\(s.splatCount)")
                row("tracks", "\(s.obstacles.count)")
                row("depth coverage", String(format: "%.0f%%", s.depthCoverage * 100))
            }
            Divider().overlay(.white.opacity(0.2))
            Text("Trust factors").font(.system(size: 13, weight: .bold)).foregroundStyle(.white.opacity(0.7))
            ForEach(s.trustFactors) { f in
                HStack {
                    Text(f.id)
                    Spacer()
                    Text(String(format: "%.2f", f.value)).fontWeight(.bold)
                        .foregroundStyle(f.value < 0.6 ? Palette.uncertain : Palette.confirmed)
                }
            }
        }
        .font(.system(size: 13, design: .monospaced))
        .foregroundStyle(.white)
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
        .padding(24)
        .transition(.opacity)
    }

    private func row(_ l: String, _ v: String) -> some View {
        HStack { Text(l); Spacer(); Text(v).fontWeight(.bold) }
    }

    // MARK: - Actions

    private func toggle() { engine.isRunning ? stop() : start() }

    private func start() {
        do {
            try feedback.start()
            startupError = nil
        } catch {
            startupError = "Audio unavailable: \(error.localizedDescription)"
        }
        engine.start()
    }

    private func stop() {
        engine.stop()
        feedback.stop()
    }
}

#Preview {
    ContentView()
}
