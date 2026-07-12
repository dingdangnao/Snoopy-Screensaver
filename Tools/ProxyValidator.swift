import AVFoundation
import Foundation

struct ProxyIndex: Decodable {
    let encoderVersion: String
    let proxies: [Proxy]
}

struct Proxy: Decodable {
    let assetID: String
    let baseName: String
    let relativePath: String
    let frameCount: Int
    let framesPerSecond: Int
    let containsAlpha: Bool
    let width: Int
    let height: Int
}

guard CommandLine.arguments.count == 2 else {
    fputs("usage: ProxyValidator DERIVED_MEDIA_DIRECTORY\n", stderr)
    exit(2)
}

let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let index = try JSONDecoder().decode(
    ProxyIndex.self,
    from: Data(contentsOf: root.appendingPathComponent("derived-media-index.json"))
)
var errors: [String] = []
var totalBytes: UInt64 = 0
for proxy in index.proxies {
    let url = root.appendingPathComponent(proxy.relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
        errors.append("\(proxy.assetID)/\(proxy.baseName): missing")
        continue
    }
    totalBytes += (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .video).first else {
        errors.append("\(proxy.assetID)/\(proxy.baseName): no video track")
        continue
    }
    let expectedDuration = Double(proxy.frameCount) / Double(proxy.framesPerSecond)
    if abs(asset.duration.seconds - expectedDuration) > 0.002 {
        errors.append("\(proxy.assetID)/\(proxy.baseName): duration \(asset.duration.seconds), expected \(expectedDuration)")
    }
    if proxy.frameCount > 1, abs(Double(track.nominalFrameRate) - Double(proxy.framesPerSecond)) > 0.01 {
        errors.append("\(proxy.assetID)/\(proxy.baseName): fps \(track.nominalFrameRate)")
    }
    if proxy.containsAlpha && !track.hasMediaCharacteristic(.containsAlphaChannel) {
        errors.append("\(proxy.assetID)/\(proxy.baseName): alpha characteristic missing")
    }
    let size = track.naturalSize
    if Int(abs(size.width)) != proxy.width || Int(abs(size.height)) != proxy.height {
        errors.append("\(proxy.assetID)/\(proxy.baseName): geometry \(size)")
    }
}

let result: [String: Any] = [
    "encoderVersion": index.encoderVersion,
    "proxyCount": index.proxies.count,
    "totalBytes": totalBytes,
    "errors": errors,
]
let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: data, as: UTF8.self))
exit(errors.isEmpty ? 0 : 1)
