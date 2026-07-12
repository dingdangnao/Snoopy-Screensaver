import Foundation

public enum CharacterAnimationKind: String, Sendable, CaseIterable {
    case basePose
    case additionalPose
    case moment
}

public struct WeightedAsset: Sendable {
    public let asset: AssetRecord
    public let weight: Int

    public init(asset: AssetRecord, weight: Int) {
        self.asset = asset
        self.weight = max(1, weight)
    }
}

public struct PlaybackSessionState: Sendable {
    public var currentBasePoseID: String?
    public var currentIdleSceneID: String?
    public private(set) var usedIDsByPool: [String: Set<String>] = [:]
    public private(set) var lastSelectedIDByPool: [String: String] = [:]
    public private(set) var recentTransitionPairIDs: [String] = []
    public private(set) var characterDurationByKind: [CharacterAnimationKind: TimeInterval] = [:]
    public private(set) var requiresBasePoseAfterVariation = false

    /// Values emitted by Apple's CharacterAnimationManager on tvOS 18.2.
    public static let targetCharacterRatios: [CharacterAnimationKind: Double] = [
        .basePose: 0.71,
        .additionalPose: 0.20,
        .moment: 0.09,
    ]

    public init(currentBasePoseID: String? = nil, currentIdleSceneID: String? = nil) {
        self.currentBasePoseID = currentBasePoseID
        self.currentIdleSceneID = currentIdleSceneID
    }

    /// A no-replacement session choice. A pool is reset only after every
    /// currently eligible item has been used.
    public mutating func choose(from assets: [AssetRecord], pool: String, seed: UInt64) -> AssetRecord? {
        guard !assets.isEmpty else { return nil }
        var used = usedIDsByPool[pool, default: []]
        var candidates = assets.filter { !used.contains($0.id) }
        if candidates.isEmpty {
            used.removeAll()
            candidates = assets
        }
        if let lastID = lastSelectedIDByPool[pool],
           Set(candidates.map(\.id)).count > 1 {
            candidates.removeAll { $0.id == lastID }
        }
        let sorted = candidates.sorted { $0.id < $1.id }
        let selected = sorted[Int(Self.mix(seed ^ UInt64(sorted.count)) % UInt64(sorted.count))]
        used.insert(selected.id)
        usedIDsByPool[pool] = used
        lastSelectedIDByPool[pool] = selected.id
        return selected
    }

