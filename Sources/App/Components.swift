import AppKit
import SwiftUI

// Parts shared by the player and the grown panel. They take their look from DesignSystem.swift.

// MARK: - Cards and lines

enum CardStyle {
    /// Stronger fill, no edge. Used inside the grown panel.
    case solid
    /// See-through fill with an edge, so the glass and track colours show through (Today on the player).
    case glass
}

extension View {
    func cardBackground(_ style: CardStyle = .solid) -> some View {
        background(RoundedRectangle(Radius.card).fill(style == .glass ? Palette.glassCard : Palette.card))
            .overlay {
                if style == .glass { RoundedRectangle(Radius.card).strokeBorder(Palette.line, lineWidth: 1) }
            }
    }

    /// A hairline on the top (or bottom) edge of a row.
    func rowDivider(_ show: Bool = true, at alignment: Alignment = .top) -> some View {
        overlay(alignment: alignment) { if show { Hairline() } }
    }

    /// The small teal switch used for every on/off setting.
    func focusSwitch() -> some View {
        toggleStyle(.switch).controlSize(.small).tint(Palette.accent)
    }
}

struct Hairline: View {
    var vertical = false
    var body: some View {
        Rectangle().fill(Palette.hairline)
            .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
    }
}

// MARK: - Buttons

/// Icon-only button with a 28pt hit area. `filled` adds a small grey square behind the icon.
struct IconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 15
    var weight: Font.Weight = .medium
    var filled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .background { if filled { RoundedRectangle(Radius.small).fill(Palette.track) } }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(filled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
        .help(label)
        .accessibilityLabel(label)
    }
}

struct BackButton: View {
    let label: String
    let action: () -> Void
    var body: some View {
        IconButton(systemName: "chevron.left", label: label, size: 14, weight: .semibold, action: action)
    }
}

struct LikeButton: View {
    let liked: Bool
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: liked ? "heart.fill" : "heart")
                .font(.system(size: 14))
                .foregroundStyle(liked ? Palette.heart : Color.secondary)
                .frame(width: Metrics.iconButton, height: Metrics.iconButton)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// Icon-only button with no shape at rest; a soft circle shows only while the pointer is over it.
/// The player uses it for previous/next beside the play button, the heart next to the song title and the
/// music arrows.
struct RoundIconButton: View {
    let systemName: String
    let label: String
    var size: CGFloat = 15
    var weight: Font.Weight = .regular
    var diameter: CGFloat = Metrics.iconButton
    /// Icon colour; dark (primary) when nil.
    var tint: Color? = nil
    /// Grey at rest and dark under the pointer, for the quieter buttons (the music arrows).
    var quiet = false
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: weight))
                .foregroundStyle(iconStyle)
                .frame(width: diameter, height: diameter)
                .background { if hovering && isEnabled { Circle().fill(Palette.hover) } }
                .contentShape(Circle())
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }

    private var iconStyle: AnyShapeStyle {
        if let tint { return AnyShapeStyle(tint) }
        return quiet && !(hovering && isEnabled) ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
    }
}

enum PillKind {
    /// Teal, white text: Add.
    case primary
    /// Outlined, grey text: Remove.
    case secondary
    /// On the dark toast: Undo.
    case onDark
}

struct PillButtonStyle: ButtonStyle {
    let kind: PillKind

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(kind == .secondary ? AppFont.body : AppFont.bodyStrong)
            .foregroundStyle(kind == .secondary ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.white))
            .lineLimit(1)
            .padding(.horizontal, 12)
            .frame(height: Metrics.pillHeight)
            .background { shape }
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }

    @ViewBuilder private var shape: some View {
        switch kind {
        case .primary: Capsule().fill(Palette.accent)
        case .secondary: Capsule().strokeBorder(Palette.line, lineWidth: 1)
        case .onDark: Capsule().fill(Palette.toastButton)
        }
    }
}

extension ButtonStyle where Self == PillButtonStyle {
    static func pill(_ kind: PillKind) -> PillButtonStyle { PillButtonStyle(kind: kind) }
}

// MARK: - Choices

/// Round choice mark: grey ring when off, teal ring with a dot when on.
struct RadioDot: View {
    let on: Bool
    var body: some View {
        ZStack {
            Circle().strokeBorder(on ? Palette.accent : Color.secondary, lineWidth: 2)
            if on { Circle().fill(Palette.accent).frame(width: 6, height: 6) }
        }
        .frame(width: 16, height: 16)
    }
}

/// Segments in a grey track. `height` is the segment; the track adds 2pt around it. `notes` puts a grey
/// word after each label (the playlist's song counts).
struct Segmented<T: Hashable>: View {
    let options: [(T, String)]
    let selection: T
    var height: CGFloat = Metrics.segmented
    var fill = false
    var hPadding: CGFloat = 9
    var notes: [String]? = nil
    let onSelect: (T) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { i in
                let (value, label) = options[i]
                SegmentCell(label: label, note: notes.flatMap { $0.indices.contains(i) ? $0[i] : nil },
                            on: value == selection, height: height, fill: fill, hPadding: hPadding) { onSelect(value) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(Radius.control).fill(Palette.track))
    }
}

