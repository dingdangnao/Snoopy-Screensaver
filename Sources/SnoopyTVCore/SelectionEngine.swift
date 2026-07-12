import Foundation

public struct SelectionEngine: Sendable {
    public let scorer: RelevancyScorer
    public init(scorer: RelevancyScorer = RelevancyScorer()) { self.scorer = scorer }

    public func choose(from assets: [AssetRecord], context: SelectionContext, memory: inout SelectionMemory, seed: UInt64 = 0) -> AssetRecord? {
        let scored = assets.compactMap { asset -> RelevancyScorer.ScoredAsset? in
            guard let score = scorer.score(asset, context: context, memory: memory) else { return nil }
            return .init(asset: asset, score: score)
        }
        let candidates = scored.isEmpty ? assets.filter { !$0.hasConditions } : scored.map(\.asset)
        guard !candidates.isEmpty else { return nil }
        let best: [AssetRecord]
        if scored.isEmpty { best = candidates }
        else {
            let highest = scored.map(\.score).max() ?? 0
            best = scored.filter { $0.score == highest }.map(\.asset)
        }
        let index = Int(mix(seed ^ UInt64(best.count)) % UInt64(best.count))
        let selected = best[index]
        memory.lastSelectedID = selected.id
        memory.recentIDs.removeAll { $0 == selected.id }
        memory.recentIDs.insert(selected.id, at: 0)
        memory.recentIDs = Array(memory.recentIDs.prefix(20))
        memory.playCounts[selected.id, default: 0] += 1
        return selected
    }

    private func mix(_ value: UInt64) -> UInt64 {
        var x = value &+ 0x9e3779b97f4a7c15
        x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
        x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
        return x ^ (x >> 31)
    }
}
