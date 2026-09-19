import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class ForegroundContactCreateServiceTests: XCTestCase {
    private final class Directory: ContactDirectory {
        var access: ContactsAccess = .full
        var existingByPhone: [String: ContactMatch] = [:]
        var existingByEmail: [String: ContactMatch] = [:]
        var created: [ContactDraft] = []
        var failSave = false
        func requestAccess() async -> Bool { self.access = .full; return true }
        func search(query: String, limit: Int) async -> [ContactMatch] { [] }
        func existing(phoneNumber: String) async -> ContactMatch? { self.existingByPhone[phoneNumber] }
        func existing(emailAddress: String) async -> ContactMatch? { self.existingByEmail[emailAddress] }
        func create(_ draft: ContactDraft) async throws -> String {
            if self.failSave { throw ContactDirectoryError.saveFailed }
            self.created.append(draft)
            return draft.displayName
        }
    }

    private final class Presenter: ContactCreatePresenter {
        var decision: ContactCreateDecision = .denied
        var shown: [ContactDraft] = []
        var cancelled = 0
        func confirm(_ draft: ContactDraft) async -> ContactCreateDecision { self.shown.append(draft); return self.decision }
        func cancel() { self.cancelled += 1 }
    }

    private func service(_ directory: Directory, _ presenter: Presenter, active: Bool = true) -> ForegroundContactCreateService {
        ForegroundContactCreateService(directory: directory, presenter: presenter, isAppActive: { active })
    }

    func testSavesOnlyWhatTheOwnerSawAndConfirmed() async throws {
        let directory = Directory()
        let presenter = Presenter()
        presenter.decision = .confirmed(ContactDraft(givenName: "Opp", familyName: "No 2", phoneNumbers: ["+1 647 612 0342"], emailAddresses: []))
        let result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: #"{"name":"  Opp No 2 ","phones":["+1 647 612 0342","+1 647 612 0342"]}"#, timeoutMilliseconds: 5_000)
        guard case let .success(payload) = result else { return XCTFail("\(result)") }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(object["saved"] as? Bool, true)
        XCTAssertEqual(object["name"] as? String, "Opp No 2")
        XCTAssertEqual(presenter.shown.map(\.displayName), ["Opp No 2"], "the owner sees the exact contact")
        XCTAssertEqual(directory.created, [ContactDraft(givenName: "Opp", familyName: "No 2", phoneNumbers: ["+1 647 612 0342"], emailAddresses: [])], "first word given, rest family, duplicates collapsed")
    }

    func testANumberOrEmailAlreadySavedIsRefusedBeforeTheOwnerIsAsked() async {
        let directory = Directory()
        directory.existingByPhone["+1 555 0100"] = ContactMatch(displayName: "Mom", phoneNumbers: ["+1 555 0100"], emailAddresses: [])
        directory.existingByEmail["a@b.c"] = ContactMatch(displayName: "Alex", phoneNumbers: [], emailAddresses: ["a@b.c"])
        let presenter = Presenter()
        presenter.decision = .confirmed(ContactDraft(givenName: "X", familyName: "", phoneNumbers: ["+1 555 0100"], emailAddresses: []))
        for params in [#"{"name":"X","phones":["+1 555 0100"]}"#, #"{"name":"X","emails":["a@b.c"]}"#] {
            let result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
            guard case let .failure(code, message) = result else { return XCTFail(params) }
            XCTAssertEqual(code, "ALREADY_EXISTS")
            XCTAssertTrue(message.contains("Mom") || message.contains("Alex"), message)
        }
        XCTAssertTrue(presenter.shown.isEmpty)
        XCTAssertTrue(directory.created.isEmpty)
    }

    func testDeniedMismatchedInactiveAndFailedSavesNeverWrite() async {
        let directory = Directory()
        let presenter = Presenter()
        let params = #"{"name":"Villa","emails":["villa@example.com"]}"#

        presenter.decision = .denied
        var result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
        guard case let .failure(denied, _) = result else { return XCTFail() }
        XCTAssertEqual(denied, "OWNER_DENIED")

        presenter.decision = .confirmed(ContactDraft(givenName: "Someone", familyName: "Else", phoneNumbers: [], emailAddresses: ["x@y.z"]))
        result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
        guard case let .failure(mismatch, _) = result else { return XCTFail() }
        XCTAssertEqual(mismatch, "CONFIRMATION_MISMATCH")
        XCTAssertEqual(presenter.cancelled, 1)

        result = await self.service(directory, presenter, active: false).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
        guard case let .failure(inactive, _) = result else { return XCTFail() }
        XCTAssertEqual(inactive, "APP_NOT_ACTIVE")

        directory.access = .denied
        result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
        guard case let .failure(permission, _) = result else { return XCTFail() }
        XCTAssertEqual(permission, "PERMISSION_DENIED")

        directory.access = .full
        directory.failSave = true
        presenter.decision = .confirmed(ContactDraft(givenName: "Villa", familyName: "", phoneNumbers: [], emailAddresses: ["villa@example.com"]))
        result = await self.service(directory, presenter).handleNodeCommand("contacts.create", paramsJSON: params, timeoutMilliseconds: nil)
        guard case let .failure(save, _) = result else { return XCTFail() }
        XCTAssertEqual(save, "SAVE_FAILED")
        XCTAssertTrue(directory.created.isEmpty)
    }

    func testTheDraftIsBoundedAndNeedsANameAndAHandle() {
        XCTAssertNil(ForegroundContactCreateService.draft(from: nil))
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"Villa"}"#), "a name alone is not a contact")
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"","phones":["1"]}"#))
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"V","phones":["1","2","3","4"]}"#), "at most three")
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"V","emails":["not an email"]}"#))
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"V","phones":["1"],"note":"x"}"#), "no other fields")
        XCTAssertNil(ForegroundContactCreateService.draft(from: #"{"name":"\#(String(repeating: "n", count: 101))","phones":["1"]}"#))
        let draft = ForegroundContactCreateService.draft(from: #"{"name":"Ada Lovelace King","phones":["+44 20 7946 0958"],"emails":["ada@example.com"]}"#)
        XCTAssertEqual(draft, ContactDraft(givenName: "Ada", familyName: "Lovelace King", phoneNumbers: ["+44 20 7946 0958"], emailAddresses: ["ada@example.com"]))
    }

    func testTheCatalogGatesCreateBehindTheContactsWriteGrantWithNoWarning() {
        let contacts = ConnectorCatalog.descriptor(.contacts)
        XCTAssertEqual(contacts.writeCommands, ["contacts.create"])
        XCTAssertNil(contacts.writeAcknowledgement)
        XCTAssertEqual(ConnectorCatalog.requirement(for: "contacts.create", paramsJSON: nil), .access(.contacts, .write))
        XCTAssertTrue(GatewayNativeNodeSurface.commands.contains("contacts.create"))
        XCTAssertTrue(GatewayNativeNodeSurface.commandPolicyAllow.contains("contacts.create"))
        XCTAssertFalse(GatewayNodeAgentTools.descriptors.contains { $0.command == "contacts.create" }, "a write is never a tool the model reaches for on its own")
    }
}
