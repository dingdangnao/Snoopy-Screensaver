import Foundation

@main
struct IndexSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "IndexSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: "usage: IndexSmoke <asset-index.json>"])
        }
        let indexURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundledRoot = indexURL.deletingLastPathComponent().appendingPathComponent("SnoopyAssets")
        let store = try AssetStore(indexURL: indexURL, assetsRootOverride: bundledRoot)
        let playable = store.playableAssets()
        guard store.index.assets.count == 397, playable.count == 284, store.activeScenes().count == 73 else {
            throw NSError(domain: "IndexSmoke", code: 3, userInfo: [NSLocalizedDescriptionKey: "unexpected inventory: total=\(store.index.assets.count), playable=\(playable.count), activeScenes=\(store.activeScenes().count)"])
        }
        let firstURL = try store.url(for: playable[0])
        guard FileManager.default.fileExists(atPath: firstURL.path) else {
            throw NSError(domain: "IndexSmoke", code: 4, userInfo: [NSLocalizedDescriptionKey: "missing first asset directory: \(firstURL.path)"])
        }
        print("index smoke OK: 397 indexed, 284 media assets, 73 active scenes")
    }
}
