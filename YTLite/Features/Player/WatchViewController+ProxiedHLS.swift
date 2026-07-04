import AVFoundation
import UIKit

// MARK: - Proxied HLS playback

extension WatchViewController {
    /// Plays a resolved HLS manifest through `HLSProxyLoader`, which supplies the
    /// desktop Safari User-Agent CoreMedia omits and rewrites the n-throttling
    /// signature so segment CDN requests are accepted.
    func attachProxiedHLS(
        manifestURL: URL,
        nSolver: (unsolved: String, solved: String)?
    ) {
        guard let proxyURL = manifestURL.ytvProxyURL else {
            attachPlayer(url: manifestURL)
            return
        }
        let loader = HLSProxyLoader(
            userAgent: HLSStreamResolver.shared.desktopSafariUA,
            nSolver: nSolver
        )
        hlsProxyLoader = loader
        let asset = AVURLAsset(url: proxyURL)
        asset.resourceLoader.setDelegate(
            loader, queue: DispatchQueue(label: "com.ytvlite.hlsproxy")
        )
        attachPlayer(item: AVPlayerItem(asset: asset))
    }
}
