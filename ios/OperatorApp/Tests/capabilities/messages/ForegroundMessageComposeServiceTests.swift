import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundMessageComposeServiceTests: XCTestCase {
    func testPresentsExactRecipientsAndBodyAndReportsNotSent() async throws {
        let presenter = RecordingMessageComposePresenter()
        let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { true })

        let result = await service.handleNodeCommand(
            "sms.compose",
            paramsJSON: #"{"recipients":["  +1 217 555 0100  ","person@example.com"],"body":"  Keep body spacing.  "}"#,
            timeoutMilliseconds: nil)

        XCTAssertEqual(presenter.presentedRecipients, ["+1 217 555 0100", "person@example.com"])
        XCTAssertEqual(presenter.presentedBody, "  Keep body spacing.  ")
        XCTAssertEqual(try payload(result), [
            "deliveryVerified": false,
            "presented": true,
            "requiresUserSend": true,
            "sent": false,
        ])
    }

    func testRejectsWrongCommandWithoutPresentation() async {
        let presenter = RecordingMessageComposePresenter()
        let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { true })

        let result = await service.handleNodeCommand("sms.send", paramsJSON: validParams, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support sms.send"))
        XCTAssertEqual(presenter.presentationCount, 0)
    }

    func testRejectsEveryInvalidParameterShapeWithoutPresentation() async {
        let invalid: [String?] = [
            nil,
            "",
            "not-json",
            "[]",
            "{}",
            #"{"recipients":[],"body":"Hello"}"#,
            #"{"recipients":"+12175550100","body":"Hello"}"#,
            #"{"recipients":[1],"body":"Hello"}"#,
            #"{"recipients":["   "],"body":"Hello"}"#,
            #"{"recipients":["+12175550100"],"body":""}"#,
            #"{"recipients":["+12175550100"],"body":"   "}"#,
            #"{"recipients":["+12175550100"],"body":1}"#,
            #"{"recipients":["+12175550100"],"body":"Hello","subject":"No"}"#,
        ]
        for paramsJSON in invalid {
            let presenter = RecordingMessageComposePresenter()
            let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { true })

            let result = await service.handleNodeCommand("sms.compose", paramsJSON: paramsJSON, timeoutMilliseconds: nil)

            XCTAssertEqual(result, .failure(code: "INVALID_REQUEST", message: "sms.compose requires only nonempty recipients and body"), "params=\(String(describing: paramsJSON))")
            XCTAssertEqual(presenter.presentationCount, 0)
        }
    }

    func testInactiveAppDoesNotCheckAvailabilityOrPresent() async {
        let presenter = RecordingMessageComposePresenter()
        let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { false })

        let result = await service.handleNodeCommand("sms.compose", paramsJSON: validParams, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to compose a message"))
        XCTAssertEqual(presenter.availabilityChecks, 0)
        XCTAssertEqual(presenter.presentationCount, 0)
    }

    func testUnavailableMessagingDoesNotPresent() async {
        let presenter = RecordingMessageComposePresenter(isAvailable: false)
        let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { true })

        let result = await service.handleNodeCommand("sms.compose", paramsJSON: validParams, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "MESSAGING_UNAVAILABLE", message: "Text message composition is unavailable on this iPhone"))
        XCTAssertEqual(presenter.presentationCount, 0)
    }

    func testBusyOrFailedPresentationReportsUnavailable() async {
        let presenter = RecordingMessageComposePresenter(presentationResult: false)
        let service = ForegroundMessageComposeService(presenter: presenter, isAppActive: { true })

        let result = await service.handleNodeCommand("sms.compose", paramsJSON: validParams, timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "PRESENTATION_UNAVAILABLE", message: "Operator could not present the message composer"))
        XCTAssertEqual(presenter.presentationCount, 1)
    }

    private var validParams: String { #"{"recipients":["+12175550100"],"body":"Hello"}"# }

    private func payload(_ result: GatewayNodeCommandResult) throws -> [String: Bool] {
        guard case let .success(payloadJSON) = result else { throw NSError(domain: "test", code: 1) }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payloadJSON.utf8)) as? [String: Bool])
    }
}

