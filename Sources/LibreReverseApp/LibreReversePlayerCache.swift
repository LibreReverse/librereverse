#if os(macOS)
import AVFoundation
import AppKit
import LibreReverseCore

struct LibreReversePreparedPersistedMedia: @unchecked Sendable {
    let frameImage: NSImage?
    let playbackURL: URL?
    let playbackPreparationError: Error?
}

/// Loads persisted frame images and resolves media away from the UI actor.
/// Frame images remain available as fallbacks when video is unavailable.
actor LibreReversePersistedMediaLoader {
    private var resolver: (any LocalMediaResolving)?

    init(resolver: (any LocalMediaResolving)? = nil) {
        self.resolver = resolver
    }

    func setResolver(_ resolver: (any LocalMediaResolving)?) {
        self.resolver = resolver
    }

    func prepare(moment: HistoricalTimelineMoment) async -> LibreReversePreparedPersistedMedia {
        let image = (try? Data(contentsOf: moment.frameImageURL)).flatMap(NSImage.init(data:))
        var playbackURL = moment.chunkURL
        let playbackError: Error? = nil
        if let candidate = playbackURL,
            !FileManager.default.fileExists(atPath: candidate.path)
        {
            playbackURL = nil
        }
        return LibreReversePreparedPersistedMedia(
            frameImage: image,
            playbackURL: playbackURL,
            playbackPreparationError: playbackError
        )
    }

    /// Prefer the independently persisted image. Otherwise decode the canonical
    /// MP4 at the exact sample time, without blocking the loader actor.
    func searchFrame(moment: HistoricalTimelineMoment) async -> NSImage? {
        if let image = (try? Data(contentsOf: moment.frameImageURL)).flatMap(NSImage.init(data:)) {
            return image
        }
        guard let url = moment.chunkURL,
            FileManager.default.fileExists(atPath: url.path),
            let mediaTime = moment.mediaTime
        else { return nil }
        let asset = AVURLAsset(
            url: url,
            options: [
                "AVURLAssetOutOfBandMIMETypeKey": "video/mp4"
            ]
        )
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let scale = max(1, Int32(moment.videoFrameRate?.rounded() ?? 600))
        let time = CMTime(seconds: mediaTime, preferredTimescale: scale)
        guard let generated = try? await generator.image(at: time) else {
            return nil
        }
        return NSImage(cgImage: generated.image, size: .zero)
    }

    func restoreArchivedMoment(
        for moment: HistoricalTimelineMoment,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        guard let videoID = moment.databaseVideoID, let resolver else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(
                moment.databaseVideoID ?? -1
            )
        }
        return try await resolver.restoreMoment(videoID: videoID, progress: progress)
    }

    func restoreArchivedHour(
        for moment: HistoricalTimelineMoment,
        progress: @escaping @Sendable (LibreReverseDayRestoreProgress) async -> Void
    ) async throws -> URL {
        guard let videoID = moment.databaseVideoID, let resolver else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(
                moment.databaseVideoID ?? -1
            )
        }
        return try await resolver.restoreDay(
            containing: moment.wallDate,
            selectedVideoID: videoID,
            progress: progress
        )
    }

    /// Installs only the recording under the cursor. The UI can reveal it as
    /// soon as this returns while the remainder of its hour keeps restoring.
    func restoreArchivedSelection(for moment: HistoricalTimelineMoment) async throws -> URL {
        guard let videoID = moment.databaseVideoID, let resolver else {
            throw LibreReverseLocalMediaResolverError.remoteMediaUnavailable(
                moment.databaseVideoID ?? -1
            )
        }
        return try await resolver.resolve(videoID: videoID)
    }
}

private final class LibreReverseReadyWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var stopObserving: (() -> Void)?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func installCleanup(_ stopObserving: @escaping () -> Void) {
        lock.lock()
        if result != nil {
            lock.unlock()
            stopObserving()
        } else {
            self.stopObserving = stopObserving
            lock.unlock()
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = self.continuation
        let stopObserving = self.stopObserving
        self.continuation = nil
        self.stopObserving = nil
        lock.unlock()
        stopObserving?()
        continuation?.resume(returning: value)
    }
}

