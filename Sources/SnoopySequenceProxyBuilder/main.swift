import AVFoundation
import CoreVideo
import CryptoKit
import Foundation
import ImageIO
import SnoopyTVCore
import VideoToolbox

private let encoderVersion = "snoopy-hevc-alpha-v2"
private let fps = 24

private struct Arguments {
    let indexURL: URL
    let outputURL: URL
    let onlyAssetID: String?

    init() throws {
        let values = Array(CommandLine.arguments.dropFirst())
        guard let indexPosition = values.firstIndex(of: "--index"), indexPosition + 1 < values.count,
              let outputPosition = values.firstIndex(of: "--output"), outputPosition + 1 < values.count else {
            throw NSError(domain: "SnoopyProxyBuilder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "usage: SnoopySequenceProxyBuilder --index asset-index.json --output DIR [--asset ID]"])
        }
        indexURL = URL(fileURLWithPath: values[indexPosition + 1]).standardizedFileURL
        outputURL = URL(fileURLWithPath: values[outputPosition + 1]).standardizedFileURL
        if let position = values.firstIndex(of: "--asset"), position + 1 < values.count {
            onlyAssetID = values[position + 1]
        } else {
            onlyAssetID = nil
        }
    }
}

private func naturalNumber(_ name: String) -> Int {
    let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
    return Int(String(stem.reversed().prefix(while: { $0.isNumber }).reversed())) ?? 0
}

private func digest(urls: [URL]) throws -> String {
    var hasher = SHA256()
    hasher.update(data: Data(encoderVersion.utf8))
    for url in urls {
        hasher.update(data: Data(url.lastPathComponent.utf8))
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            hasher.update(data: data)
        }
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

private func image(at url: URL) -> CGImage? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: 1920,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
}

private func hasAlpha(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly: return true
    default: return false
    }
}

private func pixelBuffer(from image: CGImage, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
    var optional: CVPixelBuffer?
    let status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional)
    guard status == kCVReturnSuccess, let buffer = optional else {
        throw NSError(domain: "SnoopyProxyBuilder", code: Int(status),
                      userInfo: [NSLocalizedDescriptionKey: "unable to allocate pixel buffer"])
    }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let address = CVPixelBufferGetBaseAddress(buffer),
          let context = CGContext(
            data: address, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
          ) else {
        throw NSError(domain: "SnoopyProxyBuilder", code: 3,
                      userInfo: [NSLocalizedDescriptionKey: "unable to create BGRA context"])
    }
    context.clear(CGRect(x: 0, y: 0, width: image.width, height: image.height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
                          kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
    return buffer
}

private func encode(urls: [URL], output: URL) throws -> (width: Int, height: Int, alpha: Bool) {
    guard let first = image(at: urls[0]) else {
        throw NSError(domain: "SnoopyProxyBuilder", code: 4,
                      userInfo: [NSLocalizedDescriptionKey: "unable to decode \(urls[0].path)"])
    }
    let alpha = hasAlpha(first)
    try? FileManager.default.removeItem(at: output)
    try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: output, fileType: .mov)
    var compression: [String: Any] = [AVVideoExpectedSourceFrameRateKey: fps]
    if alpha { compression[kVTCompressionPropertyKey_TargetQualityForAlpha as String] = 0.8 }
    let settings: [String: Any] = [
        AVVideoCodecKey: alpha ? AVVideoCodecType.hevcWithAlpha : AVVideoCodecType.hevc,
        AVVideoWidthKey: first.width,
        AVVideoHeightKey: first.height,
        AVVideoCompressionPropertiesKey: compression,
    ]
    let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: first.width,
            kCVPixelBufferHeightKey as String: first.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ]
    )
    guard writer.canAdd(input) else { throw writer.error ?? NSError(domain: "SnoopyProxyBuilder", code: 5) }
    writer.add(input)
    guard writer.startWriting() else { throw writer.error ?? NSError(domain: "SnoopyProxyBuilder", code: 6) }
    writer.startSession(atSourceTime: .zero)
    guard let pool = adaptor.pixelBufferPool else {
        throw NSError(domain: "SnoopyProxyBuilder", code: 7,
                      userInfo: [NSLocalizedDescriptionKey: "pixel buffer pool unavailable"])
    }
    for (index, url) in urls.enumerated() {
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed { throw writer.error ?? NSError(domain: "SnoopyProxyBuilder", code: 8) }
            Thread.sleep(forTimeInterval: 0.002)
        }
        guard let frame = index == 0 ? first : image(at: url), frame.width == first.width, frame.height == first.height else {
            throw NSError(domain: "SnoopyProxyBuilder", code: 9,
                          userInfo: [NSLocalizedDescriptionKey: "invalid frame geometry: \(url.lastPathComponent)"])
        }
        let buffer = try autoreleasepool { try pixelBuffer(from: frame, pool: pool) }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(index), timescale: CMTimeScale(fps))) else {
            throw writer.error ?? NSError(domain: "SnoopyProxyBuilder", code: 10)
        }
    }
    // End the session explicitly so even a one-frame sequence has an exact
    // 1/24-second duration instead of inheriting a container default rate.
    writer.endSession(atSourceTime: CMTime(value: CMTimeValue(urls.count), timescale: CMTimeScale(fps)))
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else { throw writer.error ?? NSError(domain: "SnoopyProxyBuilder", code: 11) }
    return (first.width, first.height, alpha)
}

