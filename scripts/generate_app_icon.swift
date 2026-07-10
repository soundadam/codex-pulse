import AppKit
import Foundation

let fileManager = FileManager.default
let repoRoot = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let resourcesURL = repoRoot.appendingPathComponent("Resources", isDirectory: true)
let iconsetURL = resourcesURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
let previewURL = resourcesURL.appendingPathComponent("AppIcon-preview.png")

try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
if fileManager.fileExists(atPath: iconsetURL.path) {
    try fileManager.removeItem(at: iconsetURL)
}
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let iconSizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png"),
]

for (size, filename) in iconSizes {
    let image = makeIcon(size: CGFloat(size))
    try savePNG(image: image, to: iconsetURL.appendingPathComponent(filename))
}

let previewImage = makeIcon(size: 1024)
try savePNG(image: previewImage, to: previewURL)

func makeIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    guard let context = NSGraphicsContext.current?.cgContext else {
        image.unlockFocus()
        return image
    }

    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let outerInset = size * 0.06
    let panelRect = rect.insetBy(dx: outerInset, dy: outerInset)
    let cornerRadius = size * 0.24

    let backgroundPath = NSBezierPath(
        roundedRect: NSRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: panelRect.height),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    context.saveGState()
    backgroundPath.addClip()

    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [
            NSColor(calibratedRed: 0.09, green: 0.11, blue: 0.12, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.09, blue: 0.08, alpha: 1).cgColor,
        ] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: panelRect.minX, y: panelRect.maxY),
        end: CGPoint(x: panelRect.maxX, y: panelRect.minY),
        options: []
    )

    context.setFillColor(NSColor.white.withAlphaComponent(0.04).cgColor)
    for step in stride(from: panelRect.minX + size * 0.08, through: panelRect.maxX, by: size * 0.12) {
        context.fill(CGRect(x: step, y: panelRect.minY, width: max(1, size * 0.005), height: panelRect.height))
    }
    context.restoreGState()

    let borderPath = NSBezierPath(
        roundedRect: NSRect(x: panelRect.minX, y: panelRect.minY, width: panelRect.width, height: panelRect.height),
        xRadius: cornerRadius,
        yRadius: cornerRadius
    )
    NSColor.white.withAlphaComponent(0.12).setStroke()
    borderPath.lineWidth = max(1.5, size * 0.012)
    borderPath.stroke()

    let baselineY = panelRect.midY - size * 0.06
    let pulsePoints = [
        CGPoint(x: panelRect.minX + size * 0.12, y: baselineY),
        CGPoint(x: panelRect.minX + size * 0.28, y: baselineY),
        CGPoint(x: panelRect.minX + size * 0.40, y: baselineY + size * 0.02),
        CGPoint(x: panelRect.minX + size * 0.50, y: baselineY + size * 0.27),
        CGPoint(x: panelRect.minX + size * 0.59, y: baselineY - size * 0.10),
        CGPoint(x: panelRect.minX + size * 0.69, y: baselineY + size * 0.09),
        CGPoint(x: panelRect.minX + size * 0.82, y: baselineY),
    ]

    let glowPath = NSBezierPath()
    glowPath.move(to: pulsePoints[0])
    for point in pulsePoints.dropFirst() {
        glowPath.line(to: point)
    }
    glowPath.lineCapStyle = .round
    glowPath.lineJoinStyle = .round
    glowPath.lineWidth = size * 0.11
    NSColor(calibratedRed: 0.25, green: 0.95, blue: 0.48, alpha: 0.18).setStroke()
    glowPath.stroke()

    let pulsePath = NSBezierPath()
    pulsePath.move(to: pulsePoints[0])
    for point in pulsePoints.dropFirst() {
        pulsePath.line(to: point)
    }
    pulsePath.lineCapStyle = .round
    pulsePath.lineJoinStyle = .round
    pulsePath.lineWidth = size * 0.05
    NSColor(calibratedRed: 0.24, green: 0.90, blue: 0.42, alpha: 1).setStroke()
    pulsePath.stroke()

    let alertCenter = CGPoint(x: panelRect.maxX - size * 0.18, y: panelRect.midY + size * 0.14)
    let alertRadius = size * 0.08
    let alertPath = NSBezierPath(ovalIn: NSRect(
        x: alertCenter.x - alertRadius,
        y: alertCenter.y - alertRadius,
        width: alertRadius * 2,
        height: alertRadius * 2
    ))
    NSColor(calibratedRed: 1.0, green: 0.31, blue: 0.31, alpha: 1).setFill()
    alertPath.fill()

    let innerAlert = NSBezierPath(ovalIn: NSRect(
        x: alertCenter.x - alertRadius * 0.58,
        y: alertCenter.y - alertRadius * 0.58,
        width: alertRadius * 1.16,
        height: alertRadius * 1.16
    ))
    NSColor.white.withAlphaComponent(0.18).setStroke()
    innerAlert.lineWidth = max(1, size * 0.01)
    innerAlert.stroke()

    let markRect = NSRect(
        x: panelRect.minX + size * 0.16,
        y: panelRect.maxY - size * 0.28,
        width: size * 0.24,
        height: size * 0.14
    )
    let mark = NSString(string: "Cdx")
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .left
    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: size * 0.10, weight: .bold),
        .foregroundColor: NSColor.white.withAlphaComponent(0.94),
        .paragraphStyle: paragraph,
    ]
    mark.draw(in: markRect, withAttributes: attributes)

    image.unlockFocus()
    return image
}

func savePNG(image: NSImage, to url: URL) throws {
    guard let tiffData = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiffData),
          let pngData = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "CodexPulseIcon", code: 1)
    }
    try pngData.write(to: url)
}
