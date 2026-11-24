import SwiftUI

// Hover rule for everything you can press: a part with no shape of its own shows a grey
// `Palette.hover` shape behind it while the pointer is over it (a circle for icons, a rounded
// rectangle for rows and text links); a part that already has a shape draws that shape darker.

struct HoverFill<S: Shape>: ViewModifier {
    let shape: S
    var enabled = true
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background { if hovering && enabled { shape.fill(Palette.hover) } }
            .contentShape(shape)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: hovering)
    }
}

extension View {
    /// Grey `shape` behind a shapeless pressable part while the pointer is over it.
    func hoverFill<S: Shape>(_ shape: S, enabled: Bool = true) -> some View {
        modifier(HoverFill(shape: shape, enabled: enabled))
    }
}

/// A text link (Show in Library, ‹ November): teal text with a small chevron, grey rounded
/// rectangle behind it on hover. `leading` puts the chevron first (back), else after the text.
struct LinkButton: View {
    let title: String
    var leading = false
    var font: Font = AppFont.bodyStrong
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 2) {
                if leading { Image(systemName: "chevron.left").font(.system(size: 12, weight: .semibold)) }
                Text(title)
                if !leading { Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).opacity(0.6) }
            }
            .font(font)
            .foregroundStyle(Palette.accentText)
            .padding(.leading, leading ? 4 : 8)
            .padding(.trailing, leading ? 10 : 6)
            .frame(height: Metrics.iconButton)
            .hoverFill(RoundedRectangle(Radius.control))
        }
        .buttonStyle(.plain)
        // The hit area reaches into the margin so the text lines up with the content edge.
        .padding(.leading, -8)
    }
}
