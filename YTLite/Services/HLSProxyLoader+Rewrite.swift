import Foundation

// MARK: - Playlist rewriting

extension HLSProxyLoader {
    /// Diagnostic: logs the variant resolutions of a multivariant manifest, or
    /// the itag AVPlayer is fetching for a child (reveals the chosen quality).
    static func logPlaylist(data: Data, url: URL) {
        guard let text = String(data: data, encoding: .utf8) else {
            return
        }
        if text.contains("#EXT-X-STREAM-INF") {
            let resolutions = text.components(separatedBy: "\n")
                .compactMap { line -> String? in
                    guard line.hasPrefix("#EXT-X-STREAM-INF") else {
                        return nil
                    }
                    return HLSStreamResolver.firstMatch(
                        in: line, pattern: "RESOLUTION=([0-9x]+)"
                    )
                }
            AppLog.player(
                "hlsProxy: multivariant, resolutions="
                    + resolutions.joined(separator: ",")
            )
        } else {
            let itag = HLSStreamResolver.firstMatch(
                in: url.absoluteString, pattern: "/itag/([0-9]+)/"
            ) ?? "?"
            AppLog.player("hlsProxy: child playlist itag=\(itag)")
        }
    }

    func rewrittenPlaylistData(_ data: Data) -> Data {
        guard let text = String(data: data, encoding: .utf8) else {
            return data
        }
        return rewritePlaylist(text).data(using: .utf8) ?? data
    }

    /// 1. Replace the unsolved n-value with the solved one across the playlist
    ///    (a single session-wide value, so a global replace is safe).
    /// 2. For master manifests, route child variant/rendition playlists back
    ///    through the proxy so they get the same UA + n-rewrite.
    private func rewritePlaylist(_ m3u8: String) -> String {
        var text = m3u8
        if let solver = nSolver, solver.unsolved != solver.solved {
            text = text.replacingOccurrences(
                of: "/n/\(solver.unsolved)/",
                with: "/n/\(solver.solved)/"
            )
        }
        let isMultiVariant = text.contains("#EXT-X-STREAM-INF")
            || text.contains("#EXT-X-MEDIA:")
        guard isMultiVariant else {
            return text
        }
        return proxyingChildURIs(in: text)
    }

    private func proxyingChildURIs(in text: String) -> String {
        let lines = text.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("#EXT-X-MEDIA:") {
                return line
                    .replacingOccurrences(
                        of: "URI=\"https://",
                        with: "URI=\"\(HLSProxy.scheme)://"
                    )
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.hasPrefix("https://") {
                return trimmed.replacingOccurrences(
                    of: "https://",
                    with: "\(HLSProxy.scheme)://"
                )
            }
            return line
        }
        return lines.joined(separator: "\n")
    }
}
