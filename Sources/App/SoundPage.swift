import SwiftUI

// MARK: - Timer & Sound page

/// One page for how long the music plays and how it sounds. The big clock opens it, and so does
/// ··· → Timer & Sound. Each part is a titled card the way Settings shows it (grey name above, lines split by
/// hairlines), so where one part ends and the next begins is plain: play mode, focus pulse, noise, volume.
struct TimerSoundPanel: View {
    @ObservedObject var c: FocusController
    @ObservedObject var settings: AppSettings

    var body: some View {
        let s = c.strings
        VStack(alignment: .leading, spacing: Metrics.groupSpacing) {
            PageHeader(title: s.timerAndSound, back: s.back) { c.panelPage = .main }
            playModeGroup(s)
            PulseGroup(c: c)
            NoiseGroup(settings: settings, s: s)
            volumeGroup(s)
        }
    }

    // MARK: Play mode

    private var modeIndex: Int { PlayMode.allCases.firstIndex(of: settings.playMode) ?? 0 }

    /// The note beside the name says what the chosen mode does.
    private func playModeGroup(_ s: Strings) -> some View {
        CardGroup(title: s.playMode, note: s.modes[modeIndex].1) {
            Segmented(options: PlayMode.allCases.enumerated().map { ($0.element, s.modes[$0.offset].0) },
                      selection: settings.playMode, height: Metrics.segmentedLarge, fill: true) { c.setPlayMode($0) }
                .padding(Metrics.cardControlInset)
            if settings.playMode == .timer { timerRows(s) }
            if settings.playMode == .pomodoro { pomodoroRows(s) }
        }
    }

    @ViewBuilder private func timerRows(_ s: Strings) -> some View {
        let presets: [(TimerChoice, String)] = [(.m25, s.minutes(25)), (.m45, s.minutes(45)), (.m60, s.minutes(60)), (.m90, s.minutes(90)), (.custom, s.custom)]
        Hairline()
        HStack(spacing: 4) {
            ForEach(presets, id: \.0) { item in
                Chip(label: item.1, selected: settings.timerChoice == item.0) { c.setTimerChoice(item.0) }
            }
        }
        .padding(Metrics.cardControlInset)
        if settings.timerChoice == .custom {
            Hairline()
            CardRow(label: s.minutes(settings.customTimerMinutes)) {
                Stepper("", value: $settings.customTimerMinutes, in: 5...240, step: 5).labelsHidden()
            }
        }
        Hairline()
        CardRow(label: s.whenEnds) {
            Segmented(options: [(TimerEndAction.stop, s.timerEnds[0]), (.keepPlaying, s.timerEnds[1])],
                      selection: settings.timerEndAction) { settings.timerEndAction = $0 }
        }
    }

    @ViewBuilder private func pomodoroRows(_ s: Strings) -> some View {
        Hairline()
        HStack(spacing: 4) {
            Chip(label: "25 / 5", selected: settings.pomodoroPreset == .p25_5) { c.setPomodoroPreset(.p25_5) }
            Chip(label: "50 / 10", selected: settings.pomodoroPreset == .p50_10) { c.setPomodoroPreset(.p50_10) }
            Chip(label: s.custom, selected: settings.pomodoroPreset == .custom) { c.setPomodoroPreset(.custom) }
        }
        .padding(Metrics.cardControlInset)
        if settings.pomodoroPreset == .custom {
            Hairline()
            CardRow(label: "\(s.focusWord) \(s.minutes(settings.customFocusMinutes))") {
                Stepper("", value: $settings.customFocusMinutes, in: 5...120, step: 5).labelsHidden()
            }
            Hairline()
            CardRow(label: "\(s.breakWord) \(s.minutes(settings.customBreakMinutes))") {
                Stepper("", value: $settings.customBreakMinutes, in: 1...30).labelsHidden()
            }
        }
        Hairline()
        CardToggleRow(title: s.longBreak.0, caption: s.longBreak.1, isOn: $settings.longBreakEvery4)
        Hairline()
        CardRow(label: s.breakMusic) {
            Segmented(options: [(BreakMusic.pause, s.breakOptions[0]), (.quieter, s.breakOptions[1])],
                      selection: settings.breakMusic) { settings.breakMusic = $0 }
        }
    }

