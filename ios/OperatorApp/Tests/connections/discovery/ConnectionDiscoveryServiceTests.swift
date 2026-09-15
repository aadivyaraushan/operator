import Foundation
import XCTest
@testable import OperatorApp
import OperatorCore

final class ConnectionDiscoveryServiceTests: XCTestCase {
    @MainActor
    func testDescribeUsesLiveSurfaceOperationsAndCatalog() async throws {
        let catalog = Data(#"[{"id":"spotify","url":"https://open.spotify.com/","verification":"webOpenedOfficial"},{"id":"messages","verification":"nativeHandled"},{"id":"discord","verification":"excluded"}]"#.utf8)
        let service = ForegroundConnectionDiscoveryService(
            catalogData: catalog,
            setup: { [
                .init(provider: "google", state: .needsSetup, registrationAvailable: false),
                .init(provider: "notion", state: .connected, registrationAvailable: true),
            ] })

        let result = await service.handleNodeCommand(
            "connections.describe", paramsJSON: "{}", timeoutMilliseconds: 1_000)
        let object = try successObject(result)

        XCTAssertEqual(Set(object["commands"] as? [String] ?? []), Set(GatewayNativeNodeSurface.commands))
        XCTAssertEqual(object["appHandoffIDs"] as? [String], ["spotify"])
        let account = try XCTUnwrap(object["accountOperations"] as? [String: Any])
        XCTAssertEqual(Set(account["read"] as? [String] ?? []), Set([
            "googleCalendarEvents", "googleDriveFiles", "gmailMessages", "googleTasks",
            "outlookInbox", "outlookCalendarEvents", "slackChannels",
            "slackHistory", "spotifySearch", "spotifyPlayback",
        ]))
        XCTAssertEqual(Set(account["write"] as? [String] ?? []), Set(AccountWriteOperation.allCases.map(\.rawValue)))
        XCTAssertEqual(account["readParameters"] as? [String: [String]], [
            "googleCalendarEvents": ["timeMin", "timeMax", "limit", "query?", "cursor?"],
            "googleDriveFiles": ["query", "limit", "cursor?"],
            "gmailMessages": ["limit", "query?", "cursor?"],
            "googleTasks": ["limit", "channel?", "cursor?"],
            "outlookInbox": ["limit", "query?", "cursor?"],
            "outlookCalendarEvents": ["timeMin", "timeMax", "limit", "cursor?"],
            "slackChannels": ["limit", "cursor?"],
            "slackHistory": ["channel", "limit", "cursor?"],
            "spotifySearch": ["query", "limit", "cursor?"],
            "spotifyPlayback": ["limit", "cursor?"],
        ])

        let details = try XCTUnwrap(object["commandDetails"] as? [[String: Any]])
        let names = Set(details.compactMap { $0["name"] as? String })
        XCTAssertTrue(["maps.search", "maps.directions", "apps.open", "whatsapp.messages",
                       "whatsapp.compose", "connections.read", "connections.write",
                       "notion.tools", "notion.call"].allSatisfy(names.contains))
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: object).count, 48_000)
    }

    @MainActor
    func testRequiresExactlyEmptyObjectAndNeverCallsOutsideProcess() async throws {
        let service = ForegroundConnectionDiscoveryService(catalogData: Data("[]".utf8), setup: { [] })
        for params in [nil, "", "null", "[]", #"{"extra":true}"#, "not-json"] as [String?] {
            let result = await service.handleNodeCommand(
                "connections.describe", paramsJSON: params, timeoutMilliseconds: 1_000)
            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "connections.describe requires exactly {}"))
        }
        let unsupported = await service.handleNodeCommand(
            "not.describe", paramsJSON: "{}", timeoutMilliseconds: nil)
        XCTAssertEqual(
            unsupported,
            .failure(code: "UNSUPPORTED_COMMAND", message: "Unsupported connection discovery command"))
    }

    @MainActor
    func testSetupOutputContainsOnlySafeProviderAndStateLabels() async throws {
        let service = ForegroundConnectionDiscoveryService(
            catalogData: Data("[]".utf8),
            setup: { [
                .init(provider: "google", state: .connected, registrationAvailable: false),
                .init(provider: "microsoftOutlook", state: .idle, registrationAvailable: true),
                .init(provider: "slack", state: .failed, registrationAvailable: true),
                .init(provider: "spotify", state: .connected, registrationAvailable: true),
                .init(provider: "notion", state: .authorizing, registrationAvailable: true),
                .init(provider: "whatsapp", state: .notChecked, registrationAvailable: true),
            ] })
        let object = try successObject(await service.handleNodeCommand(
            "connections.describe", paramsJSON: "{}", timeoutMilliseconds: nil))
        let encoded = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("token"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("clientID"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("accountID"))
        let setup = try XCTUnwrap(object["setup"] as? [[String: String]])
        XCTAssertEqual(setup.first(where: { $0["provider"] == "google" })?["state"], "needsSetup")
        XCTAssertEqual(setup.first(where: { $0["provider"] == "whatsapp" })?["state"], "notChecked")
        XCTAssertTrue((object["connectionStateNote"] as? String)?.contains("do not prove") == true)
    }

    @MainActor
    func testRouterSendsDescribeOnlyToDiscoveryHandler() async {
        let other = DiscoveryRecordingHandler()
        let discovery = DiscoveryRecordingHandler()
        let router = ForegroundNodeCommandRouter(
            location: other, calendar: other, messages: other, maps: other, handoff: other,
            whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: other,
            discovery: discovery, notion: other)
        _ = await router.handleNodeCommand("connections.describe", paramsJSON: "{}", timeoutMilliseconds: 500)
        XCTAssertEqual(discovery.commands, ["connections.describe"])
        XCTAssertEqual(other.commands, [])
    }

    private func successObject(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(payloadJSON) = result else {
            XCTFail("Expected success, got \(result)")
            return [:]
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Any])
    }
}

@MainActor
private final class DiscoveryRecordingHandler: GatewayNodeCommandHandler {
    var commands: [String] = []
    func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
        commands.append(command)
        return .success(payloadJSON: "{}")
    }
}
