#!/usr/bin/env swift
import Cocoa

let W = 600, H = 400

let img = NSImage(size: NSSize(width: W, height: H))
img.lockFocus()
let cg = NSGraphicsContext.current!.cgContext

let w = CGFloat(W), h = CGFloat(H)

// Background gradient (dark navy → purple)
let bgColors = [
    CGColor(red: 0.06, green: 0.05, blue: 0.16, alpha: 1.0),
    CGColor(red: 0.12, green: 0.07, blue: 0.24, alpha: 1.0),
]
let bg = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: bgColors as CFArray, locations: [0, 1])!
cg.drawLinearGradient(bg, start: .zero, end: CGPoint(x: w, y: h), options: [])

// Glows
for (cx, cy, r, g, b, rad) in [
    (w*0.28, h*0.55, 0.15, 0.25, 0.85, 200.0),
    (w*0.72, h*0.55, 0.7, 0.15, 0.6,  180.0),
    (w*0.50, h*0.50, 0.35, 0.25, 0.75, 140.0),
] as [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] {
    let gc = [CGColor(red: r, green: g, blue: b, alpha: 0.10),
              CGColor(red: r, green: g, blue: b, alpha: 0.0)]
    let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: gc as CFArray, locations: [0, 1])!
    cg.drawRadialGradient(g, startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                          endCenter: CGPoint(x: cx, y: cy), endRadius: rad, options: [])
}

// Dashed arrow (center, pointing right)
let ay = h * 0.50
let x1 = w * 0.39, x2 = w * 0.61

cg.setStrokeColor(CGColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 0.6))
cg.setLineWidth(2.0)
cg.setLineCap(.round)
cg.setLineDash(phase: 0, lengths: [7, 5])
cg.move(to: CGPoint(x: x1, y: ay))
cg.addLine(to: CGPoint(x: x2 - 12, y: ay))
cg.strokePath()
cg.setLineDash(phase: 0, lengths: [])

// Arrowhead
cg.setFillColor(CGColor(red: 0.55, green: 0.65, blue: 1.0, alpha: 0.7))
cg.move(to: CGPoint(x: x2, y: ay))
cg.addLine(to: CGPoint(x: x2 - 13, y: ay + 8))
cg.addLine(to: CGPoint(x: x2 - 13, y: ay - 8))
cg.closePath()
cg.fillPath()

// Top title
let title = "声 Koe をインストール" as NSString
let titleAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 15, weight: .semibold),
    .foregroundColor: NSColor(red: 0.82, green: 0.84, blue: 0.95, alpha: 0.9)
]
let ts = title.size(withAttributes: titleAttrs)
title.draw(at: NSPoint(x: (w - ts.width) / 2, y: h - 46), withAttributes: titleAttrs)

// Bottom instruction
let sub = "Koe.app を Applications にドラッグしてください" as NSString
let subAttrs: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 11, weight: .regular),
    .foregroundColor: NSColor(red: 0.55, green: 0.55, blue: 0.7, alpha: 0.65)
]
let ss = sub.size(withAttributes: subAttrs)
sub.draw(at: NSPoint(x: (w - ss.width) / 2, y: 16), withAttributes: subAttrs)

img.unlockFocus()

// Save Retina (2x)
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: W*2, pixelsHigh: H*2,
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: W, height: H)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: W, height: H),
         from: .zero, operation: .copy, fraction: 1.0)
NSGraphicsContext.restoreGraphicsState()

let data = rep.representation(using: .png, properties: [.interlaced: true])!
let out = URL(fileURLWithPath: CommandLine.arguments.count > 1
              ? CommandLine.arguments[1] : "/tmp/koe-dmg-bg.png")
try! data.write(to: out)
print("Created: \(out.path)")
