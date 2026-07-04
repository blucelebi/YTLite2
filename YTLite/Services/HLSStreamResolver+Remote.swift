import Foundation

// MARK: - Remote n-solving (iOS 12/13 fallback)

extension HLSStreamResolver {
    static func parseRemoteSolved(data: Data?, unsolved: String) -> String? {
        guard let data,
              let json = try? JSONSerialization.jsonObject(with: data)
              as? [String: Any],
              let solved = json["solved"] as? [String: Any],
              let value = solved[unsolved] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }

    /// POSTs the player-JS path and unsolved n to the configured solver service,
    /// which runs the EJS solver on a modern engine and returns the solved value.
    /// No video id or user data is sent. Yields nil when no endpoint is set.
    func solveRemote(
        unsolved: String,
        jsPath: String?,
        completion: @escaping (String?) -> Void
    ) {
        guard let endpoint = AppURLs.NSolver.endpoint, let jsPath else {
            AppLog.player("hlsResolve: no remote solver configured")
            completion(nil)
            return
        }
        guard let body = try? JSONSerialization.data(
            withJSONObject: ["jsUrl": jsPath, "n": [unsolved]]
        ) else {
            completion(nil)
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue(
            HTTPHeaderValue.contentTypeJSON,
            forHTTPHeaderField: HTTPHeader.contentType
        )
        request.httpBody = body
        AppLog.player("hlsResolve: remote solving n via \(endpoint.host ?? "")")
        let task = URLSession.shared.dataTask(with: request) { data, _, _ in
            completion(Self.parseRemoteSolved(data: data, unsolved: unsolved))
        }
        task.resume()
    }
}
