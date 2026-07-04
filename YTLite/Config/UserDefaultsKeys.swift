import Foundation

/// Centralised UserDefaults key namespace.
/// All keys used in the app must be declared here to prevent typos and collisions.
enum UserDefaultsKeys {
    enum Theme {
        static let mode = "themeMode"
    }

    enum VideoQuality {
        static let selected = "defaultVideoQuality"
    }

    enum Cache {
        static let feedPersistenceEnabled = "feedCachePersistenceEnabled"
        static let feedCacheDays = "feedCacheDays"
        static let imageCacheEnabled = "imageCacheEnabled"
        static let imageCacheDays = "imageCacheDays"
    }

    enum Auth {
        static let isAnonymous = "isAnonymous"
    }

    enum RYD {
        static let enabled    = "ryd_enabled"
        static let userId     = "ryd_userId_v2"
        static let registered = "ryd_registered_v2"
    }

    enum SponsorBlock {
        static let enabled = "sponsorblock_enabled"
        /// Returns the key for the skip-behavior setting of a given category raw value.
        static func segmentBehavior(for categoryRawValue: String) -> String {
            "sb_behavior_\(categoryRawValue)"
        }
    }

    enum Feed {
        static let showShorts = "feed_showShorts"
    }

    enum Player {
        static let backgroundPlayback = "player_backgroundPlayback"
        static let pipEnabled = "player_pipEnabled"
    }

    enum Debug {
        static let playbackSource = "debug_playbackSource"
        static let solverEndpoint = "debug_solverEndpoint"
    }
}

// MARK: - PlaybackSource

enum PlaybackSource: String, CaseIterable {
    case androidVR = "android_vr"
    case progressive = "progressive"
    case webViewHLS = "webview_hls"

    static var selected: PlaybackSource {
        let raw = UserDefaults.standard.string(
            forKey: UserDefaultsKeys.Debug.playbackSource
        )
        return raw.flatMap(PlaybackSource.init)
            ?? .androidVR
    }

    var displayName: String {
        switch self {
        case .androidVR:
            return "Android VR (default)"
        case .progressive:
            return "Progressive (360p)"
        case .webViewHLS:
            return "WebView HLS (kids/dubbed)"
        }
    }
}
