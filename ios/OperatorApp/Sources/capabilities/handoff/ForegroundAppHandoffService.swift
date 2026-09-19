import Foundation
import OperatorCore
import OSLog

@MainActor
protocol AppHandoffOpener: AnyObject {
    func open(_ url: URL) async -> Bool
}

enum AppHandoffCatalog {
    private struct Entry: Decodable {
        let id: String
        let url: String?
        let verification: String?
    }
    enum InvalidCatalog: Error { case invalidDestination }

    static func decode(_ data: Data) throws -> [String: URL] {
        let entries = try JSONDecoder().decode([Entry].self, from: data)
        var result: [String: URL] = [:]
        var seen = Set<String>()
        for entry in entries {
            guard !entry.id.isEmpty, seen.insert(entry.id).inserted else { throw InvalidCatalog.invalidDestination }
            guard let raw = entry.url else {
                guard ["nativeHandled", "excluded"].contains(entry.verification) else { throw InvalidCatalog.invalidDestination }
                continue
            }
            guard let url = URL(string: raw), isSafeDestination(url) else { throw InvalidCatalog.invalidDestination }
            result[entry.id] = url
        }
        return result
    }

    static func isSafeDestination(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        return parts.scheme == "https" && !(parts.host ?? "").isEmpty
            && parts.user == nil && parts.password == nil && parts.port == nil
            && parts.query == nil && parts.fragment == nil
    }
}

@MainActor
final class ForegroundAppHandoffService: GatewayNodeCommandHandler {
    private let destinations: [String: URL]
    private let opener: any AppHandoffOpener
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "app-handoff")

    private let links: AppLinkTable
    private let launcher: (any InstalledAppLaunching)?
    private let lookup: (any AppBundleLookup)?

    init(destinations: [String: URL], opener: any AppHandoffOpener, isAppActive: @escaping @MainActor @Sendable () -> Bool,
         links: AppLinkTable = .empty, launcher: (any InstalledAppLaunching)? = nil, lookup: (any AppBundleLookup)? = nil) {
        self.destinations = destinations
        self.opener = opener
        self.isAppActive = isAppActive
        self.links = links
        self.launcher = launcher
        self.lookup = lookup
    }
    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        guard command == "apps.open" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let paramsJSON, paramsJSON.utf8.count <= 32768,
              let raw = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let params = raw as? [String: Any],
              Set(params.keys).isSubset(of: ["appID", "draft", "name"]),
              (params["appID"] == nil) != (params["name"] == nil),
              params["draft"] == nil || params["draft"] is String
        else {
            self.logger.info("[app-handoff] rejected invalid parameter shape")
            return .failure(code: "INVALID_REQUEST", message: "apps.open takes either name (an installed app) or appID (a listed website), and an optional draft; URLs are not accepted")
        }
        if params["name"] != nil {
            guard let name = (params["name"] as? String)?.trimmingCharacters(in: .whitespaces),
                  !name.isEmpty, name.utf8.count <= 100,
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else {
                self.logger.info("[app-handoff] rejected invalid app name")
                return .failure(code: "INVALID_REQUEST", message: "apps.open name must be one short line of text")
            }
            return await self.openInstalledApp(named: name)
        }
        guard let appID = params["appID"] as? String else {
            return .failure(code: "INVALID_REQUEST", message: "apps.open appID must be text")
        }
        // The model often puts an app's name in appID; anything that is not a
        // listed website is tried as an installed app.
        if self.destinations[appID] == nil, self.launcher != nil {
            let name = appID.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, name.utf8.count <= 100, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                return .failure(code: "INVALID_REQUEST", message: "apps.open name must be one short line of text")
            }
            self.logger.info("[app-handoff] appID is not a listed website; trying it as an app name")
            return await self.openInstalledApp(named: name)
        }
        // "gmail" is both a listed website and an app: the app itself comes
        // first, the website only when the app will not open.
        if self.launcher != nil, case .success = await self.openInstalledApp(named: appID) {
            return Self.appOpened
        }
        guard let url = self.destinations[appID], AppHandoffCatalog.isSafeDestination(url) else {
            self.logger.info("[app-handoff] rejected unavailable destination")
            return .failure(code: "APP_UNAVAILABLE", message: "This app has no supported website hand-off")
        }
        guard self.isAppActive() else {
            self.logger.info("[app-handoff] rejected while Operator inactive")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator before opening another app or website")
        }
        self.logger.info("[app-handoff] opening listed website; draft stays in chat")
        guard await self.opener.open(url) else {
            self.logger.error("[app-handoff] system refused website open")
            return .failure(code: "OPEN_FAILED", message: "The website could not be opened; nothing was completed")
        }
        self.logger.info("[app-handoff] website opened actionCompleted=false draftTransferred=false")
        return Self.websiteOpened
    }

    private func openInstalledApp(named name: String) async -> GatewayNodeCommandResult {
        guard let launcher = self.launcher else {
            return .failure(code: "APP_UNAVAILABLE", message: "Opening installed apps is not available")
        }
        guard self.isAppActive() else {
            self.logger.info("[app-handoff] rejected while Operator inactive")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator before opening another app or website")
        }
        let entry = self.links.match(name)
        self.logger.info("[app-handoff] open by name name_bytes=\(name.utf8.count) in_table=\(entry != nil) has_link=\(entry?.link != nil)")
        if let link = entry?.link, let url = URL(string: link), AppLinkTable.isAppLink(link) {
            if await launcher.openLink(url) {
                self.logger.info("[app-handoff] app opened branch=link")
                return Self.appOpened
            }
            self.logger.info("[app-handoff] link refused; trying bundle id")
        }
        var bundleID = entry?.bundleID
        if bundleID == nil {
            bundleID = await self.lookup?.bundleID(forName: name)
            self.logger.info("[app-handoff] looked up by name found=\(bundleID != nil)")
        }
        guard let bundleID, AppLinkTable.isBundleID(bundleID) else {
            return .failure(code: "APP_NOT_FOUND", message: "No app with that name was found")
        }
        // The lookup took a moment; the owner may have left Operator meanwhile.
        guard self.isAppActive() else {
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator before opening another app or website")
        }
        guard launcher.openBundle(bundleID) else {
            self.logger.error("[app-handoff] bundle launch refused bundle=\(bundleID, privacy: .public)")
            return .failure(code: "OPEN_FAILED", message: "The app did not open; it may not be installed on this iPhone")
        }
        self.logger.info("[app-handoff] app opened branch=bundle bundle=\(bundleID, privacy: .public)")
        return Self.appOpened
    }

    private static let appOpened = GatewayNodeCommandResult.success(payloadJSON: #"{"opened":true,"destinationKind":"app","actionCompleted":false,"draftTransferred":false,"nextStep":"The app was opened and nothing was done inside it. Operator cannot see or control it; the owner does the rest there."}"#)
    private static let websiteOpened = GatewayNodeCommandResult.success(payloadJSON: #"{"opened":true,"destinationKind":"website","actionCompleted":false,"draftTransferred":false,"nextStep":"Only the listed website was opened. Keep the prepared draft in chat. The owner must complete any action in the destination."}"#)
}
