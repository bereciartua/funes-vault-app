// Draws Funes Vault's app icon as vector art and writes the asset catalog's AppIcon set:
// a round vault door seen from the front, its face made of rings like the growth rings of
// a tree (a memory that keeps every year), with one short arc lit in amber: the one memory
// an agent gets, not all of them. Original art, drawn here; no third-party assets.
//
//   swiftc -O scripts/app_icon.swift -o build/app_icon
//   build/app_icon iconset Apps/FunesMac/Assets.xcassets/AppIcon.appiconset
//   build/app_icon png OUT.png SIZE          one PNG, for previews, the README and the site
//
// The body follows Apple's macOS grid: an 824-point rounded square centred in 1024, with a
// soft shadow below it. scripts/make_icon.sh regenerates everything that uses the icon.
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

/// The icon on a 1024 canvas, scaled to `pixels`.
func draw(pixels: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("can't create a \(pixels)-pixel bitmap")
    }
    let scale = CGFloat(pixels) / 1024
    context.scaleBy(x: scale, y: scale)
    // Shadows ignore the transform, so their offsets and blurs are scaled by hand.
    func shadow(_ dy: CGFloat, _ blur: CGFloat, _ shade: CGColor) {
        context.setShadow(offset: CGSize(width: 0, height: dy * scale), blur: blur * scale, color: shade)
    }
    context.setShouldAntialias(true)
    context.interpolationQuality = .high
    // Small sizes get fewer, bolder rings so they stay legible.
    let small = pixels <= 64

    // The body: a rounded square, deep ink blue, lighter towards the top.
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    context.saveGState()
    shadow(-10, 28, color(0x000000, 0.30))
    context.addPath(bodyPath)
    context.setFillColor(color(0x15203B))
    context.fillPath()
    context.restoreGState()
    context.saveGState()
    context.addPath(bodyPath)
    context.clip()
    let wash = CGGradient(colorsSpace: space, colors: [color(0x2C3E6B), color(0x141C34)] as CFArray,
                          locations: [0, 1])!
    context.drawLinearGradient(wash, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    context.restoreGState()

    let center = CGPoint(x: 512, y: 512)

    // The door's rim: a brass-coloured ring with eight bolts.
    let rimRadius: CGFloat = 318
    context.saveGState()
    shadow(-8, 22, color(0x000000, 0.35))
    context.setFillColor(color(0xE9DCC3))
    context.fillEllipse(in: CGRect(x: center.x - rimRadius, y: center.y - rimRadius,
                                   width: rimRadius * 2, height: rimRadius * 2))
    context.restoreGState()
    let rimShade = CGGradient(colorsSpace: space, colors: [color(0xF6EEDD), color(0xCDBB98)] as CFArray,
                              locations: [0, 1])!
    context.saveGState()
    context.addEllipse(in: CGRect(x: center.x - rimRadius, y: center.y - rimRadius,
                                  width: rimRadius * 2, height: rimRadius * 2))
    context.clip()
    context.drawLinearGradient(rimShade, start: CGPoint(x: 512, y: 830), end: CGPoint(x: 512, y: 194), options: [])
    context.restoreGState()

    // The face, a step inside the rim.
    let faceRadius: CGFloat = 262
    context.setFillColor(color(0xFBF6EC))
    context.fillEllipse(in: CGRect(x: center.x - faceRadius, y: center.y - faceRadius,
                                   width: faceRadius * 2, height: faceRadius * 2))

    // Bolts on the rim, between face and edge.
    let boltRadius: CGFloat = small ? 20 : 15
    for i in 0..<8 {
        let angle = CGFloat(i) * .pi / 4 + .pi / 8
        let r = (rimRadius + faceRadius) / 2
        let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
        context.setFillColor(color(0x8E7A55))
        context.fillEllipse(in: CGRect(x: p.x - boltRadius, y: p.y - boltRadius - 2,
                                       width: boltRadius * 2, height: boltRadius * 2))
        context.setFillColor(color(0xB9A47C))
        context.fillEllipse(in: CGRect(x: p.x - boltRadius, y: p.y - boltRadius,
                                       width: boltRadius * 2, height: boltRadius * 2))
    }

    // The rings: slightly uneven, like a tree's, in ink. The wobble grows with the radius, so
    // the inner rings stay round and none touches its neighbour.
    let ink = color(0x1E2A4A)
    let rings: [CGFloat] = small ? [222, 160, 98] : [230, 194, 158, 122, 86]
    func ringPoint(_ index: Int, _ t: CGFloat) -> CGPoint {
        let radius = rings[index]
        let amount = small ? 0 : radius / 230
        let phase = CGFloat(index) * 1.7
        let r = radius + amount * (3.5 * sin(3 * t + phase) + 2 * sin(5 * t + phase * 0.6))
        return CGPoint(x: center.x + r * cos(t), y: center.y + r * sin(t))
    }
    func ringPath(_ index: Int, from start: CGFloat = 0, to end: CGFloat = 2 * .pi) -> CGPath {
        let path = CGMutablePath()
        let steps = 360
        for step in 0...steps {
            let p = ringPoint(index, start + (end - start) * CGFloat(step) / CGFloat(steps))
            step == 0 ? path.move(to: p) : path.addLine(to: p)
        }
        return path
    }
    context.setStrokeColor(ink)
    context.setLineWidth(small ? 20 : 12)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    for index in rings.indices {
        context.addPath(ringPath(index))
        context.strokePath()
    }

    // The one memory that's shared: an amber stretch of a middle ring, drawn over it.
    let litIndex = 1
    context.saveGState()
    shadow(0, small ? 0 : 20, color(0xFFB23E, 0.9))
    context.setStrokeColor(color(0xFFB23E))
    context.setLineWidth(small ? 30 : 26)
    context.addPath(ringPath(litIndex, from: .pi * 0.16, to: .pi * 0.44))
    context.strokePath()
    context.restoreGState()

    // The hub: the door's handle, a small ink disc with a cream centre.
    context.setFillColor(ink)
    context.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))
    context.setFillColor(color(0xFBF6EC))
    context.fillEllipse(in: CGRect(x: center.x - 12, y: center.y - 12, width: 24, height: 24))

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