    /// A no-replacement weighted choice. Duplicate historical copies of an
    /// asset ID are collapsed so they cannot receive accidental extra weight.
    public mutating func chooseWeighted(
        from weightedAssets: [WeightedAsset], pool: String, seed: UInt64
    ) -> AssetRecord? {
        guard !weightedAssets.isEmpty else { return nil }
        let unique = weightedAssets.reduce(into: [String: WeightedAsset]()) { result, entry in
            if let existing = result[entry.asset.id], existing.weight >= entry.weight { return }
            result[entry.asset.id] = entry
        }
        var used = usedIDsByPool[pool, default: []]
        var candidates = unique.values.filter { !used.contains($0.asset.id) }
        if candidates.isEmpty {
            used.removeAll()
            candidates = Array(unique.values)
        }
        if let lastID = lastSelectedIDByPool[pool], candidates.count > 1 {
            candidates.removeAll { $0.asset.id == lastID }
        }
        candidates.sort { $0.asset.id < $1.asset.id }
        let totalWeight = candidates.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return nil }
        var ticket = Int(Self.mix(seed ^ UInt64(candidates.count)) % UInt64(totalWeight))
        let selected = candidates.first { entry in
            if ticket < entry.weight { return true }
            ticket -= entry.weight
            return false
        } ?? candidates[candidates.count - 1]
        used.insert(selected.asset.id)
        usedIDsByPool[pool] = used
        lastSelectedIDByPool[pool] = selected.asset.id
        return selected.asset
    }

    public func lastSelectedID(in pool: String) -> String? {
        lastSelectedIDByPool[pool]
    }

    public static func mixedIndex(seed: UInt64, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(mix(seed ^ UInt64(count)) % UInt64(count))
    }

    public mutating func resetCharacterMix() {
        characterDurationByKind.removeAll()
        requiresBasePoseAfterVariation = false
    }

    public mutating func recordCharacterAnimation(_ kind: CharacterAnimationKind, duration: TimeInterval) {
        characterDurationByKind[kind, default: 0] += max(0, duration)
        requiresBasePoseAfterVariation = kind != .basePose
    }

    public func characterRatio(for kind: CharacterAnimationKind) -> Double {
        let total = characterDurationByKind.values.reduce(0, +)
        return total > 0 ? characterDurationByKind[kind, default: 0] / total : 0
    }

    /// Apple balances elapsed animation time, not item counts. Variations are
    /// chosen from whichever target pools are currently underrepresented;
    /// after every AP or Moment, the next animation is unconditionally a BP.
    public func nextCharacterAnimationKind(
        available: Set<CharacterAnimationKind>, seed: UInt64
    ) -> CharacterAnimationKind? {
        guard !available.isEmpty else { return nil }
        if requiresBasePoseAfterVariation, available.contains(.basePose) { return .basePose }
        if characterDurationByKind.values.reduce(0, +) == 0, available.contains(.basePose) { return .basePose }

        let ordered = CharacterAnimationKind.allCases.filter(available.contains)
        let deficits = ordered.map { kind in
            max(0, Self.targetCharacterRatios[kind, default: 0] - characterRatio(for: kind))
        }
        let totalDeficit = deficits.reduce(0, +)
        let weights = totalDeficit > 0
            ? deficits
            : ordered.map { Self.targetCharacterRatios[$0, default: 0] }
        let totalWeight = weights.reduce(0, +)
        guard totalWeight > 0 else { return ordered.first }
        let unit = Double(Self.mix(seed) % 1_000_000) / 1_000_000
        let threshold = unit * totalWeight
        var accumulated = 0.0
        for (kind, weight) in zip(ordered, weights) {
            accumulated += weight
            if threshold < accumulated { return kind }
        }
        return ordered.last
    }

    /// tvOS schedules three visitors across the 10...230 second portion of a
    /// 240 second idle scene. Each equal slot has random wiggle room after
    /// reserving the 45 second maximum visitor duration.
    public static func visitorSchedule(
        targetDuration: TimeInterval = 240,
        count: Int = 3,
        maximumVisitorDuration: TimeInterval = 45,
        seed: UInt64
    ) -> [TimeInterval] {
        guard count > 0, targetDuration > 20 else { return [] }
        let lower = 10.0
        let upper = targetDuration - 10.0
        let slot = (upper - lower) / Double(count)
        let wiggleRoom = max(0, slot - maximumVisitorDuration)
        return (0..<count).map { index in
            let mixed = mix(seed &+ UInt64(index))
            let unit = Double(mixed % 1_000_000) / 1_000_000
            return lower + Double(index) * slot + unit * wiggleRoom
        }
    }

    public mutating func recordTransitionPair(_ id: String) {
        recentTransitionPairIDs.removeAll { $0 == id }
        recentTransitionPairIDs.insert(id, at: 0)
        recentTransitionPairIDs = Array(recentTransitionPairIDs.prefix(3))
    }

    public func loopCount(seed: UInt64) -> Int {
        5 + Int(Self.mix(seed) % 6)
    }

    /// Base poses are the long-lived sitting, lying and resting states. tvOS
    /// assigns them a separate basePoseDurations pool rather than treating
    /// them like one-shot HEIC animations.
    public func basePoseLoopCount(seed: UInt64) -> Int {
        6 + Int(Self.mix(seed ^ 0x42_41_53_45_50_4f_53_45) % 5)
    }

    /// Additional poses contain a visible action around their loop and should
    /// return to the authored target pose promptly.
    public func additionalPoseLoopCount(seed: UInt64) -> Int {
        2 + Int(Self.mix(seed ^ 0x41_44_44_50_4f_53_45) % 3)
    }

    /// The original 101_AP00x group contains quieter sustained poses. Keep
    /// those longer without applying base-pose timing to every AP animation.
    public func sustainedAdditionalPoseLoopCount(seed: UInt64) -> Int {
        4 + Int(Self.mix(seed ^ 0x53_55_53_54_41_49_4e) % 4)
    }

    /// A single loopable clip (for example BP001) is the resting state, not
    /// an Intro/Loop/Outro action. tvOS resolves it from a short duration
    /// pool, so avoid applying the much larger phased-action loop count.
    public func restingLoopCount(seed: UInt64) -> Int {
        2 + Int(Self.mix(seed ^ 0x51_4e_4f_4f_50_59) % 2)
    }

    public func visitorLoopCount(seed: UInt64) -> Int {
        2 + Int(Self.mix(seed ^ 0x56_49_53_49_54_4f_52) % 3)
    }

    private static func mix(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return x ^ (x >> 31)
    }
}

public struct PlaybackGraph: Sendable {
    public let assetsByID: [String: AssetRecord]

    public init(assets: [AssetRecord]) {
        // Apple keeps historical copies of a few active scenes in multiple
        // bundles with the same asset ID. State-machine references only need
        // one record, so merge deterministically instead of trapping during
        // saver initialization. Newer bundle names sort after older ones.
        self.assetsByID = assets.sorted {
            (($0.bundle ?? ""), $0.assetPath) < (($1.bundle ?? ""), $1.assetPath)
        }.reduce(into: [:]) { result, asset in
            result[asset.id] = asset
        }
    }

    public func actions(startingAt poseID: String, among assets: [AssetRecord]) -> [AssetRecord] {
        assets.filter {
            ($0.kind == "characterAdditionalPose" || $0.kind == "characterMoment")
                && $0.startCharacterBasePoseID == poseID
        }
    }

