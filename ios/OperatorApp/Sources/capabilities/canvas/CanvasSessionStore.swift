#if canImport(WebKit)
import Foundation
import OSLog
import WebKit

/// Where the kept Canvas sign-in is stored between reads. It cannot be the
/// WebKit data store: Canvas's `canvas_session` is a session cookie (no
/// expiry), and WebKit keeps those only in memory for the life of a web
/// view, so they vanish when the setup sheet closes. Operator captures the
/// cookies while the sheet is open and keeps them itself, in the Keychain,
/// since a session cookie is a credential.
struct CanvasSessionPersistence: Sendable {
    let save: @Sendable (Data) async throws -> Void
    let load: @Sendable () async throws -> Data?
    let clear: @Sendable () async throws -> Void
}

/// The Canvas sign-in, for schools that let students make no access token.
/// The web view signs in against an isolated WebKit store; Operator then
/// reads the school's cookies out of it once and keeps them. Only the
/// school's cookies are ever kept or sent, and only to that school.
@MainActor
final class CanvasSessionStore {
    private static let identifierKey = "app.operator.canvas.sessionStore"
    private let defaults: UserDefaults
    private let persistence: CanvasSessionPersistence
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")

    init(defaults: UserDefaults = .standard, persistence: CanvasSessionPersistence) {
        self.defaults = defaults
        self.persistence = persistence
    }

    /// The store the guided sign-in uses. Made on first use, kept so a
    /// half-finished sign-in survives a relaunch of the sheet.
    func dataStore() -> WKWebsiteDataStore {
        let identifier: UUID
        if let saved = self.defaults.string(forKey: Self.identifierKey), let uuid = UUID(uuidString: saved) {
            identifier = uuid
        } else {
            identifier = UUID()
            self.defaults.set(identifier.uuidString, forKey: Self.identifierKey)
        }
        return WKWebsiteDataStore(forIdentifier: identifier)
    }

    /// Reads the school's cookies out of the live sign-in and keeps them.
    /// Called while the setup sheet is still open, so the session cookie is
    /// still there to read. Returns what was kept.
    func capture(for host: String) async -> [HTTPCookie] {
        guard self.defaults.string(forKey: Self.identifierKey) != nil else { return [] }
        let all = await self.dataStore().httpCookieStore.allCookies()
        let mine = all.filter { Self.cookie($0, matchesHost: host) }
        guard !mine.isEmpty else { return [] }
        let serialised = mine.compactMap { $0.properties }.map { props in
            Dictionary(uniqueKeysWithValues: props.map { ($0.key.rawValue, $0.value) })
        }
        if let data = try? PropertyListSerialization.data(fromPropertyList: serialised, format: .binary, options: 0) {
            try? await self.persistence.save(data)
            self.logger.info("[canvas-setup] session captured cookies=\(mine.count)")
        }
        return mine
    }

    /// The kept cookies for the school, rebuilt from the Keychain. Empty
    /// when there is no kept sign-in.
    func cookies(for host: String) async -> [HTTPCookie] {
        guard let data = try? await self.persistence.load(),
              let list = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [[String: Any]]
        else { return [] }
        return list.compactMap { dict -> HTTPCookie? in
            var props: [HTTPCookiePropertyKey: Any] = [:]
            for (key, value) in dict { props[HTTPCookiePropertyKey(rawValue: key)] = value }
            return HTTPCookie(properties: props)
        }.filter { Self.cookie($0, matchesHost: host) }
    }

    /// Signs out: the kept cookies and the web store both go.
    func clear() async {
        try? await self.persistence.clear()
        if let saved = self.defaults.string(forKey: Self.identifierKey), let uuid = UUID(uuidString: saved) {
            let store = WKWebsiteDataStore(forIdentifier: uuid)
            await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
            try? await WKWebsiteDataStore.remove(forIdentifier: uuid)
            self.defaults.removeObject(forKey: Self.identifierKey)
        }
        self.logger.info("[canvas-setup] session cleared")
    }

    static func cookie(_ cookie: HTTPCookie, matchesHost host: String) -> Bool {
        let domain = cookie.domain.lowercased()
        let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
        return host == bare || host.hasSuffix("." + bare)
    }
}
#endif
