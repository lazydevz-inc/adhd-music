import AppKit
import SwiftUI

// Shared design values. Every screen takes its colors, text sizes, corners and spacing from here,
// so a look changes in one place.

// MARK: - Color

enum Palette {
    // Accent and status
    static let accent = Color(red: 43 / 255, green: 159 / 255, blue: 178 / 255)
    /// Teal for small text and links. Lighter in dark appearance so it stays readable.
    static let accentText = dynamic(light: (31, 127, 144, 1), dark: (110, 202, 219, 1))
    /// Teal wash behind something that is on: a running timer, a set task, the song being previewed.
    static let accentWash = accent.opacity(0.14)
    /// `accentWash` under the pointer: the timer chip while it counts.
    static let accentWashHover = accent.opacity(0.24)
    /// Edge on a teal wash.
    static let accentEdge = accent.opacity(0.38)
    /// Ring around a text field being edited.
    static let accentFocus = accent.opacity(0.55)
    static let heart = Color(red: 224 / 255, green: 86 / 255, blue: 107 / 255)
    static let flagText = dynamic(light: (160, 86, 11, 1), dark: (242, 170, 98, 1))
    static let flagFill = Color(red: 232 / 255, green: 146 / 255, blue: 46 / 255).opacity(0.16)

    // Surfaces on the glass
    /// Solid card: History totals, the day card, Settings groups, the preview bar, chips at rest.
    static let card = dynamic(light: (255, 255, 255, 0.55), dark: (255, 255, 255, 0.07))
    /// See-through card that lets the glass show (Today on the player). Always drawn with `line`.
    static let glassCard = dynamic(light: (255, 255, 255, 0.24), dark: (255, 255, 255, 0.05))
    /// Sidebars of the grown panel.
    static let sidebar = dynamic(light: (255, 255, 255, 0.275), dark: (255, 255, 255, 0.035))
    /// Empty part of bars, the track of segmented controls, small filled buttons.
    static let track = dynamic(light: (0, 0, 0, 0.08), dark: (255, 255, 255, 0.12))
    /// Grey that shows behind something clickable while the pointer is over it, where it has no shape of
    /// its own: icon buttons, the task line, the Today card. On a teal fill it shades the teal the same way.
    static let hover = track
    /// Raised surface: the selected segment or chip, a key cap, a text field.
    static let raised = dynamic(light: (255, 255, 255, 1), dark: (255, 255, 255, 0.22))
    /// Timer chip at rest.
    static let chip = dynamic(light: (255, 255, 255, 0.45), dark: (255, 255, 255, 0.08))

    // Lines
    /// Edge of see-through cards and of outlined controls (chips, Remove, key cap).
    static let line = dynamic(light: (0, 0, 0, 0.10), dark: (255, 255, 255, 0.12))
    /// Dividers between rows and between areas.
    static let hairline = Color.primary.opacity(0.08)

    // One-off pictures
    /// Sample menu bar behind the icon previews in Settings.
    static let menuBarSample = [Color(hex: "#2B66B9"), Color(hex: "#3C7ACB")]
    static let toast = Color.black.opacity(0.85)
    static let toastButton = Color.white.opacity(0.18)

    private static func dynamic(light: (Double, Double, Double, Double), dark: (Double, Double, Double, Double)) -> Color {
        func ns(_ c: (Double, Double, Double, Double)) -> NSColor {
            NSColor(srgbRed: c.0 / 255, green: c.1 / 255, blue: c.2 / 255, alpha: c.3)
        }
        let lightColor = ns(light), darkColor = ns(dark)
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkColor : lightColor
        })
    }
}

// MARK: - Text

