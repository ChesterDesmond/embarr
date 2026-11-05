// Draws Ember Bar's app icon (a cup on a warm gradient) into an .iconset folder; scripts/bundle.sh turns it into .icns.
// Run: swift scripts/make-icon.swift <out.iconset>
import AppKit

guard CommandLine.arguments.count == 2 else { FileHandle.standardError.write(Data("usage: swift make-icon.swift <out.iconset>\n".utf8)); exit(2) }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let tile = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.98, green: 0.62, blue: 0.16, alpha: 1),
                        NSColor(red: 0.84, green: 0.22, blue: 0.14, alpha: 1)])!.draw(in: tile, angle: -90)
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    if let cup = NSImage(systemSymbolName: "cup.and.heat.waves.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(config) {
        let r = NSRect(x: (s - cup.size.width) / 2, y: (s - cup.size.height) / 2 - s * 0.01,
                       width: cup.size.width, height: cup.size.height)
        cup.draw(in: r)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
