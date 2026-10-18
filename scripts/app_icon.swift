// Draws Funes Vault's app icon as vector art and writes the asset catalog's AppIcon set:
// an open eye, drawn in ink on parchment, with a gold iris. Funes, in Borges' story, is the
// man who remembers everything he has ever seen. Original art, drawn here; no third-party assets.
//
//   swiftc -O scripts/app_icon.swift -o build/app_icon
//   build/app_icon iconset Apps/FunesMac/Assets.xcassets/AppIcon.appiconset
//   build/app_icon png OUT.png SIZE          one PNG, for previews, the README and the site
//
// The body follows Apple's macOS grid: an 824-point continuous-corner square centred in 1024,
// with a soft shadow below it. Sizes of 64 pixels and below use a bolder drawing of the same eye.
import AppKit
import CoreGraphics
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("app_icon: \(message)\n".utf8))
    exit(1)
}

func color(_ hex: Int, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ink = color(0x1D1912)

/// The macOS icon body: a superellipse, close to Apple's continuous-corner square.
func bodyPath() -> CGPath {
    let path = CGMutablePath()
    let steps = 400
    for step in 0..<steps {
        let t = CGFloat(step) / CGFloat(steps) * 2 * .pi
        let c = cos(t), s = sin(t)
        let p = CGPoint(x: 512 + 412 * (c < 0 ? -1 : 1) * pow(abs(c), 0.4),
                        y: 512 + 412 * (s < 0 ? -1 : 1) * pow(abs(s), 0.4))
        step == 0 ? path.move(to: p) : path.addLine(to: p)
    }
    path.closeSubpath()
    return path
}

/// The eye's outline: two lids meeting at points on the horizontal centre line.
func almondPath(corner: CGFloat, upper: CGFloat, lower: CGFloat) -> CGPath {
    let left = corner, right = 1024 - corner, dx = (right - left) * 0.21
    let path = CGMutablePath()
    path.move(to: CGPoint(x: left, y: 512))
    path.addCurve(to: CGPoint(x: right, y: 512), control1: CGPoint(x: left + dx, y: upper),
                  control2: CGPoint(x: right - dx, y: upper))
    path.addCurve(to: CGPoint(x: left, y: 512), control1: CGPoint(x: right - dx, y: lower),
                  control2: CGPoint(x: left + dx, y: lower))
    path.closeSubpath()
    return path
}

func circle(_ radius: CGFloat) -> CGRect {
    CGRect(x: 512 - radius, y: 512 - radius, width: radius * 2, height: radius * 2)
}

/// The icon on a 1024 canvas, scaled to `pixels`. Coordinates below run top-down, like the SVG it came from.
func draw(pixels: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("can't create a \(pixels)-pixel bitmap")
    }
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    context.translateBy(x: 0, y: 1024)
    context.scaleBy(x: 1, y: -1)
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // Small sizes get a heavier outline and a larger iris so the eye stays legible.
    let small = pixels <= 64

    // The body: parchment, a little darker towards the bottom, with a soft shadow below.
    let body = bodyPath()
    context.saveGState()
    if !small {
        // Shadows ignore the transform, so their offsets and blurs are scaled by hand.
        context.setShadow(offset: CGSize(width: 0, height: -10 * scale), blur: 26 * scale, color: color(0x000000, 0.32))
    }
    context.addPath(body)
    context.setFillColor(color(0xE2D0AC))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(body)
    context.clip()
    let paper = CGGradient(colorsSpace: space, colors: [color(0xF6EEDC), color(0xE2D0AC)] as CFArray, locations: [0, 1])!
    context.drawLinearGradient(paper, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    // A thin rim: light along the top edge, a touch of shade along the bottom.
    if !small {
        context.addPath(body)
        context.setLineWidth(10)
        context.replacePathWithStrokedPath()
        context.clip()
        let rim = CGGradient(colorsSpace: space,
                             colors: [color(0xFFFFFF, 0.5), color(0xFFFFFF, 0), color(0x000000, 0), color(0x000000, 0.3)] as CFArray,
                             locations: [0, 0.18, 0.85, 1])!
        context.drawLinearGradient(rim, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])
    }
    context.restoreGState()

    // The eye: white, a gold iris and an ink pupil, inside an ink outline.
    let corner: CGFloat = small ? 168 : 196
    let eye = almondPath(corner: corner, upper: small ? 236 : 250, lower: small ? 788 : 774)
    let iris: CGFloat = small ? 150 : 138
    let pupil: CGFloat = small ? 64 : 54
    context.addPath(eye)
    context.setFillColor(color(0xFDF9F0))
    context.fillPath()

    context.saveGState()
    context.addPath(eye)
    context.clip()
    context.addEllipse(in: circle(iris))
    context.clip()
    // Lit from the upper left: pale gold at the light, deep gold at the rim.
    let gold = CGGradient(colorsSpace: space, colors: [color(0xF6CF6A), color(0xA06A18)] as CFArray, locations: [0.15, 1])!
    let light = CGPoint(x: 512 - 0.16 * iris, y: 512 - 0.24 * iris)
    context.drawRadialGradient(gold, startCenter: light, startRadius: 0, endCenter: light, endRadius: 1.44 * iris,
                               options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    context.restoreGState()

    context.setFillColor(ink)
    context.fillEllipse(in: circle(pupil))

    context.addPath(eye)
    context.setStrokeColor(ink)
    context.setLineWidth(small ? 76 : 36)
    context.setLineJoin(.round)
    context.strokePath()

    guard let image = context.makeImage() else { fail("can't render the icon") }
    return image
}

func writePNG(_ image: CGImage, to path: String) {
    guard let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,
                                                            "public.png" as CFString, 1, nil) else {
        fail("can't write \(path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("can't write \(path)") }
}

let arguments = CommandLine.arguments
switch (arguments.count, arguments.count > 1 ? arguments[1] : "") {
case (3, "iconset"):
    let folder = arguments[2]
    try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
        for scale in [1, 2] {
            let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
            writePNG(draw(pixels: points * scale), to: "\(folder)/\(name)")
            images.append(["filename": name, "idiom": "mac", "scale": "\(scale)x", "size": "\(points)x\(points)"])
        }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    guard let json = try? JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]) else {
        fail("can't encode Contents.json")
    }
    try? (json + Data("\n".utf8)).write(to: URL(fileURLWithPath: "\(folder)/Contents.json"))
case (4, "png"):
    guard let size = Int(arguments[3]), size > 0 else { fail("SIZE must be a positive number") }
    writePNG(draw(pixels: size), to: arguments[2])
default:
    FileHandle.standardError.write(Data("usage: app_icon iconset FOLDER | app_icon png OUT.png SIZE\n".utf8))
    exit(2)
}
