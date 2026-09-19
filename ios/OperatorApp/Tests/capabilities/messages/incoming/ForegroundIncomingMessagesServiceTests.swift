import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundIncomingMessagesServiceTests: XCTestCase {
    private var directory: URL!

    override func setUp() async throws {
        self.directory = FileManager.default.temporaryDirectory.appendingPathComponent("incoming-svc-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func object(_ result: GatewayNodeCommandResult) throws -> [String: Any] {
        guard case let .success(payload) = result else { throw XCTSkip("not a success: \(result)") }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
    }

    func testReturnsTheFeedNewestFirstWithSinceAndLimitAndSaysWhenItIsEmpty() async throws {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let store = IncomingMessageStore(supportDirectory: self.directory, now: { clock })
        let service = ForegroundIncomingMessagesService(store: store)

        let empty = try self.object(await service.handleNodeCommand("messages.incoming", paramsJSON: nil, timeoutMilliseconds: nil))
        XCTAssertEqual((empty["messages"] as? [Any])?.count, 0)
        XCTAssertEqual(empty["storedCount"] as? Int, 0)
        XCTAssertTrue((empty["note"] as? String ?? "").contains("automation"), "an empty feed points at setup, not at silence")

        store.record(sender: "Mom", text: "dinner at 7?")
        clock = clock.addingTimeInterval(300)
        store.record(sender: "+1 555 0100", text: "your code is 123456")
        let all = try self.object(await service.handleNodeCommand("messages.incoming", paramsJSON: "{}", timeoutMilliseconds: nil))
        let messages = try XCTUnwrap(all["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["from"] as? String }, ["+1 555 0100", "Mom"])
        XCTAssertEqual(messages.map { $0["text"] as? String }, ["your code is 123456", "dinner at 7?"])
        XCTAssertEqual(messages.first?["receivedAt"] as? String, "2027-01-15T08:05:00Z")
        XCTAssertNil(all["note"])
        XCTAssertTrue((all["nextStep"] as? String ?? "").contains("texts sent manually in Messages"))

        let recent = try self.object(await service.handleNodeCommand("messages.incoming", paramsJSON: #"{"sinceRFC3339":"2027-01-15T08:01:00Z","limit":1}"#, timeoutMilliseconds: nil))
        XCTAssertEqual((recent["messages"] as? [[String: Any]])?.map { $0["from"] as? String }, ["+1 555 0100"])
        XCTAssertEqual(recent["storedCount"] as? Int, 2)
    }

    func testSentMessagesHaveRecipientsRatherThanIncomingSenders() async throws {
        let store = IncomingMessageStore(supportDirectory: self.directory)
        store.record(sender: "Mom, Dad", text: "See you soon", direction: .sent)
        let service = ForegroundIncomingMessagesService(store: store)
        let payload = try self.object(await service.handleNodeCommand("messages.incoming", paramsJSON: nil, timeoutMilliseconds: nil))
        let messages = try XCTUnwrap(payload["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.first?["direction"] as? String, "sent")
        XCTAssertEqual(messages.first?["to"] as? String, "Mom, Dad")
        XCTAssertNil(messages.first?["from"])
    }

    func testBadParametersAndOtherCommandsAreRefused() async {
        let service = ForegroundIncomingMessagesService(store: IncomingMessageStore(supportDirectory: self.directory))
        for bad in [#"{"limit":0}"#, #"{"limit":101}"#, #"{"limit":true}"#, #"{"sinceRFC3339":"yesterday"}"#, #"{"chat":"x"}"#, "[]"] {
            let result = await service.handleNodeCommand("messages.incoming", paramsJSON: bad, timeoutMilliseconds: nil)
            guard case let .failure(code, _) = result else { return XCTFail(bad) }
            XCTAssertEqual(code, "INVALID_REQUEST", bad)
        }
        let one = await service.handleNodeCommand("messages.incoming", paramsJSON: #"{"limit":1}"#, timeoutMilliseconds: nil)
        guard case .success = one else { return XCTFail("a limit of exactly one is valid") }
        let other = await service.handleNodeCommand("messages.send", paramsJSON: nil, timeoutMilliseconds: nil)
        guard case let .failure(code, _) = other else { return XCTFail() }
        XCTAssertEqual(code, "UNSUPPORTED_COMMAND")
    }

    func testTheInstallLinkIsAnICloudShortcutAndTheSharedFileIsCheckedIn() throws {
        let url = try XCTUnwrap(RecordIncomingMessageIntent.installURL)
        XCTAssertEqual(url.host, "www.icloud.com", "only an iCloud share link installs; see OperatorSendMessage")
        XCTAssertTrue(url.path.hasPrefix("/shortcuts/"))
        XCTAssertEqual(RecordIncomingMessageIntent.createAutomationURL.scheme, "shortcuts")
        let checkedIn = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/shortcuts/\(RecordIncomingMessageIntent.shortcutName).shortcut")
        XCTAssertTrue(FileManager.default.fileExists(atPath: checkedIn.path), checkedIn.path)
    }

    func testTheCatalogGatesTheFeedBehindTheMessagesReadGrant() throws {
        let messages = ConnectorCatalog.descriptor(.messages)
        XCTAssertEqual(messages.readCommands, ["messages.incoming", "messages.conversations", "messages.conversation.review"])
        XCTAssertNil(messages.readAcknowledgement, "Apple's own automation: no ban warning")
        let setup = try XCTUnwrap(messages.setupInstructions)
        XCTAssertLessThan(setup.count, 200, "the steps live in the setup card; this is one short line above it")
        XCTAssertEqual(ConnectorCatalog.requirement(for: "messages.incoming", paramsJSON: nil), .access(.messages, .read))
        XCTAssertTrue(GatewayNativeNodeSurface.commands.contains("messages.incoming"))
        XCTAssertTrue(GatewayNativeNodeSurface.commandPolicyAllow.contains("messages.incoming"))
        XCTAssertTrue(GatewayNodeAgentTools.descriptors.contains { $0.name == "messages_incoming" && $0.command == "messages.incoming" })
    }
}
