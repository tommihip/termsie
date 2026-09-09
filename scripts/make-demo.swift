#!/usr/bin/env swift
//
// Assembles the PNG frames written by `Termsie --record` into an animated GIF
// and an H.264 .mp4.
//
//   swift scripts/make-demo.swift <frames-dir> <output-basename> [width]
//
// Both are produced because they are for different places: X and most social
// sites re-encode a GIF to video anyway and the round trip looks worse than
// handing them a video directly, while a GIF is what renders inline in a
// GitHub README. Playback timing comes from the timing.txt the recorder writes,
// since ScreenCaptureKit cannot keep up with the requested frame rate and
// assuming it did would play the demo back too fast.
//
import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-demo.swift <frames-dir> <out-basename> [width]\n".utf8))
    exit(2)
}
let framesDir = URL(fileURLWithPath: args[1], isDirectory: true)
let outBase = args[2]
let targetWidth = args.count > 3 ? Int(args[3]) ?? 900 : 900

let fm = FileManager.default
let frameURLs = (try? fm.contentsOfDirectory(at: framesDir, includingPropertiesForKeys: nil))?
    .filter { $0.lastPathComponent.hasPrefix("frame-") && ["jpg", "png"].contains($0.pathExtension) }
    .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

guard !frameURLs.isEmpty else {
    FileHandle.standardError.write(Data("no frames in \(framesDir.path)\n".utf8))
    exit(1)
}

// Per-frame delays from the recorder's timestamps, falling back to a flat rate.
var delays: [Double]
if let text = try? String(contentsOf: framesDir.appendingPathComponent("timing.txt"), encoding: .utf8) {
    let stamps = text.split(separator: "\n").compactMap { Double($0) }
    delays = (0..<frameURLs.count).map { i in
        guard i + 1 < stamps.count else { return i < stamps.count && i > 0 ? stamps[i] - stamps[i - 1] : 0.1 }
        return max(0.02, stamps[i + 1] - stamps[i])
    }
} else {
    delays = Array(repeating: 0.1, count: frameURLs.count)
}

func load(_ url: URL, width: Int) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: width,
    ]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary)
}

// ------------------------------------------------------------------ GIF
let gifURL = URL(fileURLWithPath: outBase + ".gif")
guard let gif = CGImageDestinationCreateWithURL(
    gifURL as CFURL, UTType.gif.identifier as CFString, frameURLs.count, nil) else {
    FileHandle.standardError.write(Data("could not create \(gifURL.path)\n".utf8))
    exit(1)
}
CGImageDestinationSetProperties(gif, [
    kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
] as CFDictionary)

for (i, url) in frameURLs.enumerated() {
    guard let image = load(url, width: targetWidth) else { continue }
    CGImageDestinationAddImage(gif, image, [
        kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFUnclampedDelayTime: delays[i]]
    ] as CFDictionary)
}
guard CGImageDestinationFinalize(gif) else {
    FileHandle.standardError.write(Data("gif finalize failed\n".utf8))
    exit(1)
}

// ------------------------------------------------------------------ MP4
let mp4URL = URL(fileURLWithPath: outBase + ".mp4")
try? fm.removeItem(at: mp4URL)

guard let first = load(frameURLs[0], width: targetWidth) else { exit(1) }
// H.264 requires even dimensions.
let vw = first.width - (first.width % 2)
let vh = first.height - (first.height % 2)

let writer = try AVAssetWriter(outputURL: mp4URL, fileType: .mp4)
let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
    AVVideoCodecKey: AVVideoCodecType.h264,
    AVVideoWidthKey: vw,
    AVVideoHeightKey: vh,
    AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 4_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
    ],
])
input.expectsMediaDataInRealTime = false
let adaptor = AVAssetWriterInputPixelBufferAdaptor(
    assetWriterInput: input,
    sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: vw,
        kCVPixelBufferHeightKey as String: vh,
    ])
writer.add(input)
writer.startWriting()
writer.startSession(atSourceTime: .zero)

let scale: Int32 = 600
var elapsed = 0.0
for (i, url) in frameURLs.enumerated() {
    guard let image = load(url, width: targetWidth) else { continue }
    var pixelBuffer: CVPixelBuffer?
    CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &pixelBuffer)
    guard let buffer = pixelBuffer else { continue }
    CVPixelBufferLockBaseAddress(buffer, [])
    if let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer),
        width: vw, height: vh, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue) {
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: vw, height: vh))
    }
    CVPixelBufferUnlockBaseAddress(buffer, [])

    while !input.isReadyForMoreMediaData { usleep(2000) }
    adaptor.append(buffer, withPresentationTime: CMTime(
        value: CMTimeValue(elapsed * Double(scale)), timescale: scale))
    elapsed += delays[i]
}
input.markAsFinished()
let sem = DispatchSemaphore(value: 0)
writer.finishWriting { sem.signal() }
sem.wait()

func size(_ url: URL) -> String {
    let bytes = ((try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int) ?? 0
    return String(format: "%.1f MB", Double(bytes) / 1_048_576)
}
print("frames: \(frameURLs.count)  duration: \(String(format: "%.1f", elapsed))s  width: \(targetWidth)px")
print("gif: \(gifURL.path) (\(size(gifURL)))")
print("mp4: \(mp4URL.path) (\(size(mp4URL)))  status=\(writer.status.rawValue)")
