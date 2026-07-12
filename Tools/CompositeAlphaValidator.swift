import AVFoundation
import CoreGraphics
import Foundation

@main
enum CompositeAlphaValidator {
    struct Sample {
        let label: String
        let image: CGImage
    }

    static func image(from asset: AVAsset, seconds: TimeInterval) throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 24_000), actualTime: nil
        )
    }

    static func alphaCoverage(_ image: CGImage) -> Double {
        let width = 320
        let height = max(1, Int(Double(image.height) / Double(image.width) * Double(width)))
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return 0 }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let visible = stride(from: 3, to: pixels.count, by: 4).reduce(into: 0) { count, index in
            if pixels[index] > 8 { count += 1 }
        }
        return Double(visible) / Double(width * height)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 3 else {
            throw NSError(
                domain: "CompositeAlphaValidator", code: 2,
                userInfo: [NSLocalizedDescriptionKey: "usage: validator Intro.mov Loop.mov"]
            )
        }
        let intro = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[1]))
        let loop = AVURLAsset(url: URL(fileURLWithPath: CommandLine.arguments[2]))
        let composition = AVMutableComposition()
        guard let introTrack = intro.tracks(withMediaType: .video).first,
              let loopTrack = loop.tracks(withMediaType: .video).first,
              let destination = composition.addMutableTrack(
                  withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
              ) else { throw NSError(domain: "CompositeAlphaValidator", code: 3) }

        var cursor = CMTime.zero
        for (asset, track) in [(intro, introTrack), (loop, loopTrack), (loop, loopTrack)] {
            try destination.insertTimeRange(
                CMTimeRange(start: .zero, duration: asset.duration), of: track, at: cursor
            )
            cursor = CMTimeAdd(cursor, asset.duration)
        }
        let introSeconds = intro.duration.seconds
        let loopSeconds = loop.duration.seconds
        let samples = [
            Sample(label: "source-intro", image: try image(from: intro, seconds: min(0.5, introSeconds / 2))),
            Sample(label: "source-loop", image: try image(from: loop, seconds: min(0.5, loopSeconds / 2))),
            Sample(label: "composition-intro", image: try image(from: composition, seconds: min(0.5, introSeconds / 2))),
            Sample(label: "composition-loop-1", image: try image(from: composition, seconds: introSeconds + min(0.5, loopSeconds / 2))),
            Sample(label: "composition-loop-2", image: try image(from: composition, seconds: introSeconds + loopSeconds + min(0.5, loopSeconds / 2))),
        ]
        for sample in samples {
            print("\(sample.label) alphaCoverage=\(String(format: "%.6f", alphaCoverage(sample.image))) alphaInfo=\(sample.image.alphaInfo.rawValue)")
        }
    }
}
