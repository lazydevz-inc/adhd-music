// Draws the dmg window background: light glass, a faint teal glow behind the app icon, and the icon's
// waveform stretched into the arrow towards Applications.
// The waveform arrow is the app icon's headset-and-wave design, which is not under the MIT License:
// copyright lazydevz Inc., all rights reserved. See ASSETS.md.
// usage: swift dmg_background.swift <out.png> <scale 1|2> <app name>
// Window is 640 × 400 pt; Finder puts the app icon centre at (170, 176) and Applications at (470, 176).
import AppKit

let args = CommandLine.arguments
let out = args[1]
let scale = CGFloat(Double(args[2]) ?? 1)
let appName = args.count > 3 ? args[3] : "ADHD Music"
let W: CGFloat = 640, H: CGFloat = 400

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * scale), pixelsHigh: Int(H * scale),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
let base = NSGraphicsContext(bitmapImageRep: rep)!
let cg = base.cgContext
cg.translateBy(x: 0, y: H)
cg.scaleBy(x: 1, y: -1)                         // y grows downward from here on
NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!

// Background: top #FBFCFD → bottom #EEF2F5
let bg = CGGradient(colorsSpace: space, colors: [rgb(0xFBFCFD).cgColor, rgb(0xEEF2F5).cgColor] as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bg, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 0, y: H), options: [])

// Teal glow behind the app icon: ellipse 260 × 200 at (170, 176), 16% fading out by 70%.
cg.saveGState()
cg.translateBy(x: 170, y: 176)
cg.scaleBy(x: 1, y: 200 / 260)
let glow = CGGradient(colorsSpace: space, colors: [rgb(0x61ACBC, 0.16).cgColor, rgb(0x61ACBC, 0).cgColor] as CFArray, locations: [0, 0.7])!
cg.drawRadialGradient(glow, startCenter: .zero, startRadius: 0, endCenter: .zero, endRadius: 260, options: [])
cg.restoreGState()

// The waveform line (same shape as the icon's wave, all rights reserved: see the top of this file),
// then the arrow head.
func arc(_ p: CGMutablePath, cx: CGFloat, cy: CGFloat, r: CGFloat, from a0: CGFloat, to a1: CGFloat) {
    let steps = 48
    for i in 1...steps {
        let t = a0 + (a1 - a0) * CGFloat(i) / CGFloat(steps)
        p.addLine(to: CGPoint(x: cx + r * cos(t), y: cy + r * sin(t)))
    }
}
let wave = CGMutablePath()
wave.move(to: CGPoint(x: 246, y: 176))
wave.addLine(to: CGPoint(x: 297.5, y: 176))
wave.addLine(to: CGPoint(x: 297.5, y: 164))
arc(wave, cx: 305, cy: 164, r: 7.5, from: .pi, to: 2 * .pi)      // over the top
wave.addLine(to: CGPoint(x: 312.5, y: 188))
arc(wave, cx: 320, cy: 188, r: 7.5, from: .pi, to: 0)            // under the bottom
wave.addLine(to: CGPoint(x: 327.5, y: 164))
arc(wave, cx: 335, cy: 164, r: 7.5, from: .pi, to: 2 * .pi)
wave.addLine(to: CGPoint(x: 342.5, y: 176))
wave.addLine(to: CGPoint(x: 392, y: 176))
let head = CGMutablePath()
head.move(to: CGPoint(x: 386, y: 169))
head.addLine(to: CGPoint(x: 394, y: 176))
head.addLine(to: CGPoint(x: 386, y: 183))
cg.setStrokeColor(rgb(0x61ACBC).cgColor)
cg.setLineWidth(2.5)
cg.setLineCap(.round)
cg.setLineJoin(.round)
cg.addPath(wave); cg.strokePath()
cg.addPath(head); cg.strokePath()

// Two lines of text under the icons' names.
func centred(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, top: CGFloat, kern: CGFloat = 0) {
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight),
                                                 .foregroundColor: color, .paragraphStyle: style, .kern: kern]
    NSAttributedString(string: text, attributes: attrs).draw(in: NSRect(x: 0, y: top, width: W, height: size * 1.6))
}
centred("Drag \(appName) into Applications", size: 13, weight: .regular, color: rgb(0x5B5E66), top: 318)
centred("Free · macOS 26 or later · Apple silicon", size: 11, weight: .regular, color: rgb(0x9CA0A8), top: 342, kern: 0.2)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
