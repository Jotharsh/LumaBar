// Builds every image the app uses from the SVGs in branding/. Run from the repo root:  swift scripts/make_icon.swift
//
//   Resources/AppIcon.icns      the app icon (detailed art for 128 px and up, a bolder simplified one for small sizes)
//   Resources/MenuBarOn.png     one-colour menu bar glyphs (macOS tints them for light/dark mode)
//   Resources/MenuBarOff.png
//   docs/logo.png               the logo shown in the README
import AppKit

func render(_ svg: String, size: Int) throws -> Data {
    guard let image = NSImage(contentsOf: URL(fileURLWithPath: svg)) else { fatalError("cannot load \(svg)") }
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor.clear.set(); NSRect(x: 0, y: 0, width: size, height: size).fill()
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

// macOS wants each size at 1x and 2x. Small renditions use the simplified artwork so they stay readable.
for (base, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"), (128, "128x128"),
                     (256, "128x128@2x"), (256, "256x256"), (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    let svg = base <= 64 ? "branding/icon-small.svg" : "branding/icon.svg"
    try render(svg, size: base).write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "Resources/AppIcon.icns"]
try task.run(); task.waitUntilExit()
try? fm.removeItem(atPath: iconset)

// Menu bar glyphs: drawn at 72 px and shown at 18 pt, so they stay sharp on Retina screens.
try render("branding/menubar-on.svg", size: 72).write(to: URL(fileURLWithPath: "Resources/MenuBarOn.png"))
try render("branding/menubar-off.svg", size: 72).write(to: URL(fileURLWithPath: "Resources/MenuBarOff.png"))
try render("branding/icon.svg", size: 512).write(to: URL(fileURLWithPath: "docs/logo.png"))
print("Wrote Resources/AppIcon.icns, Resources/MenuBarOn.png, Resources/MenuBarOff.png, docs/logo.png")