/// Registration must deliver the initial status as well as later changes.
/// A synchronous initial callback is safe, including before cleanup is installed.
@MainActor
enum LibreReverseItemReadiness {
    static func wait(
        timeout: Duration = .seconds(10),
        observe: (@escaping @Sendable (AVPlayerItem.Status) -> Void) -> (() -> Void)
    ) async -> Bool {
        let state = LibreReverseReadyWaitState()
        let deadline = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            state.resolve(false)
        }
        defer { deadline.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                let cleanup = observe { status in
                    switch status {
                    case .readyToPlay: state.resolve(true)
                    case .failed: state.resolve(false)
                    case .unknown: break
                    @unknown default: state.resolve(false)
                    }
                }
                state.installCleanup(cleanup)
                if Task.isCancelled { state.resolve(false) }
            }
        } onCancel: {
            state.resolve(false)
        }
    }
}

private final class LibreReverseSeekWaitState: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var result: Bool?

    func install(_ continuation: CheckedContinuation<Bool, Never>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(returning: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ value: Bool) {
        lock.lock()
        guard result == nil else {
            lock.unlock()
            return
        }
        result = value
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: value)
    }
}

/// Caches a bounded set of players by chunk URL. Each item owns one reusable
/// video output; the incoming item must become ready before layer transition
/// so the outgoing layer can retain its last decoded frame during preparation.
@MainActor
final class LibreReversePlayerCache {
    var onEvict: ((URL) -> Void)?
    private struct CachedPlayer {
        let url: URL
        let player: AVPlayer
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput
    }

    struct CurrentPlayerSelection {
        let player: AVPlayer
        let item: AVPlayerItem
        let output: AVPlayerItemVideoOutput?
        let requiresLayerTransition: Bool
    }

    /// Full-range bi-planar output used by the video surface.
    static let pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange

    /// Supply the MP4 type for canonical extensionless chunk names.
    static let outOfBandMIMETypeKey = "AVURLAssetOutOfBandMIMETypeKey"
    static let outOfBandMIMEType = "video/mp4"

    private var entries: [PlayerCache.Entry<URL>] = []
    private var cached: [URL: CachedPlayer] = [:]
    private var currentPlayerURL: URL?
    private var selectionGeneration: UInt64 = 0
    private let readiness: @MainActor (AVPlayerItem) async -> Bool

    init(readiness: @escaping @MainActor (AVPlayerItem) async -> Bool = { item in
        await LibreReverseItemReadiness.wait { receive in
            let observation = item.observe(\.status, options: [.initial, .new]) { item, _ in
                receive(item.status)
            }
            return { observation.invalidate() }
        }
    }) {
        self.readiness = readiness
    }

    /// Number of retained players. Test and diagnostic surface only.
    var retainedCount: Int { cached.count }

