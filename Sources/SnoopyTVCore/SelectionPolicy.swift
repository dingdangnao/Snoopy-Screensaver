import Foundation

/// Shared runtime policy for contextual weighting and long-term variety.
///
/// Context still makes matching material more likely, but a contextual clip
/// cannot keep winning merely because a new screen-saver host starts with an
/// empty session bag. Persisted play counts softly reduce historically
/// overrepresented items, while a longer per-pool cooldown prevents quick
/// repeats across separate screen-saver sessions.
public struct SelectionPolicy: Sendable {
    public init() {}

    public func weightedAssets(
        from assets: [AssetRecord],
        context: SelectionContext,
        memory: SelectionMemory,
        pool: String
    ) -> [WeightedAsset] {
        let scorer = RelevancyScorer()
        let uniqueAssets = assets.reduce(into: [String: AssetRecord]()) { result, asset in
            result[asset.id] = asset
        }
        var candidates = uniqueAssets.values.compactMap { asset -> (AssetRecord, Int)? in
            guard let relevance = scorer.relevanceScore(asset, context: context) else { return nil }
            return (asset, relevanceWeight(for: relevance))
        }
        if candidates.isEmpty {
            candidates = uniqueAssets.values.filter { !$0.hasConditions }.map { ($0, 1) }
        }
        let minimumPlayCount = candidates.map {
            memory.playCount(for: $0.0.id, in: pool)
        }.min() ?? 0
        return candidates.map { asset, weight in
            WeightedAsset(
                asset: asset,
                weight: historyAdjustedWeight(
                    weight,
                    playCount: memory.playCount(for: asset.id, in: pool),
                    minimumPlayCount: minimumPlayCount
                )
            )
        }
    }

    /// Authored calendar/hourly matches should feel like occasional inserts,
    /// not a replacement for the ordinary scene pool. These weights preserve
    /// the priority order while avoiding the old 8:1 startup bias.
    public func relevanceWeight(for relevance: Int) -> Int {
        switch relevance {
        case 65...: return 4
        case 25...: return 3
        case 1...: return 2
        default: return 1
        }
    }

    /// Primary visual pools retain enough history to span multiple short
    /// previews. Small pools always leave at least one item outside the
    /// cooldown so selection cannot deadlock.
    public func recentLimit(for pool: String, candidateCount: Int) -> Int {
        guard candidateCount > 1 else { return 1 }
        let desired: Int
        switch pool {
        case "activeVideos", "idleScenes": desired = 12
        case "characterActions", "visitors": desired = 10
        case "palettes": desired = 8
        case "basePoses": desired = 3
        default: desired = 5
        }
        return min(desired, candidateCount - 1)
    }

    /// Apply an inverse-square-root history correction. It is deliberately
    /// soft: contextual assets retain a boost, but the correction converges
    /// when their observed count has already grown much faster than peers.
    public func historyAdjustedWeight(
        _ relevanceWeight: Int,
        playCount: Int,
        minimumPlayCount: Int
    ) -> Int {
        let historyFactor = sqrt(
            Double(max(0, minimumPlayCount) + 1) / Double(max(0, playCount) + 1)
        )
        return max(1, Int((Double(max(1, relevanceWeight)) * historyFactor * 100).rounded()))
    }
}
