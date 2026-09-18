import Foundation
import XCTest
@testable import OperatorCore

final class ConnectorPermissionsTests: XCTestCase {
    /// Representative payloads for the commands whose connector depends on the
    /// payload. Every other registered command resolves from its name alone.
    private static let representativeParams: [String: String] = [
        "connections.read": #"{"operation":"googleCalendarEvents"}"#,
        "connections.write": #"{"operation":"slackPostMessage","channelID":"C1","text":"hi"}"#,
        "notion.call": #"{"name":"notion-search","arguments":{}}"#,
    ]

    func testEveryRegisteredCommandIsGovernedByExactlyOneConnector() {
        for command in GatewayNativeNodeSurface.commands {
            let requirement = ConnectorCatalog.requirement(for: command, paramsJSON: Self.representativeParams[command])
            XCTAssertNotNil(requirement, "\(command) is registered with the gateway but no connector governs it, so the permission gate would deny it forever")
        }
        for descriptor in ConnectorCatalog.all {
            for command in descriptor.readCommands + descriptor.writeCommands {
                XCTAssertTrue(GatewayNativeNodeSurface.commands.contains(command), "\(descriptor.id) lists \(command), which the node never registers")
            }
        }
        XCTAssertEqual(Set(ConnectorCatalog.all.map(\.id)), Set(ConnectorID.allCases), "every connector needs a row on the Permissions page")
        XCTAssertEqual(Set(ConnectorCatalog.all.map(\.title)).count, ConnectorCatalog.all.count, "titles must be distinct")
        for descriptor in ConnectorCatalog.all {
            XCTAssertEqual(descriptor.hasReads, descriptor.readSummary != nil, "\(descriptor.id): a read toggle needs a summary and vice versa")
            XCTAssertEqual(descriptor.hasWrites, descriptor.writeSummary != nil, "\(descriptor.id): a write toggle needs a summary and vice versa")
        }
    }

    func testAFreshInstallPermitsNothingExceptOperatorMetadata() {
        let grants = ConnectorGrants.none
        XCTAssertTrue(grants.isEmpty)
        for command in GatewayNativeNodeSurface.commands where command != "connections.describe" {
            guard case .denied = grants.decision(for: command, paramsJSON: Self.representativeParams[command]) else {
                return XCTFail("\(command) should be denied before the owner allows anything")
            }
        }
        XCTAssertEqual(grants.decision(for: "connections.describe", paramsJSON: nil), .allowed(nil, nil))
        XCTAssertEqual(grants.decision(for: "not.a.command", paramsJSON: nil), .unknownCommand)
        XCTAssertEqual(GatewayNodeAgentTools.descriptors(permittedBy: grants), [], "the model is offered no tools until something is granted")
    }

    func testWriteImpliesReadAndRevokingReadRevokesWrite() {
        var grants = ConnectorGrants.none
        grants.set(.google, .write, allowed: true)
        XCTAssertTrue(grants.isGranted(.google, .read))
        XCTAssertTrue(grants.isGranted(.google, .write))
        grants.set(.google, .write, allowed: false)
        XCTAssertTrue(grants.isGranted(.google, .read))
        XCTAssertFalse(grants.isGranted(.google, .write))
        grants.set(.google, .write, allowed: true)
        grants.set(.google, .read, allowed: false)
        XCTAssertFalse(grants.isGranted(.google, .read))
        XCTAssertFalse(grants.isGranted(.google, .write))
        XCTAssertTrue(grants.isEmpty)
    }

    func testReadOnlySwitchBlocksEveryWriteWithoutForgettingTheGrant() {
        var grants = ConnectorGrants.none
        grants.set(.messages, .write, allowed: true)
        grants.set(.reminders, .read, allowed: true)
        grants.readOnly = true
        XCTAssertEqual(grants.decision(for: "sms.compose", paramsJSON: nil), .denied(.messages, .write))
        XCTAssertEqual(grants.decision(for: "reminders.list", paramsJSON: nil), .allowed(.reminders, .read))
        XCTAssertTrue(grants.isGranted(.messages, .write), "the switch hides the grant; it does not delete it")
        grants.readOnly = false
        XCTAssertEqual(grants.decision(for: "sms.compose", paramsJSON: nil), .allowed(.messages, .write))
    }

    func testPublishedToolsFollowReadGrants() {
        var grants = ConnectorGrants.none
        grants.set(.reminders, .read, allowed: true)
        grants.set(.music, .read, allowed: true)
        XCTAssertEqual(
            GatewayNodeAgentTools.descriptors(permittedBy: grants).map(\.name),
            ["reminders_list", "music_now_playing", "music_search"])
        grants.set(.messages, .write, allowed: true)
        let published = GatewayNodeAgentTools.descriptors(permittedBy: grants).map(\.name)
        XCTAssertEqual(published, ["reminders_list", "music_now_playing", "music_search", "messages_incoming"], "a write grant carries the read grant, so the texts feed appears; the compose write itself is never a tool")
        XCTAssertFalse(published.contains { $0.hasPrefix("sms_") }, "writes are never published as tools, granted or not")
    }

