import Foundation
import OperatorCore
import OSLog
#if os(iOS)
import MediaPlayer
#endif
#if canImport(UIKit)
import UIKit
#endif

// The owner's own music library, read only.
//
// This is deliberately not Spotify. Spotify needs an OAuth app that is still
// in development mode with a user cap; the library already on the phone needs
// one permission string and answers the two questions people actually ask —
// what is playing, and do I own a copy of this.
//
// It never starts, stops or skips anything. Playback is a write, and writes
// wait until the reads above them are proven.

enum MusicAccess: Equatable, Sendable {
    case notDetermined
    case granted
    case denied
}

struct MusicTrack: Sendable, Equatable {
    let id: String
    let title: String
    let artist: String?
    let album: String?
    let durationSeconds: Int?
}

struct NowPlaying: Sendable, Equatable {
    let track: MusicTrack?
    let isPlaying: Bool
}

@MainActor
protocol MusicLibrary: AnyObject, Sendable {
    var access: MusicAccess { get }
    func requestAccess() async -> Bool
    func nowPlaying() async -> NowPlaying
    func search(query: String, limit: Int) async -> [MusicTrack]
}

@MainActor
final class ForegroundMusicService: GatewayNodeCommandHandler {
    static let maximumLimit = 20
    static let defaultLimit = 10
    static let maximumQueryLength = 200

    private struct SearchPayload: Encodable {
        struct Track: Encodable {
            let id: String
            let title: String
            let artist: String?
            let album: String?
            let seconds: Int?
        }

        let tracks: [Track]
    }

    private struct NowPlayingPayload: Encodable {
        let title: String?
        let artist: String?
        let album: String?
        let playing: Bool
    }

    private let library: any MusicLibrary
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-music")

    init(library: any MusicLibrary, isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.library = library
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "music.nowPlaying" || command == "music.search" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        var query: String?
        var limit = Self.defaultLimit
        if command == "music.search" {
            guard let parsed = Self.searchRequest(from: paramsJSON) else {
                self.logger.info("[music] refused branch=invalid_params")
                return .failure(
                    code: "INVALID_REQUEST",
                    message: "music.search requires a nonempty query and an optional limit between 1 and \(Self.maximumLimit)")
            }
            query = parsed.0
            limit = parsed.1
        } else {
            guard Self.acceptsEmptyObject(paramsJSON) else {
                self.logger.info("[music] refused branch=invalid_params")
                return .failure(code: "INVALID_REQUEST", message: "music.nowPlaying does not accept parameters")
            }
        }

        guard self.isAppActive() else {
            self.logger.info("[music] refused branch=app_not_active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your music library")
        }
        let deadline = Date().addingTimeInterval(Double(GatewayDeadline.bounded(timeoutMilliseconds)) / 1_000)
        if self.library.access == .denied {
            self.logger.info("[music] refused branch=permission_denied")
            return .failure(code: "PERMISSION_DENIED", message: "Media library permission was denied")
        }
        if self.library.access == .notDetermined {
            guard let granted = await GatewayDeadline.run(
                milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
                { [library] in await library.requestAccess() })
            else {
                self.logger.info("[music] refused branch=permission_timeout")
                return .failure(code: "TIMEOUT", message: "Media library permission was not answered in time")
            }
            guard self.isAppActive() else {
                self.logger.info("[music] refused branch=app_left_during_permission")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to read your music library")
            }
            guard granted else {
                self.logger.info("[music] refused branch=permission_request_denied")
                return .failure(code: "PERMISSION_DENIED", message: "Media library permission was denied")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data?
        let remaining = Int(deadline.timeIntervalSinceNow * 1_000)
        let requested = limit
        if let query {
            guard let found = await GatewayDeadline.run(
                milliseconds: remaining, { [library] in await library.search(query: query, limit: requested) })
            else {
                self.logger.info("[music] refused branch=search_timeout")
                return .failure(code: "TIMEOUT", message: "Searching your music library took too long")
            }
            let tracks = found
                .prefix(requested)
                .map { SearchPayload.Track(id: $0.id, title: $0.title, artist: $0.artist, album: $0.album, seconds: $0.durationSeconds) }
            data = try? encoder.encode(SearchPayload(tracks: Array(tracks)))
            self.logger.info("[music] search returned count=\(tracks.count)")
        } else {
            guard let state = await GatewayDeadline.run(
                milliseconds: remaining, { [library] in await library.nowPlaying() })
            else {
                self.logger.info("[music] refused branch=now_playing_timeout")
                return .failure(code: "TIMEOUT", message: "Reading what is playing took too long")
            }
            data = try? encoder.encode(NowPlayingPayload(
                title: state.track?.title, artist: state.track?.artist,
                album: state.track?.album, playing: state.isPlaying))
            self.logger.info("[music] nowPlaying playing=\(state.isPlaying) hasTrack=\(state.track != nil)")
        }
        guard let data, let payloadJSON = String(data: data, encoding: .utf8) else {
            self.logger.error("[music] failed branch=encode")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read your music library")
        }
        return .success(payloadJSON: payloadJSON)
    }

    static func searchRequest(from paramsJSON: String?) -> (String, Int)? {
        guard let paramsJSON, paramsJSON.utf8.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["query", "limit"]),
              let rawQuery = object["query"] as? String
        else { return nil }
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= Self.maximumQueryLength else { return nil }
        guard let rawLimit = object["limit"] else { return (query, Self.defaultLimit) }
        guard let limit = JSONNumber.integer(rawLimit, in: 1 ... Self.maximumLimit) else { return nil }
        return (query, limit)
    }

    static func acceptsEmptyObject(_ paramsJSON: String?) -> Bool {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return true }
        guard let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any]
        else { return false }
        return object.isEmpty
    }
}

#if os(iOS)
@MainActor
final class SystemMusicLibrary: MusicLibrary {
    var access: MusicAccess {
        switch MPMediaLibrary.authorizationStatus() {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            // Called back off the main actor; see the note in
            // ForegroundRemindersService for why this must be @Sendable.
            MPMediaLibrary.requestAuthorization { @Sendable status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    func nowPlaying() async -> NowPlaying {
        let player = MPMusicPlayerController.systemMusicPlayer
        guard let item = player.nowPlayingItem else {
            return NowPlaying(track: nil, isPlaying: player.playbackState == .playing)
        }
        return NowPlaying(track: Self.track(item), isPlaying: player.playbackState == .playing)
    }

    func search(query: String, limit: Int) async -> [MusicTrack] {
        let mediaQuery = MPMediaQuery.songs()
        mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(
            value: query, forProperty: MPMediaItemPropertyTitle, comparisonType: .contains))
        return (mediaQuery.items ?? []).prefix(limit).map(Self.track)
    }

    private static func track(_ item: MPMediaItem) -> MusicTrack {
        MusicTrack(
            id: String(item.persistentID),
            title: item.title ?? "",
            artist: item.artist,
            album: item.albumTitle,
            durationSeconds: item.playbackDuration > 0 ? Int(item.playbackDuration.rounded()) : nil)
    }
}
#endif

#if os(iOS)
extension ForegroundMusicService {
    convenience init() {
        self.init(
            library: SystemMusicLibrary(),
            isAppActive: { UIApplication.shared.applicationState == .active })
    }
}
#endif