    /// Apple asset prefixes identify authoring batches, not isolated scene
    /// families. Idle-scene exclusion lists intentionally reference AP/CM
    /// assets from other prefixes, so the pool is global and is narrowed only
    /// by explicit metadata relationships.
    public func characterActions(
        ofKind kind: String, for idleScene: AssetRecord, among assets: [AssetRecord]
    ) -> [AssetRecord] {
        let exclusions: Set<String>
        switch kind {
        case "characterAdditionalPose":
            exclusions = Set(idleScene.idleScene?.exclusions?.excludedCharacterAdditionalPoses ?? [])
        case "characterMoment":
            exclusions = Set(idleScene.idleScene?.exclusions?.excludedCharacterMoments ?? [])
        default:
            return []
        }
        return assets.filter { asset in
            guard asset.kind == kind, !exclusions.contains(asset.id) else { return false }
            guard let parents = asset.parentIdleSceneIDs, !parents.isEmpty else { return true }
            return parents.contains(idleScene.id)
        }
    }

    /// Visitors use the same global-pool rule. Cross-prefix visitor IDs in
    /// `excludedVisitors` are direct authored evidence for this behavior.
    public func visitors(for idleScene: AssetRecord, among assets: [AssetRecord]) -> [AssetRecord] {
        let excluded = Set(idleScene.idleScene?.exclusions?.excludedVisitors ?? [])
        return assets.filter { $0.kind == "idleSceneVisitor" && !excluded.contains($0.id) }
    }

    public func poseTransition(from startID: String, to endID: String) -> AssetRecord? {
        assetsByID.values.first {
            $0.kind == "characterPoseTransition"
                && $0.startCharacterBasePoseID == startID
                && $0.endCharacterBasePoseID == endID
        }
    }

    public func animationQueue(currentPoseID: String, target: AssetRecord) -> [AssetRecord]? {
        guard target.kind == "characterAdditionalPose" || target.kind == "characterMoment",
              let start = target.startCharacterBasePoseID else { return nil }
        if start == currentPoseID { return [target] }
        guard let transition = poseTransition(from: currentPoseID, to: start) else { return nil }
        return [transition, target]
    }

    public func reactionQueue(from startID: String, to endID: String) -> [AssetRecord]? {
        guard let enter = reactionEnter(from: startID), let exit = reactionExit(to: endID) else { return nil }
        return [enter, exit]
    }

    public func reactionEnter(from poseID: String) -> AssetRecord? {
        assetsByID.values.first {
            $0.kind == "characterReactionTransitionPose"
                && $0.phase?.kind == "enter"
                && $0.phase?.startCharacterPoseID == poseID
        }
    }

    public func reactionExit(to poseID: String) -> AssetRecord? {
        assetsByID.values.first {
            $0.kind == "characterReactionTransitionPose"
                && $0.phase?.kind == "exit"
                && $0.phase?.endCharacterPoseID == poseID
        }
    }

    public func phaseSprites(in asset: AssetRecord, phase: String) -> [SpriteRecord] {
        asset.sprites.filter { sprite in
            if let explicit = sprite.phase { return explicit.caseInsensitiveCompare(phase) == .orderedSame }
            let path = sprite.contentPath ?? sprite.metadataPath ?? ""
            return path.localizedCaseInsensitiveContains(phase)
        }
    }

    public func transitionCandidates(for activeScene: AssetRecord) -> [SceneTransitionSelection] {
        let categories = (activeScene.transitionCategoryIDs ?? []).compactMap { assetsByID[$0] }
        return categories.flatMap { categoryAsset -> [SceneTransitionSelection] in
            guard let category = categoryAsset.transitionCategory else { return [] }
            return category.sceneTransitionPairIDs.compactMap { pairID in
                guard let pairAsset = assetsByID[pairID], let pair = pairAsset.transitionPair else { return nil }
                return SceneTransitionSelection(
                    categoryID: categoryAsset.id,
                    pairID: pairID,
                    hideParametersID: pair.hideParametersID,
                    revealParametersID: pair.revealParametersID,
                    hideCharacterPoseIDs: category.hideCharacterPoseIDs,
                    revealCharacterPoseIDs: category.revealCharacterPoseIDs,
                    preventsIdleSceneChange: category.preventsIdleSceneChange
                )
            }
        }
    }
}

public struct SceneTransitionSelection: Sendable, Equatable {
    public let categoryID: String
    public let pairID: String
    public let hideParametersID: String?
    public let revealParametersID: String?
    public let hideCharacterPoseIDs: [String]
    public let revealCharacterPoseIDs: [String]
    public let preventsIdleSceneChange: Bool

    /// The authored pair records include several contextual variants of the
    /// same wipe (for example ClockWipe with weather/time exclusions). Treat
    /// the actual Hide/Reveal parameter pair as the visual family so runtime
    /// recency rotates real artwork instead of merely rotating metadata IDs.
    public var parameterFamilyID: String {
        (hideParametersID ?? "none") + "|" + (revealParametersID ?? "none")
    }
}
