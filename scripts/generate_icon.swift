import AppKit
import CoreGraphics
import Foundation

func renderIcon(size: Int) -> NSBitmapImageRep {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext

    let inset = s * 0.08
    let rect = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let cornerRadius = rect.width * 0.225

    let path = NSBezierPath(roundedRect: rect, xRadius: cornerRadius, yRadius: cornerRadius)
    path.addClip()

    // Warm Kaya wood gradient background
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        CGColor(red: 0.91, green: 0.75, blue: 0.46, alpha: 1.0),
        CGColor(red: 0.79, green: 0.60, blue: 0.32, alpha: 1.0)
    ] as CFArray
    let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0])!
    ctx.drawLinearGradient(
        grad,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )

    // Subtle Goban grid lines in background
    ctx.setStrokeColor(CGColor(red: 0.22, green: 0.15, blue: 0.06, alpha: 0.15))
    ctx.setLineWidth(max(1.0, s * 0.006))
    let step = rect.width / 4.0
    for i in 1...3 {
        let pos = rect.minX + CGFloat(i) * step
        ctx.move(to: CGPoint(x: pos, y: rect.minY))
        ctx.addLine(to: CGPoint(x: pos, y: rect.maxY))
        ctx.strokePath()

        let yPos = rect.minY + CGFloat(i) * step
        ctx.move(to: CGPoint(x: rect.minX, y: yPos))
        ctx.addLine(to: CGPoint(x: rect.maxX, y: yPos))
        ctx.strokePath()
    }

    // Crisp stacked "GO" and "COACH" centered vertically
    let textColor = NSColor(calibratedRed: 0.12, green: 0.09, blue: 0.05, alpha: 1.0)
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center

    let goFont = NSFont.systemFont(ofSize: s * 0.35, weight: .black)
    let goAttrs: [NSAttributedString.Key: Any] = [
        .font: goFont,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
        .kern: s * 0.012
    ]
    let goStr = NSAttributedString(string: "GO", attributes: goAttrs)
    let goSize = goStr.size()
    let goRect = CGRect(
        x: (s - goSize.width) / 2.0,
        y: s * 0.43,
        width: goSize.width,
        height: goSize.height
    )
    goStr.draw(in: goRect)

    let coachFont = NSFont.systemFont(ofSize: s * 0.165, weight: .heavy)
    let coachAttrs: [NSAttributedString.Key: Any] = [
        .font: coachFont,
        .foregroundColor: textColor,
        .paragraphStyle: paragraph,
        .kern: s * 0.008
    ]
    let coachStr = NSAttributedString(string: "COACH", attributes: coachAttrs)
    let coachSize = coachStr.size()
    let coachRect = CGRect(
        x: (s - coachSize.width) / 2.0,
        y: s * 0.22,
        width: coachSize.width,
        height: coachSize.height
    )
    coachStr.draw(in: coachRect)

    // Border stroke around the squircle
    ctx.setStrokeColor(CGColor(red: 0.42, green: 0.28, blue: 0.12, alpha: 0.85))
    ctx.setLineWidth(max(1.5, s * 0.018))
    path.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let projectDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().path
let iconsetDir = "\(projectDir)/Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: iconsetDir)
try FileManager.default.createDirectory(atPath: iconsetDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    let rep = renderIcon(size: px)
    if let pngData = rep.representation(using: .png, properties: [:]) {
        let outURL = URL(fileURLWithPath: "\(iconsetDir)/\(filename)")
        try pngData.write(to: outURL)
    }
}
print("Generated iconset at \(iconsetDir)")