    // MARK: Volume

    /// The app's music volume (the noise follows it). Speakers on both ends say what the slider is.
    private func volumeGroup(_ s: Strings) -> some View {
        CardGroup(title: s.volume) {
            HStack(spacing: 8) {
                Image(systemName: "speaker.fill").font(.system(size: 10))
                Slider(value: $settings.volume, in: 0...1).tint(Palette.accent)
                    .accessibilityLabel(s.volume)
                Image(systemName: "speaker.wave.3.fill").font(.system(size: 11))
                Text("\(Int((settings.volume * 100).rounded()))%").monospacedDigit().frame(width: 34, alignment: .trailing)
            }
            .font(AppFont.body)
            .foregroundStyle(.secondary)
            .padding(.horizontal, Metrics.cardPadding)
            .frame(minHeight: Metrics.row)
        }
    }
}

// MARK: - Focus pulse

/// What the pulse is for, a picture of it at the chosen level, and the four levels. The note beside the
/// name says how the chosen level sounds.
private struct PulseGroup: View {
    @ObservedObject var c: FocusController

    var body: some View {
        let s = c.strings
        CardGroup(title: s.pulse, badge: "ADHD", note: s.pulseLevelHints[c.effect.rawValue]) {
            VStack(alignment: .leading, spacing: 10) {
                Text(s.pulseWhy).font(AppFont.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                PulseWave(depth: PulseWave.depth(for: c.effect))
                    .fill(c.effect == .off ? AnyShapeStyle(Color.primary.opacity(0.28)) : AnyShapeStyle(Palette.accent))
                    .frame(height: 40)
                    .animation(.easeInOut(duration: 0.3), value: c.effect)
                    .accessibilityHidden(true)
                Segmented(options: EffectChoice.allCases.map { ($0, s.effectNames[$0.rawValue]) },
                          selection: c.effect, height: Metrics.segmentedLarge, fill: true) { c.setEffect($0) }
            }
            .padding(Metrics.cardPadding)
        }
    }
}

/// Bars of a music waveform. The pulse makes them swell and dip in a steady rhythm; the higher the level,
/// the deeper the dips, and Off shows the music alone. The bars come from a fixed seed, so between levels
/// only the rhythm changes.
struct PulseWave: Shape {
    var depth: Double
    var bars = 66
    var barsPerPulse = 4

    static func depth(for level: EffectChoice) -> Double { [0, 0.3, 0.55, 0.85][level.rawValue] }

    var animatableData: Double {
        get { depth }
        set { depth = newValue }
    }

    func path(in rect: CGRect) -> Path {
        var random = SeededRandom(seed: 11)
        var path = Path()
        let step = rect.width / CGFloat(bars)
        let barWidth = min(2.2, step * 0.6)
        var envelope = 0.78
        for i in 0..<bars {
            envelope = min(1, max(0.5, envelope + (random.next() - 0.5) * 0.24))
            let jitter = 0.86 + random.next() * 0.14
            let phase = Double(i % barsPerPulse) / Double(barsPerPulse)
            let pulse = 1 - depth * (0.5 - 0.5 * cos(2 * .pi * phase))
            let height = CGFloat(max(1.4, Double(rect.height) * envelope * jitter * pulse))
            let x = rect.minX + CGFloat(i) * step + (step - barWidth) / 2
            path.addRoundedRect(in: CGRect(x: x, y: rect.midY - height / 2, width: barWidth, height: height),
                                cornerSize: CGSize(width: barWidth / 2, height: barWidth / 2))
        }
        return path
    }
}

// MARK: - Noise

/// Background noise: a switch line like Settings, six pictures, and the level while it plays. Off keeps the
/// last sound and the switch brings it back; a picture turns the noise on with that sound.
private struct NoiseGroup: View {
    @ObservedObject var settings: AppSettings
    let s: Strings

