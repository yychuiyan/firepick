#!/usr/bin/env swift

import CoreGraphics
import Foundation
import ImageIO

let size = 1024
let colorSpace = CGColorSpaceCreateDeviceRGB()
let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue)

guard
    let context = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    )
else {
    fatalError("Unable to create icon canvas")
}

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: colorSpace, components: [red, green, blue, alpha])!
}

func radialGlow(center: CGPoint, radius: CGFloat, inner: CGColor, outer: CGColor) {
    let gradient = CGGradient(
        colorsSpace: colorSpace,
        colors: [inner, outer] as CFArray,
        locations: [0, 1]
    )!
    context.drawRadialGradient(
        gradient,
        startCenter: center,
        startRadius: 0,
        endCenter: center,
        endRadius: radius,
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
}

func ellipse(
    center: CGPoint,
    width: CGFloat,
    height: CGFloat,
    rotation: CGFloat,
    fill: CGColor
) {
    context.saveGState()
    context.translateBy(x: center.x, y: center.y)
    context.rotate(by: rotation)
    context.setFillColor(fill)
    context.fillEllipse(in: CGRect(
        x: -width / 2,
        y: -height / 2,
        width: width,
        height: height
    ))
    context.restoreGState()
}

let background = CGGradient(
    colorsSpace: colorSpace,
    colors: [color(0.025, 0.055, 0.11), color(0.035, 0.17, 0.25)] as CFArray,
    locations: [0, 1]
)!
context.drawLinearGradient(
    background,
    start: CGPoint(x: 120, y: 80),
    end: CGPoint(x: 900, y: 950),
    options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
)

radialGlow(
    center: CGPoint(x: 500, y: 530),
    radius: 440,
    inner: color(0.08, 0.78, 0.67, 0.30),
    outer: color(0.08, 0.78, 0.67, 0)
)
radialGlow(
    center: CGPoint(x: 510, y: 530),
    radius: 250,
    inner: color(1.0, 0.72, 0.18, 0.42),
    outer: color(1.0, 0.72, 0.18, 0)
)

context.setBlendMode(.screen)
let stars: [(CGFloat, CGFloat, CGFloat, CGFloat)] = [
    (170, 790, 7, 0.56), (250, 840, 4, 0.36), (820, 760, 6, 0.48),
    (760, 860, 3, 0.32), (875, 210, 5, 0.42), (145, 255, 4, 0.36),
    (295, 185, 3, 0.28), (690, 150, 4, 0.32)
]
for (x, y, radius, alpha) in stars {
    context.setFillColor(color(1, 0.96, 0.78, alpha))
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}
context.setBlendMode(.normal)

ellipse(
    center: CGPoint(x: 405, y: 565),
    width: 300,
    height: 160,
    rotation: 0.40,
    fill: color(0.12, 0.84, 0.77, 0.42)
)
ellipse(
    center: CGPoint(x: 615, y: 565),
    width: 300,
    height: 160,
    rotation: -0.40,
    fill: color(0.12, 0.84, 0.77, 0.42)
)

let antenna = CGMutablePath()
antenna.move(to: CGPoint(x: 485, y: 650))
antenna.addCurve(
    to: CGPoint(x: 395, y: 775),
    control1: CGPoint(x: 455, y: 710),
    control2: CGPoint(x: 425, y: 750)
)
antenna.move(to: CGPoint(x: 535, y: 650))
antenna.addCurve(
    to: CGPoint(x: 625, y: 775),
    control1: CGPoint(x: 565, y: 710),
    control2: CGPoint(x: 595, y: 750)
)
context.addPath(antenna)
context.setStrokeColor(color(1, 0.77, 0.27, 0.9))
context.setLineWidth(18)
context.setLineCap(.round)
context.strokePath()

for (x, y, radius) in [(395.0, 775.0, 18.0), (625.0, 775.0, 18.0)] {
    context.setFillColor(color(1, 0.83, 0.38))
    context.fillEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
}

ellipse(
    center: CGPoint(x: 510, y: 545),
    width: 132,
    height: 230,
    rotation: 0,
    fill: color(1, 0.78, 0.24)
)
ellipse(
    center: CGPoint(x: 500, y: 620),
    width: 58,
    height: 128,
    rotation: -0.10,
    fill: color(1, 0.94, 0.58, 0.72)
)
context.setFillColor(color(0.99, 0.68, 0.15))
context.fillEllipse(in: CGRect(x: 435, y: 662, width: 150, height: 150))

context.setBlendMode(.screen)
for (x, y, radius, alpha) in [
    (425.0, 420.0, 42.0, 0.68), (560.0, 365.0, 30.0, 0.54),
    (650.0, 440.0, 20.0, 0.42), (350.0, 355.0, 15.0, 0.34)
] {
    radialGlow(
        center: CGPoint(x: x, y: y),
        radius: radius * 2.4,
        inner: color(1, 0.82, 0.32, alpha),
        outer: color(1, 0.82, 0.32, 0)
    )
}
context.setBlendMode(.normal)

guard
    let image = context.makeImage(),
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
        "public.png" as CFString,
        1,
        nil
    )
else {
    fatalError("Unable to encode icon")
}

CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination) else {
    fatalError("Unable to write icon")
}
