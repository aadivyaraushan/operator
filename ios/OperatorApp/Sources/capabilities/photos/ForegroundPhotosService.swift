import Foundation
import OperatorCore
import OSLog
import Photos
#if canImport(UIKit)
import UIKit
#endif

// Photos returns descriptions of photos, never photos.
//
// The agent gets identifiers, dates, kinds and album names — enough to say
// "the receipt you photographed on Tuesday is in Recents" and enough for a
// later hand-off to open it. Image bytes are not in the payload and there is
// no verb here that would produce them. That is a deliberate ceiling: pixels
// leaving the phone is a different decision from metadata leaving it, it
// needs its own consent, and nothing in the product asks for it yet.

enum PhotosAccess: Equatable, Sendable {
    case notDetermined
    /// iOS lets the owner grant a chosen subset. Anything outside it is
    /// indistinguishable from a photo that does not exist, which is the point.
    case limited
    case full
    case denied
}

struct PhotoItem: Sendable, Equatable {
    let id: String
    let created: Date?
    let isVideo: Bool
    let isFavorite: Bool
    let albumName: String?
}

@MainActor
protocol PhotoLibrary: AnyObject, Sendable {
    var access: PhotosAccess { get }
    func requestAccess() async -> Bool
    func search(album: String?, from: Date?, to: Date?, limit: Int) async -> [PhotoItem]
}

@MainActor
final class ForegroundPhotosService: GatewayNodeCommandHandler {
    static let maximumLimit = 25
    static let defaultLimit = 10
    static let maximumAlbumLength = 100

    private struct Payload: Encodable {
        struct Item: Encodable {
            let id: String
            let created: String?
            let kind: String
            let favorite: Bool
            let album: String?
        }

        let photos: [Item]
        let partialAccess: Bool
    }

    struct Request: Equatable, Sendable {
        let album: String?
        let from: Date?
        let to: Date?
        let limit: Int
    }

    private let library: any PhotoLibrary
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "foreground-photos")

    init(library: any PhotoLibrary, isAppActive: @escaping @MainActor @Sendable () -> Bool) {
        self.library = library
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "photos.latest" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let request = Self.request(from: paramsJSON) else {
            self.logger.info("[photos] refused branch=invalid_params")
            return .failure(
                code: "INVALID_REQUEST",
                message: "photos.latest accepts an optional album, from, to and a limit between 1 and \(Self.maximumLimit)")
        }
        guard self.isAppActive() else {
            self.logger.info("[photos] refused branch=app_not_active")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look through your photos")
        }
        // A photo library is the one local read whose cost scales with the
        // owner's data, so the deadline earns its keep here more than
        // anywhere else on the phone.
        let deadline = Date().addingTimeInterval(Double(GatewayDeadline.bounded(timeoutMilliseconds)) / 1_000)
        if self.library.access == .denied {
            self.logger.info("[photos] refused branch=permission_denied")
            return .failure(code: "PERMISSION_DENIED", message: "Photos permission was denied")
        }
        if self.library.access == .notDetermined {
            guard let granted = await GatewayDeadline.run(
                milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
                { [library] in await library.requestAccess() })
            else {
                self.logger.info("[photos] refused branch=permission_timeout")
                return .failure(code: "TIMEOUT", message: "Photos permission was not answered in time")
            }
            guard self.isAppActive() else {
                self.logger.info("[photos] refused branch=app_left_during_permission")
                return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to look through your photos")
            }
            guard granted else {
                self.logger.info("[photos] refused branch=permission_request_denied")
                return .failure(code: "PERMISSION_DENIED", message: "Photos permission was denied")
            }
        }

        let partial = self.library.access == .limited
        let formatter = ISO8601DateFormatter()
        guard let found = await GatewayDeadline.run(
            milliseconds: Int(deadline.timeIntervalSinceNow * 1_000),
            { [library] in
                await library.search(album: request.album, from: request.from, to: request.to, limit: request.limit)
            })
        else {
            self.logger.info("[photos] refused branch=search_timeout")
            return .failure(code: "TIMEOUT", message: "Looking through your photos took too long")
        }
        let items = found
            .prefix(request.limit)
            .map { photo in
                Payload.Item(
                    id: photo.id,
                    created: photo.created.map(formatter.string(from:)),
                    kind: photo.isVideo ? "video" : "image",
                    favorite: photo.isFavorite,
                    album: photo.albumName)
            }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(Payload(photos: Array(items), partialAccess: partial)),
              let payloadJSON = String(data: data, encoding: .utf8)
        else {
            self.logger.error("[photos] failed branch=encode count=\(items.count)")
            return .failure(code: "INTERNAL_ERROR", message: "Operator could not read your photo library")
        }
        self.logger.info("[photos] returned count=\(items.count) partial=\(partial)")
        return .success(payloadJSON: payloadJSON)
    }

    static func request(from paramsJSON: String?) -> Request? {
        guard let paramsJSON, !paramsJSON.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return Request(album: nil, from: nil, to: nil, limit: Self.defaultLimit)
        }
        guard paramsJSON.utf8.count <= 4096,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys).isSubset(of: ["album", "from", "to", "limit"])
        else { return nil }

        var album: String?
        if let raw = object["album"] {
            guard let text = raw as? String else { return nil }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= Self.maximumAlbumLength else { return nil }
            album = trimmed
        }

        func date(_ key: String) -> Date?? {
            guard let raw = object[key] else { return .some(nil) }
            guard let text = raw as? String, let parsed = Self.rfc3339(text) else { return nil }
            return .some(parsed)
        }
        guard let from = date("from"), let to = date("to") else { return nil }
        // A window that ends before it starts is a mistake, not an empty range.
        if let from, let to, to < from { return nil }

        var limit = Self.defaultLimit
        if let raw = object["limit"] {
            guard let parsed = JSONNumber.integer(raw, in: 1 ... Self.maximumLimit) else { return nil }
            limit = parsed
        }
        return Request(album: album, from: from, to: to, limit: limit)
    }

    private static func rfc3339(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
    }
}

