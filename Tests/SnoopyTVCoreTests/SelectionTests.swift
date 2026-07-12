import XCTest
@testable import SnoopyTVCore

final class SelectionTests: XCTestCase {
    func testAlphaProxyTrimsDecoderOnlyLeadingFrame() {
        let alpha = DerivedMediaProxy(
            assetID: "BP004", baseName: "BP004", relativePath: "BP004.mov",
            sourceDigest: "digest", frameCount: 40, framesPerSecond: 24,
            width: 1920, height: 1080, containsAlpha: true, codec: "hevcWithAlpha"
        )
        XCTAssertEqual(alpha.leadingDecodeTrim, 1.0 / 24.0, accuracy: 0.000_001)
        let opaque = DerivedMediaProxy(
            assetID: "video", baseName: "video", relativePath: "video.mov",
            sourceDigest: "digest", frameCount: 40, framesPerSecond: 24,
            width: 1920, height: 1080, containsAlpha: false, codec: "hevc"
        )
        XCTAssertEqual(opaque.leadingDecodeTrim, 0)
    }

    private func asset(_ id: String, condition: String? = nil) -> AssetRecord {
        let info: JSONValue = condition.map { .array([.object(["weather": .object(["condition": .string($0)])])]) } ?? .array([])
        return AssetRecord(id: id, bundle: "bundle", relativePath: id, path: nil, metadataType: "activeScene", type: nil, status: nil,
                           relevancyData: .object(["info": info]), sprites: [SpriteRecord(metadataPath: nil, contentPath: nil, spriteType: "video", assetBaseName: id,
                           assetSize: [1920,1080], frameIndexDigitCount: 2, mediaFiles: [id + ".mov"], media: nil, endBehavior: "freeze",
                           customTiming: nil, placement: nil, plane: "centerpiece")], integrity: IntegrityRecord(valid: true, metadata: nil, version: nil, status: nil, missingMedia: nil, missingSpriteMedia: nil))
    }

    func testWeatherSpecificAssetWins() {
        let engine = SelectionEngine()
        var memory = SelectionMemory()
        let context = SelectionContext(weatherConditions: ["snowy"])
        let selected = engine.choose(from: [asset("generic"), asset("snow", condition: "snowy")], context: context, memory: &memory, seed: 1)
        XCTAssertEqual(selected?.id, "snow")
    }

    func testEmptyInfoRemainsGenericCandidate() {
        XCTAssertNotNil(RelevancyScorer().score(
            asset("generic"), context: SelectionContext(), memory: SelectionMemory()
        ))
    }

    func testRecentAssetIsAvoidedWhenTie() {
        let engine = SelectionEngine()
        var memory = SelectionMemory(lastSelectedID: "one")
        let context = SelectionContext(weatherConditions: ["clear"])
        let selected = engine.choose(from: [asset("one"), asset("two")], context: context, memory: &memory, seed: 2)
        XCTAssertEqual(selected?.id, "two")
    }

    func testTieBreakVariesAcrossRandomSeeds() {
        let engine = SelectionEngine()
        let values = Set((0..<64).compactMap { seed -> String? in
            var memory = SelectionMemory()
            return engine.choose(
                from: [asset("one"), asset("two"), asset("three")],
                context: SelectionContext(), memory: &memory, seed: UInt64(seed)
            )?.id
        })
        XCTAssertEqual(values, ["one", "two", "three"])
    }

    func testSelectionMemoryDecodesLegacyPayloadAndTracksPoolsIndependently() throws {
        let legacy = #"{"lastSelectedID":"old","recentIDs":["old"],"playCounts":{"old":2}}"#.data(using: .utf8)!
        var memory = try JSONDecoder().decode(SelectionMemory.self, from: legacy)
        XCTAssertEqual(memory.lastSelectedID, "old")
        XCTAssertTrue(memory.recentIDsByPool.isEmpty)

        memory.record("active-a", in: "activeVideos")
        memory.record("idle-a", in: "idleScenes")
        XCTAssertEqual(memory.lastSelectedID(in: "activeVideos"), "active-a")
        XCTAssertEqual(memory.lastSelectedID(in: "idleScenes"), "idle-a")
        XCTAssertEqual(memory.recentIDs(in: "activeVideos"), ["active-a"])

        let roundTrip = try JSONDecoder().decode(
            SelectionMemory.self, from: JSONEncoder().encode(memory)
        )
        XCTAssertEqual(roundTrip.recentIDs(in: "idleScenes"), ["idle-a"])
    }

