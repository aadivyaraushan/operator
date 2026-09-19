import Foundation
import OperatorCore
import XCTest
@testable import OperatorApp

@MainActor
final class CustomMessageSendTests: XCTestCase {
    func testCustomModeSendsThePersonsWordsNotTheModels() async throws {
        let parts = self.parts(mode: .custom)
        async let result = parts.service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"Mom","body":"model draft"}"#, timeoutMilliseconds: nil)
        await self.waitUntil { parts.prompt.pending != nil }
        XCTAssertEqual(parts.prompt.pending?.recipients, ["Mom"])
        XCTAssertTrue(parts.runner.opens.isEmpty, "nothing goes to Shortcuts before the person has written")
        parts.prompt.submit("  my own words ")

        guard case let .success(payload) = await result else { return XCTFail("expected success") }
        XCTAssertEqual(try self.sentInput(parts.runner)["body"] as? String, "my own words")
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(reply["sent"] as? Bool, true)
        XCTAssertEqual(reply["writtenByPerson"] as? Bool, true)
        XCTAssertEqual(reply["body"] as? String, "my own words")
        XCTAssertEqual(parts.store.messages(limit: 1).first?.text, "my own words")
        XCTAssertNil(parts.prompt.pending)
    }

    func testDecliningToWriteSendsNothing() async throws {
        let parts = self.parts(mode: .custom)
        async let result = parts.service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"Mom","body":"model draft"}"#, timeoutMilliseconds: nil)
        await self.waitUntil { parts.prompt.pending != nil }
        parts.prompt.decline()

        guard case let .success(payload) = await result else { return XCTFail("expected success") }
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        XCTAssertEqual(reply["sent"] as? Bool, false)
        XCTAssertEqual(reply["outcome"] as? String, "declined")
        XCTAssertTrue(parts.runner.opens.isEmpty)
        XCTAssertEqual(parts.store.count, 0)
    }

    func testAnEmptyMessageCannotBeSubmitted() async {
        let parts = self.parts(mode: .custom)
        async let result = parts.service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"Mom","body":"x"}"#, timeoutMilliseconds: nil)
        await self.waitUntil { parts.prompt.pending != nil }
        parts.prompt.submit("   ")
        XCTAssertNotNil(parts.prompt.pending, "still waiting for real words")
        parts.prompt.decline()
        _ = await result
    }

    func testAutoModeSendsTheModelsWordsWithoutAsking() async throws {
        let parts = self.parts(mode: .auto)
        _ = await parts.service.handleNodeCommand("sms.send", paramsJSON: #"{"recipient":"Mom","body":"model draft"}"#, timeoutMilliseconds: nil)
        XCTAssertNil(parts.prompt.pending)
        XCTAssertEqual(try self.sentInput(parts.runner)["body"] as? String, "model draft")
    }

    func testASecondRequestWhileOneIsOpenIsTurnedAway() async {
        let prompt = CustomMessagePrompt()
        async let first = prompt.write(to: ["Mom"])
        await self.waitUntil { prompt.pending != nil }
        let second = await prompt.write(to: ["Dad"])
        XCTAssertNil(second)
        XCTAssertEqual(prompt.pending?.recipients, ["Mom"])
        prompt.decline()
        _ = await first
    }

    func testModeDefaultsToCustomAndIsRemembered() {
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        XCTAssertEqual(UserDefaultsMessageWriteModeStore(defaults: defaults).load(), .custom)
        UserDefaultsMessageWriteModeStore(defaults: defaults).save(.auto)
        XCTAssertEqual(UserDefaultsMessageWriteModeStore(defaults: defaults).load(), .auto)
    }

    // MARK: helpers

    private struct Parts {
        let service: ForegroundMessageSendService
        let prompt: CustomMessagePrompt
        let runner: AnsweringRunner
        let store: IncomingMessageStore
    }

    private func parts(mode: MessageWriteMode) -> Parts {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let runner = AnsweringRunner()
        let coordinator = ShortcutSendCoordinator(runner: runner, timeout: .milliseconds(500))
        runner.coordinator = coordinator
        let prompt = CustomMessagePrompt()
        let store = IncomingMessageStore(supportDirectory: directory)
        let service = ForegroundMessageSendService(
            store: store, coordinator: coordinator, isAppActive: { true },
            writeMode: { mode }, customPrompt: prompt)
        return Parts(service: service, prompt: prompt, runner: runner, store: store)
    }

    private func sentInput(_ runner: AnsweringRunner) throws -> [String: Any] {
        let url = try XCTUnwrap(runner.opens.first)
        let text = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "text" }?.value)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func waitUntil(timeout: TimeInterval = 1, condition: @escaping @MainActor () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { await Task.yield() }
    }
}

/// Opens every URL and reports success straight back, as Shortcuts would.
@MainActor
private final class AnsweringRunner: ShortcutRunner {
    var opens: [URL] = []
    weak var coordinator: ShortcutSendCoordinator?
    func run(_ url: URL) async -> Bool {
        self.opens.append(url)
        Task { @MainActor in self.coordinator?.resolve(.success) }
        return true
    }
}