/// Text roles. Icon sizes stay with the parts that draw them.
enum AppFont {
    /// Today's total on the player.
    static let clock = Font.system(size: 50, weight: .semibold)
    /// A day's total in History, songs in Mix in Library.
    static let bigNumber = Font.system(size: 22, weight: .bold)
    /// Month in History.
    static let heading = Font.system(size: 18, weight: .bold)
    /// Totals in History.
    static let stat = Font.system(size: 16, weight: .semibold)
    /// Sound, Timer.
    static let pageTitle = Font.system(size: 15, weight: .semibold)
    /// Row names in the grown panel, the music choice, effect levels.
    static let label = Font.system(size: 13)
    static let labelStrong = Font.system(size: 13, weight: .semibold)
    /// Most text on the player and in notes.
    static let body = Font.system(size: 12)
    /// Section names, song titles, buttons.
    static let bodyStrong = Font.system(size: 12, weight: .semibold)
    /// Second lines and small labels.
    static let caption = Font.system(size: 11)
    static let captionStrong = Font.system(size: 11, weight: .semibold)
    /// Hour marks and times inside calendar cells.
    static let micro = Font.system(size: 10)
    /// Tags: Preview, More/Less.
    static let microStrong = Font.system(size: 10, weight: .semibold)
}

// MARK: - Motion

enum Motion {
    /// Hover looks come and go at this pace everywhere.
    static let hover = Animation.easeOut(duration: 0.12)
}

// MARK: - Corners

enum Radius {
    /// Small tags.
    static let badge: CGFloat = 4
    /// Selected segment, key cap, small square buttons.
    static let small: CGFloat = 6
    /// Controls and list rows: segmented track, chips, text fields, calendar cells.
    static let control: CGFloat = 8
    /// Cards.
    static let card: CGFloat = 10
    /// Hover shape around the player's song row: the 40pt cover (corner 9) sits 4pt inside, so 9 + 4.
    static let songRow: CGFloat = 13
    /// The player panel.
    static let panel: CGFloat = 18
    /// The grown panel (History, Library, Settings).
    static let panelExpanded: CGFloat = 16
}

extension RoundedRectangle {
    /// Every rounded shape in the app uses continuous (Apple-style) corners.
    init(_ radius: CGFloat) { self.init(cornerRadius: radius, style: .continuous) }
}

// MARK: - Sizes and spacing

enum Metrics {
    static let compactWidth: CGFloat = 320
    static let expandedSize = CGSize(width: 840, height: 560)
    /// Player panel. The first row is 28pt tall with its text in the middle, so 14 on top reads like the 16 elsewhere.
    static let compactInsets = EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16)
    /// Gap between groups on the player.
    static let compactSpacing: CGFloat = 12
    /// Gap between the titled card groups on the player's Timer & Sound page.
    static let groupSpacing: CGFloat = 14
    /// Content of every grown-panel page, so nothing jumps when switching tabs.
    static let pageInsets = EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)
    static let sidebarWidth: CGFloat = 200
    static let sidebarInsets = EdgeInsets(top: 16, leading: 12, bottom: 16, trailing: 12)
    /// Text inside sidebar rows; with `sidebarInsets` it starts 20pt from the edge, like page content.
    static let sidebarItemInset: CGFloat = 8
    /// Tab bar of the grown panel.
    static let headerHeight: CGFloat = 44
    /// Inner padding of cards.
    static let cardPadding: CGFloat = 12
    /// Card padding next to a line of text. Text carries about 2–3pt of its own space, so 10 reads like 12.
    static let cardTextEdge: CGFloat = 10
    /// Inset around a full-width control row inside a card (segments, a row of chips).
    static let cardControlInset: CGFloat = 10
    /// Hit area of every icon-only button.
    static let iconButton: CGFloat = 28
    /// Previous/next beside the play button (icon 20).
    static let transportButton: CGFloat = 44
    /// Song row on the player: the cover lines up with the previous button's icon (37 in from the left).
    static let songRowInset: CGFloat = 37
    /// The heart's 28pt button sits right under the music row's › button. That row is 192 wide and centred,
    /// so 48 in from the right. (It used to sit under the next button's icon, which left too wide a gap.)
    static let songRowHeartInset: CGFloat = 48
    static let pillHeight: CGFloat = 26
    /// Segment height inside the 2pt track: regular 24 (28 overall), large 28 (32 overall).
    static let segmented: CGFloat = 24
    static let segmentedLarge: CGFloat = 28
    /// Settings rows with one line and with two lines.
    static let row: CGFloat = 40
    static let rowTwoLine: CGFloat = 48
}
