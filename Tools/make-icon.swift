// Draws Folio's app icon as a full .iconset with Core Graphics only, so it works on
// a machine that has the Command Line Tools but no Xcode.
//
// The mark: a sheet of paper adrift in space. The page keeps the app's identity — a
// document with one removed line and one added line — while the setting is a nebula, a
// star field and a ringed planet behind it. Small sizes drop the sky detail and keep the
// page and the planet, because stars turn to noise at 16 pixels.
//
// Usage: swift Tools/make-icon.swift <output.iconset directory>

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count > 1 else {
    FileHandle.standardError.write("usage: make-icon.swift <output.iconset>\n".data(using: .utf8)!)
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

let colorSpace = CGColorSpaceCreateDeviceRGB()

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red / 255, green / 255, blue / 255, alpha])!
}

func roundedRect(_ rect: CGRect, radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

// MARK: - Palette

let skyTop = color(46, 34, 92)
let skyBottom = color(8, 7, 20)
let nebulaViolet = color(124, 76, 214, 0.45)
let nebulaCyan = color(42, 197, 212, 0.22)
let starWhite = color(255, 255, 255)
let planetBody = color(233, 168, 106)
let planetShade = color(186, 112, 70)
let ringLight = color(246, 226, 200, 0.95)
let paper = color(250, 250, 248)
let paperShade = color(206, 213, 224)
let ink = color(38, 44, 58)
let graphite = color(126, 136, 152)
let removed = color(226, 74, 66)
let added = color(52, 168, 83)

/// One star. Placement is deterministic so every size shows the same sky.
struct Sparkle {
    var x: CGFloat
    var y: CGFloat
    var radius: CGFloat
    var alpha: CGFloat
}

func makeSky(in rect: CGRect, avoiding page: CGRect, count: Int) -> [Sparkle] {
    var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
    func random() -> CGFloat {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return CGFloat((seed >> 11) & 0xFFFF_FFFF) / CGFloat(0xFFFF_FFFF)
    }
    var sparkles: [Sparkle] = []
    var attempts = 0
    // Keep the paper clean: no stars behind or immediately around it.
    let breathingRoom = page.insetBy(dx: -rect.width * 0.03, dy: -rect.height * 0.03)
    while sparkles.count < count, attempts < count * 40 {
        attempts += 1
        let point = CGPoint(x: rect.minX + random() * rect.width,
                            y: rect.minY + random() * rect.height)
        if breathingRoom.contains(point) { continue }
        sparkles.append(Sparkle(x: point.x, y: point.y,
                                radius: rect.width * (0.0022 + random() * 0.0052),
                                alpha: 0.30 + random() * 0.70))
    }
    return sparkles
}

// MARK: - Drawing

func draw(size: CGFloat) -> CGImage {
    let context = CGContext(data: nil, width: Int(size), height: Int(size),
                            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let unit = size / 1024
    let small = size <= 32

    let inset = 70 * unit
    let card = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    context.saveGState()
    context.addPath(roundedRect(card, radius: 200 * unit))
    context.clip()

    // Night sky
    let sky = CGGradient(colorsSpace: colorSpace, colors: [skyTop, skyBottom] as CFArray,
                         locations: [0, 1])!
    context.drawLinearGradient(sky,
                               start: CGPoint(x: card.minX, y: card.maxY),
                               end: CGPoint(x: card.maxX, y: card.minY),
                               options: [])

    if !small {
        // Two soft nebula glows, violet and cyan.
        for (tint, centre, radius) in [
            (nebulaViolet,
             CGPoint(x: card.minX + card.width * 0.22, y: card.maxY - card.height * 0.16),
             card.width * 0.55),
            (nebulaCyan,
             CGPoint(x: card.maxX - card.width * 0.10, y: card.minY + card.height * 0.36),
             card.width * 0.46),
        ] {
            let glow = CGGradient(colorsSpace: colorSpace,
                                  colors: [tint, tint.copy(alpha: 0)!] as CFArray,
                                  locations: [0, 1])!
            context.drawRadialGradient(glow, startCenter: centre, startRadius: 0,
                                       endCenter: centre, endRadius: radius, options: [])
        }
    }

    // The page floats slightly off-centre and tilted.
    let pageSize = CGSize(width: card.width * (small ? 0.54 : 0.49),
                          height: card.height * (small ? 0.62 : 0.61))
    let pageCentre = CGPoint(x: card.midX - card.width * (small ? 0.04 : 0.05),
                             y: card.midY - card.height * (small ? 0.05 : 0.02))
    let pageRect = CGRect(x: pageCentre.x - pageSize.width / 2,
                          y: pageCentre.y - pageSize.height / 2,
                          width: pageSize.width, height: pageSize.height)

    if !small {
        for sparkle in makeSky(in: card, avoiding: pageRect, count: 52) {
            context.addEllipse(in: CGRect(x: sparkle.x - sparkle.radius, y: sparkle.y - sparkle.radius,
                                          width: sparkle.radius * 2, height: sparkle.radius * 2))
            context.setFillColor(starWhite.copy(alpha: sparkle.alpha)!)
            context.fillPath()
        }
    }

    // Ringed planet, behind the page and running off the card edge.
    let planetCentre = CGPoint(x: card.maxX - card.width * (small ? 0.13 : 0.16),
                               y: card.maxY - card.height * (small ? 0.13 : 0.20))
    let planetRadius = card.width * (small ? 0.15 : 0.15)
    let ringSize = CGSize(width: planetRadius * 3.2, height: planetRadius * 0.95)
    let ringWidth = planetRadius * 0.16

    func addRing() {
        let transform = CGAffineTransform(translationX: planetCentre.x, y: planetCentre.y)
            .rotated(by: -22 * .pi / 180)
        let path = CGMutablePath()
        path.addEllipse(in: CGRect(x: -ringSize.width / 2, y: -ringSize.height / 2,
                                   width: ringSize.width, height: ringSize.height),
                        transform: transform)
        context.addPath(path)
    }

    if !small {
        context.setLineWidth(ringWidth)
        context.setStrokeColor(ringLight)
        addRing()
        context.strokePath()
    }

    context.saveGState()
    context.addEllipse(in: CGRect(x: planetCentre.x - planetRadius, y: planetCentre.y - planetRadius,
                                  width: planetRadius * 2, height: planetRadius * 2))
    context.clip()
    let planetGradient = CGGradient(colorsSpace: colorSpace,
                                    colors: [planetBody, planetShade] as CFArray,
                                    locations: [0, 1])!
    context.drawLinearGradient(planetGradient,
                               start: CGPoint(x: planetCentre.x - planetRadius,
                                              y: planetCentre.y + planetRadius),
                               end: CGPoint(x: planetCentre.x + planetRadius,
                                            y: planetCentre.y - planetRadius),
                               options: [])
    context.restoreGState()

    // The near half of the ring, so it crosses in front of the planet.
    if !small {
    context.saveGState()
    context.clip(to: CGRect(x: card.minX, y: card.minY,
                            width: card.width, height: planetCentre.y - card.minY))
    context.setLineWidth(ringWidth)
    context.setStrokeColor(ringLight)
    addRing()
    context.strokePath()
    context.restoreGState()
    }

    // The page goes on last, in front of the sky and the planet.
    context.saveGState()
    context.translateBy(x: pageCentre.x, y: pageCentre.y)
    if !small { context.rotate(by: -7 * .pi / 180) }
    context.translateBy(x: -pageCentre.x, y: -pageCentre.y)

    context.saveGState()
    context.setShadow(offset: CGSize(width: 0, height: -12 * unit), blur: 36 * unit,
                      color: color(0, 0, 0, 0.6))
    context.addPath(roundedRect(pageRect, radius: 34 * unit))
    context.setFillColor(paper)
    context.fillPath()
    context.restoreGState()

    func bar(_ rect: CGRect, _ fill: CGColor) {
        context.addPath(roundedRect(rect, radius: min(rect.height / 2, 12 * unit)))
        context.setFillColor(fill)
        context.fillPath()
    }

    let pageInset = pageRect.width * (small ? 0.15 : 0.12)
    let available = pageRect.width - pageInset * 2

    if small {
        let barHeight = pageRect.height * 0.18
        let gap = (pageRect.height - pageInset * 2 - barHeight * 3) / 2
        let fills = [graphite, removed, added]
        for row in 0..<3 {
            let top = pageRect.maxY - pageInset - CGFloat(row) * (barHeight + gap) - barHeight
            bar(CGRect(x: pageRect.minX + pageInset, y: top,
                       width: row == 2 ? available * 0.7 : available, height: barHeight), fills[row])
        }
    } else {
        // A heading, then four lines with one removed and one added.
        let headingHeight = pageRect.height * 0.088
        let barHeight = pageRect.height * 0.074
        let gap = pageRect.height * 0.064
        let widths: [CGFloat] = [0.82, 0.56, 0.92, 0.48]
        let tints: [CGColor] = [paperShade, removed, added, paperShade]
        let block = headingHeight + gap * 1.5 + barHeight * 4 + gap * 3
        var y = pageCentre.y + block / 2 - headingHeight

        bar(CGRect(x: pageRect.minX + pageInset, y: y,
                   width: available * 0.62, height: headingHeight), ink)
        y -= gap * 1.5

        for (index, fraction) in widths.enumerated() {
            y -= barHeight
            bar(CGRect(x: pageRect.minX + pageInset, y: y,
                       width: available * fraction, height: barHeight), tints[index])
            y -= gap
        }
    }
    context.restoreGState()

    context.restoreGState()
    return context.makeImage()!
}

func write(_ image: CGImage, to url: URL) throws {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw NSError(domain: "make-icon", code: 2)
    }
}

let variants: [(name: String, pixels: CGFloat)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = draw(size: variant.pixels)
    try write(image, to: outputDirectory.appendingPathComponent("\(variant.name).png"))
}
print("wrote \(variants.count) icon variants to \(outputDirectory.path)")
