import Foundation

public struct DerivedMediaIndex: Codable, Sendable {
    public let schemaVersion: Int
    public let encoderVersion: String
    public var proxies: [DerivedMediaProxy]

    public init(schemaVersion: Int = 1, encoderVersion: String, proxies: [DerivedMediaProxy]) {
        self.schemaVersion = schemaVersion
        self.encoderVersion = encoderVersion
        self.proxies = proxies
    }

    public func proxy(assetID: String, baseName: String) -> DerivedMediaProxy? {
        proxies.first { $0.assetID == assetID && $0.baseName == baseName }
    }
}

public struct DerivedMediaProxy: Codable, Sendable, Equatable {
    public let assetID: String
    public let baseName: String
    public let relativePath: String
    public let sourceDigest: String
    public let frameCount: Int
    public let framesPerSecond: Int
    public let width: Int
    public let height: Int
    public let containsAlpha: Bool
    public let codec: String

    public init(assetID: String, baseName: String, relativePath: String, sourceDigest: String,
                frameCount: Int, framesPerSecond: Int, width: Int, height: Int,
                containsAlpha: Bool, codec: String) {
        self.assetID = assetID
        self.baseName = baseName
        self.relativePath = relativePath
        self.sourceDigest = sourceDigest
        self.frameCount = frameCount
        self.framesPerSecond = framesPerSecond
        self.width = width
        self.height = height
        self.containsAlpha = containsAlpha
        self.codec = codec
    }

    /// AVFoundation can expose an empty drawable at exactly t=0 for an
    /// HEVC-with-alpha proxy even though source frame zero is populated. The
    /// first decoded 24 fps frame is available one frame later. Trimming that
    /// decoder-only lead frame preserves the authored visual sequence and
    /// prevents a transparent pulse at concatenation boundaries.
    public var leadingDecodeTrim: TimeInterval {
        guard containsAlpha, framesPerSecond > 0, frameCount > 2 else { return 0 }
        return 1.0 / Double(framesPerSecond)
    }
}

public struct DerivedMediaStore: Sendable {
    public let root: URL
    public let index: DerivedMediaIndex

    public init?(root: URL) {
        let indexURL = root.appendingPathComponent("derived-media-index.json")
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode(DerivedMediaIndex.self, from: data),
              decoded.schemaVersion == 1 else { return nil }
        self.root = root
        self.index = decoded
    }

    public func url(assetID: String, baseName: String) -> URL? {
        guard let proxy = index.proxy(assetID: assetID, baseName: baseName),
              !proxy.relativePath.contains(".."), !proxy.relativePath.hasPrefix("/") else { return nil }
        let url = root.appendingPathComponent(proxy.relativePath)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func proxy(for url: URL) -> DerivedMediaProxy? {
        let rootPath = root.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relativePath = String(path.dropFirst(rootPath.count + 1))
        return index.proxies.first { $0.relativePath == relativePath }
    }
}