    func testWeightedSessionChoiceUsesEveryCandidateWithoutReplacement() {
        var state = PlaybackSessionState()
        let weighted = [
            WeightedAsset(asset: asset("generic"), weight: 1),
            WeightedAsset(asset: asset("seasonal"), weight: 8),
            WeightedAsset(asset: asset("other"), weight: 2),
        ]
        let firstCycle = (0..<3).compactMap {
            state.chooseWeighted(from: weighted, pool: "active", seed: UInt64($0))?.id
        }
        XCTAssertEqual(Set(firstCycle), Set(["generic", "seasonal", "other"]))
    }

    func testWeightedChoiceFavorsRelevantAssetsAcrossSeedsWithoutExcludingGeneric() {
        let weighted = [
            WeightedAsset(asset: asset("generic"), weight: 1),
            WeightedAsset(asset: asset("holiday"), weight: 8),
        ]
        var holidayCount = 0
        var genericCount = 0
        for seed in UInt64(0)..<256 {
            var state = PlaybackSessionState()
            switch state.chooseWeighted(from: weighted, pool: "active", seed: seed)?.id {
            case "holiday": holidayCount += 1
            case "generic": genericCount += 1
            default: break
            }
        }
        XCTAssertGreaterThan(holidayCount, genericCount)
        XCTAssertGreaterThan(genericCount, 0)
    }