@MainActor
final class SystemPhotoLibrary: PhotoLibrary {
    var access: PhotosAccess {
        switch PHPhotoLibrary.authorizationStatus(for: .readWrite) {
        case .authorized: .full
        case .limited: .limited
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    func requestAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return status == .authorized || status == .limited
    }

    func search(album: String?, from: Date?, to: Date?, limit: Int) async -> [PhotoItem] {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        var predicates: [NSPredicate] = []
        if let from { predicates.append(NSPredicate(format: "creationDate >= %@", from as NSDate)) }
        if let to { predicates.append(NSPredicate(format: "creationDate <= %@", to as NSDate)) }
        if !predicates.isEmpty {
            options.predicate = NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
        }
        options.fetchLimit = limit

        var albumTitle: String?
        let assets: PHFetchResult<PHAsset>
        if let album {
            let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
            var match: PHAssetCollection?
            collections.enumerateObjects { collection, _, stop in
                if collection.localizedTitle?.caseInsensitiveCompare(album) == .orderedSame {
                    match = collection
                    stop.pointee = true
                }
            }
            guard let match else { return [] }
            albumTitle = match.localizedTitle
            assets = PHAsset.fetchAssets(in: match, options: options)
        } else {
            assets = PHAsset.fetchAssets(with: options)
        }

        var items: [PhotoItem] = []
        assets.enumerateObjects { asset, _, stop in
            items.append(PhotoItem(
                id: asset.localIdentifier,
                created: asset.creationDate,
                isVideo: asset.mediaType == .video,
                isFavorite: asset.isFavorite,
                albumName: albumTitle))
            if items.count >= limit { stop.pointee = true }
        }
        return items
    }
}

#if canImport(UIKit)
extension ForegroundPhotosService {
    convenience init() {
        self.init(
            library: SystemPhotoLibrary(),
            isAppActive: { UIApplication.shared.applicationState == .active })
    }
}
#endif