@MainActor
final class ForegroundNodeCommandRouterMessageTests: XCTestCase {
    func testComposeForwardsOnlyToMessagesWithUnchangedParameters() async {
        let location = RecordingNodeCommandHandler()
        let calendar = RecordingNodeCommandHandler()
        let messages = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"presented":true}"#))
        let maps = RecordingNodeCommandHandler()
        let router = ForegroundNodeCommandRouter(location: location, calendar: calendar, messages: messages, maps: maps, handoff: RecordingNodeCommandHandler(), whatsapp: RecordingNodeCommandHandler(), whatsappCompose: RecordingNodeCommandHandler(), accounts: RecordingNodeCommandHandler(), accountWrite: RecordingNodeCommandHandler(), notion: RecordingNodeCommandHandler())
        let params = #"{"recipients":[" +12175550100 "],"body":" Exact body "}"#

        let result = await router.handleNodeCommand("sms.compose", paramsJSON: params, timeoutMilliseconds: 12_345)

        XCTAssertEqual(result, .success(payloadJSON: #"{"presented":true}"#))
        XCTAssertEqual(messages.invocations, [.init(command: "sms.compose", paramsJSON: params, timeoutMilliseconds: 12_345)])
        XCTAssertTrue(location.invocations.isEmpty)
        XCTAssertTrue(calendar.invocations.isEmpty)
        XCTAssertTrue(maps.invocations.isEmpty)
    }

    func testExistingLocationAndCalendarRoutesRemainSeparate() async {
        let location = RecordingNodeCommandHandler()
        let calendar = RecordingNodeCommandHandler()
        let messages = RecordingNodeCommandHandler()
        let maps = RecordingNodeCommandHandler()
        let router = ForegroundNodeCommandRouter(location: location, calendar: calendar, messages: messages, maps: maps, handoff: RecordingNodeCommandHandler(), whatsapp: RecordingNodeCommandHandler(), whatsappCompose: RecordingNodeCommandHandler(), accounts: RecordingNodeCommandHandler(), accountWrite: RecordingNodeCommandHandler(), notion: RecordingNodeCommandHandler())

        _ = await router.handleNodeCommand("location.get", paramsJSON: #"{"desiredAccuracy":"precise"}"#, timeoutMilliseconds: 1_000)
        _ = await router.handleNodeCommand("calendar.events", paramsJSON: "{}", timeoutMilliseconds: 2_000)

        XCTAssertEqual(location.invocations, [.init(command: "location.get", paramsJSON: #"{"desiredAccuracy":"precise"}"#, timeoutMilliseconds: 1_000)])
        XCTAssertEqual(calendar.invocations, [.init(command: "calendar.events", paramsJSON: "{}", timeoutMilliseconds: 2_000)])
        XCTAssertTrue(messages.invocations.isEmpty)
        XCTAssertTrue(maps.invocations.isEmpty)
    }

    func testSmsSendNeverCallsAHandler() async {
        let location = RecordingNodeCommandHandler()
        let calendar = RecordingNodeCommandHandler()
        let messages = RecordingNodeCommandHandler()
        let maps = RecordingNodeCommandHandler()
        let router = ForegroundNodeCommandRouter(location: location, calendar: calendar, messages: messages, maps: maps, handoff: RecordingNodeCommandHandler(), whatsapp: RecordingNodeCommandHandler(), whatsappCompose: RecordingNodeCommandHandler(), accounts: RecordingNodeCommandHandler(), accountWrite: RecordingNodeCommandHandler(), notion: RecordingNodeCommandHandler())

        let result = await router.handleNodeCommand("sms.send", paramsJSON: "{}", timeoutMilliseconds: nil)

        XCTAssertEqual(result, .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support sms.send"))
        XCTAssertTrue(location.invocations.isEmpty)
        XCTAssertTrue(calendar.invocations.isEmpty)
        XCTAssertTrue(messages.invocations.isEmpty)
        XCTAssertTrue(maps.invocations.isEmpty)
    }

    func testWhatsAppReadCommandsForwardOnlyToWhatsAppHandler() async {
        let other = RecordingNodeCommandHandler()
        let whatsapp = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"chats":[]}"#))
        let router = ForegroundNodeCommandRouter(
            location: other, calendar: other, messages: other, maps: other,
            handoff: other, whatsapp: whatsapp, whatsappCompose: other, accounts: other, accountWrite: other, notion: other)

        for command in ["whatsapp.chats", "whatsapp.messages", "whatsapp.sync"] {
            _ = await router.handleNodeCommand(command, paramsJSON: #"{"limit":4}"#, timeoutMilliseconds: 9_000)
        }

        XCTAssertEqual(whatsapp.invocations.map(\.command), ["whatsapp.chats", "whatsapp.messages", "whatsapp.sync"])
        XCTAssertTrue(other.invocations.isEmpty)
    }

    func testWhatsAppComposeForwardsOnlyToComposeHandler() async {
        let other = RecordingNodeCommandHandler()
        let compose = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"sent":true}"#))
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: other, whatsapp: other, whatsappCompose: compose, accounts: other, accountWrite: other, notion: other)
        let params = #"{"recipientJID":"123@s.whatsapp.net","body":"hello"}"#
        let result = await router.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 4_000)
        XCTAssertEqual(result, .success(payloadJSON: #"{"sent":true}"#))
        XCTAssertEqual(compose.invocations, [.init(command: "whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 4_000)])
        XCTAssertTrue(other.invocations.isEmpty)
    }

    func testConnectionsReadForwardsOnlyToAccountsHandler() async {
        let other = RecordingNodeCommandHandler()
        let accounts = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"page":[]}"#))
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: other, whatsapp: other, whatsappCompose: other, accounts: accounts, accountWrite: other, notion: other)

        _ = await router.handleNodeCommand("connections.read", paramsJSON: #"{"operation":"spotifyPlayback","limit":1}"#, timeoutMilliseconds: 5_000)

        XCTAssertEqual(accounts.invocations.map(\.command), ["connections.read"])
        XCTAssertTrue(other.invocations.isEmpty)
    }

    func testConnectionsWriteForwardsOnlyToAccountWriteHandler() async {
        let other = RecordingNodeCommandHandler()
        let writer = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"ok":true}"#))
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: other, whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: writer, notion: other)
        let params = #"{"operation":"slackPostMessage","channelID":"C123","text":"hello"}"#
        _ = await router.handleNodeCommand("connections.write", paramsJSON: params, timeoutMilliseconds: 5_000)
        XCTAssertEqual(writer.invocations, [.init(command: "connections.write", paramsJSON: params, timeoutMilliseconds: 5_000)])
        XCTAssertTrue(other.invocations.isEmpty)
    }

    func testNotionCommandsForwardOnlyToNotionHandler() async {
        let other = RecordingNodeCommandHandler()
        let notion = RecordingNodeCommandHandler(result: .success(payloadJSON: #"{"tools":[]}"#))
        let router = ForegroundNodeCommandRouter(location: other, calendar: other, messages: other, maps: other, handoff: other, whatsapp: other, whatsappCompose: other, accounts: other, accountWrite: other, notion: notion)
        for command in ["notion.tools", "notion.call"] { _ = await router.handleNodeCommand(command, paramsJSON: "{}", timeoutMilliseconds: 8_000) }
        XCTAssertEqual(notion.invocations.map(\.command), ["notion.tools", "notion.call"])
        XCTAssertTrue(other.invocations.isEmpty)
    }
}

private struct RecordedNodeInvocation: Equatable {
    let command: String
    let paramsJSON: String?
    let timeoutMilliseconds: Int?
}

@MainActor
private final class RecordingNodeCommandHandler: GatewayNodeCommandHandler {
    let result: GatewayNodeCommandResult
    private(set) var invocations: [RecordedNodeInvocation] = []

    init(result: GatewayNodeCommandResult = .success(payloadJSON: "{}")) {
        self.result = result
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult
    {
        self.invocations.append(.init(
            command: command,
            paramsJSON: paramsJSON,
            timeoutMilliseconds: timeoutMilliseconds))
        return self.result
    }
}

@MainActor
private final class RecordingMessageComposePresenter: MessageComposePresenter {
    private let available: Bool
    private let presentationResult: Bool
    private(set) var availabilityChecks = 0
    private(set) var presentationCount = 0
    private(set) var presentedRecipients: [String]?
    private(set) var presentedBody: String?

    init(isAvailable: Bool = true, presentationResult: Bool = true) {
        self.available = isAvailable
        self.presentationResult = presentationResult
    }

    var isAvailable: Bool {
        self.availabilityChecks += 1
        return self.available
    }

    func present(recipients: [String], body: String) -> Bool {
        self.presentationCount += 1
        self.presentedRecipients = recipients
        self.presentedBody = body
        return self.presentationResult
    }
}