    /// Returns a player for `url`, reusing a retained one when present.
    ///
    /// - Returns: the player, and whether it had to be created.
    func player(for url: URL, now: Date = Date()) -> (player: AVPlayer, created: Bool) {
        let outcome = PlayerCache.access(entries, key: url, at: now)
        entries = outcome.entries
        if let existing = cached[url] {
            return (existing.player, false)
        }
        let recycled = outcome.evicted.compactMap { url -> CachedPlayer? in
            let value = cached.removeValue(forKey: url)
            if value != nil {
                if currentPlayerURL == url { currentPlayerURL = nil }
                onEvict?(url)
            }
            return value
        }.first
        let asset = AVURLAsset(
            url: url,
            options: [Self.outOfBandMIMETypeKey: Self.outOfBandMIMEType]
        )
        let item = AVPlayerItem(asset: asset)
        let player: AVPlayer
        if let recycled {
            // Replacing the item reuses the bounded player allocation when
            // crossing into a chunk outside the current LRU set.
            player = recycled.player
            player.replaceCurrentItem(with: item)
        } else {
            player = AVPlayer(playerItem: item)
        }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Self.pixelFormat
        ])
        item.add(output)
        cached[url] = CachedPlayer(url: url, player: player, item: item, output: output)
        return (player, true)
    }

    /// Readiness belongs to the exact item, including when an LRU player is recycled.
    /// Each cached item owns one video output across all repeat selections.
    func setCurrentPlayer(for url: URL) async -> CurrentPlayerSelection? {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        guard let cachedPlayer = cached[url] else { return nil }
        guard await readiness(cachedPlayer.item), !Task.isCancelled else {
            if !Task.isCancelled, cachedPlayer.item.status == .failed {
                invalidate(cachedPlayer.item)
            }
            return nil
        }
        guard generation == selectionGeneration,
              cached[url]?.item === cachedPlayer.item,
              cachedPlayer.player.currentItem === cachedPlayer.item else { return nil }
        let changed = currentPlayerURL != url
        currentPlayerURL = url
        return CurrentPlayerSelection(
            player: cachedPlayer.player,
            item: cachedPlayer.item,
            output: changed ? cachedPlayer.output : nil,
            requiresLayerTransition: changed
        )
    }

    func ensureReady(_ player: AVPlayer) async -> Bool {
        guard let item = player.currentItem else { return false }
        let ready = await readiness(item)
        return ready && !Task.isCancelled && player.currentItem === item
    }

    /// Seeks with cancellation scoped to the awaiting task.
    ///
    /// Cancellation releases the awaiting task but deliberately does not call
    /// `cancelPendingSeeks()`: a replacement seek can target the same cached
    /// player, and cancelling the AVPlayer globally would race that newer work.
    func seek(
        _ player: AVPlayer,
        to target: CMTime,
        tolerance: CMTime
    ) async -> Bool {
        if CMTimeCompare(player.currentTime(), target) == 0 { return true }
        let state = LibreReverseSeekWaitState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                state.install(continuation)
                player.seek(
                    to: target,
                    toleranceBefore: tolerance,
                    toleranceAfter: tolerance
                ) { finished in
                    state.resolve(finished)
                }
                if Task.isCancelled { state.resolve(false) }
            }
        } onCancel: {
            state.resolve(false)
        }
    }

    /// Evicts exactly the cache record that still owns `item`.
    ///
    /// AVPlayers are normally recycled at the five-item LRU bound,
    /// but a terminally failed item must not be reused on the next selection.
    /// Item identity prevents a late callback from evicting a recycled player
    /// that already owns newer media.
    @discardableResult
    func invalidate(_ item: AVPlayerItem) -> URL? {
        guard
            let entry = cached.first(where: { $0.value.item === item })
        else { return nil }
        invalidate(entry.key)
        return entry.key
    }

    /// URL-scoped companion used when readiness fails before an item can be
    /// published to the presentation controller.
    @discardableResult
    func invalidate(_ url: URL) -> Bool {
        guard let cachedPlayer = cached.removeValue(forKey: url) else { return false }
        cachedPlayer.player.pause()
        cachedPlayer.player.replaceCurrentItem(with: nil)
        entries = PlayerCache.removing(url, from: entries)
        if currentPlayerURL == url { currentPlayerURL = nil }
        onEvict?(url)
        return true
    }

    /// Removes every retained player. Used when the explorer is torn down.
    func removeAll() {
        selectionGeneration &+= 1
        for entry in cached.values {
            entry.player.pause()
            entry.player.replaceCurrentItem(with: nil)
            onEvict?(entry.url)
        }
        cached.removeAll()
        entries.removeAll()
        currentPlayerURL = nil
    }
}

/// Hosts `AVPlayerLayer`s and transitions between them.
///
/// Each player gets its own layer. The outgoing layer remains visible until
/// the incoming layer is installed, preventing blank frames at boundaries.
@MainActor
final class LibreReversePlayerLayerView: NSView {
    final class PreparedPresentation {
        fileprivate let host: NSView
        fileprivate let player: AVPlayer
        fileprivate let outgoing: [NSView]

        fileprivate init(
            host: NSView,
            player: AVPlayer,
            outgoing: [NSView]
        ) {
            self.host = host
            self.player = player
            self.outgoing = outgoing
        }
    }

    var videoGravity: AVLayerVideoGravity = .resizeAspect {
        didSet { currentLayer?.videoGravity = videoGravity }
    }

