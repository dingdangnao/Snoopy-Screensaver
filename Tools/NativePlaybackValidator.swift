import Foundation

@main
enum NativePlaybackValidator {
    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            throw NSError(domain: "NativePlaybackValidator", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "usage: NativePlaybackValidator asset-index.json"])
        }
        let indexURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let store = try AssetStore(indexURL: indexURL)
        let derivedStore = DerivedMediaStore(
            root: indexURL.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".derived-media", isDirectory: true)
        )
        let assets = store.index.assets
        let graph = PlaybackGraph(assets: assets)
        var errors: [String] = []

        func videoExists(_ asset: AssetRecord, _ sprite: SpriteRecord) -> Bool {
            guard let directory = try? store.url(for: asset),
                  let base = sprite.assetBaseName else { return false }
            let name = asset.media?.first(where: { $0.name == base + ".mov" })?.name
                ?? base + ".mov"
            if FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path
            ) { return true }
            return derivedStore?.url(assetID: asset.id, baseName: base) != nil
        }

        let basePoses = assets.filter { $0.kind == "characterBasePose" }
        let baseIDs = Set(basePoses.map(\.id))
        let actions = assets.filter { $0.kind == "characterAdditionalPose" || $0.kind == "characterMoment" }
        for action in actions {
            guard let start = action.startCharacterBasePoseID, let end = action.endCharacterBasePoseID else {
                errors.append("\(action.id): missing From/To base pose")
                continue
            }
            if !baseIDs.contains(start) { errors.append("\(action.id): unknown start \(start)") }
            if !baseIDs.contains(end) { errors.append("\(action.id): unknown end \(end)") }
            for current in baseIDs where graph.animationQueue(currentPoseID: current, target: action) == nil {
                errors.append("\(action.id): no queue from \(current) to \(start)")
            }
        }
        for start in baseIDs {
            for end in baseIDs where graph.reactionQueue(from: start, to: end) == nil {
                errors.append("reaction: no queue \(start) -> RPH -> \(end)")
            }
        }

        let idleScenes = assets.filter { $0.kind == "idleScene" }
        let idleIDs = Set(idleScenes.map(\.id))
        var videoIdleCount = 0
        for idle in idleScenes {
            guard let directory = try? store.url(for: idle) else {
                errors.append("\(idle.id): invalid directory")
                continue
            }
            var playable = false
            for sprite in idle.sprites {
                if sprite.spriteType == "video" { videoIdleCount += 1 }
                guard let base = sprite.assetBaseName else { continue }
                playable = playable || (idle.media ?? []).contains { media in
                    guard let name = media.name else { return false }
                    return name == base + ".mov" || name.hasPrefix(base + "_")
                }
            }
            if !playable || !FileManager.default.fileExists(atPath: directory.path) {
                errors.append("\(idle.id): no playable background")
            }
        }

        let palettes = assets.filter { $0.kind == "scenePalette" }
        for palette in palettes {
            for parent in palette.scenePalette?.parentIdleSceneIDs ?? [] where !idleIDs.contains(parent) {
                errors.append("\(palette.id): unknown parent idle \(parent)")
            }
        }

        let activeScenes = assets.filter { $0.kind == "activeScene" }
        var transitionReferenceCount = 0
        for active in activeScenes {
            let candidates = graph.transitionCandidates(for: active)
            if candidates.isEmpty { errors.append("\(active.id): no scene transition candidates") }
            for candidate in candidates {
                transitionReferenceCount += 1
                for (phase, parameterID) in [("hide", candidate.hideParametersID), ("reveal", candidate.revealParametersID)] {
                    guard let parameterID, let parameter = graph.assetsByID[parameterID] else {
                        errors.append("\(candidate.pairID): missing \(phase) parameters")
                        continue
                    }
                    if !parameter.sprites.contains(where: { $0.plane == "mask" }) {
                        errors.append("\(parameterID): missing mask")
                    }
                    if !parameter.sprites.contains(where: { $0.plane == "foregroundEffect" }) {
                        errors.append("\(parameterID): missing outline")
                    }
                    if !parameter.sprites.contains(where: { $0.plane == "mask" && videoExists(parameter, $0) }) {
                        errors.append("\(parameterID): mask media unavailable")
                    }
                    if !parameter.sprites.contains(where: {
                        $0.plane == "foregroundEffect" && videoExists(parameter, $0)
                    }) {
                        errors.append("\(parameterID): outline media unavailable")
                    }
                }
                for id in candidate.hideCharacterPoseIDs {
                    if graph.assetsByID[id]?.transitionPhase != "hide" { errors.append("\(id): not hide phase") }
                    if let pose = graph.assetsByID[id], !pose.sprites.contains(where: { videoExists(pose, $0) }) {
                        errors.append("\(id): hide pose media unavailable")
                    }
                }
                for id in candidate.revealCharacterPoseIDs {
                    if graph.assetsByID[id]?.transitionPhase != "reveal" { errors.append("\(id): not reveal phase") }
                    if let pose = graph.assetsByID[id], !pose.sprites.contains(where: { videoExists(pose, $0) }) {
                        errors.append("\(id): reveal pose media unavailable")
                    }
                }
            }
        }

        let visitors = assets.filter { $0.kind == "idleSceneVisitor" }
        let visitorPlanes = Dictionary(grouping: visitors) {
            $0.sprites.first?.plane ?? "unknown"
        }.mapValues(\.count)
        for visitor in visitors where !visitor.sprites.contains(where: { videoExists(visitor, $0) }) {
            errors.append("\(visitor.id): visitor media unavailable")
        }

        let state = PlaybackSessionState()
        for seed in UInt64(0)..<200 {
            if !(5...10).contains(state.loopCount(seed: seed)) { errors.append("phased loop out of range") }
            if !(6...10).contains(state.basePoseLoopCount(seed: seed)) { errors.append("base pose loop out of range") }
            if !(2...4).contains(state.additionalPoseLoopCount(seed: seed)) { errors.append("additional pose loop out of range") }
            if !(4...7).contains(state.sustainedAdditionalPoseLoopCount(seed: seed)) { errors.append("sustained AP loop out of range") }
            if !(2...3).contains(state.restingLoopCount(seed: seed)) { errors.append("resting loop out of range") }
            if !(2...4).contains(state.visitorLoopCount(seed: seed)) { errors.append("visitor loop out of range") }
        }

        let result: [String: Any] = [
            "assets": assets.count,
            "idleScenes": idleScenes.count,
            "videoIdleScenes": videoIdleCount,
            "actions": actions.count,
            "transitionReferences": transitionReferenceCount,
            "visitors": visitors.count,
            "visitorPlanes": visitorPlanes,
            "errors": errors,
        ]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if !errors.isEmpty { exit(1) }
    }
}