@main
private enum Main {
    static func main() throws {
        let arguments = try Arguments()
        let store = try AssetStore(indexURL: arguments.indexURL)
        try FileManager.default.createDirectory(at: arguments.outputURL, withIntermediateDirectories: true)
        let oldIndexURL = arguments.outputURL.appendingPathComponent("derived-media-index.json")
        let oldIndex = (try? Data(contentsOf: oldIndexURL)).flatMap { try? JSONDecoder().decode(DerivedMediaIndex.self, from: $0) }
        var records: [DerivedMediaProxy] = []
        let assets = store.index.assets.filter { arguments.onlyAssetID == nil || $0.id == arguments.onlyAssetID }
        for asset in assets {
            guard let directory = try? store.url(for: asset) else { continue }
            for sprite in asset.sprites where sprite.spriteType == "frameSequence" {
                guard let baseName = sprite.assetBaseName else { continue }
                let names = (asset.media ?? []).compactMap(\.name).filter {
                    $0.hasPrefix(baseName + "_") && URL(fileURLWithPath: $0).pathExtension.lowercased() == "heic"
                }.sorted { naturalNumber($0) < naturalNumber($1) }
                let urls = names.map { directory.appendingPathComponent($0) }
                guard !urls.isEmpty else { continue }
                let sourceDigest = try digest(urls: urls)
                let bundle = asset.bundle ?? "unbundled"
                let relativePath = "\(bundle)/\(asset.id)/\(baseName).mov"
                let output = arguments.outputURL.appendingPathComponent(relativePath)
                if oldIndex?.encoderVersion == encoderVersion,
                   let existing = oldIndex?.proxy(assetID: asset.id, baseName: baseName),
                   existing.sourceDigest == sourceDigest,
                   FileManager.default.fileExists(atPath: output.path) {
                    records.append(existing)
                    print("cached \(asset.id)/\(baseName)")
                    continue
                }
                print("encoding \(asset.id)/\(baseName) (\(urls.count) frames)")
                let result = try encode(urls: urls, output: output)
                records.append(DerivedMediaProxy(
                    assetID: asset.id, baseName: baseName, relativePath: relativePath,
                    sourceDigest: sourceDigest, frameCount: urls.count, framesPerSecond: fps,
                    width: result.width, height: result.height, containsAlpha: result.alpha,
                    codec: result.alpha ? "hevcWithAlpha" : "hevc"
                ))
            }
        }
        if arguments.onlyAssetID != nil, let oldIndex {
            let generatedKeys = Set(records.map { "\($0.assetID)/\($0.baseName)" })
            records.append(contentsOf: oldIndex.proxies.filter { !generatedKeys.contains("\($0.assetID)/\($0.baseName)") })
        }
        records.sort { ($0.assetID, $0.baseName) < ($1.assetID, $1.baseName) }
        let result = DerivedMediaIndex(encoderVersion: encoderVersion, proxies: records)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(result).write(to: oldIndexURL, options: .atomic)
        print("proxies=\(records.count) index=\(oldIndexURL.path)")
    }
}