/// One option of `Segmented`: raised and bold when chosen. Under the pointer an option shows the grey
/// hover shape; the chosen one (already raised) darkens a little.
private struct SegmentCell: View {
    let label: String
    var note: String? = nil
    let on: Bool
    let height: CGFloat
    let fill: Bool
    let hPadding: CGFloat
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label).font(on ? AppFont.bodyStrong : AppFont.body)
                if let note { Text(note).font(AppFont.body).foregroundStyle(.tertiary).monospacedDigit() }
            }
                .lineLimit(1)
                .padding(.horizontal, hPadding)
                .frame(maxWidth: fill ? .infinity : nil, minHeight: height, maxHeight: height)
                .background {
                    ZStack {
                        RoundedRectangle(Radius.small).fill(on ? Palette.raised : .clear)
                            .shadow(color: .black.opacity(on ? 0.12 : 0), radius: 1, y: 1)
                        if hovering { RoundedRectangle(Radius.small).fill(Palette.hover.opacity(on ? 0.5 : 1)) }
                    }
                }
                .contentShape(Rectangle())
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? .primary : .secondary)
        .onHover { hovering = $0 }
    }
}

/// Preset button in a row of equal chips (timer lengths, pomodoro presets).
struct Chip: View {
    let label: String
    let selected: Bool
    var height: CGFloat = 30
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(AppFont.bodyStrong)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(RoundedRectangle(Radius.control).fill(selected ? Palette.raised : Palette.card))
                // The chip already has a shape, so under the pointer that shape darkens.
                .overlay { if hovering { RoundedRectangle(Radius.control).fill(Palette.hover.opacity(selected ? 0.5 : 1)) } }
                .overlay(RoundedRectangle(Radius.control).strokeBorder(selected ? Palette.accent : Palette.line, lineWidth: 1))
                .contentShape(Rectangle())
                .animation(Motion.hover, value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

// MARK: - Headers and numbers

/// Title row of the player's Timer & Sound page.
struct PageHeader: View {
    let title: String
    let back: String
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            // Pulls the 28pt hit area into the margin so the chevron lines up with the content edge.
            BackButton(label: back, action: onBack).padding(.leading, -6)
            Text(title).font(AppFont.pageTitle)
            Spacer()
        }
        .frame(height: Metrics.iconButton)
    }
}

// MARK: - Grouped cards (Settings, Timer & Sound)

/// A group the way Settings shows it: a grey name above a solid card. The name can carry a small teal
/// badge and a grey note at the right end. Put `Hairline()` between the rows inside.
struct CardGroup<Content: View>: View {
    let title: String
    var badge: String?
    var note: String?
    let content: Content

    init(title: String, badge: String? = nil, note: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.note = note
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 6) {
                Text(title).font(AppFont.bodyStrong).foregroundStyle(.secondary)
                if let badge {
                    Text(badge)
                        .font(AppFont.microStrong)
                        .foregroundStyle(Palette.accentText)
                        .padding(.horizontal, 6)
                        .frame(height: 16)
                        .background(Capsule().fill(Palette.accentWash))
                }
                Spacer(minLength: 8)
                if let note { Text(note).font(AppFont.caption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            VStack(alignment: .leading, spacing: 0) { content }
                .cardBackground()
        }
    }
}

/// One line in a card group: a name on the left and its control on the right. The control keeps its full
/// size; a name that doesn't fit wraps instead.
struct CardRow<Control: View>: View {
    let label: String
    var divider = false
    let control: Control

    init(label: String, divider: Bool = false, @ViewBuilder control: () -> Control) {
        self.label = label
        self.divider = divider
        self.control = control()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(AppFont.label)
            Spacer(minLength: 8)
            control.fixedSize()
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(minHeight: Metrics.row)
        .rowDivider(divider)
    }
}

/// A card line with a name, a grey second line and a switch.
struct CardToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var divider = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(AppFont.label)
                Text(caption).font(AppFont.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn).labelsHidden().focusSwitch()
                .accessibilityLabel(title)
        }
        .padding(.horizontal, Metrics.cardPadding)
        .frame(minHeight: Metrics.rowTwoLine)
        .rowDivider(divider)
    }
}

/// Small grey label over a number (History totals).
struct StatBlock: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(AppFont.caption).foregroundStyle(.secondary)
            Text(value).font(AppFont.stat).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }
    }
}

// MARK: - Bars and covers

