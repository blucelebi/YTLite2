import AVFoundation
import Foundation

/// Source that plays the JS-context HLS manifest (kids / dubbed / rqh=1 content):
/// resolves it via `HLSStreamResolver` (URLSession + n-solve) and plays through
/// `HLSProxyLoader`. Owns quality selection by filtering the multivariant
/// manifest to the chosen resolution (the concrete 1080p fix).
final class WebViewHLSSource: VideoSource {
    let kind: VideoSourceKind = .webViewHLS
    let supportsQualitySelection = true
    private(set) var availableQualities: [VideoQuality] = []
    private(set) var currentQuality: VideoQuality?

    private let resolver: HLSStreamResolver
    private let apiClient: WatchService
    private let proxyQueueLabel = "com.ytvlite.hlsproxy"
    private var manifestURL: URL?
    private var nSolver: (unsolved: String, solved: String)?
    private var captions: [SubtitleTrack] = []
    private var activeLoader: HLSProxyLoader?

    init(apiClient: WatchService, resolver: HLSStreamResolver = .shared) {
        self.resolver = resolver
        self.apiClient = apiClient
    }

    /// Parses the multivariant manifest into one quality per resolution height
    /// (plus an Auto entry), sorted high→low.
    static func parseQualities(from manifest: String) -> [VideoQuality] {
        var byHeight: [Int: VideoQuality] = [:]
        for line in manifest.components(separatedBy: "\n")
        where line.hasPrefix("#EXT-X-STREAM-INF") {
            let resText = HLSStreamResolver.firstMatch(
                in: line, pattern: "RESOLUTION=[0-9]+x([0-9]+)"
            )
            guard let height = resText.flatMap(Int.init) else {
                continue
            }
            let fpsText = HLSStreamResolver.firstMatch(
                in: line, pattern: "FRAME-RATE=([0-9]+)"
            )
            let fps = fpsText.flatMap(Int.init)
            let label = (fps ?? 0) > 30 ? "\(height)p\(fps ?? 0)" : "\(height)p"
            byHeight[height] = VideoQuality(
                id: "\(height)", label: label, height: height, fps: fps
            )
        }
        let heights = byHeight.values.sorted {
            ($0.height ?? 0) > ($1.height ?? 0)
        }
        let auto = VideoQuality(id: "auto", label: "Auto", height: nil, fps: nil)
        return [auto] + heights
    }

    /// Applies the user's default-quality setting: the best variant not
    /// exceeding the cap; Auto when no cap is set.
    static func preferredQuality(
        from qualities: [VideoQuality],
        maxHeight: Int?
    ) -> VideoQuality? {
        guard let maxHeight else {
            return qualities.first
        }
        let capped = qualities.first { ($0.height ?? .max) <= maxHeight }
        // Nothing at or below the cap → the smallest variant beats Auto.
        return capped ?? qualities.last
    }

    func loadPlayback(
        videoId: String,
        cancellation: CancellationToken?,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        // Captions come from the IOS player client in parallel with the
        // manifest resolve: the WEB timedtext URLs found in the watch HTML
        // are POT-gated and return empty bodies.
        let group = DispatchGroup()
        var innertubeCaptions: [SubtitleTrack] = []
        var resolveResult: Result<ResolvedHLS, Error> = .failure(
            HLSStreamResolver.ResolverError.noManifest
        )
        group.enter()
        apiClient.fetchCaptionTracks(videoId: videoId) { tracks in
            innertubeCaptions = tracks
            group.leave()
        }
        group.enter()
        resolver.resolve(videoId: videoId) { result in
            resolveResult = result
            group.leave()
        }
        group.notify(queue: .global()) { [weak self] in
            switch resolveResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let resolved):
                self?.handleResolved(
                    resolved,
                    innertubeCaptions: innertubeCaptions,
                    completion: completion
                )
            }
        }
    }

    func selectQuality(
        _ quality: VideoQuality,
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        currentQuality = quality
        guard let prepared = buildPlayback(height: quality.height) else {
            completion(.failure(HLSStreamResolver.ResolverError.noManifest))
            return
        }
        completion(.success(prepared))
    }

    // MARK: - Private

    private func handleResolved(
        _ resolved: ResolvedHLS,
        innertubeCaptions: [SubtitleTrack],
        completion: @escaping (Result<PreparedPlayback, Error>) -> Void
    ) {
        manifestURL = resolved.manifestURL
        nSolver = resolved.nSolver
        captions = innertubeCaptions.isEmpty
            ? resolved.captions
            : innertubeCaptions
        resolver.fetchText(url: resolved.manifestURL) { [weak self] result in
            guard let self else {
                return
            }
            let manifest = (try? result.get()) ?? ""
            self.availableQualities = Self.parseQualities(from: manifest)
            let preferred = Self.preferredQuality(
                from: self.availableQualities,
                maxHeight: VideoQualityStore.maxHeight
            )
            self.currentQuality = preferred
            guard let prepared = self.buildPlayback(height: preferred?.height) else {
                completion(.failure(HLSStreamResolver.ResolverError.noManifest))
                return
            }
            completion(.success(prepared))
        }
    }

    private func buildPlayback(height: Int?) -> PreparedPlayback? {
        guard let manifestURL, let proxyURL = manifestURL.ytvProxyURL else {
            return nil
        }
        let loader = HLSProxyLoader(
            userAgent: resolver.desktopSafariUA, nSolver: nSolver
        )
        loader.selectedHeight = height
        activeLoader = loader
        let asset = AVURLAsset(url: proxyURL)
        asset.resourceLoader.setDelegate(
            loader, queue: DispatchQueue(label: proxyQueueLabel)
        )
        return PreparedPlayback(
            item: AVPlayerItem(asset: asset),
            resourceLoader: loader,
            captions: captions
        )
    }
}
