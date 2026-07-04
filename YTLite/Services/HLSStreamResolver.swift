import Foundation

// MARK: - HLS Stream Resolver
//
// Resolves a playable YouTube HLS manifest without a WKWebView:
//   1. URLSession GET the watch page (desktop Safari UA) → hlsManifestUrl + jsUrl.
//      The server-rendered HTML already carries an spc= (proof-of-context) URL.
//   2. URLSession GET the multivariant manifest → the unsolved n-throttling value.
//   3. Solve n: on iOS 14+ in a local JSContext; older devices need a remote
//      solver (base.js uses ES2020 syntax the iOS 12/13 JS engine cannot parse).
// The solved n is handed to `HLSProxyLoader`, which rewrites /n/ and fixes the
// User-Agent so AVPlayer's segment requests are accepted (HTTP 200, not 403).

struct ResolvedHLS {
    let manifestURL: URL
    let nSolver: (unsolved: String, solved: String)?
}

final class HLSStreamResolver {
    enum ResolverError: Error {
        case noManifest
        case badResponse
        case solveUnavailable
    }

    static let shared = HLSStreamResolver()

    let desktopSafariUA = [
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
        "AppleWebKit/605.1.15 (KHTML, like Gecko)",
        "Version/17.5 Safari/605.1.15"
    ].joined(separator: " ")

    private init() {}

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let group = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[group])
    }

    static func manifestURL(from html: String) -> URL? {
        let raw = firstMatch(
            in: html, pattern: "\"hlsManifestUrl\":\"(https[^\"]+)\""
        )?.replacingOccurrences(of: "\\/", with: "/")
        return raw.flatMap { URL(string: $0) }
    }

    // MARK: Public

    func resolve(
        videoId: String,
        attempt: Int = 0,
        completion: @escaping (Result<ResolvedHLS, Error>) -> Void
    ) {
        let watch = "https://www.youtube.com/watch?v=\(videoId)"
        guard let url = URL(string: watch) else {
            completion(.failure(ResolverError.noManifest))
            return
        }
        AppLog.player("hlsResolve: fetching watch page \(videoId) (try \(attempt))")
        fetchText(url: url) { [weak self] result in
            guard let self else {
                return
            }
            switch result {
            case .failure(let error):
                self.retryOrFail(
                    videoId: videoId,
                    attempt: attempt,
                    error: error,
                    completion: completion
                )
            case .success(let html):
                self.handleWatchPage(
                    html: html,
                    videoId: videoId,
                    attempt: attempt,
                    completion: completion
                )
            }
        }
    }

    /// The watch page intermittently ships without a pre-rendered player
    /// response (no hlsManifestUrl). Retry a couple of times before failing.
    private func retryOrFail(
        videoId: String,
        attempt: Int,
        error: Error,
        completion: @escaping (Result<ResolvedHLS, Error>) -> Void
    ) {
        guard attempt < 2 else {
            completion(.failure(error))
            return
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { [weak self] in
            self?.resolve(
                videoId: videoId, attempt: attempt + 1, completion: completion
            )
        }
    }

    func fetchText(
        url: URL,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        var request = URLRequest(url: url)
        request.setValue(
            desktopSafariUA, forHTTPHeaderField: HTTPHeader.userAgent
        )
        request.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        request.setValue(
            "en-US,en;q=0.9", forHTTPHeaderField: HTTPHeader.acceptLanguage
        )
        let task = URLSession.shared.dataTask(with: request) { data, _, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let data,
                  let text = String(data: data, encoding: .utf8) else {
                completion(.failure(ResolverError.badResponse))
                return
            }
            completion(.success(text))
        }
        task.resume()
    }

    // MARK: Pipeline steps

    private func handleWatchPage(
        html: String,
        videoId: String,
        attempt: Int,
        completion: @escaping (Result<ResolvedHLS, Error>) -> Void
    ) {
        guard let manifestURL = Self.manifestURL(from: html) else {
            AppLog.player("hlsResolve: no hlsManifestUrl in page")
            retryOrFail(
                videoId: videoId,
                attempt: attempt,
                error: ResolverError.noManifest,
                completion: completion
            )
            return
        }
        let jsPath = Self.firstMatch(
            in: html, pattern: "\"jsUrl\":\"([^\"]+base\\.js)\""
        )
        AppLog.player("hlsResolve: manifest ok, jsUrl=\(jsPath ?? "nil")")
        fetchText(url: manifestURL) { [weak self] result in
            guard let self else {
                return
            }
            let manifestText = (try? result.get()) ?? ""
            self.solveThenFinish(
                manifestURL: manifestURL,
                manifestText: manifestText,
                jsPath: jsPath,
                completion: completion
            )
        }
    }

    private func solveThenFinish(
        manifestURL: URL,
        manifestText: String,
        jsPath: String?,
        completion: @escaping (Result<ResolvedHLS, Error>) -> Void
    ) {
        guard let unsolved = Self.firstMatch(
            in: manifestText, pattern: "/n/([A-Za-z0-9_-]{10,})/"
        ) else {
            AppLog.player("hlsResolve: no n in manifest; serving as-is")
            completion(.success(
                ResolvedHLS(manifestURL: manifestURL, nSolver: nil)
            ))
            return
        }
        solveN(unsolved: unsolved, jsPath: jsPath) { solved in
            let mapping = solved.map { (unsolved, $0) }
            AppLog.player("hlsResolve: n \(unsolved) -> \(solved ?? "nil")")
            completion(.success(
                ResolvedHLS(manifestURL: manifestURL, nSolver: mapping)
            ))
        }
    }
}