    func testAccountCommandsResolveToTheProviderNamedInTheOperation() {
        let reads: [(String, ConnectorID)] = [
            ("googleCalendarEvents", .google), ("googleDriveFiles", .google), ("googleDriveFileContent", .google), ("gmailMessages", .google), ("googleTasks", .googleTasks),
            ("outlookInbox", .microsoft), ("outlookCalendarEvents", .outlookCalendar),
            ("slackChannels", .slack), ("slackHistory", .slack),
            ("spotifySearch", .spotify), ("spotifyPlayback", .spotify),
        ]
        for (operation, provider) in reads {
            XCTAssertEqual(
                ConnectorCatalog.requirement(for: "connections.read", paramsJSON: #"{"operation":"\#(operation)"}"#),
                .access(provider, .read), operation)
        }
        let writes: [(String, ConnectorID)] = [
            ("googleCalendarCreateEvent", .google), ("googleCalendarUpdateEvent", .google), ("googleDriveCreateTextFile", .google),
            ("googleSheetsAppendRows", .google), ("googleDocsReplaceText", .google), ("googleSlidesAddSlide", .google), ("googleDriveMoveFile", .google),
            ("googleTasksCreateTask", .googleTasks), ("googleTasksUpdateTask", .googleTasks),
            ("outlookCreateDraft", .microsoft), ("outlookSendMail", .microsoft),
            ("outlookCalendarCreateEvent", .outlookCalendar), ("outlookCalendarUpdateEvent", .outlookCalendar),
            ("slackPostMessage", .slack), ("spotifyStartPlayback", .spotify),
        ]
        for (operation, provider) in writes {
            XCTAssertEqual(
                ConnectorCatalog.requirement(for: "connections.write", paramsJSON: #"{"operation":"\#(operation)"}"#),
                .access(provider, .write), operation)
        }
        XCTAssertNil(ConnectorCatalog.requirement(for: "connections.read", paramsJSON: #"{"operation":"dropboxFiles"}"#))
        XCTAssertNil(ConnectorCatalog.requirement(for: "connections.read", paramsJSON: nil))
        XCTAssertNil(ConnectorCatalog.requirement(for: "connections.read", paramsJSON: "not json"))
    }

    func testNotionSplitsByToolNameAndTreatsUnknownToolsAsWrites() {
        XCTAssertEqual(ConnectorCatalog.requirement(for: "notion.tools", paramsJSON: nil), .access(.notion, .read))
        XCTAssertEqual(ConnectorCatalog.requirement(for: "notion.call", paramsJSON: #"{"name":"notion-fetch","arguments":{}}"#), .access(.notion, .read))
        XCTAssertEqual(ConnectorCatalog.requirement(for: "notion.call", paramsJSON: #"{"name":"notion-create-pages","arguments":{}}"#), .access(.notion, .write))
        XCTAssertEqual(ConnectorCatalog.requirement(for: "notion.call", paramsJSON: #"{"name":"notion-something-new","arguments":{}}"#), .access(.notion, .write))
        XCTAssertNil(ConnectorCatalog.requirement(for: "notion.call", paramsJSON: #"{"arguments":{}}"#))
    }

    func testOnlyTheUnofficialClientsCarryAnAcknowledgementAndEachIsComplete() {
        for descriptor in ConnectorCatalog.all {
            switch descriptor.id {
            case .whatsapp:
                let ack = descriptor.writeAcknowledgement
                XCTAssertNotNil(ack, "sending through an unofficial client must be acknowledged")
                XCTAssertTrue(ack!.title.lowercased().contains("banned"))
                XCTAssertGreaterThanOrEqual(ack!.statements.count, 3)
                XCTAssertTrue(ack!.paragraphs.joined().contains("unofficial client"))
                XCTAssertNil(descriptor.readAcknowledgement, "WhatsApp reads were judged lower risk")
            case .discord:
                let ack = descriptor.readAcknowledgement
                XCTAssertNotNil(ack, "reading with the owner's login is a self-bot in Discord's terms")
                XCTAssertTrue(ack!.title.lowercased().contains("banned"))
                XCTAssertGreaterThanOrEqual(ack!.statements.count, 3)
                XCTAssertTrue(ack!.paragraphs.joined().contains("second account"))
                XCTAssertNil(descriptor.writeAcknowledgement)
                XCTAssertFalse(descriptor.hasWrites, "Discord is read-only by design")
                XCTAssertEqual(descriptor.acknowledgement(for: .read), ack)
                XCTAssertNil(descriptor.acknowledgement(for: .write))
            default:
                XCTAssertNil(descriptor.writeAcknowledgement, "\(descriptor.id) has no account at stake")
                XCTAssertNil(descriptor.readAcknowledgement, "\(descriptor.id) has no account at stake")
            }
        }
    }

    func testGrantsSurviveEncoding() throws {
        var grants = ConnectorGrants(readOnly: true)
        grants.set(.contacts, .read, allowed: true)
        grants.set(.slack, .write, allowed: true)
        let data = try JSONEncoder().encode(grants)
        let decoded = try JSONDecoder().decode(ConnectorGrants.self, from: data)
        XCTAssertEqual(decoded, grants)
        XCTAssertTrue(decoded.readOnly)
        XCTAssertTrue(decoded.isGranted(.slack, .write))
    }
}
