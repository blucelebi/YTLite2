import AVFoundation
import Foundation

// MARK: - Proxy scheme helpers

enum HLSProxy {
    static let scheme = "ytvproxy"
}

extension URL {
    /// https:// → ytvproxy:// so AVPlayer routes the request through the loader.
    var ytvProxyURL: URL? {
        guard var comps = URLComponents(
            url: self, resolvingAgainstBaseURL: false
        ) else {
            return nil
        }
        comps.scheme = HLSProxy.scheme
        return comps.url
    }

    /// ytvproxy:// → https:// for the real network request.
    var ytvRealURL: URL? {
        guard scheme == HLSProxy.scheme,
              var comps = URLComponents(
                  url: self, resolvingAgainstBaseURL: false
              ) else {
            return nil
        }
        comps.scheme = "https"
        return comps.url
    }
}

// MARK: - HLSProxyLoader
//
// Forwards every HLS playlist/segment request through URLSession with a desktop
// Safari User-Agent (CoreMedia's native HLS stack does not reliably send our UA,
// and manifest.googlevideo.com rejects other UAs). Rewrites the unsolved
// n-throttling value to the solved one so segment CDN requests return 200.

final class HLSProxyLoader: NSObject, AVAssetResourceLoaderDelegate {
    struct Fetch {
        let data: Data?
        let response: URLResponse?
        let error: Error?
        let realURL: URL
    }

    let userAgent: String
    let nSolver: (unsolved: String, solved: String)?

    init(userAgent: String, nSolver: (unsolved: String, solved: String)?) {
        self.userAgent = userAgent
        self.nSolver = nSolver
    }

    static func uti(isPlaylist: Bool, mime: String) -> String {
        if isPlaylist {
            return "public.m3u-playlist"
        }
        if mime.contains("mp4") || mime.contains("mpeg-4") {
            return "public.mpeg-4"
        }
        return "public.mpeg-2-transport-stream"
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource
        loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        guard let proxyURL = loadingRequest.request.url,
              let realURL = proxyURL.ytvRealURL else {
            return false
        }
        let task = URLSession.shared.dataTask(
            with: makeRequest(url: realURL)
        ) { [weak self] data, response, error in
            let fetch = Fetch(
                data: data, response: response, error: error, realURL: realURL
            )
            self?.handleResponse(fetch: fetch, loadingRequest: loadingRequest)
        }
        task.resume()
        return true
    }

    // MARK: Request / response

    private func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.setValue(userAgent, forHTTPHeaderField: HTTPHeader.userAgent)
        if url.host?.contains("googlevideo.com") == true {
            request.setValue(
                AppURLs.YouTube.base, forHTTPHeaderField: HTTPHeader.origin
            )
            request.setValue(
                AppURLs.YouTube.base + "/",
                forHTTPHeaderField: HTTPHeader.referer
            )
            if let cookies = cookieHeader() {
                request.setValue(cookies, forHTTPHeaderField: "Cookie")
            }
        }
        return request
    }

    private func cookieHeader() -> String? {
        guard let base = URL(string: AppURLs.YouTube.base),
              let cookies = HTTPCookieStorage.shared.cookies(for: base),
              !cookies.isEmpty else {
            return nil
        }
        return cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    private func handleResponse(
        fetch: Fetch,
        loadingRequest: AVAssetResourceLoadingRequest
    ) {
        if let error = fetch.error {
            loadingRequest.finishLoading(with: error)
            return
        }
        guard let http = fetch.response as? HTTPURLResponse,
              let data = fetch.data else {
            loadingRequest.finishLoading(
                with: NSError(domain: "HLSProxy", code: -1)
            )
            return
        }
        let mime = ((http.allHeaderFields["Content-Type"]
            as? String) ?? "").lowercased()
        let isPlaylist = mime.contains("mpegurl")
            || fetch.realURL.pathExtension.lowercased() == "m3u8"
            || fetch.realURL.lastPathComponent.lowercased() == "index.m3u8"
        if http.statusCode >= 400 {
            AppLog.player(
                "hlsProxy: \(fetch.realURL.lastPathComponent) "
                    + "HTTP \(http.statusCode)"
            )
        } else if isPlaylist {
            Self.logPlaylist(data: data, url: fetch.realURL)
        }
        fulfill(
            loadingRequest: loadingRequest,
            data: isPlaylist ? rewrittenPlaylistData(data) : data,
            isPlaylist: isPlaylist,
            mime: mime
        )
    }

    private func fulfill(
        loadingRequest: AVAssetResourceLoadingRequest,
        data: Data,
        isPlaylist: Bool,
        mime: String
    ) {
        if let info = loadingRequest.contentInformationRequest {
            info.contentType = Self.uti(isPlaylist: isPlaylist, mime: mime)
            info.contentLength = Int64(data.count)
            info.isByteRangeAccessSupported = false
        }
        loadingRequest.dataRequest?.respond(with: data)
        loadingRequest.finishLoading()
    }
}
