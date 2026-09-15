import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ConnectorPermissionCenterTests: XCTestCase {
    private final class MemoryStore: ConnectorGrantStore, @unchecked Sendable {
        var grants: ConnectorGrants?
        var onboarding = false
        var saves = 0
        func loadGrants() -> ConnectorGrants? { self.grants }
        func saveGrants(_ grants: ConnectorGrants) { self.grants = grants; self.saves += 1 }
        func loadOnboardingComplete() -> Bool { self.onboarding }
        func saveOnboardingComplete(_ complete: Bool) { self.onboarding = complete }
    }

    @MainActor private final class RecordingHandler: GatewayNodeCommandHandler {
        var commands: [String] = []
        func handleNodeCommand(_ command: String, paramsJSON: String?, timeoutMilliseconds: Int?) async -> GatewayNodeCommandResult {
            self.commands.append(command)
            return .success(payloadJSON: #"{"ok":true}"#)
        }
    }

    func testADeniedCommandNeverReachesTheRouterAndBecomesThePendingRequest() async throws {
        let store = MemoryStore()
        let center = ConnectorPermissionCenter(store: store)
        let inner = RecordingHandler()
        let guarded = PermissionGuardedNodeCommandHandler(center: center, next: inner)

        let result = await guarded.handleNodeCommand("reminders.list", paramsJSON: nil, timeoutMilliseconds: nil)

        guard case let .failure(code, message) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(code, "PERMISSION_DENIED")
        XCTAssertTrue(message.contains("Reminders"))
        XCTAssertTrue(message.contains("Do not retry"))
        XCTAssertEqual(inner.commands, [])
        XCTAssertEqual(center.pendingRequest, ConnectorGrantRequest(connector: .reminders, access: .read, command: "reminders.list"))
        XCTAssertEqual(center.activity.map(\.outcome), [.denied])
        XCTAssertEqual(center.publishedTools, [])
    }

    func testAllowingThePendingRequestGrantsPersistsRepublishesAndClearsIt() async throws {
        let store = MemoryStore()
        let center = ConnectorPermissionCenter(store: store)
        var republished = 0
        center.grantsDidChange = { republished += 1 }
        let inner = RecordingHandler()
        let guarded = PermissionGuardedNodeCommandHandler(center: center, next: inner)
        _ = await guarded.handleNodeCommand("contacts.search", paramsJSON: #"{"query":"Mom"}"#, timeoutMilliseconds: nil)

        center.allowPendingRequest()

        XCTAssertNil(center.pendingRequest)
        XCTAssertTrue(center.isGranted(.contacts, .read))
        XCTAssertEqual(store.grants?.isGranted(.contacts, .read), true, "grants persist")
        XCTAssertEqual(republished, 1)
        XCTAssertEqual(center.publishedTools.map(\.name), ["contacts_search"])

        let result = await guarded.handleNodeCommand("contacts.search", paramsJSON: #"{"query":"Mom"}"#, timeoutMilliseconds: nil)
        guard case .success = result else { return XCTFail("expected the call to pass through once granted") }
        XCTAssertEqual(inner.commands, ["contacts.search"])
        XCTAssertEqual(center.activity.first?.outcome, .ran)
    }

    func testGrantsAreRestoredFromTheStoreAndOperatorMetadataIsNeverGated() async throws {
        let store = MemoryStore()
        var saved = ConnectorGrants.none
        saved.set(.device, .read, allowed: true)
        store.grants = saved
        let center = ConnectorPermissionCenter(store: store)
        let inner = RecordingHandler()
        let guarded = PermissionGuardedNodeCommandHandler(center: center, next: inner)

        _ = await guarded.handleNodeCommand("device.status", paramsJSON: nil, timeoutMilliseconds: nil)
        _ = await guarded.handleNodeCommand("connections.describe", paramsJSON: nil, timeoutMilliseconds: nil)

        XCTAssertEqual(inner.commands, ["device.status", "connections.describe"])
        XCTAssertEqual(center.activity.map(\.command), ["device.status"], "metadata calls are not personal data and are not logged as reads")
        XCTAssertNil(center.pendingRequest)
    }

    func testReadOnlyBlocksAGrantedWriteAndTheRequestNamesTheWrite() async throws {
        let store = MemoryStore()
        let center = ConnectorPermissionCenter(store: store)
        center.set(.messages, .write, allowed: true)
        center.setReadOnly(true)
        let inner = RecordingHandler()
        let guarded = PermissionGuardedNodeCommandHandler(center: center, next: inner)

        let result = await guarded.handleNodeCommand("sms.compose", paramsJSON: #"{"recipients":["+1"],"body":"hi"}"#, timeoutMilliseconds: nil)

        guard case let .failure(code, _) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(code, "PERMISSION_DENIED")
        XCTAssertEqual(inner.commands, [])
        XCTAssertEqual(center.pendingRequest?.access, .write)
        XCTAssertTrue(center.isGranted(.messages, .write), "the switch hides the grant; it does not delete it")
    }

    func testAnUnknownCommandIsRefusedAsUnsupportedNotAsAPermissionAsk() async throws {
        let center = ConnectorPermissionCenter(store: MemoryStore())
        let inner = RecordingHandler()
        let guarded = PermissionGuardedNodeCommandHandler(center: center, next: inner)

        let result = await guarded.handleNodeCommand("shell.exec", paramsJSON: nil, timeoutMilliseconds: nil)

        guard case let .failure(code, _) = result else { return XCTFail("expected a refusal") }
        XCTAssertEqual(code, "UNSUPPORTED_COMMAND")
        XCTAssertNil(center.pendingRequest)
        XCTAssertEqual(inner.commands, [])
    }

    func testOnboardingCompletionPersistsAndTheActivityLogIsBounded() async throws {
        let store = MemoryStore()
        let center = ConnectorPermissionCenter(store: store)
        XCTAssertFalse(center.hasCompletedOnboarding)
        center.completeOnboarding()
        XCTAssertTrue(ConnectorPermissionCenter(store: store).hasCompletedOnboarding)

        center.set(.device, .read, allowed: true)
        for _ in 0..<(ConnectorPermissionCenter.activityLimit + 20) {
            _ = center.authorize("device.status", paramsJSON: nil)
        }
        XCTAssertEqual(center.activity.count, ConnectorPermissionCenter.activityLimit)
    }
}