    var body: some View {
        let on = settings.noise != .off
        CardGroup(title: s.noise) {
            CardToggleRow(title: s.noiseRow, caption: s.noiseWhy,
                          isOn: Binding(get: { settings.noise != .off },
                                        set: { settings.noise = $0 ? settings.noisePick : .off }))
            Hairline()
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                ForEach(NoiseChoice.pictured, id: \.self) { choice in
                    NoiseTile(choice: choice, name: s.noiseName(choice),
                              selected: on && settings.noise == choice, dimmed: !on) { settings.noise = choice }
                }
            }
            .padding(EdgeInsets(top: Metrics.cardControlInset, leading: Metrics.cardPadding,
                                bottom: Metrics.cardPadding, trailing: Metrics.cardPadding))
            if on {
                Hairline()
                HStack(spacing: 10) {
                    Text(s.noiseLevel).font(AppFont.label).frame(width: 40, alignment: .leading)
                    Slider(value: $settings.noiseLevel, in: 0...1).tint(Palette.accent)
                        .accessibilityLabel(s.noiseLevel)
                    Text("\(Int((settings.noiseLevel * 100).rounded()))%")
                        .font(AppFont.body).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .padding(.horizontal, Metrics.cardPadding)
                .frame(minHeight: Metrics.row)
            }
        }
    }
}

/// One picture in the noise grid. Chosen: a teal check on the picture and a teal name. Under the pointer
/// the picture darkens a little (it has a shape of its own).
private struct NoiseTile: View {
    let choice: NoiseChoice
    let name: String
    let selected: Bool
    let dimmed: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 4) {
                NoisePicture(choice: choice)
                    .frame(height: 42)
                    .overlay { if hovering { Palette.hover } }
                    .clipShape(RoundedRectangle(Radius.control))
                    .overlay(alignment: .topTrailing) {
                        if selected {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Palette.accent))
                                .shadow(color: .black.opacity(0.25), radius: 1.5, y: 1)
                                .padding(4)
                        }
                    }
                Text(name)
                    .font(selected ? AppFont.captionStrong : AppFont.caption)
                    .foregroundStyle(selected ? AnyShapeStyle(Palette.accentText)
                                              : (dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)))
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .opacity(dimmed ? 0.55 : 1)
            .contentShape(Rectangle())
            .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Small pictures for the noise choices: a scene for each recording, and a grain for each noise colour
/// (brown coarse, pink medium, white fine). Drawn in an 88×48 box and stretched to the tile.
struct NoisePicture: View {
    let choice: NoiseChoice

    var body: some View {
        Canvas { context, size in
            context.scaleBy(x: size.width / 88, y: size.height / 48)
            switch choice {
            case .rain: Self.rain(&context)
            case .ocean: Self.waves(&context)
            case .stream: Self.stream(&context)
            case .brown:
                Self.grain(&context, colors: ("#926246", "#6C442E"),
                           dark: (11, 28, 2.4...5, Color(red: 40 / 255, green: 18 / 255, blue: 8 / 255, opacity: 0.28)),
                           light: (12, 22, 2...4.2, Color(red: 1, green: 222 / 255, blue: 196 / 255, opacity: 0.16)))
            case .pink:
                Self.grain(&context, colors: ("#EDAAC0", "#DA86A2"),
                           dark: (21, 80, 1...1.9, Color(red: 140 / 255, green: 40 / 255, blue: 80 / 255, opacity: 0.2)),
                           light: (22, 70, 0.9...1.7, Color.white.opacity(0.34)))
            case .white:
                Self.grain(&context, colors: ("#F8F9FB", "#E5E8ED"),
                           dark: (31, 300, 0.4...0.75, Color(red: 20 / 255, green: 22 / 255, blue: 26 / 255, opacity: 0.3)),
                           light: (32, 180, 0.35...0.65, Color.white.opacity(0.95)))
            case .off:
                break
            }
        }
        .accessibilityHidden(true)
    }