    func testCalendarResolverCoversSummerAndPeanutsDates() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let birthday = calendar.date(from: DateComponents(year: 2026, month: 8, day: 10))!
        let events = SnoopyCalendarResolver.events(for: birthday, calendar: calendar)
        XCTAssertTrue(events.contains("summer"))
        XCTAssertTrue(events.contains("peanutsSnoopysBirthday"))
    }

    func testNestedHourlyEventMatchesRuntimeMetadataShape() {
        let hourly = AssetRecord(
            id: "sunrise", bundle: "bundle", relativePath: "sunrise", metadataType: "activeScene",
            relevancyData: .object(["info": .array([
                .object(["hourlyEvent": .object(["hourlyEvent": .object(["sunrise": .object([:])])])])
            ])])
        )
        XCTAssertNotNil(RelevancyScorer().score(
            hourly, context: SelectionContext(hourlyEvents: ["sunrise"]), memory: SelectionMemory()
        ))
        XCTAssertNil(RelevancyScorer().score(
            hourly, context: SelectionContext(hourlyEvents: ["sunset"]), memory: SelectionMemory()
        ))
    }

    func testMoonWeatherConditionMatchesEphemerisContext() {
        let moonVisitor = asset("moon", condition: "moonFull")
        XCTAssertNotNil(RelevancyScorer().score(
            moonVisitor,
            context: SelectionContext(moonPhases: ["moonFull"]),
            memory: SelectionMemory()
        ))
    }

    func testCategoryDependencyRequiresMatchingActiveVisitorAndWeather() {
        let dependent = AssetRecord(
            id: "rain-companion", metadataType: "characterMoment",
            relevancyData: .object([
                "dependencies": .array([.object([
                    "category": .string("sceneFullscreenEffectVisitor"),
                    "info": .array([.object([
                        "weather": .object(["condition": .string("rainy")])
                    ])])
                ])]),
                "exclusions": .array([]), "info": .array([])
            ])
        )
        let scorer = RelevancyScorer()
        XCTAssertNil(scorer.score(
            dependent,
            context: SelectionContext(weatherConditions: ["rainy"]),
            memory: SelectionMemory()
        ))
        XCTAssertNotNil(scorer.score(
            dependent,
            context: SelectionContext(
                weatherConditions: ["rainy"],
                activeCategories: ["sceneFullscreenEffectVisitor"]
            ),
            memory: SelectionMemory()
        ))
        XCTAssertNil(scorer.score(
            dependent,
            context: SelectionContext(
                weatherConditions: ["sunny"],
                activeCategories: ["sceneFullscreenEffectVisitor"]
            ),
            memory: SelectionMemory()
        ))
    }

    func testConditionalCategoryExclusionDoesNotRemoveOrdinaryWeatherAction() {
        let excludedWithRainEffect = AssetRecord(
            id: "paper-kite", metadataType: "characterAdditionalPose",
            relevancyData: .object([
                "dependencies": .array([]),
                "exclusions": .array([.object([
                    "category": .string("sceneFullscreenEffectVisitor"),
                    "info": .array([.object([
                        "weather": .object(["condition": .string("rainy")])
                    ])])
                ])]),
                "info": .array([])
            ])
        )
        let scorer = RelevancyScorer()
        XCTAssertNotNil(scorer.score(
            excludedWithRainEffect,
            context: SelectionContext(weatherConditions: ["rainy"]),
            memory: SelectionMemory()
        ))
        XCTAssertNil(scorer.score(
            excludedWithRainEffect,
            context: SelectionContext(
                weatherConditions: ["rainy"],
                activeCategories: ["sceneFullscreenEffectVisitor"]
            ),
            memory: SelectionMemory()
        ))
    }

    func testHistoricalSeasonalBundleRepeatsMonthDayWindow() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent("asset-index.json")
        let seasonal = asset("seasonal")
        let index = AssetIndex(
            schemaVersion: 1, assetRoot: ".", assetsRoot: nil, assets: [seasonal],
            bundles: [BundleRecord(name: "bundle", preferredOrder: 2,
                                   activeDateRange: DateRange(startDate: "2025-05-01", endDate: "2025-08-01"))]
        )
        try JSONEncoder().encode(index).write(to: indexURL)
        let store = try AssetStore(indexURL: indexURL)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let july2026 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 11))!
        XCTAssertEqual(store.eligible([seasonal], on: july2026, calendar: calendar).map(\.id), ["seasonal"])
    }

    func testIdleSceneAndCharacterShareDesignViewport() {
        let idle = SpriteRecord(
            spriteType: "frameSequence", assetBaseName: "house", assetSize: [960, 720],
            placement: .object(["anchored": .object(["alignment": .string("bottom"), "to": .string("viewport")])])
        )
        let character = SpriteRecord(
            spriteType: "frameSequence", assetBaseName: "snoopy", assetSize: [1920, 1080],
            placement: .object(["anchored": .object(["alignment": .string("center"), "to": .string("viewport")])])
        )
        let viewport = CGRect(x: 0, y: 0, width: 960, height: 540)
        XCTAssertEqual(SpritePlacementResolver.frame(for: idle, in: viewport), CGRect(x: 240, y: 0, width: 480, height: 360))
        XCTAssertEqual(SpritePlacementResolver.frame(for: character, in: viewport), viewport)

        let sixteenByTen = CGRect(x: 0, y: 0, width: 960, height: 600)
        let idleFit = SpritePlacementResolver.frame(for: idle, in: sixteenByTen)
        XCTAssertEqual(idleFit.origin.x, 240, accuracy: 0.001)
        XCTAssertEqual(idleFit.origin.y, 30, accuracy: 0.001)
        XCTAssertEqual(idleFit.width, 480, accuracy: 0.001)
        XCTAssertEqual(idleFit.height, 360, accuracy: 0.001)
        let characterFit = SpritePlacementResolver.frame(for: character, in: sixteenByTen)
        XCTAssertEqual(characterFit.origin.x, 0, accuracy: 0.001)
        XCTAssertEqual(characterFit.origin.y, 30, accuracy: 0.001)
        XCTAssertEqual(characterFit.width, 960, accuracy: 0.001)
        XCTAssertEqual(characterFit.height, 540, accuracy: 0.001)
        let fit = SpritePlacementResolver.aspectFitFrame(
            contentSize: CGSize(width: 1920, height: 1080), in: sixteenByTen
        )
        XCTAssertEqual(fit, characterFit)
        XCTAssertTrue(sixteenByTen.contains(fit))
        let offsetCharacter = SpritePlacementResolver.frame(
            for: character, in: sixteenByTen, sceneOffset: PointRecord(x: 96, y: -54)
        )
        XCTAssertEqual(offsetCharacter.origin.x, 48, accuracy: 0.001)
        XCTAssertEqual(offsetCharacter.origin.y, 3, accuracy: 0.001)
        XCTAssertEqual(offsetCharacter.size, characterFit.size)

        let ultrawide = CGRect(x: 0, y: 0, width: 1200, height: 500)
        let ultrawideFit = SpritePlacementResolver.frame(for: character, in: ultrawide)
        XCTAssertEqual(ultrawideFit.width, 888.889, accuracy: 0.001)
        XCTAssertEqual(ultrawideFit.height, 500, accuracy: 0.001)
        XCTAssertEqual(ultrawideFit.midX, ultrawide.midX, accuracy: 0.001)
        XCTAssertTrue(ultrawide.contains(ultrawideFit))
        let fill = SpritePlacementResolver.aspectFillFrame(
            contentSize: CGSize(width: 1920, height: 1080), in: sixteenByTen
        )
        XCTAssertEqual(fill.height, 600, accuracy: 0.001)
        XCTAssertGreaterThan(fill.width, 960)
        XCTAssertEqual(fill.midX, sixteenByTen.midX, accuracy: 0.001)
    }

    func testSessionBagDoesNotRepeatBeforeExhaustionAndLoopRangeIsFiveToTen() {
        var state = PlaybackSessionState()
        let assets = [asset("one"), asset("two"), asset("three")]
        let firstCycle = (0..<3).compactMap { state.choose(from: assets, pool: "moments", seed: UInt64($0))?.id }
        XCTAssertEqual(Set(firstCycle), Set(assets.map(\.id)))
        let afterReset = state.choose(from: assets, pool: "moments", seed: 4)?.id
        XCTAssertNotEqual(afterReset, firstCycle.last)
        XCTAssertTrue((5...10).contains(state.loopCount(seed: 1)))
        XCTAssertEqual(Set((0..<128).map { state.loopCount(seed: UInt64($0)) }), Set(5...10))
        XCTAssertEqual(Set((0..<128).map { state.basePoseLoopCount(seed: UInt64($0)) }), Set(6...10))
        XCTAssertEqual(Set((0..<128).map { state.additionalPoseLoopCount(seed: UInt64($0)) }), Set(2...4))
        XCTAssertEqual(Set((0..<128).map { state.sustainedAdditionalPoseLoopCount(seed: UInt64($0)) }), Set(4...7))
        XCTAssertEqual(Set((0..<128).map { state.restingLoopCount(seed: UInt64($0)) }), Set(2...3))
        XCTAssertEqual(Set((0..<128).map { state.visitorLoopCount(seed: UInt64($0)) }), Set(2...4))
    }

    func testAppleCharacterDurationRatiosAndForcedBasePoseReturn() {
        var state = PlaybackSessionState()
        let all: Set<CharacterAnimationKind> = [.basePose, .additionalPose, .moment]
        XCTAssertEqual(state.nextCharacterAnimationKind(available: all, seed: 1), .basePose)

        state.recordCharacterAnimation(.basePose, duration: 71)
        state.recordCharacterAnimation(.additionalPose, duration: 20)
        XCTAssertTrue(state.requiresBasePoseAfterVariation)
        XCTAssertEqual(state.nextCharacterAnimationKind(available: all, seed: 2), .basePose)

        state.recordCharacterAnimation(.basePose, duration: 1)
        XCTAssertFalse(state.requiresBasePoseAfterVariation)
        XCTAssertEqual(state.characterRatio(for: .basePose), 72.0 / 92.0, accuracy: 0.0001)
        XCTAssertEqual(PlaybackSessionState.targetCharacterRatios[.basePose], 0.71)
        XCTAssertEqual(PlaybackSessionState.targetCharacterRatios[.additionalPose], 0.20)
        XCTAssertEqual(PlaybackSessionState.targetCharacterRatios[.moment], 0.09)
    }

    func testAppleVisitorScheduleUsesThreeNonOverlappingSlots() {
        let times = PlaybackSessionState.visitorSchedule(seed: 42)
        XCTAssertEqual(times.count, 3)
        XCTAssertTrue((10.0...38.334).contains(times[0]))
        XCTAssertTrue((83.333...111.667).contains(times[1]))
        XCTAssertTrue((156.666...185.0).contains(times[2]))
        XCTAssertGreaterThanOrEqual(times[1] - times[0], 45)
        XCTAssertGreaterThanOrEqual(times[2] - times[1], 45)
    }

    func testPlaybackGraphFollowsPoseEdgesAndTransitionCategories() {
        let action = AssetRecord(
            id: "action", metadataType: "characterAdditionalPose",
            startCharacterBasePoseID: "BP001", endCharacterBasePoseID: "BP003"
        )
        let poseTransition = AssetRecord(
            id: "BP003_To_BP001", metadataType: "characterPoseTransition",
            startCharacterBasePoseID: "BP003", endCharacterBasePoseID: "BP001"
        )
        let reactionEnter = AssetRecord(
            id: "BP001_To_RPH", metadataType: "characterReactionTransitionPose",
            phase: TransitionPhaseRecord(kind: "enter", startCharacterPoseID: "BP001")
        )
        let reactionExit = AssetRecord(
            id: "RPH_To_BP003", metadataType: "characterReactionTransitionPose",
            phase: TransitionPhaseRecord(kind: "exit", endCharacterPoseID: "BP003")
        )
        let pair = AssetRecord(
            id: "pair", metadataType: "sceneTransitionPair",
            transitionPair: TransitionPairRecord(hideParametersID: "hide", revealParametersID: "reveal")
        )
        let category = AssetRecord(
            id: "category", metadataType: "sceneTransitionCategory",
            transitionCategory: TransitionCategoryRecord(
                hideCharacterPoseIDs: ["hidePose"], revealCharacterPoseIDs: ["revealPose"],
                sceneTransitionPairIDs: ["pair"], preventsIdleSceneChange: true
            )
        )
        let active = AssetRecord(id: "active", metadataType: "activeScene", transitionCategoryIDs: ["category"])
        let graph = PlaybackGraph(assets: [
            action, poseTransition, reactionEnter, reactionExit, pair, category, active,
        ])
        XCTAssertEqual(graph.actions(startingAt: "BP001", among: [action]).map(\.id), ["action"])
        XCTAssertEqual(graph.poseTransition(from: "BP003", to: "BP001")?.id, poseTransition.id)
        XCTAssertEqual(graph.animationQueue(currentPoseID: "BP003", target: action)?.map(\.id),
                       [poseTransition.id, action.id])
        XCTAssertEqual(graph.reactionQueue(from: "BP001", to: "BP003")?.map(\.id),
                       [reactionEnter.id, reactionExit.id])
        let transition = graph.transitionCandidates(for: active).first
        XCTAssertEqual(transition,
                       SceneTransitionSelection(categoryID: "category", pairID: "pair",
                                                hideParametersID: "hide", revealParametersID: "reveal",
                                                hideCharacterPoseIDs: ["hidePose"], revealCharacterPoseIDs: ["revealPose"],
                                                preventsIdleSceneChange: true))
        XCTAssertEqual(transition?.parameterFamilyID, "hide|reveal")
    }

    func testPlaybackGraphKeepsEveryAuthoredPoseBranchReachable() {
        let toB = AssetRecord(
            id: "BP_A_To_BP_B", metadataType: "characterPoseTransition",
            startCharacterBasePoseID: "BP_A", endCharacterBasePoseID: "BP_B"
        )
        let toC = AssetRecord(
            id: "BP_A_To_BP_C", metadataType: "characterPoseTransition",
            startCharacterBasePoseID: "BP_A", endCharacterBasePoseID: "BP_C"
        )
        let actionFromB = AssetRecord(
            id: "actionFromB", metadataType: "characterAdditionalPose",
            startCharacterBasePoseID: "BP_B", endCharacterBasePoseID: "BP_A"
        )
        let actionFromC = AssetRecord(
            id: "actionFromC", metadataType: "characterAdditionalPose",
            startCharacterBasePoseID: "BP_C", endCharacterBasePoseID: "BP_A"
        )
        let graph = PlaybackGraph(assets: [toB, toC, actionFromB, actionFromC])

        XCTAssertEqual(
            graph.animationQueue(currentPoseID: "BP_A", target: actionFromB)?.map(\.id),
            [toB.id, actionFromB.id]
        )
        XCTAssertEqual(
            graph.animationQueue(currentPoseID: "BP_A", target: actionFromC)?.map(\.id),
            [toC.id, actionFromC.id]
        )

        var state = PlaybackSessionState(currentBasePoseID: "BP_A")
        let branches = [actionFromB, actionFromC]
        let first = state.choose(from: branches, pool: "characterActions", seed: 1)
        let second = state.choose(from: branches, pool: "characterActions", seed: 2)
        XCTAssertEqual(Set([first?.id, second?.id].compactMap { $0 }), Set(branches.map(\.id)))
    }

    func testPlaybackGraphUsesGlobalAuthoringPoolsAndExplicitSceneExclusions() {
        let idle = AssetRecord(
            id: "104_IS031", metadataType: "idleScene",
            idleScene: IdleSceneRecord(exclusions: IdleSceneExclusionsRecord(
                excludedCharacterAdditionalPoses: ["103_AP025"],
                excludedVisitors: ["101_VI001"]
            ))
        )
        let allowedAction = AssetRecord(id: "102_AP018", metadataType: "characterAdditionalPose")
        let excludedAction = AssetRecord(id: "103_AP025", metadataType: "characterAdditionalPose")
        let allowedVisitor = AssetRecord(id: "103_VI024", metadataType: "idleSceneVisitor")
        let excludedVisitor = AssetRecord(id: "101_VI001", metadataType: "idleSceneVisitor")
        let assets = [idle, allowedAction, excludedAction, allowedVisitor, excludedVisitor]
        let graph = PlaybackGraph(assets: assets)

        XCTAssertEqual(
            graph.characterActions(ofKind: "characterAdditionalPose", for: idle, among: assets).map(\.id),
            [allowedAction.id]
        )
        XCTAssertEqual(graph.visitors(for: idle, among: assets).map(\.id), [allowedVisitor.id])
    }

    func testMothersFathersAndHalloweenSeasonWindows() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let mothersDay = calendar.date(from: DateComponents(year: 2026, month: 5, day: 10))!
        let fathersDay = calendar.date(from: DateComponents(year: 2026, month: 6, day: 21))!
        let octoberFirst = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        XCTAssertTrue(SnoopyCalendarResolver.events(for: mothersDay, calendar: calendar).contains("mothersDay"))
        XCTAssertTrue(SnoopyCalendarResolver.events(for: fathersDay, calendar: calendar).contains("fathersDay"))
        XCTAssertTrue(SnoopyCalendarResolver.events(for: octoberFirst, calendar: calendar).contains("halloweenSeason"))
    }

    func testHolidayThemesCoverHalloweenThanksgivingAndChristmas() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let halloween = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31))!
        let thanksgiving = calendar.date(from: DateComponents(year: 2026, month: 11, day: 26))!
        let christmasEve = calendar.date(from: DateComponents(year: 2026, month: 12, day: 24))!
        let christmas = calendar.date(from: DateComponents(year: 2026, month: 12, day: 25))!

        XCTAssertTrue(SnoopyCalendarResolver.events(for: halloween, calendar: calendar).isSuperset(
            of: ["halloween", "halloweenSeason"]
        ))
        XCTAssertTrue(SnoopyCalendarResolver.events(for: thanksgiving, calendar: calendar).isSuperset(
            of: ["thanksgiving", "thanksgivingSeason", "peanutsCharlieBrownThanksgiving"]
        ))
        XCTAssertTrue(SnoopyCalendarResolver.events(for: christmasEve, calendar: calendar).isSuperset(
            of: ["christmasEve", "christmasSeason"]
        ))
        XCTAssertTrue(SnoopyCalendarResolver.events(for: christmas, calendar: calendar).isSuperset(
            of: ["christmas", "christmasSeason"]
        ))

        let christmasAsset = AssetRecord(
            id: "christmas", metadataType: "idleScene",
            relevancyData: .object(["info": .array([.object([
                "calendar": .object(["event": .object(["christmas": .object([:])])])
            ])])])
        )
        XCTAssertNotNil(RelevancyScorer().score(
            christmasAsset,
            context: SelectionContext(calendarEvents: SnoopyCalendarResolver.events(
                for: christmas, calendar: calendar
            )),
            memory: SelectionMemory()
        ))
        XCTAssertNil(RelevancyScorer().score(
            christmasAsset,
            context: SelectionContext(calendarEvents: SnoopyCalendarResolver.events(
                for: halloween, calendar: calendar
            )),
            memory: SelectionMemory()
        ))
    }
}
