import AVFoundation
import Foundation

@main
enum VideoPlaceholderValidator {
    static func main() throws {
        guard (2...3).contains(CommandLine.arguments.count) else {
            throw NSError(domain: "VideoPlaceholderValidator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "usage: VideoPlaceholderValidator asset-index.json [derived-media-root]"])
        }
        let store = try AssetStore(indexURL: URL(fileURLWithPath: CommandLine.arguments[1]))
        let derived = CommandLine.arguments.count == 3
            ? DerivedMediaStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            : nil
        var checked = 0
        var failures: [String] = []
        for asset in store.playableAssets() {
            for sprite in asset.sprites {
                guard let baseName = sprite.assetBaseName else { continue }
                var url: URL?
                if let directory = try? store.url(for: asset) {
                    let name = asset.media?.first(where: { $0.name == baseName + ".mov" })?.name ?? baseName + ".mov"
                    let candidate = directory.appendingPathComponent(name)
                    if FileManager.default.fileExists(atPath: candidate.path) { url = candidate }
                }
                if url == nil { url = derived?.url(assetID: asset.id, baseName: baseName) }
                guard let url else { continue }
                let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
                generator.appliesPreferredTrackTransform = true
                generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
                generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
                do {
                    _ = try generator.copyCGImage(
                        at: CMTime(seconds: 0.04, preferredTimescale: 600), actualTime: nil
                    )
                    checked += 1
                } catch {
                    failures.append("\(asset.id)/\(baseName): \(error.localizedDescription)")
                }
            }
        }
        print("placeholder frames checked=\(checked) failures=\(failures.count)")
        failures.forEach { print($0) }
        if !failures.isEmpty { exit(1) }
    }
}