    private static let box = Path(CGRect(x: 0, y: 0, width: 88, height: 48))

    private static func vertical(_ colors: [Color]) -> GraphicsContext.Shading {
        .linearGradient(Gradient(colors: colors), startPoint: .zero, endPoint: CGPoint(x: 0, y: 48))
    }

    /// Rain on a dark green slope.
    private static func rain(_ context: inout GraphicsContext) {
        context.fill(box, with: vertical([Color(hex: "#7C97B2"), Color(hex: "#4E6884")]))
        var slope = Path()
        slope.move(to: CGPoint(x: 0, y: 37))
        slope.addCurve(to: CGPoint(x: 44, y: 34), control1: CGPoint(x: 14, y: 32), control2: CGPoint(x: 28, y: 36))
        slope.addCurve(to: CGPoint(x: 88, y: 34), control1: CGPoint(x: 60, y: 32), control2: CGPoint(x: 74, y: 31))
        slope.addLine(to: CGPoint(x: 88, y: 48))
        slope.addLine(to: CGPoint(x: 0, y: 48))
        slope.closeSubpath()
        context.fill(slope, with: .color(Color(red: 34 / 255, green: 62 / 255, blue: 50 / 255, opacity: 0.55)))
        var random = SeededRandom(seed: 3)
        var streaks = Path()
        for _ in 0..<30 {
            let x = random.next() * 96 - 4, y = random.next() * 36 - 4
            streaks.move(to: CGPoint(x: x, y: y))
            streaks.addLine(to: CGPoint(x: x - 2.2, y: y + 6.2))
        }
        context.stroke(streaks, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 1.1, lineCap: .round))
        context.fill(dots(seed: 5, count: 10, radius: 0.5...0.9, height: 30), with: .color(.white.opacity(0.5)))
    }

    /// Sky, sea with two lines of crests, foam and a pebble beach.
    private static func waves(_ context: inout GraphicsContext) {
        let sky = Color(hex: "#D4EAF5")
        context.fill(box, with: .linearGradient(
            Gradient(stops: [.init(color: sky, location: 0), .init(color: sky, location: 0.3),
                             .init(color: Color(hex: "#63A9CD"), location: 0.31), .init(color: Color(hex: "#2E78A2"), location: 1)]),
            startPoint: .zero, endPoint: CGPoint(x: 0, y: 48)))
        var beach = Path()
        beach.move(to: CGPoint(x: 0, y: 40))
        beach.addCurve(to: CGPoint(x: 56, y: 38), control1: CGPoint(x: 18, y: 36), control2: CGPoint(x: 36, y: 42))
        beach.addCurve(to: CGPoint(x: 88, y: 38), control1: CGPoint(x: 76, y: 34), control2: CGPoint(x: 80, y: 37))
        beach.addLine(to: CGPoint(x: 88, y: 48))
        beach.addLine(to: CGPoint(x: 0, y: 48))
        beach.closeSubpath()
        context.fill(beach, with: .color(Color(hex: "#DCCCA6")))
        var crests = Path()
        crests.addWave(from: CGPoint(x: -4, y: 21), segments: 10, length: 10, height: 3)
        crests.addWave(from: CGPoint(x: -8, y: 29), segments: 8, length: 12, height: 3.4)
        context.stroke(crests, with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        var foam = Path()
        foam.move(to: CGPoint(x: 0, y: 37.5))
        foam.addCurve(to: CGPoint(x: 56, y: 35.5), control1: CGPoint(x: 18, y: 33.5), control2: CGPoint(x: 36, y: 39.5))
        foam.addCurve(to: CGPoint(x: 88, y: 35.5), control1: CGPoint(x: 76, y: 31.5), control2: CGPoint(x: 80, y: 34.5))
        context.stroke(foam, with: .color(.white.opacity(0.95)), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
    }

    /// A stream winding through grass, with pebbles on the banks.
    private static func stream(_ context: inout GraphicsContext) {
        context.fill(box, with: vertical([Color(hex: "#AFD69E"), Color(hex: "#76AC66")]))
        var water = Path()
        water.move(to: CGPoint(x: 40, y: -4))
        water.addCurve(to: CGPoint(x: 48, y: 28), control1: CGPoint(x: 26, y: 10), control2: CGPoint(x: 62, y: 16))
        water.addCurve(to: CGPoint(x: 44, y: 54), control1: CGPoint(x: 34, y: 40), control2: CGPoint(x: 32, y: 42))
        context.stroke(water, with: .color(Color(hex: "#6DB5DF")), style: StrokeStyle(lineWidth: 10, lineCap: .round))
        var shine = Path()
        shine.move(to: CGPoint(x: 41, y: 1))
        shine.addCurve(to: CGPoint(x: 47, y: 27), control1: CGPoint(x: 33, y: 10), control2: CGPoint(x: 57, y: 16))
        shine.addCurve(to: CGPoint(x: 43, y: 50), control1: CGPoint(x: 37, y: 38), control2: CGPoint(x: 35, y: 41))
        context.stroke(shine, with: .color(.white.opacity(0.65)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
        var pebbles = Path()
        for (x, y, r) in [(30.0, 14.0, 2.0), (26, 33, 2.4), (62, 22, 2.2), (58, 40, 1.8), (22, 22, 1.4)] {
            pebbles.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        context.fill(pebbles, with: .color(Color(hex: "#DCD5C3")))
    }

    /// A diagonal colour with darker and lighter specks; bigger specks read as a deeper noise.
    private static func grain(_ context: inout GraphicsContext, colors: (String, String),
                              dark: (UInt32, Int, ClosedRange<Double>, Color),
                              light: (UInt32, Int, ClosedRange<Double>, Color)) {
        context.fill(box, with: .linearGradient(Gradient(colors: [Color(hex: colors.0), Color(hex: colors.1)]),
                                                startPoint: .zero, endPoint: CGPoint(x: 88, y: 48)))
        context.fill(dots(seed: dark.0, count: dark.1, radius: dark.2), with: .color(dark.3))
        context.fill(dots(seed: light.0, count: light.1, radius: light.2), with: .color(light.3))
    }

    private static func dots(seed: UInt32, count: Int, radius: ClosedRange<Double>, height: Double = 48) -> Path {
        var random = SeededRandom(seed: seed)
        var path = Path()
        for _ in 0..<count {
            let x = random.next() * 88, y = random.next() * height
            let r = radius.lowerBound + random.next() * (radius.upperBound - radius.lowerBound)
            path.addEllipse(in: CGRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r))
        }
        return path
    }
}

private extension Path {
    /// Arcs that alternate up and down along a line: wave crests.
    mutating func addWave(from start: CGPoint, segments: Int, length: CGFloat, height: CGFloat) {
        move(to: start)
        var x = start.x
        for k in 0..<segments {
            let dy = k % 2 == 0 ? -height : height
            addQuadCurve(to: CGPoint(x: x + length, y: start.y), control: CGPoint(x: x + length / 2, y: start.y + dy))
            x += length
        }
    }
}

/// Fixed-seed random numbers (mulberry32), so the pictures and the wave look the same every time.
struct SeededRandom {
    private var state: UInt32

    init(seed: UInt32) { state = seed }

    mutating func next() -> Double {
        state = state &+ 0x6D2B79F5
        var t = (state ^ (state >> 15)) &* (1 | state)
        t = (t &+ ((t ^ (t >> 7)) &* (61 | t))) ^ t
        return Double(t ^ (t >> 14)) / 4_294_967_296
    }
}
