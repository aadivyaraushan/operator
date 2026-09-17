#if canImport(WebKit)
import Foundation
import OSLog
import WebKit

/// The Canvas sign-in kept as a browser session, for schools that do not let
/// students make access tokens. It lives in a WebKit data store of its own,
/// keyed by an identifier Operator keeps, so it is isolated from every other
/// web view and can be dropped whole. Only the school's cookies are ever
/// read out of it, and only to sign a read to that school.
@MainActor
final class CanvasSessionStore {
    private static let identifierKey = "app.operator.canvas.sessionStore"
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "app.operator.ios", category: "canvas-setup")

    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    /// The store the guided sign-in should use. Made on first use, kept
    /// after, so a session survives a relaunch.
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

    /// The school's cookies, if a session is there. Empty means signed out.
    func cookies(for host: String) async -> [HTTPCookie] {
        guard self.defaults.string(forKey: Self.identifierKey) != nil else { return [] }
        let all = await self.dataStore().httpCookieStore.allCookies()
        return all.filter { cookie in
            let domain = cookie.domain.lowercased()
            let bare = domain.hasPrefix(".") ? String(domain.dropFirst()) : domain
            return host == bare || host.hasSuffix("." + bare)
        }
    }

    /// Signs out: every record in the store goes, and the identifier with it.
    func clear() async {
        guard let saved = self.defaults.string(forKey: Self.identifierKey), let uuid = UUID(uuidString: saved) else { return }
        let store = WKWebsiteDataStore(forIdentifier: uuid)
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        try? await WKWebsiteDataStore.remove(forIdentifier: uuid)
        self.defaults.removeObject(forKey: Self.identifierKey)
        self.logger.info("[canvas-setup] session cleared")
    }
}
#endif
