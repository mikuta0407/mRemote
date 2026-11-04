// Draws the app icon: a remote screen with a shell prompt on it, for a
// client of both remote desktops (RDP) and shells (SSH).
//
// Usage: swift tools/AppIcon/make-app-icon.swift App/Assets.xcassets/AppIcon.appiconset
//
// Writes the three 1024px appearances the asset catalog names: light (opaque,
// as App Store Connect wants it), dark (on a clear ground, which the system
// fills) and tinted (grayscale, which the system colours).

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let side = CGFloat(size)

enum Appearance: String, CaseIterable {
    case light = "AppIcon-light.png"
    case dark = "AppIcon-dark.png"
    case tinted = "AppIcon-tinted.png"
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: alpha)
}

func gray(_ white: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(gray: white, alpha: alpha)
}

func draw(_ appearance: Appearance, in c: CGContext) {
    // Core Graphics counts up from the bottom; the drawing below is laid out
    // from the top, as the icon is looked at.
    c.translateBy(x: 0, y: side)
    c.scaleBy(x: 1, y: -1)

    // The ground: a deep blue falling to teal, top left to bottom right.
    switch appearance {
    case .light:
        let gradient = CGGradient(
            colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
            colors: [color(0x1E3A8A), color(0x0E7490)] as CFArray,
            locations: [0, 1])!
        c.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: side, y: side), options: [])
    case .dark, .tinted:
        break
    }

    let frameColor: CGColor
    let screenColor: CGColor
    let promptColor: CGColor
    switch appearance {
    case .light:
        frameColor = gray(1)
        screenColor = color(0x0B1220)
        promptColor = color(0x5EEAD4)
    case .dark:
        frameColor = color(0x93C5FD)
        screenColor = color(0x0B1220)
        promptColor = color(0x5EEAD4)
    case .tinted:
        frameColor = gray(1)
        screenColor = gray(0.12)
        promptColor = gray(0.85)
    }

    // The screen: a wide rounded display, set a little above centre so the
    // stand under it balances the whole.
    let screen = CGRect(x: 172, y: 236, width: 680, height: 470)
    let bezel: CGFloat = 40
    c.setFillColor(frameColor)
    c.addPath(CGPath(roundedRect: screen, cornerWidth: 72, cornerHeight: 72, transform: nil))
    c.fillPath()
    let glass = screen.insetBy(dx: bezel, dy: bezel)
    c.setFillColor(screenColor)
    c.addPath(CGPath(roundedRect: glass, cornerWidth: 36, cornerHeight: 36, transform: nil))
    c.fillPath()

    // The stand: a neck and a foot.
    c.setFillColor(frameColor)
    c.fill(CGRect(x: 472, y: screen.maxY - 2, width: 80, height: 88))
    c.addPath(CGPath(
        roundedRect: CGRect(x: 352, y: screen.maxY + 76, width: 320, height: 48),
        cornerWidth: 24, cornerHeight: 24, transform: nil))
    c.fillPath()

    // The prompt, ">_", large enough to read at the smallest sizes.
    c.setStrokeColor(promptColor)
    c.setLineWidth(52)
    c.setLineCap(.round)
    c.setLineJoin(.round)
    let left = glass.minX + 96
    let middle = glass.midY
    c.move(to: CGPoint(x: left, y: middle - 100))
    c.addLine(to: CGPoint(x: left + 116, y: middle))
    c.addLine(to: CGPoint(x: left, y: middle + 100))
    c.strokePath()
    c.move(to: CGPoint(x: left + 200, y: middle + 100))
    c.addLine(to: CGPoint(x: left + 360, y: middle + 100))
    c.strokePath()
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "App/Assets.xcassets/AppIcon.appiconset")
for appearance in Appearance.allCases {
    let alpha: CGImageAlphaInfo = appearance == .light ? .noneSkipLast : .premultipliedLast
    guard let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: alpha.rawValue)
    else { fatalError("no context for \(appearance)") }
    draw(appearance, in: context)
    let url = output.appendingPathComponent(appearance.rawValue)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("cannot write \(url.path)") }
    print("wrote \(url.path)")
}
