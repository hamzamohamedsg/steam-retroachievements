// Draws the app icon: a gold pixel-art trophy on a Steam-blue rounded square.
// Writes Resources/AppIcon.icns (macOS), Resources/AppIcon.ico (Windows) and docs/icon.png (README, Linux).
// Run: swift scripts/make-icon.swift
import AppKit

// G gold, L highlight, D shade, W sparkle; one character per pixel, top row first.
let art = [
    "..............W.",
    ".............WWW",
    "..............W.",
    "...GGGGGGGGGG...",
    "GGGGLGGGGGGGDGGG",
    "G..GLGGGGGGGD..G",
    "G..GLGGGGGGGD..G",
    ".G.GLGGGGGGGD.G.",
    "..GGGLGGGGGDDG..",
    "....GGGGGGGD....",
    ".....GGGGGD.....",
    "......GGGD......",
    ".......GD.......",
    ".......GD.......",
    ".....GGGGDD.....",
    "....GGGGGGDD....",
    "....GGGGGGDD....",
]
let colors: [Character: NSColor] = [
    "G": NSColor(srgbRed: 0.898, green: 0.710, blue: 0.051, alpha: 1),
    "L": NSColor(srgbRed: 1.0, green: 0.886, blue: 0.478, alpha: 1),
    "D": NSColor(srgbRed: 0.722, green: 0.525, blue: 0.043, alpha: 1),
    "W": NSColor(white: 1, alpha: 0.9),
]

func draw(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size) / 1024  // everything below is in a 1024-point canvas
    NSGraphicsContext.current?.cgContext.scaleBy(x: s, y: s)

    // macOS icon grid: an 824-point body with ~185-point corners, a soft shadow below.
    let body = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    NSColor.black.setFill()
    body.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.165, green: 0.278, blue: 0.369, alpha: 1),
               ending: NSColor(srgbRed: 0.090, green: 0.114, blue: 0.145, alpha: 1))!.draw(in: body, angle: -90)

    // Pixel art centred on the body, nudged down so the base sits on a light floor.
    let cell: CGFloat = 34, cols = CGFloat(art[0].count), rows = CGFloat(art.count)
    let x0 = 512 - cols * cell / 2, top = 512 + rows * cell / 2 - 10
    NSColor(srgbRed: 0.40, green: 0.76, blue: 0.96, alpha: 0.18).setFill()
    NSBezierPath(ovalIn: NSRect(x: 512 - 190, y: top - rows * cell - 34, width: 380, height: 60)).fill()
    // No antialiasing: neighbouring cells meet without seams, and pixel art should stay crisp.
    NSGraphicsContext.current?.cgContext.setShouldAntialias(false)
    for (r, line) in art.enumerated() {
        for (c, ch) in line.enumerated() {
            guard let color = colors[ch] else { continue }
            color.setFill()
            NSRect(x: x0 + CGFloat(c) * cell, y: top - CGFloat(r + 1) * cell, width: cell, height: cell).fill()
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try draw(size: base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try draw(size: base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
try draw(size: 512).write(to: root.appendingPathComponent("docs/icon.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run()
p.waitUntilExit()
precondition(p.terminationStatus == 0, "iconutil failed")

// ICO with PNG entries (Windows Vista and later): a 6-byte header, a 16-byte entry per size, then the PNGs.
let pngs = [16, 24, 32, 48, 64, 256].map { ($0, draw(size: $0)) }
var ico = Data([0, 0, 1, 0, UInt8(pngs.count), 0])
var offset = 6 + 16 * pngs.count
func le(_ v: Int, _ n: Int) -> [UInt8] { (0..<n).map { UInt8((v >> (8 * $0)) & 0xFF) } }
for (size, png) in pngs {
    ico += [UInt8(size % 256), UInt8(size % 256), 0, 0] + le(1, 2) + le(32, 2) + le(png.count, 4) + le(offset, 4)  // 256 is stored as 0
    offset += png.count
}
for (_, png) in pngs { ico += png }
try ico.write(to: root.appendingPathComponent("Resources/AppIcon.ico"))
print("Wrote Resources/AppIcon.icns, Resources/AppIcon.ico and docs/icon.png")
