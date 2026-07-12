import AVFoundation
import Cocoa
import ImageIO
import ScreenSaver

/// Offline Apple TV-style Snoopy screen saver. Full-screen active-scene videos
/// and metadata-driven HEIC composites share one randomized playback queue.
@objc(DingDangSnoopySaverView)
final class SnoopySaverView: ScreenSaverView {
    private enum PlaybackKind { case video, composite }
    private enum TransitionStage: String { case hide, reveal }
    private enum PendingSceneStage {
        case activeScene(AssetRecord)
        case transition(TransitionStage, SceneTransitionSelection)
    }

    private var store: AssetStore?
    private var derivedMediaStore: DerivedMediaStore?
    private var playbackGraph: PlaybackGraph?
    private var sessionState = PlaybackSessionState()
    private var pendingBasePoseID: String?
    private var pendingCharacterAssetIDs: [String] = []
    private var pendingSceneStages: [PendingSceneStage] = []
    private var currentPaletteAssetID: String?
    private var currentSceneOffset: PointRecord?
    private var lastRevealTransitionPoseID: String?
    private var consecutiveTransitionsPreventingIdleSceneChange = 0
    private var idleSceneStartedAt: TimeInterval?
    private var idleSceneTargetDuration: TimeInterval = 240
    private var idleSceneAnimationCount = 0
    private var idleSceneTargetAnimationCount = Int.max
    private var visitorScheduleTimes: [TimeInterval] = []
    private var nextVisitorScheduleIndex = 0
    private var idleSceneChangeRequested = false
    private var hasPlayedInitialActiveScene = false
    private var player: AVPlayer?
    private var playerLayer: AVPlayerLayer?
    private var playerReadyObservation: NSKeyValueObservation?
    private var activeVideoPlaceholderLayer: CALayer?
    private var activeHalftoneLayer: CALayer?
    private var activeVideoAssetID: String?
    private var compositeVideoLayer: AVPlayerLayer?
    private var compositeVideoHostView: NSView?
    private var retiringCompositePlayer: AVPlayer?
    private var retiringCompositeHostView: NSView?
    private var retiringFrameView: NSImageView?
    private var compositeVideoPlaceholderLayer: CALayer?
    private var compositeVideoReadyObservation: NSKeyValueObservation?
    private var compositeItemStatusObservation: NSKeyValueObservation?
    private var compositePrerollTimeout: DispatchWorkItem?
    private var compositePlaybackGeneration: UInt64 = 0
    private var visitorPlayer: AVQueuePlayer?
    private var visitorLayer: AVPlayerLayer?
    private var visitorPlaceholderLayer: CALayer?
    private var visitorReadyObservation: NSKeyValueObservation?
    private var visitorHostView: NSView?
    private var visitorSprite: SpriteRecord?
    private var visitorIgnoresSceneOffset = false
    private var visitorIsFullscreenEffect = false
    private var visitorEndObserver: NSObjectProtocol?
    private var transitionPlayers: [AVPlayer] = []
    private var transitionLayers: [CALayer] = []
    private var transitionEndObserver: NSObjectProtocol?
    private var transitionHostView: NSView?
    private var retiringTransitionPlayers: [AVPlayer] = []
    private var retiringTransitionHostView: NSView?
    private var holdingCompletedIdleEntrySurface = false
    private var transitionPrerollTimeout: DispatchWorkItem?
    private var transitionPlaybackGeneration: UInt64 = 0
    private var transitionItemStatusObservations: [NSKeyValueObservation] = []
    private var idleExitTransitionInProgress = false
    private var idleEntryRequestedWhileExiting = false
    private var holdingActiveFrameForIdleEntry = false
    private var playerEndObserver: NSObjectProtocol?
    private var playerFailureObserver: NSObjectProtocol?
    private var playerStallObserver: NSObjectProtocol?
    private var playerBoundaryObserver: Any?
    private var watchdogWorkItem: DispatchWorkItem?
    private var advanceWorkItem: DispatchWorkItem?
    private var frameTimer: Timer?
    private var backgroundColorView: NSView?
    private var halftoneView: NSImageView?
    private var backgroundImageView: NSImageView?
    private var backgroundVideoHostView: NSView?
    private var backgroundVideoLayer: AVPlayerLayer?
    private var backgroundVideoPlayer: AVQueuePlayer?
    private var backgroundVideoLooper: AVPlayerLooper?
    private var backgroundVideoReadyObservation: NSKeyValueObservation?
    private var backgroundVideoPlaceholderLayer: CALayer?
    private var overlayView: NSView?
    private var frameView: NSImageView?
    private var backgroundSprite: SpriteRecord?
    private var foregroundSprite: SpriteRecord?
    private var frameGeneration: UInt64 = 0
    private let frameDecodeLock = NSLock()
    private var pendingFrameKeys = Set<String>()
    private let decodedFrameCache: NSCache<NSString, CGImage> = {
        let cache = NSCache<NSString, CGImage>()
        cache.totalCostLimit = 64 * 1024 * 1024
        cache.countLimit = 16
        return cache
    }()
    private let frameDecodeQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.dingdangnao.snoopy.frame-decode"
        queue.qualityOfService = .userInitiated
        // One decoder is fast enough to stay ahead of 24 fps and avoids the
        // large CPU spikes caused by two HEIC decoders racing at startup.
        queue.maxConcurrentOperationCount = 1
        return queue
    }()
    private var memory = SelectionMemory()
    private var seed = UInt64.random(in: UInt64.min...UInt64.max)
    private var isPlaying = false
    private var isStopping = true
    private var currentAssetID: String?

    @objc(initWithFrame:isPreview:)
    override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        configureView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureView()
    }

    private func configureView() {
        animationTimeInterval = 1.0 / 30.0
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        loadSelectionMemory()
        loadStore()
    }

    override func startAnimation() {
        super.startAnimation()
        isStopping = false
        seed = UInt64.random(in: UInt64.min...UInt64.max)
        sessionState = PlaybackSessionState()
        pendingBasePoseID = nil
        pendingCharacterAssetIDs.removeAll()
        pendingSceneStages.removeAll()
        currentPaletteAssetID = nil
        currentSceneOffset = nil
        lastRevealTransitionPoseID = nil
        consecutiveTransitionsPreventingIdleSceneChange = 0
        idleSceneStartedAt = nil
        idleSceneAnimationCount = 0
        visitorScheduleTimes.removeAll()
        nextVisitorScheduleIndex = 0
        idleSceneChangeRequested = false
        hasPlayedInitialActiveScene = false
        // Start identically in Preview and full-screen mode. The first media
        // tree installs synchronously and its decoded first-frame placeholder
        // remains visible during AVPlayer preroll; no poster/cover interstitial.
        playNext()
    }

    override func stopAnimation() {
        isStopping = true
        cancelPendingAdvance()
        cleanCurrentPlayback()
        super.stopAnimation()
    }

    override func draw(_ rect: NSRect) {
        (layer?.backgroundColor.map(NSColor.init(cgColor:)) ?? NSColor.black)?.setFill()
        rect.fill()
    }

    override func animateOneFrame() {
        if !isStopping, !isPlaying, advanceWorkItem == nil {
            scheduleNext(after: 0.05)
        }
    }

    private func loadStore() {
        let defaults = SnoopyPreferences.defaults
        let configuredPath = defaults.string(forKey: SnoopyPreferences.assetIndexPathKey)
        let path = configuredPath ?? defaultIndexURL()?.path
        guard let path else {
            NSLog("SnoopyTVScreenSaver: 未找到 asset-index.json")
            return
        }
        do {
            store = try AssetStore(indexURL: URL(fileURLWithPath: path))
            playbackGraph = store.map { PlaybackGraph(assets: $0.index.assets) }
            let bundledDerived = Bundle(for: Self.self).resourceURL?.appendingPathComponent("DerivedMedia", isDirectory: true)
            let sourceDerived = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".derived-media", isDirectory: true)
            derivedMediaStore = [bundledDerived, sourceDerived].compactMap { $0 }.lazy.compactMap(DerivedMediaStore.init(root:)).first
            NSLog("SnoopyTVScreenSaver: derived proxies=%ld", derivedMediaStore?.index.proxies.count ?? 0)
            if configuredPath == nil { defaults.set(path, forKey: SnoopyPreferences.assetIndexPathKey) }
        } catch {
            NSLog("SnoopyTVScreenSaver: %@", error.localizedDescription)
        }
    }

    private func defaultIndexURL() -> URL? {
        let bundleIndex = Bundle(for: Self.self).url(forResource: "asset-index", withExtension: "json")
        let sourceIndex = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/asset-index.json")
        return [bundleIndex, sourceIndex].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func halftoneImageURL() -> URL? {
        let bundled = Bundle(for: Self.self).url(forResource: "halftone_pattern", withExtension: "png")
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/halftone_pattern.png")
        return [bundled, source].compactMap { $0 }.first {
            FileManager.default.fileExists(atPath: $0.path)
        }
    }

    private func scheduleNext(after delay: TimeInterval) {
        guard !isStopping else { return }
        advanceWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.advanceWorkItem = nil
            self.playNext()
        }
        advanceWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelPendingAdvance() {
        advanceWorkItem?.cancel()
        advanceWorkItem = nil
    }

    private func finishCurrentPlayback(_ reason: String) {
        guard isPlaying, !isStopping else { return }
        NSLog("SnoopyTVScreenSaver: finish %@ (%@)", currentAssetID ?? "unknown", reason)
        if let pendingBasePoseID { sessionState.currentBasePoseID = pendingBasePoseID }
        pendingBasePoseID = nil
        let shouldHoldActiveFrame: Bool
        if playerLayer != nil, let next = pendingSceneStages.first,
           case .transition(.hide, _) = next {
            shouldHoldActiveFrame = true
        } else {
            shouldHoldActiveFrame = false
        }
        holdingActiveFrameForIdleEntry = shouldHoldActiveFrame
        // Keep the outgoing layer tree alive until playNext installs the
        // incoming tree in the same Core Animation transaction. The previous
        // 120 ms remove-then-wait sequence exposed the root black layer.
        isPlaying = false
        scheduleNext(after: 0)
    }

    private func cleanCurrentPlayback(
        preservingActiveVideo: Bool = false,
        preservingIdleComposite: Bool = false
    ) {
        isPlaying = false
        currentAssetID = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        frameTimer?.invalidate()
        frameTimer = nil
        frameGeneration &+= 1
        frameDecodeQueue.cancelAllOperations()
        frameDecodeLock.lock()
        pendingFrameKeys.removeAll()
        frameDecodeLock.unlock()
        if let observer = playerEndObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = playerFailureObserver { NotificationCenter.default.removeObserver(observer) }
        if let observer = playerStallObserver { NotificationCenter.default.removeObserver(observer) }
        if !preservingIdleComposite, let observer = visitorEndObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = transitionEndObserver { NotificationCenter.default.removeObserver(observer) }
        playerEndObserver = nil
        playerFailureObserver = nil
        playerStallObserver = nil
        if !preservingIdleComposite { visitorEndObserver = nil }
        transitionEndObserver = nil
        transitionPrerollTimeout?.cancel()
        transitionPrerollTimeout = nil
        transitionItemStatusObservations.removeAll()
        transitionPlaybackGeneration &+= 1
        idleExitTransitionInProgress = false
        idleEntryRequestedWhileExiting = false
        if holdingCompletedIdleEntrySurface, transitionHostView != nil {
            retirePreviousTransitionSurface()
            transitionPlayers.forEach { $0.pause() }
            retiringTransitionPlayers = transitionPlayers
            retiringTransitionHostView = transitionHostView
            transitionPlayers.removeAll()
            transitionLayers.removeAll()
            transitionHostView = nil
            holdingCompletedIdleEntrySurface = false
        } else {
            transitionPlayers.forEach { $0.pause() }
            transitionPlayers.removeAll()
            transitionLayers.forEach { $0.removeFromSuperlayer() }
            transitionLayers.removeAll()
            transitionHostView?.removeFromSuperview()
            transitionHostView = nil
        }
        player?.pause()
        if let observer = playerBoundaryObserver { player?.removeTimeObserver(observer) }
        playerBoundaryObserver = nil
        if !preservingActiveVideo {
            playerReadyObservation = nil
            activeVideoPlaceholderLayer?.removeFromSuperlayer()
            activeVideoPlaceholderLayer = nil
            if !preservingIdleComposite { player = nil }
            playerLayer?.removeFromSuperlayer()
            playerLayer = nil
            activeHalftoneLayer?.removeFromSuperlayer()
            activeHalftoneLayer = nil
            activeVideoAssetID = nil
            holdingActiveFrameForIdleEntry = false
        }
        if preservingIdleComposite {
            // A failed incoming candidate may already have been discarded.
            // In that case the retiring surface is the only visible foreground
            // and must survive the retry instead of being collected here.
            let hasCurrentComposite = player != nil || compositeVideoHostView != nil || frameView != nil
            if hasCurrentComposite {
                retirePreviousCompositeSurface()
                retiringCompositePlayer = player
                retiringCompositeHostView = compositeVideoHostView
                retiringFrameView = frameView
            }
            player = nil
            compositeVideoLayer = nil
            compositeVideoHostView = nil
            frameView = nil
        } else {
            retirePreviousCompositeSurface()
            compositeVideoLayer?.removeFromSuperlayer()
            compositeVideoLayer = nil
            compositeVideoHostView?.removeFromSuperview()
            compositeVideoHostView = nil
            frameView?.removeFromSuperview()
            frameView = nil
        }
        compositeVideoReadyObservation = nil
        compositeItemStatusObservation = nil
        compositePrerollTimeout?.cancel()
        compositePrerollTimeout = nil
        compositePlaybackGeneration &+= 1
        compositeVideoPlaceholderLayer?.removeFromSuperlayer()
        compositeVideoPlaceholderLayer = nil
        if !preservingIdleComposite {
            removeVisitorPlayback()
            backgroundColorView?.removeFromSuperview()
            backgroundColorView = nil
            halftoneView?.removeFromSuperview()
            halftoneView = nil
            backgroundImageView?.removeFromSuperview()
            backgroundImageView = nil
            backgroundVideoPlayer?.pause()
            backgroundVideoReadyObservation = nil
            backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
            backgroundVideoPlaceholderLayer = nil
            backgroundVideoLooper = nil
            backgroundVideoPlayer = nil
            backgroundVideoLayer?.removeFromSuperlayer()
            backgroundVideoLayer = nil
            backgroundVideoHostView?.removeFromSuperview()
            backgroundVideoHostView = nil
            overlayView?.removeFromSuperview()
            overlayView = nil
            backgroundSprite = nil
        }
        foregroundSprite = nil
        if isStopping {
            retirePreviousTransitionSurface()
        }
    }

    private func retirePreviousCompositeSurface() {
        retiringCompositePlayer?.pause()
        retiringCompositePlayer = nil
        retiringCompositeHostView?.removeFromSuperview()
        retiringCompositeHostView = nil
        retiringFrameView?.removeFromSuperview()
        retiringFrameView = nil
    }

    private func retirePreviousTransitionSurface() {
        retiringTransitionPlayers.forEach { $0.pause() }
        retiringTransitionPlayers.removeAll()
        retiringTransitionHostView?.removeFromSuperview()
        retiringTransitionHostView = nil
    }

    private func retirePreviousPlaybackSurfaces() {
        retirePreviousCompositeSurface()
        retirePreviousTransitionSurface()
    }

    /// Once the duplicate transition scene is drawable it becomes the sole
    /// owner of the outgoing IdleScene. Leaving the normal character/backdrop
    /// mounted underneath defeats the reveal mask: it exposes that second
    /// IdleScene instead of the ActiveScene and can briefly show two Snoopys.
    private func retireOutgoingIdleSurfaceForTransition() {
        retirePreviousCompositeSurface()
        compositeVideoLayer?.removeFromSuperlayer()
        compositeVideoLayer = nil
        compositeVideoHostView?.removeFromSuperview()
        compositeVideoHostView = nil
        frameView?.removeFromSuperview()
        frameView = nil
        removeVisitorPlayback()
        backgroundColorView?.removeFromSuperview()
        backgroundColorView = nil
        halftoneView?.removeFromSuperview()
        halftoneView = nil
        backgroundImageView?.removeFromSuperview()
        backgroundImageView = nil
        backgroundVideoPlayer?.pause()
        backgroundVideoReadyObservation = nil
        backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
        backgroundVideoPlaceholderLayer = nil
        backgroundVideoLooper = nil
        backgroundVideoPlayer = nil
        backgroundVideoLayer?.removeFromSuperlayer()
        backgroundVideoLayer = nil
        backgroundVideoHostView?.removeFromSuperview()
        backgroundVideoHostView = nil
        overlayView?.removeFromSuperview()
        overlayView = nil
        backgroundSprite = nil
        foregroundSprite = nil
    }

    private var hasRetiringPlaybackSurface: Bool {
        retiringCompositeHostView != nil || retiringFrameView != nil || retiringTransitionHostView != nil
    }

    private var hasMountedNormalIdleSurface: Bool {
        retiringCompositeHostView != nil || retiringFrameView != nil
            || compositeVideoHostView != nil || frameView != nil
            || backgroundColorView != nil || halftoneView != nil
            || backgroundImageView != nil || backgroundVideoHostView != nil
            || overlayView != nil
    }

    private func keepRetiringPlaybackSurfaceAbove(_ incomingView: NSView) {
        if let host = retiringCompositeHostView, host.superview === self {
            addSubview(host, positioned: .above, relativeTo: incomingView)
        }
        if let view = retiringFrameView, view.superview === self {
            addSubview(view, positioned: .above, relativeTo: incomingView)
        }
        if let host = retiringTransitionHostView, host.superview === self {
            addSubview(host, positioned: .above, relativeTo: incomingView)
        }
    }

    private func cleanTransitionOverlay() {
        if let observer = transitionEndObserver { NotificationCenter.default.removeObserver(observer) }
        transitionEndObserver = nil
        transitionPrerollTimeout?.cancel()
        transitionPrerollTimeout = nil
        transitionItemStatusObservations.removeAll()
        transitionPlaybackGeneration &+= 1
        transitionPlayers.forEach { $0.pause() }
        transitionPlayers.removeAll()
        transitionLayers.forEach {
            $0.mask = nil
            $0.removeFromSuperlayer()
        }
        transitionLayers.removeAll()
        transitionHostView?.removeFromSuperview()
        transitionHostView = nil
    }

    private func installWatchdog(defaultSeconds: TimeInterval) {
        watchdogWorkItem?.cancel()
        let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init)
        let seconds = max(0.5, testSeconds ?? defaultSeconds)
        let work = DispatchWorkItem { [weak self] in self?.finishCurrentPlayback("watchdog") }
        watchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func installTransitionWatchdog(
        defaultSeconds: TimeInterval, generation: UInt64,
        stage: TransitionStage, selection: SceneTransitionSelection
    ) {
        watchdogWorkItem?.cancel()
        let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init)
        let seconds = max(0.5, testSeconds ?? defaultSeconds)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.transitionPlaybackGeneration == generation else { return }
            self.completeSceneTransitionStage(stage, selection: selection, reason: "watchdog")
        }
        watchdogWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    private func currentContext() -> SelectionContext {
        let now = Date()
        let override = SnoopyPreferences.defaults.string(forKey: SnoopyPreferences.weatherOverrideKey)
            .flatMap { $0.isEmpty ? nil : $0 }
        let snapshot = SnoopyPreferences.weatherSnapshot().flatMap { $0.isUsable ? $0 : nil }
        let weather = override.map { Set([$0]) } ?? Set(snapshot?.conditions ?? [])
        return SelectionContext(
            date: now,
            timeOfDay: currentTimeOfDay(),
            routine: SnoopyCalendarResolver.routine(for: now),
            weatherConditions: weather,
            calendarEvents: SnoopyCalendarResolver.events(for: now),
            hourlyEvents: SnoopyCalendarResolver.hourlyEvents(
                for: now, sunrise: snapshot?.sunrise, sunset: snapshot?.sunset
            ),
            moonPhases: [SnoopyCalendarResolver.moonCondition(for: now)]
        )
    }

    private func playNext() {
        guard !isStopping, let store else {
            return
        }
        // AppKit commits the outgoing removal and incoming installation as a
        // single frame. AVPlayer playback remains time-driven; only implicit
        // layer property animations are disabled for this swap.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let continuingIdleComposite = sessionState.currentIdleSceneID != nil
            && playerLayer == nil
            && pendingSceneStages.isEmpty
        // Keep the authored outgoing Idle surface for both character-to-
        // character swaps and Idle -> Hide -> ActiveScene. Previously the
        // rotation path cleared it before Hide was drawable, then exposed its
        // separately-retained last frame again when the Hide host was removed.
        cleanCurrentPlayback(
            preservingActiveVideo: holdingActiveFrameForIdleEntry,
            preservingIdleComposite: continuingIdleComposite
        )
        let context = currentContext()
        NSLog("SnoopyTVScreenSaver: context time=%@ routine=%@ weather=%@ calendar=%@ hourly=%@",
              context.timeOfDay ?? "none", context.routine ?? "none",
              context.weatherConditions.sorted().joined(separator: ","),
              context.calendarEvents.sorted().joined(separator: ","),
              context.hourlyEvents.sorted().joined(separator: ","))
        let kind: PlaybackKind
        let started: Bool
        if !pendingSceneStages.isEmpty {
            let stage = pendingSceneStages.removeFirst()
            switch stage {
            case .activeScene(let asset):
                kind = .video
                started = startActiveVideo(asset, from: store, context: context)
            case .transition(let phase, let selection):
                kind = .composite
                started = playSceneTransitionStage(phase, selection: selection, from: store, context: context)
            }
        } else {
            // CharacterAnimationManager in tvOS drains pendingAnimationQueue
            // before asking the display coordinator for a different scene type.
            kind = pendingCharacterAssetIDs.isEmpty ? nextPlaybackKind() : .composite
            switch kind {
            case .video:
                started = playRandomVideo(from: store, context: context)
            case .composite:
                started = playRandomComposite(from: store, context: context)
            }
        }
        if !started {
            NSLog("SnoopyTVScreenSaver: unable to start requested %@; will retry same media class", String(describing: kind))
            scheduleNext(after: 0.5)
        } else {
            let visibleSurfaceCount = subviews.filter { !$0.isHidden && $0.alphaValue > 0 }.count
                + (layer?.sublayers?.filter { !$0.isHidden && $0.opacity > 0 }.count ?? 0)
            if visibleSurfaceCount == 0 {
                NSLog("SnoopyTVScreenSaver: ERROR committed playback with no visible surface")
            }
            saveSelectionMemory()
        }
    }

    private func nextPlaybackKind() -> PlaybackKind {
        if ProcessInfo.processInfo.environment["SNOOPY_TEST_START_WITH_COMPOSITE"] == "1",
           sessionState.currentIdleSceneID == nil, !hasPlayedInitialActiveScene {
            return .composite
        }
        if ProcessInfo.processInfo.environment["SNOOPY_TEST_NATIVE_SEQUENCE"] == "1" {
            if sessionState.currentIdleSceneID != nil {
                return shouldRotateIdleScene ? .video : .composite
            }
            return hasPlayedInitialActiveScene ? .composite : .video
        }
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_PLAYBACK_KIND"] == "video" { return .video }
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_PLAYBACK_KIND"] == "composite" { return .composite }
        if sessionState.currentIdleSceneID != nil {
            if shouldRotateIdleScene {
                idleSceneChangeRequested = true
                NSLog("SnoopyTVScreenSaver: idle scene reached Apple 240s target; requesting active scene transition")
                return .video
            }
            return .composite
        }
        // IdleCharacterPoster starts with an ActiveScene, then enters a long
        // IdleScene residency. It does not use a 1:4 shuffled media bag.
        return hasPlayedInitialActiveScene ? .composite : .video
    }

    private var shouldRotateIdleScene: Bool {
        guard sessionState.currentIdleSceneID != nil,
              let startedAt = idleSceneStartedAt else { return false }
        return idleSceneAnimationCount >= idleSceneTargetAnimationCount
            || ProcessInfo.processInfo.systemUptime - startedAt >= idleSceneTargetDuration
    }

    private func beginIdleScene(_ id: String) {
        sessionState.currentIdleSceneID = id
        idleSceneStartedAt = ProcessInfo.processInfo.systemUptime
        idleSceneAnimationCount = 0
        idleSceneTargetAnimationCount = ProcessInfo.processInfo.environment["SNOOPY_TEST_IDLE_ROTATION_COUNT"]
            .flatMap(Int.init) ?? .max
        idleSceneTargetDuration = ProcessInfo.processInfo.environment["SNOOPY_TEST_IDLE_ROTATION_SECONDS"]
            .flatMap(Double.init) ?? 240
        sessionState.resetCharacterMix()
        visitorScheduleTimes = PlaybackSessionState.visitorSchedule(
            targetDuration: idleSceneTargetDuration, seed: seed
        )
        nextVisitorScheduleIndex = 0
        idleSceneChangeRequested = false
        NSLog("SnoopyTVScreenSaver: begin idle scene %@ targetDuration=%.0f visitorSchedule=%@",
              id, idleSceneTargetDuration,
              visitorScheduleTimes.map { String(format: "%.1f", $0) }.joined(separator: ","))
    }

    private func clearIdleSceneState() {
        sessionState.currentIdleSceneID = nil
        sessionState.currentBasePoseID = nil
        idleSceneStartedAt = nil
        idleSceneAnimationCount = 0
        visitorScheduleTimes.removeAll()
        nextVisitorScheduleIndex = 0
        currentPaletteAssetID = nil
        currentSceneOffset = nil
        pendingCharacterAssetIDs.removeAll()
    }

    private func sessionChoice(from assets: [AssetRecord], pool: String, context: SelectionContext) -> AssetRecord? {
        let scorer = RelevancyScorer()
        let uniqueAssets = assets.reduce(into: [String: AssetRecord]()) { result, asset in
            result[asset.id] = asset
        }
        var weighted = uniqueAssets.values.compactMap { asset -> WeightedAsset? in
            guard let relevance = scorer.relevanceScore(asset, context: context) else { return nil }
            let weight: Int
            switch relevance {
            case 65...: weight = 8
            case 25...: weight = 4
            case 1...: weight = 2
            default: weight = 1
            }
            return WeightedAsset(asset: asset, weight: weight)
        }
        if weighted.isEmpty {
            weighted = uniqueAssets.values.filter { !$0.hasConditions }.map {
                WeightedAsset(asset: $0, weight: 1)
            }
        }
        let persistedRecent = Set(memory.recentIDs(in: pool))
        let fresh = weighted.filter { !persistedRecent.contains($0.asset.id) }
        if !fresh.isEmpty {
            weighted = fresh
        } else if let lastID = memory.lastSelectedID(in: pool), weighted.count > 1 {
            weighted.removeAll { $0.asset.id == lastID }
        }
        defer { seed &+= 1 }
        let selected = sessionState.chooseWeighted(from: weighted, pool: pool, seed: seed)
        if let selected {
            memory.record(selected.id, in: pool)
        }
        return selected
    }

    private func playRandomVideo(from store: AssetStore, context: SelectionContext) -> Bool {
        var candidates = store.eligible(store.activeScenes(), on: context.date).filter { asset in
            guard let directory = try? store.url(for: asset) else { return false }
            return asset.sprites.contains { sprite in
                guard sprite.spriteType == "video", let base = sprite.assetBaseName else { return false }
                let name = asset.media?.first(where: { $0.name == base + ".mov" })?.name ?? base + ".mov"
                return FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
            }
        }
        let hasOutgoingIdle = sessionState.currentIdleSceneID != nil
        // `preventsIdleSceneChange` only means that an already-mounted room
        // must be retained. It does not forbid that transition from creating
        // the first IdleScene. For later 240s rotations, let authored dream /
        // story transitions retain the room at most twice, then force one of
        // the scene-changing RealWorld transitions so houses still rotate.
        let requiresNewIdle = hasOutgoingIdle && idleSceneChangeRequested
            && consecutiveTransitionsPreventingIdleSceneChange >= 2
        if requiresNewIdle, let graph = playbackGraph {
            candidates = candidates.filter { active in
                graph.transitionCandidates(for: active).contains {
                    !$0.preventsIdleSceneChange && sceneTransitionIsPlayable($0, from: store)
                }
            }
        }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_ASSET_ID"] {
            candidates = candidates.filter { $0.id == forcedID }
        }
        guard let selected = sessionChoice(from: candidates, pool: "activeVideos", context: context) else { return false }
        if let selection = chooseSceneTransition(
            for: selected, context: context, from: store, requiresSceneChange: requiresNewIdle
        ) {
            sessionState.recordTransitionPair(selection.pairID)
            if selection.preventsIdleSceneChange {
                consecutiveTransitionsPreventingIdleSceneChange += 1
            } else {
                consecutiveTransitionsPreventingIdleSceneChange = 0
            }
            // ActiveScene is the upper maskHost in tvOS. Hide makes it
            // transparent to enter the IdleScene below; Reveal makes it
            // opaque again to exit IdleScene. Keep one moving player through
            // the complete Hide -> Active -> Reveal cycle.
            pendingSceneStages = [.transition(.hide, selection)]
            guard startActiveVideo(selected, from: store, context: context) else {
                pendingSceneStages.removeAll()
                return false
            }
            if hasOutgoingIdle,
               !playSceneTransitionStage(.reveal, selection: selection, from: store, context: context) {
                NSLog("SnoopyTVScreenSaver: idle exit transition unavailable; continuing moving active video %@", selected.id)
            }
            return true
        }
        if idleSceneChangeRequested {
            clearIdleSceneState()
            idleSceneChangeRequested = false
        }
        return startActiveVideo(selected, from: store, context: context)
    }

    private func startActiveVideo(_ selected: AssetRecord, from store: AssetStore, context: SelectionContext) -> Bool {
        guard let sprite = selected.sprites.first(where: { $0.spriteType == "video" }),
           let base = sprite.assetBaseName,
           let directory = try? store.url(for: selected) else { return false }
        let media = selected.media?.first(where: { $0.name == base + ".mov" })
        let name = media?.name ?? base + ".mov"
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return false }

        let item = AVPlayerItem(url: url)
        let player = AVPlayer(playerItem: item)
        player.actionAtItemEnd = .pause
        let palette = paletteColors(from: store, context: context)
        layer?.backgroundColor = palette.0.cgColor
        if let halftoneURL = halftoneImageURL(),
           let source = CGImageSourceCreateWithURL(halftoneURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let halftone = CALayer()
            halftone.frame = bounds
            halftone.contents = image
            halftone.contentsGravity = .resize
            halftone.opacity = 0.1
            layer?.addSublayer(halftone)
            activeHalftoneLayer = halftone
        }
        let videoLayer = AVPlayerLayer(player: player)
        // ActiveScene is a full-screen movie in tvOS. On non-16:9 displays
        // scale it proportionally until it covers the viewport; cropping is
        // preferable to letterboxing and never distorts the source.
        videoLayer.videoGravity = .resizeAspect
        videoLayer.frame = activeVideoFrame(for: sprite)
        layer?.masksToBounds = true
        layer?.addSublayer(videoLayer)
        if let image = videoPlaceholderImage(at: url) {
            let placeholder = CALayer()
            placeholder.frame = videoLayer.frame
            placeholder.contents = image
            placeholder.contentsGravity = .resizeAspect
            placeholder.backgroundColor = palette.0.cgColor
            layer?.addSublayer(placeholder)
            activeVideoPlaceholderLayer = placeholder
            playerReadyObservation = videoLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) {
                [weak self, weak videoLayer] _, _ in
                guard videoLayer?.isReadyForDisplay == true else { return }
                DispatchQueue.main.async {
                    self?.activeVideoPlaceholderLayer?.removeFromSuperlayer()
                    self?.activeVideoPlaceholderLayer = nil
                    self?.playerReadyObservation = nil
                }
            }
        }
        self.player = player
        self.playerLayer = videoLayer
        activeVideoAssetID = selected.id
        foregroundSprite = sprite
        currentAssetID = selected.id
        isPlaying = true
        hasPlayedInitialActiveScene = true

        playerEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.hasPendingIdleEntryTransition {
                    self.beginPendingIdleEntryTransition()
                } else {
                    self.finishCurrentPlayback("video ended")
                }
            }
        }
        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main
        ) { [weak self] notification in
            NSLog("SnoopyTVScreenSaver: video failure %@", String(describing: notification.userInfo))
            self?.finishCurrentPlayback("video failed")
        }
        playerStallObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemPlaybackStalled, object: item, queue: .main
        ) { [weak self] _ in
            self?.installWatchdog(defaultSeconds: 5)
        }
        let visualEnd = ProcessInfo.processInfo.environment["SNOOPY_TEST_ACTIVE_END_SECONDS"].flatMap(Double.init)
            ?? media?.effectiveEndSeconds ?? media?.durationSeconds
            ?? AVURLAsset(url: url).duration.seconds
        if visualEnd.isFinite, visualEnd > 0.5 {
            let entryOverlap = pendingIdleEntryTransitionDuration(from: store)
            let triggerTime = entryOverlap.map { max(0.25, visualEnd - $0) } ?? visualEnd
            let boundary = CMTime(seconds: triggerTime, preferredTimescale: 600)
            playerBoundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: boundary)], queue: .main) { [weak self] in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if self.hasPendingIdleEntryTransition {
                        self.beginPendingIdleEntryTransition()
                    } else {
                        self.finishCurrentPlayback("visual content ended")
                    }
                }
            }
            if let entryOverlap {
                NSLog("SnoopyTVScreenSaver: active/idle-entry overlap asset=%@ start=%.3f overlap=%.3f end=%.3f",
                      selected.id, triggerTime, entryOverlap, visualEnd)
            }
        }
        let watchdogSeconds = (media?.durationSeconds ?? 117) + 3
        installWatchdog(defaultSeconds: watchdogSeconds)
        let effectiveDescription = media?.effectiveEndSeconds.map { String(format: "%.3f", $0) } ?? "container-end"
        let durationDescription = media?.durationSeconds.map { String(format: "%.3f", $0) } ?? "unknown"
        NSLog("SnoopyTVScreenSaver: video %@ effectiveEnd=%@ duration=%@ fillFrame=%@ bounds=%@",
              selected.id, effectiveDescription, durationDescription,
              NSStringFromRect(videoLayer.frame), NSStringFromRect(bounds))
        player.play()
        return true
    }

    private var hasPendingIdleEntryTransition: Bool {
        guard let first = pendingSceneStages.first,
              case .transition(.hide, _) = first else { return false }
        return true
    }

    private func pendingIdleEntryTransitionDuration(from store: AssetStore) -> TimeInterval? {
        guard let first = pendingSceneStages.first,
              case .transition(.hide, let selection) = first else { return nil }
        return transitionDuration(.hide, selection: selection, from: store)
    }

    private func transitionDuration(
        _ stage: TransitionStage, selection: SceneTransitionSelection, from store: AssetStore
    ) -> TimeInterval? {
        guard let graph = playbackGraph,
              let parameterID = stage == .hide ? selection.hideParametersID : selection.revealParametersID,
              let parameter = graph.assetsByID[parameterID],
              let mask = parameter.sprites.first(where: { $0.plane == "mask" }),
              let url = videoURL(for: parameter, sprite: mask, store: store) else { return nil }
        let seconds = AVURLAsset(url: url).duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : nil
    }

    private func beginPendingIdleEntryTransition() {
        guard isPlaying, let store, let first = pendingSceneStages.first,
              case .transition(.hide, let selection) = first else { return }
        if idleExitTransitionInProgress {
            idleEntryRequestedWhileExiting = true
            NSLog("SnoopyTVScreenSaver: idle entry requested while idle exit is active; deferring pair=%@",
                  selection.pairID)
            return
        }
        pendingSceneStages.removeFirst()
        if let observer = playerEndObserver { NotificationCenter.default.removeObserver(observer) }
        playerEndObserver = nil
        if let observer = playerBoundaryObserver, let player {
            player.removeTimeObserver(observer)
        }
        playerBoundaryObserver = nil
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        holdingActiveFrameForIdleEntry = true
        let movingTime = player?.currentTime().seconds ?? 0
        NSLog("SnoopyTVScreenSaver: begin moving idle entry pair=%@ activeTime=%.3f rate=%.2f",
              selection.pairID, movingTime, player?.rate ?? 0)
        if !playSceneTransitionStage(.hide, selection: selection, from: store, context: currentContext()) {
            finishCurrentPlayback("unable to start moving idle entry transition")
        }
    }

    private func completeIdleExitTransitionAndContinueActiveVideo(selection: SceneTransitionSelection) {
        let id = activeVideoAssetID ?? "active video"
        idleExitTransitionInProgress = false
        // The moving ActiveScene (or its decoded placeholder) is already
        // underneath both surfaces. Move it out of the Reveal mask host and
        // remove the outgoing Idle surface in one display transaction.
        // in one display transaction so the old character/room cannot flash
        // back for a frame between them.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let activeLayer = playerLayer {
            activeLayer.mask = nil
            layer?.addSublayer(activeLayer)
        }
        cleanTransitionOverlay()
        retirePreviousCompositeSurface()
        CATransaction.commit()
        currentAssetID = id
        isPlaying = true
        let duration = player?.currentItem?.duration.seconds ?? 0
        let current = player?.currentTime().seconds ?? 0
        let remaining = duration.isFinite ? max(1, duration - current) : 120
        installWatchdog(defaultSeconds: remaining + 3)
        if !selection.preventsIdleSceneChange {
            clearIdleSceneState()
            idleSceneChangeRequested = false
        }
        NSLog("SnoopyTVScreenSaver: idle exit completed over moving video %@ time=%.3f rate=%.2f",
              id, current, player?.rate ?? 0)
        if idleEntryRequestedWhileExiting {
            idleEntryRequestedWhileExiting = false
            DispatchQueue.main.async { [weak self] in self?.beginPendingIdleEntryTransition() }
        }
    }

    private func completeSceneTransitionStage(
        _ stage: TransitionStage, selection: SceneTransitionSelection, reason: String
    ) {
        guard isPlaying else { return }
        watchdogWorkItem?.cancel()
        watchdogWorkItem = nil
        if stage == .reveal, playerLayer != nil {
            completeIdleExitTransitionAndContinueActiveVideo(selection: selection)
        } else {
            if stage == .hide {
                holdingCompletedIdleEntrySurface = true
                if selection.preventsIdleSceneChange, idleSceneChangeRequested,
                   let currentIdleSceneID = sessionState.currentIdleSceneID {
                    // A dream/story transition intentionally returns to the
                    // same authored room. That return begins a fresh 240s
                    // residency; leaving the old timer expired would launch
                    // another ActiveScene immediately after one character
                    // action and make these families look like interstitials.
                    beginIdleScene(currentIdleSceneID)
                }
            }
            finishCurrentPlayback("\(stage.rawValue) scene transition \(reason)")
        }
    }

    private func chooseSceneTransition(
        for activeScene: AssetRecord, context: SelectionContext, from store: AssetStore,
        requiresSceneChange: Bool
    ) -> SceneTransitionSelection? {
        guard let graph = playbackGraph else { return nil }
        let scorer = RelevancyScorer()
        var allCandidates = graph.transitionCandidates(for: activeScene).filter {
            sceneTransitionIsPlayable($0, from: store)
        }
        if let forcedPairID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_TRANSITION_PAIR_ID"] {
            allCandidates = allCandidates.filter { $0.pairID == forcedPairID }
        }
        guard !allCandidates.isEmpty else { return nil }
        if requiresSceneChange {
            allCandidates = allCandidates.filter { !$0.preventsIdleSceneChange }
            guard !allCandidates.isEmpty else { return nil }
        }
        if consecutiveTransitionsPreventingIdleSceneChange >= 2 {
            let sceneChanging = allCandidates.filter { !$0.preventsIdleSceneChange }
            if !sceneChanging.isEmpty { allCandidates = sceneChanging }
        }
        if let lastRevealTransitionPoseID {
            let freshPose = allCandidates.filter { !$0.revealCharacterPoseIDs.contains(lastRevealTransitionPoseID) }
            if !freshPose.isEmpty { allCandidates = freshPose }
        }
        var candidates = allCandidates.filter { candidate in
            guard let pair = graph.assetsByID[candidate.pairID] else { return false }
            return scorer.relevanceScore(pair, context: context) != nil
        }
        guard !candidates.isEmpty else { return nil }

        // Pick the real TM artwork family first. The manifest has many pair
        // references, but weather/time variants often point at the same mask
        // files; pair-only recency therefore kept showing Clock/Horizontal.
        let families = Dictionary(grouping: candidates, by: \SceneTransitionSelection.parameterFamilyID)
        let recentFamilies = Set(memory.recentIDs(in: "sceneTransitionParameterFamilies"))
        let freshFamilyIDs = families.keys.filter { !recentFamilies.contains($0) }
        var familyIDs = freshFamilyIDs.isEmpty ? Array(families.keys) : freshFamilyIDs
        if freshFamilyIDs.isEmpty,
           let lastFamilyID = memory.lastSelectedID(in: "sceneTransitionParameterFamilies"),
           familyIDs.count > 1 {
            familyIDs.removeAll { $0 == lastFamilyID }
        }
        familyIDs.sort()
        guard !familyIDs.isEmpty else { return nil }

        func relevanceWeight(for candidate: SceneTransitionSelection) -> Int {
            guard let pair = graph.assetsByID[candidate.pairID],
                  let relevance = scorer.relevanceScore(pair, context: context) else { return 0 }
            switch relevance {
            case 65...: return 8
            case 25...: return 4
            case 1...: return 2
            default: return 1
            }
        }

        let familyWeights = familyIDs.map { familyID in
            families[familyID, default: []].map(relevanceWeight).max() ?? 1
        }
        let totalFamilyWeight = familyWeights.reduce(0, +)
        var familyTicket = Int(PlaybackSessionState.mixedIndex(
            seed: seed, count: max(1, totalFamilyWeight)
        ))
        var selectedFamilyID = familyIDs[0]
        for (familyID, weight) in zip(familyIDs, familyWeights) {
            if familyTicket < weight {
                selectedFamilyID = familyID
                break
            }
            familyTicket -= weight
        }

        candidates = families[selectedFamilyID, default: []]
        let recentRevealPoseIDs = Set(memory.recentIDs(in: "sceneTransitionPoses.reveal"))
        let recentTransitionCategoryIDs = Set(memory.recentIDs(in: "sceneTransitionCategories"))
        let recentPairIDs = Set(memory.recentIDs(in: "sceneTransitionPairs"))
            .union(sessionState.recentTransitionPairIDs)
        let freshCandidates = candidates.filter { candidate in
            !recentPairIDs.contains(candidate.pairID)
                && !recentTransitionCategoryIDs.contains(candidate.categoryID)
                && candidate.revealCharacterPoseIDs.allSatisfy { !recentRevealPoseIDs.contains($0) }
        }
        if !freshCandidates.isEmpty { candidates = freshCandidates }
        if let lastPairID = memory.lastSelectedID(in: "sceneTransitionPairs"), candidates.count > 1 {
            let withoutLast = candidates.filter { $0.pairID != lastPairID }
            if !withoutLast.isEmpty { candidates = withoutLast }
        }
        candidates.sort { ($0.categoryID, $0.pairID) < ($1.categoryID, $1.pairID) }
        seed &+= 1
        let totalCandidateWeight = candidates.map(relevanceWeight).reduce(0, +)
        var candidateTicket = Int(PlaybackSessionState.mixedIndex(
            seed: seed, count: max(1, totalCandidateWeight)
        ))
        var selected = candidates[0]
        for candidate in candidates {
            let weight = relevanceWeight(for: candidate)
            if candidateTicket < weight {
                selected = candidate
                break
            }
            candidateTicket -= weight
        }
        seed &+= 1
        memory.record(selected.pairID, in: "sceneTransitionPairs")
        memory.record(selected.categoryID, in: "sceneTransitionCategories")
        memory.record(selected.parameterFamilyID, in: "sceneTransitionParameterFamilies")
        NSLog("SnoopyTVScreenSaver: selected transition family=%@ pair=%@ category=%@ availableFamilies=%d",
              selected.parameterFamilyID, selected.pairID, selected.categoryID, families.count)
        return selected
    }

    private func sceneTransitionIsPlayable(
        _ selection: SceneTransitionSelection, from store: AssetStore
    ) -> Bool {
        guard let graph = playbackGraph else { return false }
        for parameterID in [selection.hideParametersID, selection.revealParametersID] {
            guard let parameterID, let parameter = graph.assetsByID[parameterID],
                  let mask = parameter.sprites.first(where: { $0.plane == "mask" }),
                  let outline = parameter.sprites.first(where: { $0.plane == "foregroundEffect" }),
                  videoURL(for: parameter, sprite: mask, store: store) != nil,
                  videoURL(for: parameter, sprite: outline, store: store) != nil else { return false }
        }
        for (phase, ids) in [("hide", selection.hideCharacterPoseIDs),
                             ("reveal", selection.revealCharacterPoseIDs)] where !ids.isEmpty {
            let hasPlayablePose = ids.compactMap { graph.assetsByID[$0] }.contains { asset in
                asset.transitionPhase == phase
                    && asset.sprites.contains { videoURL(for: asset, sprite: $0, store: store) != nil }
            }
            if !hasPlayablePose { return false }
        }
        return true
    }

    private func playSceneTransitionStage(
        _ stage: TransitionStage, selection: SceneTransitionSelection,
        from store: AssetStore, context: SelectionContext
    ) -> Bool {
        guard let graph = playbackGraph else { return false }
        // Do not clear the outgoing IdleScene at reveal start. Its final
        // Reveal pose remains underneath the ActiveScene mask until the upper
        // scene is fully opaque, then the coordinator unloads it.
        let eligible = store.eligible(store.playableAssets(), on: context.date)
        let idleAssets = eligible.filter { $0.kind == "idleScene" }
        let idle: AssetRecord
        if let id = sessionState.currentIdleSceneID,
           let current = idleAssets.first(where: { $0.id == id }) {
            idle = current
        } else {
            guard let selected = sessionChoice(from: idleAssets, pool: "idleScenes", context: context) else { return false }
            idle = selected
            beginIdleScene(selected.id)
        }
        guard let directory = try? store.url(for: idle) else { return false }
        currentSceneOffset = idle.idleScene?.sceneOffset
        let backgroundSprite = idle.sprites.first
        let backgroundImage = firstHEICName(in: idle).map { directory.appendingPathComponent($0) }
        let backgroundVideo = idle.sprites.first(where: { $0.spriteType == "video" })
            .flatMap { videoURL(for: idle, sprite: $0, store: store) }
        guard backgroundImage != nil || backgroundVideo != nil else { return false }
        let palette = paletteColors(from: store, context: context, idleScene: idle)

        let parameterID = stage == .hide ? selection.hideParametersID : selection.revealParametersID
        let poseIDs = stage == .hide ? selection.hideCharacterPoseIDs : selection.revealCharacterPoseIDs
        guard let parameterID, let parameterAsset = graph.assetsByID[parameterID],
              let maskSprite = parameterAsset.sprites.first(where: { $0.plane == "mask" }),
              let outlineSprite = parameterAsset.sprites.first(where: { $0.plane == "foregroundEffect" }),
              let maskURL = videoURL(for: parameterAsset, sprite: maskSprite, store: store),
              let outlineURL = videoURL(for: parameterAsset, sprite: outlineSprite, store: store),
              let activeSurfaceLayer = playerLayer else { return false }

        let host = NSView(frame: bounds)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(host)
        transitionHostView = host
        guard let hostLayer = host.layer else { return false }
        // AVPlayer.preroll() may finish before an AVPlayerLayer renderer has a
        // drawable. Keep the complete transition tree barely visible so every
        // renderer participates in composition, then expose it only after all
        // layers report readyForDisplay.
        hostLayer.opacity = 0.001

        transitionPlayers = []
        transitionLayers = []
        var synchronizedVideoLayers: [AVPlayerLayer] = []
        var firstFrameLayers: [CALayer] = []

        func firstFrameLayer(for url: URL, frame: CGRect) -> CALayer? {
            guard let image = videoPlaceholderImage(at: url) else { return nil }
            let layer = CALayer()
            layer.frame = frame
            layer.contents = image
            layer.contentsGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            firstFrameLayers.append(layer)
            transitionLayers.append(layer)
            return layer
        }

        // tvOS keeps IdleScene at the bottom of the stack and uses the upper
        // ActiveScene as maskHostView. This port mirrors that ownership with
        // the already-mounted ActiveScene player and one transition tree.

        let sceneLayer = CALayer()
        sceneLayer.frame = bounds
        sceneLayer.backgroundColor = palette.background.cgColor
        sceneLayer.masksToBounds = true

        // Palette overlay belongs to the palette base. Putting an opaque
        // late-night overlay above the idle scene erases the house/tent and
        // halftone completely, leaving only the subsequently-added MOV pose.
        if let overlay = palette.overlay {
            let overlayLayer = CALayer()
            overlayLayer.frame = bounds
            overlayLayer.backgroundColor = overlay.cgColor
            sceneLayer.addSublayer(overlayLayer)
            transitionLayers.append(overlayLayer)
        }

        if let halftoneURL = halftoneImageURL(),
           let source = CGImageSourceCreateWithURL(halftoneURL as CFURL, nil),
           let image = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            let halftone = CALayer()
            halftone.frame = bounds
            halftone.contents = image
            halftone.contentsGravity = .resize
            halftone.opacity = 0.1
            sceneLayer.addSublayer(halftone)
            transitionLayers.append(halftone)
        }

        let eligiblePoses = poseIDs.compactMap { graph.assetsByID[$0] }.filter {
            $0.transitionPhase == stage.rawValue
        }
        let selectedPose = sessionChoice(
            from: eligiblePoses, pool: "sceneTransitionPoses.\(stage.rawValue)", context: context
        )
        if stage == .reveal {
            lastRevealTransitionPoseID = selectedPose?.id
        }
        var poseLayer: AVPlayerLayer?
        var poseFirstFrameLayer: CALayer?
        var poseItem: AVPlayerItem?
        if let poseAsset = selectedPose,
           let poseSprite = poseAsset.sprites.first,
           let poseURL = videoURL(for: poseAsset, sprite: poseSprite, store: store) {
            let item = AVPlayerItem(url: poseURL)
            let posePlayer = AVPlayer(playerItem: item)
            let layer = AVPlayerLayer(player: posePlayer)
            layer.frame = compositeFrame(for: poseSprite)
            layer.videoGravity = .resizeAspect
            layer.backgroundColor = NSColor.clear.cgColor
            layer.opacity = 1
            poseLayer = layer
            poseItem = item
            poseFirstFrameLayer = firstFrameLayer(for: poseURL, frame: layer.frame)
            transitionPlayers.append(posePlayer)
            transitionLayers.append(layer)
            synchronizedVideoLayers.append(layer)
            // Install the transition character only after the IdleScene
            // background below. Adding it here let the subsequently-added
            // opaque house/tent layer cover Snoopy for the whole transition.
        }

        if let backgroundImage,
           let image = decodedCGImage(at: backgroundImage, maxPixelSize: maximumPixelSize(for: backgroundSprite)) {
            let backgroundLayer = CALayer()
            backgroundLayer.frame = compositeFrame(for: backgroundSprite)
            backgroundLayer.contents = image
            backgroundLayer.contentsGravity = .resize
            sceneLayer.addSublayer(backgroundLayer)
            transitionLayers.append(backgroundLayer)
        } else if let backgroundVideo, let backgroundSprite {
            let idlePlayer = AVPlayer(url: backgroundVideo)
            let idleLayer = AVPlayerLayer(player: idlePlayer)
            idleLayer.frame = compositeFrame(for: backgroundSprite)
            idleLayer.videoGravity = .resizeAspect
            idleLayer.opacity = 1
            sceneLayer.addSublayer(idleLayer)
            if let firstFrame = firstFrameLayer(for: backgroundVideo, frame: idleLayer.frame) {
                sceneLayer.addSublayer(firstFrame)
            }
            transitionPlayers.append(idlePlayer)
            transitionLayers.append(idleLayer)
            synchronizedVideoLayers.append(idleLayer)
        }
        if let poseLayer {
            sceneLayer.addSublayer(poseLayer)
            if let poseFirstFrameLayer { sceneLayer.addSublayer(poseFirstFrameLayer) }
        }

        // Transition masks describe a full-screen wipe, not an idle sprite.
        // Aspect-fill the matte and outline together so 16:10/ultrawide never
        // exposes an unmasked strip; the character/idle scene stays aspect-fit.
        let viewport = activeVideoFrame(for: maskSprite)
        let maskItem = AVPlayerItem(url: maskURL)
        let maskPlayer = AVPlayer(playerItem: maskItem)
        let maskLayer = AVPlayerLayer(player: maskPlayer)
        // The tvOS maskHost is the upper ActiveScene, not the IdleScene.
        // Its local bounds are 16:9 even when its frame aspect-fills a 16:10
        // display, so the matte remains aligned with the moving movie.
        maskLayer.frame = activeSurfaceLayer.bounds
        maskLayer.videoGravity = .resizeAspect
        hostLayer.addSublayer(sceneLayer)
        activeSurfaceLayer.mask = maskLayer

        let outlinePlayer = AVPlayer(url: outlineURL)
        let outlineLayer = AVPlayerLayer(player: outlinePlayer)
        outlineLayer.frame = viewport
        outlineLayer.videoGravity = .resizeAspect
        outlineLayer.backgroundColor = NSColor.clear.cgColor
        outlineLayer.opacity = 1
        hostLayer.addSublayer(outlineLayer)
        if let firstOutline = firstFrameLayer(for: outlineURL, frame: viewport) {
            hostLayer.addSublayer(firstOutline)
        }
        transitionPlayers.append(contentsOf: [maskPlayer, outlinePlayer])
        transitionLayers.append(contentsOf: [sceneLayer, maskLayer, outlineLayer])
        synchronizedVideoLayers.append(contentsOf: [maskLayer, outlineLayer])

        let maskDuration = AVURLAsset(url: maskURL).duration.seconds
        let poseDuration = poseItem?.asset.duration.seconds ?? 0
        // Hide enters IdleScene. Apple lets the initial SceneTransitionPose
        // finish after the short ActiveScene wipe; ending on the mask item
        // stopped many 4-8 second poses before Snoopy became visible.
        let completionItem = stage == .hide && poseDuration > maskDuration
            ? (poseItem ?? maskItem) : maskItem
        let completionDuration = max(maskDuration, poseDuration)
        let revealMaskLead = stage == .reveal ? max(0, poseDuration - maskDuration) : 0
        transitionEndObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: completionItem, queue: .main
        ) { [weak self] _ in
            self?.completeSceneTransitionStage(stage, selection: selection, reason: "ended")
        }
        let duration = completionDuration
        if stage == .reveal { idleExitTransitionInProgress = true }
        currentAssetID = "\(selection.pairID).\(stage.rawValue)"
        isPlaying = true

        transitionPlaybackGeneration &+= 1
        let generation = transitionPlaybackGeneration
        let prerollStartedAt = ProcessInfo.processInfo.systemUptime
        let resultLock = NSLock()
        var allPrerollsSucceeded = true
        var didStart = false
        var didBeginPreroll = false
        let startSynchronizedPlayback: () -> Void = { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            resultLock.lock()
            let succeeded = allPrerollsSucceeded
            resultLock.unlock()
            guard succeeded else {
                self.finishCurrentPlayback("transition preroll failed")
                return
            }
            didStart = true
            self.transitionPrerollTimeout?.cancel()
            self.transitionPrerollTimeout = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            hostLayer.opacity = 1
            firstFrameLayers.forEach { $0.removeFromSuperlayer() }
            if self.hasMountedNormalIdleSurface {
                // The transition tree is now the sole maskHost-equivalent
                // owner. Remove any normal or retiring Idle tree in this same
                // display transaction. This also makes Reveal resilient to a
                // stale surface left by a failed prior stage.
                self.retireOutgoingIdleSurfaceForTransition()
            }
            // Reparent the same moving ActiveScene layer into the transition
            // host. It sits above the unmasked IdleScene and below the authored
            // outline; Hide/Reveal now affect only this upper scene.
            if activeSurfaceLayer.superlayer !== hostLayer {
                activeSurfaceLayer.removeFromSuperlayer()
                hostLayer.insertSublayer(activeSurfaceLayer, above: sceneLayer)
            }
            CATransaction.commit()
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
                + CMTime(seconds: 0.06, preferredTimescale: 600)
            self.transitionPlayers.forEach { transitionPlayer in
                // Host-time synchronized playback is rejected by AVFoundation
                // while the player's automatic stall waiting is enabled.
                // Every transition surface has already been prerolled, so let
                // the shared clock (rather than per-player buffering) govern
                // when mask, outline, pose and idle motion become visible.
                transitionPlayer.automaticallyWaitsToMinimizeStalling = false
                let isWipePlayer = transitionPlayer === maskPlayer || transitionPlayer === outlinePlayer
                let startTime = hostTime + CMTime(
                    seconds: isWipePlayer ? revealMaskLead : 0,
                    preferredTimescale: 600
                )
                transitionPlayer.setRate(1, time: .zero, atHostTime: startTime)
            }
            self.installTransitionWatchdog(
                defaultSeconds: (duration.isFinite ? duration : 2) + 1,
                generation: generation, stage: stage, selection: selection
            )
            NSLog("SnoopyTVScreenSaver: transition synchronized stage=%@ preroll=%.3f players=%ld wipeLead=%.3f",
                  stage.rawValue, ProcessInfo.processInfo.systemUptime - prerollStartedAt,
                  self.transitionPlayers.count, revealMaskLead)
        }
        let beginPreroll: () -> Void = { [weak self] in
            guard let self, !didBeginPreroll, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            didBeginPreroll = true
            self.transitionItemStatusObservations.removeAll()
            let group = DispatchGroup()
            for player in self.transitionPlayers {
                player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                group.enter()
                player.preroll(atRate: 1) { succeeded in
                    if !succeeded {
                        resultLock.lock()
                        allPrerollsSucceeded = false
                        resultLock.unlock()
                    }
                    group.leave()
                }
            }
            group.notify(queue: .main) {
                let rendererDeadline = ProcessInfo.processInfo.systemUptime + 0.6
                var waitForDrawable: (() -> Void)!
                waitForDrawable = {
                    guard self.isPlaying,
                          self.transitionPlaybackGeneration == generation,
                          !didStart else { return }
                    if synchronizedVideoLayers.allSatisfy(\.isReadyForDisplay)
                        || ProcessInfo.processInfo.systemUptime >= rendererDeadline {
                        startSynchronizedPlayback()
                    } else {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 120.0) {
                            waitForDrawable()
                        }
                    }
                }
                waitForDrawable()
            }
        }
        var readyItems = Set<ObjectIdentifier>()
        let expectedReadyItems = transitionPlayers.compactMap(\.currentItem).count
        transitionItemStatusObservations = transitionPlayers.compactMap { player in
            guard let item = player.currentItem else { return nil }
            return item.observe(\.status, options: [.initial, .new]) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self, self.isPlaying,
                          self.transitionPlaybackGeneration == generation,
                          !didBeginPreroll else { return }
                    switch item.status {
                    case .readyToPlay:
                        readyItems.insert(ObjectIdentifier(item))
                        if readyItems.count == expectedReadyItems { beginPreroll() }
                    case .failed:
                        resultLock.lock()
                        allPrerollsSucceeded = false
                        resultLock.unlock()
                        self.finishCurrentPlayback("transition item failed to become ready")
                    default:
                        break
                    }
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.transitionPlaybackGeneration == generation else { return }
            NSLog("SnoopyTVScreenSaver: transition preroll timeout stage=%@", stage.rawValue)
            self.finishCurrentPlayback("transition preroll timeout")
        }
        transitionPrerollTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: timeout)
        NSLog("SnoopyTVScreenSaver: transition prepared stage=%@ category=%@ pair=%@ parameters=%@ retainIdle=%d matteFrame=%@ sceneBounds=%@ heldActive=%d",
              stage.rawValue, selection.categoryID, selection.pairID, parameterID,
              selection.preventsIdleSceneChange ? 1 : 0,
              NSStringFromRect(viewport), NSStringFromRect(sceneLayer.frame),
              holdingActiveFrameForIdleEntry ? 1 : 0)
        return true
    }

    private func playRandomComposite(from store: AssetStore, context: SelectionContext) -> Bool {
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_COMPOSITE_KIND"] == "switcher" {
            return playSwitcherSequence(from: store, context: context)
        }
        // SS assets are authored switcher/interstitial scenes, not members of
        // the ordinary IdleScene character queue. Never insert 102_SS001 (or
        // any sibling) merely because an idle composite failed or a bag slot
        // happened to select it. They remain available only to explicit tests.
        return playIdleCharacterComposite(from: store, context: context)
    }

    private func playSwitcherSequence(from store: AssetStore, context: SelectionContext) -> Bool {
        currentSceneOffset = nil
        var assets = store.eligible(store.playableAssets(), on: context.date).filter { $0.kind == "switcherScene" }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_SWITCHER_ID"] {
            assets = assets.filter { $0.id == forcedID }
        }
        guard let selected = sessionChoice(from: assets, pool: "switchers", context: context) else { return false }
        let palette = paletteColors(from: store, context: context)
        if let plan = phasedVideoPlan(for: selected, store: store) {
            return startVideoComposition(assetID: selected.id, backgroundImage: nil, backgroundSprite: nil,
                                         plan: plan, palette: palette, pendingPoseID: nil)
        }
        let frames = phasedFrameURLs(for: selected, store: store, minimumDuration: 0)
        guard !frames.isEmpty else { return false }
        return startFrameComposition(
            assetID: selected.id,
            backgroundImage: nil,
            backgroundSprite: nil,
            frameURLs: frames,
            foregroundSprite: selected.sprites.first(where: { $0.spriteType == "frameSequence" }),
            palette: palette
        )
    }

    private struct PhasedVideoPlan {
        let urls: [URL]
        let sprite: SpriteRecord
        let loopCount: Int
    }

    private struct VisitorPlaybackPlan {
        let assetID: String
        let media: PhasedVideoPlan
        let ignoresSceneOffset: Bool
        let isFullscreenEffect: Bool
        let isBackgroundPlane: Bool
    }

    private func phaseRank(_ sprite: SpriteRecord) -> Int {
        let phase = sprite.phase ?? sprite.contentPath ?? sprite.metadataPath ?? ""
        if phase.localizedCaseInsensitiveContains("intro") { return 0 }
        if phase.localizedCaseInsensitiveContains("loop") { return 1 }
        if phase.localizedCaseInsensitiveContains("outro") { return 2 }
        return 1
    }

    private func videoURL(for asset: AssetRecord, sprite: SpriteRecord, store: AssetStore) -> URL? {
        guard let base = sprite.assetBaseName else { return nil }
        if let directory = try? store.url(for: asset) {
            let name = asset.media?.first(where: { $0.name == base + ".mov" })?.name ?? base + ".mov"
            let original = directory.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: original.path) { return original }
        }
        return derivedMediaStore?.url(assetID: asset.id, baseName: base)
    }

    private func phasedVideoPlan(
        for asset: AssetRecord, store: AssetStore,
        repeatOneShot: Bool = false, visitorLoop: Bool = false
    ) -> PhasedVideoPlan? {
        let sprites = asset.sprites.sorted { phaseRank($0) < phaseRank($1) }
        guard !sprites.isEmpty else { return nil }
        var intro: [URL] = []
        var loop: [URL] = []
        var outro: [URL] = []
        var representative: SpriteRecord?
        for sprite in sprites {
            guard let url = videoURL(for: asset, sprite: sprite, store: store) else { continue }
            representative = representative ?? sprite
            switch phaseRank(sprite) {
            case 0: intro.append(url)
            case 2: outro.append(url)
            default: loop.append(url)
            }
        }
        guard let representative, !(intro.isEmpty && loop.isEmpty && outro.isEmpty) else { return nil }
        let hasExplicitPhases = sprites.contains { sprite in
            let value = sprite.phase ?? sprite.contentPath ?? ""
            return value.localizedCaseInsensitiveContains("intro")
                || value.localizedCaseInsensitiveContains("loop")
                || value.localizedCaseInsensitiveContains("outro")
        }
        let isFrameSequenceProxy = sprites.contains { $0.spriteType == "frameSequence" }
        let loops: Int
        if let testLoops = ProcessInfo.processInfo.environment["SNOOPY_TEST_COMPOSITE_LOOPS"].flatMap(Int.init) {
            loops = max(1, testLoops)
        } else if asset.kind == "characterBasePose" {
            loops = sessionState.basePoseLoopCount(seed: seed)
        } else if asset.kind == "characterAdditionalPose" {
            // The HEVC-alpha proxy preserves the authored Intro/Loop/Outro
            // split. Apple repeats AP Loop to meet its duration pool; treating
            // every converted HEIC phase as a one-shot produced 1–2s scenes.
            loops = asset.id.hasPrefix("101_AP00")
                ? sessionState.sustainedAdditionalPoseLoopCount(seed: seed)
                : sessionState.additionalPoseLoopCount(seed: seed)
        } else if isFrameSequenceProxy {
            // HEIC sequences remain authored one-shots even when their
            // metadata happens to contain named phase folders. The HEVC-alpha
            // proxy is only a lower-CPU transport for that exact frame list.
            loops = 1
        } else if hasExplicitPhases, visitorLoop {
            loops = sessionState.visitorLoopCount(seed: seed)
        } else if hasExplicitPhases {
            // Native MOV animations repeat only their Loop phase; Intro and
            // Outro remain one-shot.
            loops = sessionState.loopCount(seed: seed)
        } else if repeatOneShot {
            loops = sessionState.restingLoopCount(seed: seed)
        } else {
            loops = 1
        }
        seed &+= 1
        var urls = intro
        if !hasExplicitPhases && !repeatOneShot {
            urls.append(contentsOf: loop)
            urls.append(contentsOf: outro)
        } else if loop.isEmpty {
            urls.append(contentsOf: outro)
        } else {
            for _ in 0..<loops { urls.append(contentsOf: loop) }
            urls.append(contentsOf: outro)
        }
        return PhasedVideoPlan(urls: urls, sprite: representative, loopCount: loops)
    }

    private func startVideoComposition(
        assetID: String,
        backgroundImage: URL?,
        backgroundVideo: URL? = nil,
        backgroundSprite: SpriteRecord?,
        plan: PhasedVideoPlan,
        palette: (background: NSColor, overlay: NSColor?),
        pendingPoseID: String?,
        visitor: VisitorPlaybackPlan? = nil,
        characterAnimationKind: CharacterAnimationKind? = nil
    ) -> Bool {
        guard !plan.urls.isEmpty else { return false }
        let estimatedSeconds = estimatedDuration(of: plan.urls)
        let visitorSeconds = visitor.map { estimatedDuration(of: $0.media.urls) } ?? 0
        var visitorInstalled = false
        installCompositeBackdrop(backgroundImage: backgroundImage, backgroundVideo: backgroundVideo,
                                 backgroundSprite: backgroundSprite, palette: palette)
        if let visitor, visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        self.foregroundSprite = plan.sprite
        let frame = compositeFrame(for: plan.sprite)
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let isReplacingRetainedSurface = hasRetiringPlaybackSurface
        // An opacity of zero can keep AVPlayerLayer out of the render tree and
        // prevent readyForDisplay from ever becoming true. Keep the incoming
        // tree participating in composition without making it perceptible.
        host.layer?.opacity = isReplacingRetainedSurface ? 0.001 : 1
        addSubview(host)
        compositeVideoHostView = host

        guard let seamlessItem = seamlessVideoItem(for: plan.urls) else { return false }
        // A multi-item AVQueuePlayer briefly exposes the transparent backdrop
        // while VideoToolbox switches decoders between Intro/Loop/Outro or an
        // action and its returning BasePose. A single composition item lets
        // AVFoundation pre-roll the complete authored timeline without an
        // item-boundary drawable gap. Do not put that sole item back into an
        // advancing AVQueuePlayer: advancing the final item clears currentItem
        // before the end notification can retain its last drawable.
        let items = [seamlessItem]
        let queue = AVPlayer(playerItem: seamlessItem)
        queue.actionAtItemEnd = .pause
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.frame = host.bounds
        videoLayer.videoGravity = .resize
        videoLayer.backgroundColor = NSColor.clear.cgColor
        host.layer?.addSublayer(videoLayer)
        // AVAssetImageGenerator does not reproduce every HEVC-alpha first
        // frame exactly. It is safe for a cold start, but must never replace a
        // retained authored surface during an internal composite handoff.
        if !isReplacingRetainedSurface, let image = videoPlaceholderImage(at: plan.urls[0]) {
            let placeholder = CALayer()
            placeholder.frame = host.bounds
            placeholder.contents = image
            placeholder.contentsGravity = .resize
            placeholder.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(placeholder)
            compositeVideoPlaceholderLayer = placeholder
        }
        keepRetiringPlaybackSurfaceAbove(host)
        if let visitor, !visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        let visitorControlsCompletion = visitorInstalled && visitorSeconds > estimatedSeconds
        // Foreground visitors are installed after the incoming character host.
        // Re-establish the retained character/reveal directly above the
        // incoming host while leaving foreground visitors above both.
        keepRetiringPlaybackSurfaceAbove(host)
        player = queue
        compositeVideoLayer = videoLayer
        currentAssetID = assetID
        self.pendingBasePoseID = pendingPoseID
        isPlaying = true
        NSLog("SnoopyTVScreenSaver: hardware composition %@ items=%ld loops=%d visitorDuration=%.3f frame=%@",
              assetID, plan.urls.count, plan.loopCount, visitorSeconds, NSStringFromRect(frame))

        // Short BP_To_BP and reaction clips can finish almost completely
        // before an unprimed AVPlayerLayer presents its first drawable. Require
        // both a successful preroll and an actual layer drawable before the
        // old authored surface is atomically exchanged for the new one.
        compositePlaybackGeneration &+= 1
        let generation = compositePlaybackGeneration
        var didBeginPreroll = false
        var didFinishPreroll = false
        var didStart = false
        var abandonIncoming: ((String) -> Void)!
        var startPlaybackIfReady: (() -> Void)!

        abandonIncoming = { [weak self, weak queue, weak host] reason in
            guard let self, let queue, let host, !didStart,
                  self.compositePlaybackGeneration == generation,
                  self.player === queue else { return }
            didStart = true
            self.compositePrerollTimeout?.cancel()
            self.compositePrerollTimeout = nil
            self.compositeVideoReadyObservation = nil
            self.compositeItemStatusObservation = nil
            if let observer = self.playerEndObserver { NotificationCenter.default.removeObserver(observer) }
            if let observer = self.playerFailureObserver { NotificationCenter.default.removeObserver(observer) }
            self.playerEndObserver = nil
            self.playerFailureObserver = nil
            self.compositeVideoPlaceholderLayer?.removeFromSuperlayer()
            self.compositeVideoPlaceholderLayer = nil
            queue.pause()
            host.removeFromSuperview()
            self.compositeVideoLayer?.removeFromSuperlayer()
            self.player = nil
            self.compositeVideoLayer = nil
            self.compositeVideoHostView = nil
            self.currentAssetID = nil
            self.pendingBasePoseID = nil
            self.isPlaying = false
            self.compositePlaybackGeneration &+= 1
            NSLog("SnoopyTVScreenSaver: discarded unready composite %@ (%@); retaining outgoing surface",
                  assetID, reason)
            self.scheduleNext(after: 0.1)
        }

        startPlaybackIfReady = { [weak self, weak queue, weak videoLayer, weak host] in
            guard let self, let queue, let videoLayer, let host, !didStart,
                  didFinishPreroll, videoLayer.isReadyForDisplay, self.isPlaying,
                  self.compositePlaybackGeneration == generation,
                  self.player === queue else { return }
            didStart = true
            self.compositePrerollTimeout?.cancel()
            self.compositePrerollTimeout = nil
            self.compositeVideoReadyObservation = nil
            self.compositeItemStatusObservation = nil
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            host.layer?.opacity = 1
            self.compositeVideoPlaceholderLayer?.removeFromSuperlayer()
            self.compositeVideoPlaceholderLayer = nil
            self.retirePreviousPlaybackSurfaces()
            CATransaction.commit()
            if let characterAnimationKind {
                self.sessionState.recordCharacterAnimation(characterAnimationKind, duration: estimatedSeconds)
            }
            self.installWatchdog(defaultSeconds: max(estimatedSeconds, visitorSeconds) + 3)
            queue.play()
            NSLog("SnoopyTVScreenSaver: composite surface committed %@ time=%.3f",
                  assetID, queue.currentTime().seconds)
        }

        compositeVideoReadyObservation = videoLayer.observe(
            \.isReadyForDisplay, options: [.initial, .new]
        ) { _, _ in
            DispatchQueue.main.async { startPlaybackIfReady() }
        }
        compositeItemStatusObservation = queue.observe(
            \.status, options: [.initial, .new]
        ) { [weak self, weak queue] player, _ in
            DispatchQueue.main.async {
                guard let self, let queue, !didBeginPreroll, !didStart,
                      self.isPlaying, self.compositePlaybackGeneration == generation,
                      self.player === queue else { return }
                switch player.status {
                case .readyToPlay:
                    didBeginPreroll = true
                    queue.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
                    queue.preroll(atRate: 1) { succeeded in
                        DispatchQueue.main.async {
                            if succeeded {
                                didFinishPreroll = true
                                startPlaybackIfReady()
                            } else {
                                abandonIncoming("preroll failed")
                            }
                        }
                    }
                case .failed:
                    abandonIncoming("player failed to become ready")
                default:
                    break
                }
            }
        }
        if let last = items.last {
            playerEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: last, queue: .main
            ) { [weak self, weak queue] _ in
                // Keep currentItem and its final decoded frame attached until
                // the next MOV/HEIC surface has committed in one transaction.
                queue?.pause()
                NSLog("SnoopyTVScreenSaver: composite MOV ended currentItemRetained=%d",
                      queue?.currentItem === last ? 1 : 0)
                if !visitorControlsCompletion {
                    self?.finishCurrentPlayback("phased video ended")
                }
            }
        }
        playerFailureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            guard let failedItem = note.object as? AVPlayerItem,
                  items.contains(where: { $0 === failedItem }) else { return }
            NSLog("SnoopyTVScreenSaver: phased video failed %@", String(describing: note.userInfo))
            if didStart {
                self?.finishCurrentPlayback("phased video failed")
            } else {
                abandonIncoming("video failed before first drawable")
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            guard let self, !didStart, self.isPlaying,
                  self.compositePlaybackGeneration == generation else { return }
            NSLog("SnoopyTVScreenSaver: composite preroll timeout %@", assetID)
            abandonIncoming("drawable/preroll timeout")
        }
        compositePrerollTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: timeout)
        return true
    }

    private func estimatedDuration(of urls: [URL]) -> TimeInterval {
        urls.reduce(0.0) { partial, url in
            let seconds = AVURLAsset(url: url).duration.seconds
            return partial + (seconds.isFinite && seconds > 0 ? seconds : 2)
        }
    }

    private func seamlessVideoItem(for urls: [URL]) -> AVPlayerItem? {
        let composition = AVMutableComposition()
        guard let destination = composition.addMutableTrack(
            withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid
        ) else { return nil }
        var cursor = CMTime.zero
        var copiedTransform = false
        do {
            for url in urls {
                let asset = AVURLAsset(url: url)
                guard let source = asset.tracks(withMediaType: .video).first else { return nil }
                let duration = asset.duration
                guard duration.isValid, CMTimeCompare(duration, .zero) > 0 else { return nil }
                if !copiedTransform {
                    destination.preferredTransform = source.preferredTransform
                    copiedTransform = true
                }
                let trimSeconds = derivedMediaStore?.proxy(for: url)?.leadingDecodeTrim ?? 0
                let sourceStart = CMTime(seconds: trimSeconds, preferredTimescale: 600)
                let sourceDuration = CMTimeSubtract(duration, sourceStart)
                guard sourceDuration.isValid, CMTimeCompare(sourceDuration, .zero) > 0 else { return nil }
                try destination.insertTimeRange(
                    CMTimeRange(start: sourceStart, duration: sourceDuration), of: source, at: cursor
                )
                cursor = CMTimeAdd(cursor, sourceDuration)
            }
        } catch {
            NSLog("SnoopyTVScreenSaver: unable to assemble seamless composite item %@",
                  String(describing: error))
            return nil
        }
        guard CMTimeCompare(cursor, .zero) > 0 else { return nil }
        return AVPlayerItem(asset: composition)
    }

    @discardableResult
    private func installVisitor(_ visitor: VisitorPlaybackPlan, finishesPlayback: Bool) -> Bool {
        guard visitorPlayer == nil else { return false }
        let items = visitor.media.urls.map(AVPlayerItem.init(url:))
        guard !items.isEmpty else { return false }
        let queue = AVQueuePlayer(items: items)
        queue.actionAtItemEnd = .advance
        queue.isMuted = true
        let frame = visitor.isFullscreenEffect
            ? bounds
            : compositeFrame(for: visitor.media.sprite, ignoresSceneOffset: visitor.ignoresSceneOffset)
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        let videoLayer = AVPlayerLayer(player: queue)
        videoLayer.frame = host.bounds
        videoLayer.videoGravity = .resize
        videoLayer.backgroundColor = NSColor.clear.cgColor
        host.layer?.addSublayer(videoLayer)
        if let image = videoPlaceholderImage(at: visitor.media.urls[0]) {
            let placeholder = CALayer()
            placeholder.frame = host.bounds
            placeholder.contents = image
            placeholder.contentsGravity = .resize
            placeholder.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(placeholder)
            visitorPlaceholderLayer = placeholder
            visitorReadyObservation = videoLayer.observe(
                \.isReadyForDisplay, options: [.initial, .new]
            ) { [weak self, weak videoLayer] _, _ in
                guard videoLayer?.isReadyForDisplay == true else { return }
                DispatchQueue.main.async {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    self?.visitorPlaceholderLayer?.removeFromSuperlayer()
                    self?.visitorPlaceholderLayer = nil
                    self?.visitorReadyObservation = nil
                    CATransaction.commit()
                }
            }
        }
        addSubview(host)
        visitorPlayer = queue
        visitorLayer = videoLayer
        visitorHostView = host
        visitorSprite = visitor.media.sprite
        visitorIgnoresSceneOffset = visitor.ignoresSceneOffset || visitor.isFullscreenEffect
        visitorIsFullscreenEffect = visitor.isFullscreenEffect
        if let last = items.last {
            visitorEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime, object: last, queue: .main
            ) { [weak self] _ in
                guard let self else { return }
                if finishesPlayback {
                    self.finishCurrentPlayback("visitor duration completed")
                } else {
                    self.removeVisitorPlayback()
                }
            }
        }
        queue.play()
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"] == nil,
           nextVisitorScheduleIndex < visitorScheduleTimes.count {
            let elapsed = idleSceneStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
            NSLog("SnoopyTVScreenSaver: visitor schedule fired index=%d target=%.1f actual=%.1f",
                  nextVisitorScheduleIndex, visitorScheduleTimes[nextVisitorScheduleIndex], elapsed)
            nextVisitorScheduleIndex += 1
        }
        let planeName = visitor.media.sprite.plane ?? "unknown"
        NSLog("SnoopyTVScreenSaver: visitor %@ items=%ld fullscreen=%d plane=%@",
              visitor.assetID, items.count, visitor.isFullscreenEffect ? 1 : 0, planeName)
        return true
    }

    private func removeVisitorPlayback() {
        if let observer = visitorEndObserver { NotificationCenter.default.removeObserver(observer) }
        visitorEndObserver = nil
        visitorPlayer?.pause()
        visitorPlayer = nil
        visitorReadyObservation = nil
        visitorPlaceholderLayer?.removeFromSuperlayer()
        visitorPlaceholderLayer = nil
        visitorLayer?.removeFromSuperlayer()
        visitorLayer = nil
        visitorHostView?.removeFromSuperview()
        visitorHostView = nil
        visitorSprite = nil
        visitorIgnoresSceneOffset = false
        visitorIsFullscreenEffect = false
    }

    private func installCompositeBackdrop(
        backgroundImage: URL?, backgroundVideo: URL? = nil, backgroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?)
    ) {
        layer?.backgroundColor = palette.background.cgColor
        // CharacterAnimationManager keeps one IdleScene alive while BP/AP/CM
        // foreground animations change. Reuse that exact background tree so
        // a decoder/preroll boundary cannot expose the root black layer.
        if backgroundColorView != nil {
            backgroundColorView?.layer?.backgroundColor = palette.background.cgColor
            return
        }
        let colorView = NSView(frame: bounds)
        colorView.autoresizingMask = [.width, .height]
        colorView.wantsLayer = true
        colorView.layer?.backgroundColor = palette.background.cgColor
        addSubview(colorView)
        backgroundColorView = colorView
        if let overlay = palette.overlay {
            let view = NSView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.wantsLayer = true
            view.layer?.backgroundColor = overlay.cgColor
            addSubview(view)
            overlayView = view
        }
        if let url = halftoneImageURL(), let image = NSImage(contentsOf: url) {
            let view = NSImageView(frame: bounds)
            view.autoresizingMask = [.width, .height]
            view.image = image
            view.imageScaling = .scaleAxesIndependently
            view.alphaValue = 0.1
            addSubview(view)
            halftoneView = view
        }
        self.backgroundSprite = backgroundSprite
        if let backgroundVideo {
            let frame = compositeFrame(for: backgroundSprite)
            let host = NSView(frame: frame)
            host.wantsLayer = true
            let queue = AVQueuePlayer()
            queue.isMuted = true
            let item = AVPlayerItem(url: backgroundVideo)
            let looper = AVPlayerLooper(player: queue, templateItem: item)
            let videoLayer = AVPlayerLayer(player: queue)
            videoLayer.frame = host.bounds
            videoLayer.videoGravity = .resize
            videoLayer.backgroundColor = NSColor.clear.cgColor
            host.layer?.addSublayer(videoLayer)
            if let image = videoPlaceholderImage(at: backgroundVideo) {
                let placeholder = CALayer()
                placeholder.frame = host.bounds
                placeholder.contents = image
                placeholder.contentsGravity = .resize
                placeholder.backgroundColor = NSColor.clear.cgColor
                host.layer?.addSublayer(placeholder)
                backgroundVideoPlaceholderLayer = placeholder
                backgroundVideoReadyObservation = videoLayer.observe(
                    \.isReadyForDisplay, options: [.initial, .new]
                ) { [weak self, weak videoLayer] _, _ in
                    guard videoLayer?.isReadyForDisplay == true else { return }
                    DispatchQueue.main.async {
                        self?.backgroundVideoPlaceholderLayer?.removeFromSuperlayer()
                        self?.backgroundVideoPlaceholderLayer = nil
                        self?.backgroundVideoReadyObservation = nil
                    }
                }
            }
            addSubview(host)
            backgroundVideoHostView = host
            backgroundVideoLayer = videoLayer
            backgroundVideoPlayer = queue
            backgroundVideoLooper = looper
            queue.play()
        }
        if let backgroundImage,
           let cgImage = decodedCGImage(at: backgroundImage, maxPixelSize: maximumPixelSize(for: backgroundSprite)) {
            let view = NSImageView(frame: compositeFrame(for: backgroundSprite))
            view.image = NSImage(cgImage: cgImage, size: view.frame.size)
            view.imageScaling = .scaleAxesIndependently
            addSubview(view)
            backgroundImageView = view
        }
        NSLog("SnoopyTVScreenSaver: composite backdrop image=%d video=%d halftone=%d overlay=%d frame=%@",
              backgroundImage != nil ? 1 : 0, backgroundVideo != nil ? 1 : 0,
              halftoneView != nil ? 1 : 0, palette.overlay != nil ? 1 : 0,
              NSStringFromRect(compositeFrame(for: backgroundSprite)))
    }

    private func playIdleCharacterComposite(from store: AssetStore, context: SelectionContext) -> Bool {
        let eligible = store.eligible(store.playableAssets(), on: context.date)
        var idleAssets = eligible.filter { $0.kind == "idleScene" }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_IDLE_ID"] {
            idleAssets = idleAssets.filter { $0.id == forcedID }
        }
        let idle: AssetRecord
        if let currentID = sessionState.currentIdleSceneID,
           let current = idleAssets.first(where: { $0.id == currentID }) {
            idle = current
        } else {
            guard let selected = sessionChoice(from: idleAssets, pool: "idleScenes", context: context) else { return false }
            idle = selected
            beginIdleScene(selected.id)
            currentPaletteAssetID = nil
        }
        guard let idleDirectory = try? store.url(for: idle) else { return false }
        currentSceneOffset = idle.idleScene?.sceneOffset
        let backgroundSprite = idle.sprites.first
        let backgroundImageURL = firstHEICName(in: idle).map { idleDirectory.appendingPathComponent($0) }
        let backgroundVideoURL = idle.sprites.first(where: { $0.spriteType == "video" })
            .flatMap { videoURL(for: idle, sprite: $0, store: store) }
        guard backgroundImageURL != nil || backgroundVideoURL != nil else { return false }
        idleSceneAnimationCount += 1
        // The numeric prefix is an authoring wave, not a character family.
        // All four base poses are 101 assets while later 102/103/104 idle
        // scenes and actions deliberately reference those same 101_BP states.
        // Prefix-scoping here caused pose teleports on every later scene.
        var posePool = eligible.filter { $0.kind == "characterBasePose" }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_POSE_ID"] {
            posePool = posePool.filter { $0.id == forcedID }
        }
        let pose: AssetRecord
        if let currentID = sessionState.currentBasePoseID,
           let current = posePool.first(where: { $0.id == currentID }) {
            pose = current
        } else {
            guard let selected = sessionChoice(from: posePool, pool: "basePoses", context: context) else { return false }
            pose = selected
            sessionState.currentBasePoseID = selected.id
        }
        let palette = paletteColors(from: store, context: context, idleScene: idle)
        // A queued BP transition/reaction/action must finish against the same
        // idle scene and palette. This mirrors CharacterAnimationManager's
        // pendingAnimationQueue instead of re-randomizing every segment.
        if !pendingCharacterAssetIDs.isEmpty {
            let nextID = pendingCharacterAssetIDs.removeFirst()
            guard let segment = playbackGraph?.assetsByID[nextID] else { return false }
            return playCharacterSegment(segment, idle: idle, currentPose: pose.id,
                                        backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                                        backgroundSprite: backgroundSprite,
                                        palette: palette, store: store, visitor: nil)
        }
        let elapsedInIdleScene = idleSceneStartedAt.map {
            ProcessInfo.processInfo.systemUptime - $0
        } ?? 0
        let forcedVisitor = ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"] != nil
        let visitorIsDue = nextVisitorScheduleIndex < visitorScheduleTimes.count
            && elapsedInIdleScene >= visitorScheduleTimes[nextVisitorScheduleIndex]
        let visitor = (forcedVisitor || visitorIsDue)
            ? visitorPlaybackPlan(for: idle, among: eligible, context: context, store: store)
            : nil
        var coupledContext = context
        if visitor?.isFullscreenEffect == true {
            coupledContext.activeCategories.insert("sceneFullscreenEffectVisitor")
        }

        let forcedCharacterKind = ProcessInfo.processInfo.environment["SNOOPY_FORCE_CHARACTER_KIND"]
        let additionalActions = playbackGraph?.characterActions(
            ofKind: "characterAdditionalPose", for: idle, among: eligible
        ) ?? []
        let moments = playbackGraph?.characterActions(
            ofKind: "characterMoment", for: idle, among: eligible
        ) ?? []
        let requestedActionKind: String?
        if ProcessInfo.processInfo.environment["SNOOPY_FORCE_BASE_POSE_ONLY"] == "1"
            || forcedCharacterKind == "base" {
            requestedActionKind = nil
        } else if forcedCharacterKind == "additional" {
            requestedActionKind = "characterAdditionalPose"
        } else if forcedCharacterKind == "moment" {
            requestedActionKind = "characterMoment"
        } else {
            var available: Set<CharacterAnimationKind> = [.basePose]
            if additionalActions.contains(where: {
                playbackGraph?.animationQueue(currentPoseID: pose.id, target: $0) != nil
            }) {
                available.insert(.additionalPose)
            }
            if moments.contains(where: {
                playbackGraph?.animationQueue(currentPoseID: pose.id, target: $0) != nil
            }) {
                available.insert(.moment)
            }
            switch sessionState.nextCharacterAnimationKind(available: available, seed: seed) {
            case .additionalPose: requestedActionKind = "characterAdditionalPose"
            case .moment: requestedActionKind = "characterMoment"
            default: requestedActionKind = nil
            }
            NSLog("SnoopyTVScreenSaver: character ratios base=%.3f additional=%.3f moment=%.3f next=%@",
                  sessionState.characterRatio(for: .basePose),
                  sessionState.characterRatio(for: .additionalPose),
                  sessionState.characterRatio(for: .moment),
                  requestedActionKind ?? "basePose")
        }
        var allActions: [AssetRecord]
        switch requestedActionKind {
        case "characterAdditionalPose": allActions = additionalActions
        case "characterMoment": allActions = moments
        default: allActions = []
        }
        if let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_CHARACTER_ASSET_ID"] {
            allActions = allActions.filter { $0.id == forcedID }
        }
        let queue = characterAnimationQueue(
            startingAt: pose.id, actions: allActions, context: coupledContext
        )
        if let first = queue.first {
            pendingCharacterAssetIDs = queue.dropFirst().map(\.id)
            return playCharacterSegment(first, idle: idle, currentPose: pose.id,
                                        backgroundImageURL: backgroundImageURL, backgroundVideoURL: backgroundVideoURL,
                                        backgroundSprite: backgroundSprite,
                                        palette: palette, store: store, visitor: visitor)
        }
        if let plan = phasedVideoPlan(for: pose, store: store, repeatOneShot: true) {
            return startVideoComposition(
                assetID: "\(idle.id)+\(pose.id)", backgroundImage: backgroundImageURL,
                backgroundVideo: backgroundVideoURL,
                backgroundSprite: backgroundSprite, plan: plan, palette: palette,
                pendingPoseID: pose.id, visitor: visitor, characterAnimationKind: .basePose
            )
        }
        let frames = phasedFrameURLs(for: pose, store: store, minimumDuration: 0)
        guard !frames.isEmpty else { return false }
        return startFrameComposition(
            assetID: "\(idle.id)+\(pose.id)",
            backgroundImage: backgroundImageURL,
            backgroundVideo: backgroundVideoURL,
            backgroundSprite: backgroundSprite,
            frameURLs: frames,
            foregroundSprite: pose.sprites.first(where: { $0.spriteType == "frameSequence" }),
            palette: palette,
            pendingPoseID: pose.id, visitor: visitor, characterAnimationKind: .basePose
        )
    }

    /// Apple's CharacterAnimationManager chooses a relevant AP/Moment first,
    /// then resolves the current BP to that asset's authored From_BP through
    /// pendingAnimationQueue. Restricting selection to actions that already
    /// started at the current pose made every A node favor the same outgoing
    /// edge and left BP_A_To_BP_B/C assets unused.
    private func characterAnimationQueue(
        startingAt startPoseID: String, actions: [AssetRecord], context: SelectionContext
    ) -> [AssetRecord] {
        guard let graph = playbackGraph else { return [] }
        let reachable = actions.filter {
            graph.animationQueue(currentPoseID: startPoseID, target: $0) != nil
        }
        guard let target = sessionChoice(
            from: reachable, pool: "characterActions", context: context
        ), let queue = graph.animationQueue(currentPoseID: startPoseID, target: target) else {
            return []
        }
        NSLog("SnoopyTVScreenSaver: character queue %@",
              queue.map { "\($0.id)[\($0.startCharacterBasePoseID ?? "?")->\($0.endCharacterBasePoseID ?? "?")]" }
                .joined(separator: " -> "))
        return queue
    }

    private func playCharacterSegment(
        _ asset: AssetRecord, idle: AssetRecord, currentPose: String,
        backgroundImageURL: URL?, backgroundVideoURL: URL?, backgroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?), store: AssetStore,
        visitor: VisitorPlaybackPlan?
    ) -> Bool {
        let endPose: String
        if asset.kind == "characterReactionTransitionPose", asset.phase?.kind == "exit" {
            endPose = asset.phase?.endCharacterPoseID ?? currentPose
        } else {
            endPose = normalizedEndPoseID(for: asset) ?? currentPose
        }
        let animationKind: CharacterAnimationKind?
        switch asset.kind {
        case "characterAdditionalPose": animationKind = .additionalPose
        case "characterMoment": animationKind = .moment
        case "characterBasePose": animationKind = .basePose
        default: animationKind = nil
        }
        if let plan = phasedVideoPlan(for: asset, store: store) {
            if asset.kind == "characterReactionTransitionPose",
               asset.phase?.kind == "exit",
               let basePose = playbackGraph?.assetsByID[endPose],
               basePose.kind == "characterBasePose",
               let basePlan = phasedVideoPlan(for: basePose, store: store, repeatOneShot: true) {
                // tvOS exits the Reveal reaction hold into the selected BP
                // loop. Keep RPH_To_BP and that loop in one AVPlayerItem so
                // the sequence is Reveal -> transition -> Loop, never
                // transition -> a separately-mounted Intro/first-frame host.
                let combined = PhasedVideoPlan(
                    urls: plan.urls + basePlan.urls,
                    sprite: plan.sprite,
                    loopCount: plan.loopCount + basePlan.loopCount
                )
                let started = startVideoComposition(
                    assetID: "\(idle.id)+\(asset.id)+\(basePose.id)",
                    backgroundImage: backgroundImageURL,
                    backgroundVideo: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, plan: combined,
                    palette: palette, pendingPoseID: endPose, visitor: visitor
                )
                if started {
                    sessionState.recordCharacterAnimation(
                        .basePose, duration: estimatedDuration(of: basePlan.urls)
                    )
                }
                return started
            }
            if let animationKind, animationKind != .basePose,
               let basePose = playbackGraph?.assetsByID[endPose],
               basePose.kind == "characterBasePose",
               let basePlan = phasedVideoPlan(for: basePose, store: store, repeatOneShot: true) {
                // Apple queues a BP immediately after every AP/Moment. Keep
                // both in one seamless player timeline so a short action never
                // becomes a standalone 1–2 second "scene" or teardown gap.
                let combined = PhasedVideoPlan(
                    urls: plan.urls + basePlan.urls,
                    sprite: plan.sprite,
                    loopCount: plan.loopCount + basePlan.loopCount
                )
                let started = startVideoComposition(
                    assetID: "\(idle.id)+\(asset.id)+\(basePose.id)",
                    backgroundImage: backgroundImageURL,
                    backgroundVideo: backgroundVideoURL,
                    backgroundSprite: backgroundSprite, plan: combined,
                    palette: palette, pendingPoseID: endPose, visitor: visitor
                )
                if started {
                    sessionState.recordCharacterAnimation(
                        animationKind, duration: estimatedDuration(of: plan.urls)
                    )
                    sessionState.recordCharacterAnimation(
                        .basePose, duration: estimatedDuration(of: basePlan.urls)
                    )
                }
                return started
            }
            return startVideoComposition(
                assetID: "\(idle.id)+\(asset.id)", backgroundImage: backgroundImageURL,
                backgroundVideo: backgroundVideoURL,
                backgroundSprite: backgroundSprite, plan: plan, palette: palette,
                pendingPoseID: endPose, visitor: visitor,
                characterAnimationKind: animationKind
            )
        }
        var fallbackFrames = phasedFrameURLs(for: asset, store: store, minimumDuration: 0)
        guard !fallbackFrames.isEmpty else { return false }
        var appendedBaseFrameCount = 0
        if let animationKind, animationKind != .basePose,
           let basePose = playbackGraph?.assetsByID[endPose] {
            let baseFrames = phasedFrameURLs(for: basePose, store: store, minimumDuration: 0)
            if !baseFrames.isEmpty {
                let repeats = max(1, Int(ceil(8.0 / (Double(baseFrames.count) / 24.0))))
                for _ in 0..<repeats { fallbackFrames.append(contentsOf: baseFrames) }
                appendedBaseFrameCount = baseFrames.count * repeats
            }
        }
        NSLog("SnoopyTVScreenSaver: proxy missing for %@; falling back to HEIC (%ld frames)",
              asset.id, fallbackFrames.count)
        let started = startFrameComposition(
            assetID: "\(idle.id)+\(asset.id)", backgroundImage: backgroundImageURL,
            backgroundVideo: backgroundVideoURL, backgroundSprite: backgroundSprite,
            frameURLs: fallbackFrames,
            foregroundSprite: asset.sprites.first(where: { $0.spriteType == "frameSequence" }),
            palette: palette, pendingPoseID: endPose,
            visitor: visitor,
            characterAnimationKind: appendedBaseFrameCount == 0 ? animationKind : nil
        )
        if started, let animationKind, appendedBaseFrameCount > 0 {
            sessionState.recordCharacterAnimation(
                animationKind,
                duration: Double(fallbackFrames.count - appendedBaseFrameCount) / 24.0
            )
            sessionState.recordCharacterAnimation(
                .basePose, duration: Double(appendedBaseFrameCount) / 24.0
            )
        }
        return started
    }

    private func visitorPlaybackPlan(
        for idle: AssetRecord, among assets: [AssetRecord],
        context: SelectionContext, store: AssetStore
    ) -> VisitorPlaybackPlan? {
        // VI/WE prefixes are production waves. Cross-wave IDs appear in the
        // official idle-scene exclusion lists, proving the pool is global.
        var candidates = playbackGraph?.visitors(for: idle, among: assets) ?? []
        let forcedID = ProcessInfo.processInfo.environment["SNOOPY_FORCE_VISITOR_ID"]
        if let forcedID { candidates = candidates.filter { $0.id == forcedID } }
        let selected = forcedID == nil
            ? sessionChoice(from: candidates, pool: "visitors", context: context)
            : candidates.first
        guard let asset = selected,
              let media = phasedVideoPlan(for: asset, store: store, visitorLoop: true) else { return nil }
        let plane = media.sprite.plane ?? "foregroundVisitor"
        return VisitorPlaybackPlan(
            assetID: asset.id, media: media,
            ignoresSceneOffset: asset.visitor?.ignoresSceneOffset ?? false,
            isFullscreenEffect: asset.visitor?.isFullscreenEffect ?? false,
            isBackgroundPlane: plane.hasPrefix("background")
        )
    }

    private func normalizedStartPoseID(for asset: AssetRecord) -> String? {
        asset.startCharacterBasePoseID ?? poseID(in: asset, after: "From_")
    }

    private func normalizedEndPoseID(for asset: AssetRecord) -> String? {
        asset.endCharacterBasePoseID ?? poseID(in: asset, after: "To_")
    }

    private func poseID(in asset: AssetRecord, after marker: String) -> String? {
        let candidates = [asset.id] + asset.sprites.compactMap(\.assetBaseName)
        for candidate in candidates {
            guard let range = candidate.range(of: marker, options: .caseInsensitive) else { continue }
            let suffix = candidate[range.upperBound...]
            let token = suffix.split(separator: "_").first.map(String.init) ?? ""
            guard token.hasPrefix("BP") else { continue }
            return "\(asset.id.prefix(3))_\(token)"
        }
        return nil
    }

    private func phasedFrameURLs(for asset: AssetRecord, store: AssetStore, minimumDuration: TimeInterval) -> [URL] {
        guard let directory = try? store.url(for: asset) else { return [] }
        let phaseRank: (SpriteRecord) -> Int = { sprite in
            let path = sprite.contentPath ?? sprite.metadataPath ?? ""
            if path.localizedCaseInsensitiveContains("intro") { return 0 }
            if path.localizedCaseInsensitiveContains("loop") { return 1 }
            if path.localizedCaseInsensitiveContains("outro") { return 2 }
            return 1
        }
        var intro: [URL] = []
        var loop: [URL] = []
        var outro: [URL] = []
        for sprite in asset.sprites.filter({ $0.spriteType == "frameSequence" }).sorted(by: { phaseRank($0) < phaseRank($1) }) {
            guard let base = sprite.assetBaseName else { continue }
            let indexedNames = (asset.media ?? []).compactMap(\.name)
            let names = indexedNames.isEmpty ? (sprite.mediaFiles ?? []) : indexedNames
            let urls = names
                .filter { $0.hasPrefix(base) && ["heic", "png", "jpg"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
                .sorted { naturalFrameNumber($0) < naturalFrameNumber($1) }
                .map { directory.appendingPathComponent($0) }
            switch phaseRank(sprite) {
            case 0: intro.append(contentsOf: urls)
            case 2: outro.append(contentsOf: urls)
            default: loop.append(contentsOf: urls)
            }
        }
        if loop.isEmpty { loop = intro.isEmpty ? outro : intro }
        var result = intro
        result.append(contentsOf: loop)
        // `minimumDuration` is retained for source compatibility with older
        // callers, but OneShotSprites must preserve the authored frame list
        // exactly. Repeating frames here changes the metadata state machine.
        _ = minimumDuration
        result.append(contentsOf: outro)
        if let testSeconds = ProcessInfo.processInfo.environment["SNOOPY_TEST_SEGMENT_SECONDS"].flatMap(Double.init) {
            return Array(result.prefix(max(1, Int(testSeconds * 24))))
        }
        return result
    }

    private func firstHEICName(in asset: AssetRecord) -> String? {
        if let name = asset.media?.first(where: { $0.suffix == ".heic" })?.name { return name }
        return asset.sprites.lazy.flatMap { $0.mediaFiles ?? [] }.first {
            URL(fileURLWithPath: $0).pathExtension.lowercased() == "heic"
        }
    }

    private func startFrameComposition(
        assetID: String,
        backgroundImage: URL?,
        backgroundVideo: URL? = nil,
        backgroundSprite: SpriteRecord?,
        frameURLs: [URL],
        foregroundSprite: SpriteRecord?,
        palette: (background: NSColor, overlay: NSColor?),
        pendingPoseID: String? = nil,
        visitor: VisitorPlaybackPlan? = nil,
        characterAnimationKind: CharacterAnimationKind? = nil
    ) -> Bool {
        guard !frameURLs.isEmpty else { return false }
        let estimatedSeconds = TimeInterval(frameURLs.count) / 24.0
        let visitorSeconds = visitor.map { estimatedDuration(of: $0.media.urls) } ?? 0
        var visitorInstalled = false
        installCompositeBackdrop(backgroundImage: backgroundImage, backgroundVideo: backgroundVideo,
                                 backgroundSprite: backgroundSprite, palette: palette)
        if let visitor, visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        self.foregroundSprite = foregroundSprite
        let sequenceView = NSImageView(frame: compositeFrame(for: foregroundSprite))
        sequenceView.wantsLayer = true
        sequenceView.layer?.contentsGravity = .resize
        let isReplacingRetainedSurface = hasRetiringPlaybackSurface
        sequenceView.layer?.opacity = isReplacingRetainedSurface ? 0.001 : 1
        addSubview(sequenceView)
        keepRetiringPlaybackSurfaceAbove(sequenceView)
        if let visitor, !visitor.isBackgroundPlane {
            visitorInstalled = installVisitor(visitor, finishesPlayback: visitorSeconds > estimatedSeconds)
        }
        let visitorControlsCompletion = visitorInstalled && visitorSeconds > estimatedSeconds
        keepRetiringPlaybackSurfaceAbove(sequenceView)
        frameView = sequenceView
        currentAssetID = assetID
        pendingBasePoseID = pendingPoseID
        isPlaying = true
        let backgroundFrame = compositeFrame(for: backgroundSprite)
        let foregroundFrame = compositeFrame(for: foregroundSprite)
        NSLog("SnoopyTVScreenSaver: composite %@ (%ld frames) background=%@ foreground=%@",
              assetID, frameURLs.count, NSStringFromRect(backgroundFrame), NSStringFromRect(foregroundFrame))
        NSLog("SnoopyTVScreenSaver: palette %@ overlay=%@", palette.background.description,
              palette.overlay?.description ?? "none")

        frameGeneration &+= 1
        let generation = frameGeneration
        let maxPixelSize = maximumPixelSize(for: foregroundSprite)
        // Decode only a tiny startup buffer synchronously. A single worker
        // stays ahead after that, avoiding bursty CPU and memory pressure.
        for url in Array(frameURLs.prefix(12)) {
            cacheDecodedImage(at: url, maxPixelSize: maxPixelSize)
        }
        guard let firstFrame = cachedImage(for: frameURLs[0])
            ?? decodedCGImage(at: frameURLs[0], maxPixelSize: maxPixelSize) else {
            sequenceView.removeFromSuperview()
            frameView = nil
            currentAssetID = nil
            pendingBasePoseID = nil
            isPlaying = false
            NSLog("SnoopyTVScreenSaver: discarded undecodable HEIC composite %@; retaining outgoing surface",
                  assetID)
            return false
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sequenceView.layer?.contents = firstFrame
        sequenceView.layer?.opacity = 1
        retirePreviousPlaybackSurfaces()
        CATransaction.commit()
        if let characterAnimationKind {
            sessionState.recordCharacterAnimation(
                characterAnimationKind, duration: TimeInterval(frameURLs.count) / 24.0
            )
        }
        preloadFrames(frameURLs, from: 0, count: 32, generation: generation, maxPixelSize: maxPixelSize)

        let startTime = ProcessInfo.processInfo.systemUptime
        var lastDisplayedIndex = 0
        var missedFrameTicks = 0
        let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self, weak sequenceView] timer in
            guard let self, let sequenceView, self.isPlaying, self.frameGeneration == generation else {
                timer.invalidate()
                return
            }
            let elapsed = ProcessInfo.processInfo.systemUptime - startTime
            let desiredIndex = Int(elapsed * 24.0)
            guard desiredIndex < frameURLs.count else {
                timer.invalidate()
                if !visitorControlsCompletion {
                    self.finishCurrentPlayback("composite ended; decodeMisses=\(missedFrameTicks)")
                }
                return
            }
            if desiredIndex != lastDisplayedIndex {
                if let image = self.cachedImage(for: frameURLs[desiredIndex]) {
                    sequenceView.layer?.contents = image
                    lastDisplayedIndex = desiredIndex
                    self.preloadFrames(frameURLs, from: desiredIndex + 1, count: 32,
                                       generation: generation, maxPixelSize: maxPixelSize)
                } else {
                    missedFrameTicks += 1
                    self.requestDecodedImage(at: frameURLs[desiredIndex], generation: generation, maxPixelSize: maxPixelSize)
                }
            }
        }
        timer.tolerance = 0.004
        frameTimer = timer
        RunLoop.main.add(timer, forMode: .common)
        installWatchdog(defaultSeconds: max(15, estimatedSeconds, visitorSeconds) + 3)
        return true
    }

    private func maximumPixelSize(for sprite: SpriteRecord?) -> Int {
        let frame = SpritePlacementResolver.frame(for: sprite, in: bounds)
        let displaySize = Int(ceil(max(frame.size.width, frame.size.height)))
        // 1440 px preserves the line-art detail on desktop displays while
        // avoiding the steep HEIC decode cost of a new 1920 px image 24 times
        // per second. CALayer performs the final display-size stretch.
        return max(1, min(sprite?.assetSize?.max() ?? 1920, displaySize, 1440))
    }

    private func compositeFrame(for sprite: SpriteRecord?, ignoresSceneOffset: Bool = false) -> CGRect {
        SpritePlacementResolver.frame(
            for: sprite, in: bounds, sceneOffset: currentSceneOffset,
            ignoresSceneOffset: ignoresSceneOffset
        )
    }

    private func activeVideoFrame(for sprite: SpriteRecord?) -> CGRect {
        let values = sprite?.assetSize ?? [1920, 1080]
        let size = values.count >= 2
            ? CGSize(width: values[0], height: values[1])
            : SpritePlacementResolver.designViewport
        return SpritePlacementResolver.aspectFillFrame(contentSize: size, in: bounds)
    }

    private func videoPlaceholderImage(at url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.08, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.08, preferredTimescale: 600)
        return try? generator.copyCGImage(
            at: CMTime(seconds: 0.04, preferredTimescale: 600), actualTime: nil
        )
    }

    private func cachedImage(for url: URL) -> CGImage? {
        decodedFrameCache.object(forKey: url.path as NSString)
    }

    private func cacheDecodedImage(at url: URL, maxPixelSize: Int) {
        guard cachedImage(for: url) == nil,
              let image = decodedCGImage(at: url, maxPixelSize: maxPixelSize) else { return }
        let cost = image.bytesPerRow * image.height
        decodedFrameCache.setObject(image, forKey: url.path as NSString, cost: cost)
    }

    private func requestDecodedImage(at url: URL, generation: UInt64, maxPixelSize: Int) {
        let key = url.path
        guard cachedImage(for: url) == nil else { return }
        frameDecodeLock.lock()
        let inserted = pendingFrameKeys.insert(key).inserted
        frameDecodeLock.unlock()
        guard inserted else { return }
        frameDecodeQueue.addOperation { [weak self] in
            guard let self else { return }
            defer {
                self.frameDecodeLock.lock()
                self.pendingFrameKeys.remove(key)
                self.frameDecodeLock.unlock()
            }
            guard self.frameGeneration == generation else { return }
            autoreleasepool {
                self.cacheDecodedImage(at: url, maxPixelSize: maxPixelSize)
            }
        }
    }

    private func preloadFrames(_ urls: [URL], from start: Int, count: Int, generation: UInt64, maxPixelSize: Int) {
        guard start < urls.count else { return }
        let end = min(urls.count, start + count)
        var seen = Set<String>()
        for url in urls[start..<end] where seen.insert(url.path).inserted {
            requestDecodedImage(at: url, generation: generation, maxPixelSize: maxPixelSize)
        }
    }

    private func decodedCGImage(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func paletteColors(
        from store: AssetStore, context: SelectionContext, idleScene: AssetRecord? = nil
    ) -> (background: NSColor, overlay: NSColor?) {
        var palettes = store.eligible(store.index.assets, on: context.date).filter { $0.kind == "scenePalette" }
        if let idleScene {
            let related = palettes.filter { $0.scenePalette?.parentIdleSceneIDs?.contains(idleScene.id) == true }
            if !related.isEmpty { palettes = related }
            let excluded = Set(idleScene.idleScene?.exclusions?.excludedPalettes ?? [])
            palettes.removeAll { excluded.contains($0.id) }
        }
        let asset: AssetRecord?
        if idleScene != nil, let currentPaletteAssetID,
           let current = palettes.first(where: { $0.id == currentPaletteAssetID }) {
            asset = current
        } else {
            asset = sessionChoice(from: palettes, pool: "palettes", context: context)
            if idleScene != nil { currentPaletteAssetID = asset?.id }
        }
        guard let asset else {
            return (NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1), nil)
        }
        if let palette = asset.scenePalette {
            return (
                palette.backgroundColor.map(color(from:))
                    ?? NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1),
                palette.overlayColor.map(color(from:))
            )
        }
        guard let directory = try? store.url(for: asset),
              let data = try? Data(contentsOf: directory.appendingPathComponent("metadata.icmetadata")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let node = (plist["scenePalette"] as? [String: Any])?["_0"] as? [String: Any] else {
            return (NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1), nil)
        }
        return (
            color(from: node["backgroundColor"] as? [String: Any], defaultAlpha: 1)
                ?? NSColor(calibratedRed: 0.98, green: 0.72, blue: 0.37, alpha: 1),
            color(from: node["overlayColor"] as? [String: Any], defaultAlpha: 0.25)
        )
    }

    private func color(from record: ColorRecord) -> NSColor {
        NSColor(calibratedRed: record.red / 255, green: record.green / 255,
                blue: record.blue / 255, alpha: record.alpha)
    }

    private func color(from dictionary: [String: Any]?, defaultAlpha: CGFloat) -> NSColor? {
        guard let dictionary,
              let red = (dictionary["red"] as? NSNumber)?.doubleValue,
              let green = (dictionary["green"] as? NSNumber)?.doubleValue,
              let blue = (dictionary["blue"] as? NSNumber)?.doubleValue else { return nil }
        let alpha = (dictionary["alpha"] as? NSNumber)?.doubleValue ?? Double(defaultAlpha)
        return NSColor(calibratedRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
    }

    private func naturalFrameNumber(_ name: String) -> Int {
        let stem = URL(fileURLWithPath: name).deletingPathExtension().lastPathComponent
        let digits = stem.reversed().prefix { $0.isNumber }.reversed()
        return Int(String(digits)) ?? 0
    }

    private func currentTimeOfDay() -> String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 6..<12: return "morning"
        case 12..<18: return "afternoon"
        case 18..<23: return "evening"
        default: return "lateNight"
        }
    }

    private func loadSelectionMemory() {
        guard let data = SnoopyPreferences.defaults.data(forKey: SnoopyPreferences.selectionMemoryKey),
              let decoded = try? JSONDecoder().decode(SelectionMemory.self, from: data) else { return }
        memory = decoded
    }

    private func saveSelectionMemory() {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        SnoopyPreferences.defaults.set(data, forKey: SnoopyPreferences.selectionMemoryKey)
    }

    override func layout() {
        super.layout()
        playerLayer?.frame = activeVideoFrame(for: foregroundSprite)
        activeVideoPlaceholderLayer?.frame = activeVideoFrame(for: foregroundSprite)
        activeHalftoneLayer?.frame = bounds
        backgroundColorView?.frame = bounds
        halftoneView?.frame = bounds
        backgroundImageView?.frame = compositeFrame(for: backgroundSprite)
        if let host = backgroundVideoHostView {
            host.frame = compositeFrame(for: backgroundSprite)
            backgroundVideoLayer?.frame = host.bounds
        }
        overlayView?.frame = bounds
        frameView?.frame = compositeFrame(for: foregroundSprite)
        if let host = compositeVideoHostView {
            host.frame = compositeFrame(for: foregroundSprite)
            compositeVideoLayer?.frame = host.bounds
        }
        if let host = visitorHostView {
            host.frame = visitorIsFullscreenEffect
                ? bounds
                : compositeFrame(for: visitorSprite, ignoresSceneOffset: visitorIgnoresSceneOffset)
            visitorLayer?.frame = host.bounds
            visitorPlaceholderLayer?.frame = host.bounds
        }
        transitionHostView?.frame = bounds
    }
}