    private var currentHost: NSView?
    private var currentLayer: AVPlayerLayer?
    private var pendingPresentation: PreparedPresentation?
    private var readinessObservation: NSKeyValueObservation?
    private var seekCompletedPresentation: PreparedPresentation?
    #if DEBUG
    var interactionTestReadyForDisplay: Bool?
    var interactionTestVisibleSurfaceCount: Int {
        subviews.filter { $0 !== brandBackgroundView && $0.alphaValue > 0 }.count
    }
    func interactionTestPublishReadySurface() { publishReadyPresentationIfPossible() }
    #endif
    private let brandBackgroundView = LibreReverseBrandVibrancyBackgroundView(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.cornerRadius = CGFloat(
            BrandVibrancyBackgroundContract.frameDetailCornerRadius
        )
        layer?.cornerCurve = .continuous
        layer?.borderWidth = CGFloat(BrandVibrancyBackgroundContract.strokeWidth)
        layer?.borderColor =
            NSColor(
                srgbRed: CGFloat(BrandVibrancyBackgroundContract.brandBlackRed),
                green: CGFloat(BrandVibrancyBackgroundContract.brandBlackGreen),
                blue: CGFloat(BrandVibrancyBackgroundContract.brandBlackBlue),
                alpha: CGFloat(BrandVibrancyBackgroundContract.opacity(for: .medium))
            ).cgColor
        brandBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(brandBackgroundView)
        NSLayoutConstraint.activate([
            brandBackgroundView.topAnchor.constraint(equalTo: topAnchor),
            brandBackgroundView.leadingAnchor.constraint(equalTo: leadingAnchor),
            brandBackgroundView.trailingAnchor.constraint(equalTo: trailingAnchor),
            brandBackgroundView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
    }

    /// Attaches the incoming player surface while retaining all old surfaces.
    /// Cancellation is checked before and after attachment, before awaiting a seek.
    func prepare(player: AVPlayer) -> PreparedPresentation {
        readinessObservation = nil
        seekCompletedPresentation = nil
        // A superseded, never-published layer cannot be useful as a fallback.
        if let pendingPresentation { pendingPresentation.host.removeFromSuperview() }
        self.pendingPresentation = nil
        let outgoing = subviews.filter { $0 !== brandBackgroundView }
        let incoming = AVPlayerLayer(player: player)
        incoming.videoGravity = videoGravity
        let host = NSView(frame: bounds)
        host.translatesAutoresizingMaskIntoConstraints = false
        host.wantsLayer = true
        // The outgoing decoded surface remains visible through readiness and
        // seek. `complete(_:)` publishes only after the target seek has
        // returned and the incoming layer reports drawable pixels.
        host.alphaValue = 0
        host.layer = incoming
        addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: topAnchor),
            host.leadingAnchor.constraint(equalTo: leadingAnchor),
            host.trailingAnchor.constraint(equalTo: trailingAnchor),
            host.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        currentHost = host
        currentLayer = incoming

        let presentation = PreparedPresentation(
            host: host,
            player: player,
            outgoing: outgoing
        )
        pendingPresentation = presentation
        return presentation
    }

    /// A superseding seek to the same URL reuses the player. If the prior task
    /// was cancelled after attachment but before completion, the new task owns
    /// and completes that still-pending layer transaction.
    func pendingPresentation(for player: AVPlayer) -> PreparedPresentation? {
        guard pendingPresentation?.player === player else { return nil }
        // A newer seek owns readiness from this point. A callback from the
        // cancelled seek cannot publish until the replacement seek completes.
        readinessObservation = nil
        seekCompletedPresentation = nil
        return pendingPresentation
    }

    /// Seek completion alone does not mean AVPlayerLayer has drawable pixels.
    /// Keep the outgoing layer (or the still underneath) until both are ready.
    func complete(_ presentation: PreparedPresentation) {
        guard currentHost === presentation.host,
              currentLayer?.player === presentation.player else { return }
        seekCompletedPresentation = presentation
        readinessObservation = currentLayer?.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.publishReadyPresentationIfPossible() }
        }
        publishReadyPresentationIfPossible()
    }

    private func publishReadyPresentationIfPossible() {
        guard let presentation = seekCompletedPresentation,
              currentHost === presentation.host,
              currentLayer?.player === presentation.player else { return }
        var ready = currentLayer?.isReadyForDisplay == true
        #if DEBUG
        if let override = interactionTestReadyForDisplay { ready = override }
        #endif
        guard ready else { return }
        readinessObservation = nil
        seekCompletedPresentation = nil
        pendingPresentation = nil
        // Publish atomically: an arbitrary animation delay cannot establish
        // readiness and can expose a blank container after cancellation.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        presentation.host.alphaValue = 1
        alphaValue = 1
        for old in presentation.outgoing { old.removeFromSuperview() }
        CATransaction.commit()
    }

    /// Detaches the presented layer without disturbing the player cache.
    func clear() {
        alphaValue = 0
        readinessObservation = nil
        seekCompletedPresentation = nil
        subviews.filter { $0 !== brandBackgroundView }.forEach { $0.removeFromSuperview() }
        currentHost = nil
        currentLayer = nil
        pendingPresentation = nil
    }
}
#endif