/// Played stretches of a day on a bar spanning 18 hours from the day start.
/// The "now" mark sticks out 3pt above and below the bar without taking layout space.
struct DayBar: View {
    let rows: [DayRow]
    let dayStart: Date
    let now: Date?
    var height: CGFloat = 10
    var span: TimeInterval = 18 * 3600

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            Capsule().fill(Palette.track)
                .overlay(alignment: .topLeading) {
                    // An explicit leading stack: on its own the overlay centres stretches of different
                    // widths on one another, which drew short ones off their time.
                    ZStack(alignment: .topLeading) {
                        ForEach(rows.filter { $0.kind == .play }) { row in
                            let x = CGFloat(row.start.timeIntervalSince(dayStart) / span) * w
                            let width = max(2, CGFloat(row.seconds / span) * w)
                            RoundedRectangle(min(3, width / 2)).fill(Palette.accent)
                                .frame(width: width, height: height)
                                .offset(x: x)
                        }
                    }
                }
                .overlay(alignment: .topLeading) {
                    if let now {
                        let x = CGFloat(now.timeIntervalSince(dayStart) / span) * w
                        if x >= 0 && x <= w {
                            RoundedRectangle(1).fill(Color.primary)
                                .frame(width: 2, height: height + 6)
                                .offset(x: x - 1, y: -3)
                        }
                    }
                }
        }
        .frame(height: height)
    }
}

struct ProgressBar: View {
    let value: Double
    var height: CGFloat = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track)
                Capsule().fill(Palette.accent).frame(width: geo.size.width * CGFloat(min(1, max(0, value))))
            }
        }
        .frame(height: height)
    }
}

/// A `ProgressBar` you can click or drag to move through a song (the Library preview).
/// A knob shows while the pointer is over it or dragging. The hit area is taller than the bar, but the
/// layout height stays the bar's, so it sits exactly where a `ProgressBar` would.
struct SeekBar: View {
    let value: Double
    var height: CGFloat = 4
    var enabled = true
    /// The spot under the pointer while dragging, nil once the drag ends, so the caller can show that time.
    var onScrub: (Double?) -> Void = { _ in }
    /// Where to move, as a fraction of the song, when the click or drag ends.
    let onSeek: (Double) -> Void

    @State private var hovering = false
    @State private var dragValue: Double?
    private let hitHeight: CGFloat = 16
    private let knob: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let shown = CGFloat(min(1, max(0, dragValue ?? value)))
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.track).frame(height: height)
                Capsule().fill(Palette.accent).frame(width: width * shown, height: height)
                if enabled && (hovering || dragValue != nil) {
                    Circle().fill(Palette.accent).frame(width: knob, height: knob)
                        .offset(x: min(max(0, width * shown - knob / 2), width - knob))
                }
            }
            .frame(width: width, height: hitHeight)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        guard enabled else { return }
                        let f = fraction(g.location.x, width)
                        dragValue = f
                        onScrub(f)
                    }
                    .onEnded { g in
                        guard enabled else { return }
                        let f = fraction(g.location.x, width)
                        dragValue = nil
                        onScrub(nil)
                        onSeek(f)
                    }
            )
        }
        .frame(height: hitHeight)
        .onHover { hovering = $0 }
        .padding(.vertical, -(hitHeight - height) / 2)
    }

    private func fraction(_ x: CGFloat, _ width: CGFloat) -> Double {
        Double(min(1, max(0, x / width)))
    }
}

struct CoverView: View {
    let colors: [Color]
    let size: CGFloat
    /// The song's cover (generated with Suno); without one (or if it can't be read) the colours are drawn instead.
    var image: URL? = nil

    var body: some View {
        let c = colors.count >= 3 ? colors : [.blue, .cyan, .purple]
        ZStack {
            if let image, let picture = CoverImages.shared.image(image) {
                Image(nsImage: picture).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
            } else {
                LinearGradient(colors: [c[2], c[0]], startPoint: .topLeading, endPoint: .bottomTrailing)
                RadialGradient(colors: [c[0], c[0].opacity(0)], center: UnitPoint(x: 0.28, y: 0.30), startRadius: 0, endRadius: size * 0.62)
                RadialGradient(colors: [c[1], c[1].opacity(0)], center: UnitPoint(x: 0.78, y: 0.72), startRadius: 0, endRadius: size * 0.66)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(size * 0.225))
        .overlay(RoundedRectangle(size * 0.225).strokeBorder(.white.opacity(0.35), lineWidth: 1))
        .shadow(color: .black.opacity(0.15), radius: 3, y: 2)
    }
}

/// Cover pictures, read once from the library folder (small JPEGs made by Scripts/build_library.py).
@MainActor
final class CoverImages {
    static let shared = CoverImages()
    private let cache = NSCache<NSURL, NSImage>()

    func image(_ url: URL) -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        guard let picture = NSImage(contentsOf: url) else { return nil }
        cache.setObject(picture, forKey: url as NSURL)
        return picture
    }
}
