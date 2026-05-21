#!/usr/bin/env swift
// scripts/render-dmg-background.swift
//
// Renders Resources/dmg-background.png and dmg-background@2x.png — the
// header + chevron-arrow artwork shown behind the icons when a user mounts
// Rubien-<version>.dmg in Finder. Run this once after editing the layout or
// branding; the resulting PNGs are committed to git so the release build
// itself doesn't depend on Swift being available.
//
// Run from the project root:
//   ./scripts/render-dmg-background.swift
//
// Layout matches the create-dmg invocation in scripts/build-app.sh:
//   window      660 x 400 px
//   icon size   100 px
//   Rubien.app  centered at (165, 200)
//   Applications drop-link centered at (495, 200)
// The PNG provides everything BEHIND the icons: light gradient,
// "To install, drag Rubien to Applications" header, and three chevron
// arrows sitting between the icon slots.

import AppKit
import Foundation

let projectRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let resourcesDir = projectRoot.appendingPathComponent("Resources", isDirectory: true)
try? FileManager.default.createDirectory(at: resourcesDir, withIntermediateDirectories: true)

func render(scale: CGFloat, to file: URL) throws {
    let width = 660
    let height = 400
    let pixelsWide = Int(CGFloat(width) * scale)
    let pixelsHigh = Int(CGFloat(height) * scale)

    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        fatalError("Failed to allocate NSBitmapImageRep")
    }
    rep.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: scale, y: scale)

    // 1. Light gradient backdrop (top: warm cream, bottom: cool gray-blue)
    //    — borrows the Dia.app reference palette feel without copying it.
    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.99, green: 0.97, blue: 0.95, alpha: 1.0),
        NSColor(srgbRed: 0.94, green: 0.95, blue: 0.97, alpha: 1.0),
    ])!
    gradient.draw(in: NSRect(x: 0, y: 0, width: width, height: height), angle: -90)

    // 2. Header text: "To install, drag Rubien to Applications"
    //    Bold "Rubien" and "Applications", regular for the rest.
    //    NSAttributedString must be drawn flipped because AppKit's default
    //    coordinate origin is bottom-left.
    let header = NSMutableAttributedString()
    let regular = NSFont.systemFont(ofSize: 18, weight: .regular)
    let bold = NSFont.systemFont(ofSize: 18, weight: .semibold)
    let textColor = NSColor(srgbRed: 0.15, green: 0.18, blue: 0.22, alpha: 1.0)

    func append(_ text: String, _ font: NSFont) {
        header.append(NSAttributedString(string: text, attributes: [
            .font: font,
            .foregroundColor: textColor,
        ]))
    }
    append("To install, drag ", regular)
    append("Rubien", bold)
    append(" to ", regular)
    append("Applications", bold)

    let headerSize = header.size()
    let headerRect = NSRect(
        x: (CGFloat(width) - headerSize.width) / 2,
        y: CGFloat(height) - 80,
        width: headerSize.width,
        height: headerSize.height
    )
    header.draw(in: headerRect)

    // 3. Three chevron arrows between the icon slots. Centered around the
    //    horizontal midpoint, vertically aligned with where Finder places
    //    the icons (~y=200 from the top = 200 px from the bottom in flipped
    //    AppKit coords).
    let chevronSize: CGFloat = 36
    let chevronColors: [NSColor] = [
        NSColor(srgbRed: 0.60, green: 0.62, blue: 0.65, alpha: 0.6),
        NSColor(srgbRed: 0.45, green: 0.48, blue: 0.52, alpha: 0.8),
        NSColor(srgbRed: 0.20, green: 0.22, blue: 0.25, alpha: 1.0),
    ]
    let chevronCenterY = CGFloat(height) - 200
    let chevronSpacing: CGFloat = 22
    let totalChevronWidth = chevronSpacing * CGFloat(chevronColors.count - 1)
    let firstChevronX = CGFloat(width) / 2 - totalChevronWidth / 2
    for (idx, color) in chevronColors.enumerated() {
        let cx = firstChevronX + CGFloat(idx) * chevronSpacing
        let chevronText = NSAttributedString(string: "›", attributes: [
            .font: NSFont.systemFont(ofSize: chevronSize, weight: .medium),
            .foregroundColor: color,
        ])
        let size = chevronText.size()
        let rect = NSRect(
            x: cx - size.width / 2,
            y: chevronCenterY - size.height / 2,
            width: size.width,
            height: size.height
        )
        chevronText.draw(in: rect)
    }

    // 4. Save as PNG.
    guard let data = rep.representation(using: .png, properties: [:]) else {
        fatalError("Failed to serialize PNG")
    }
    try data.write(to: file)
    print("   ✓ wrote \(file.path) (\(pixelsWide) x \(pixelsHigh))")
}

try render(scale: 1, to: resourcesDir.appendingPathComponent("dmg-background.png"))
try render(scale: 2, to: resourcesDir.appendingPathComponent("dmg-background@2x.png"))
