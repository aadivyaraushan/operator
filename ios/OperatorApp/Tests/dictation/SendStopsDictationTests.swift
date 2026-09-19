import XCTest
@testable import OperatorApp

@MainActor
final class SendStopsDictationTests: XCTestCase {
    func testSendingTurnsTheMicOff() async throws {
        let service = ListeningDictationService()
        let model = ChatSessionModel(
            store: RecordingPersistence(),
            gateway: RuntimeGateGateway(),
            dictation: OfflineDictationModel(service: service))

        model.startDictation()
        await waitUntil { model.dictation.state == .recording }
        service.emit(.transcript("book a table"))
        model.send()

        XCTAssertTrue(service.didStop)
        XCTAssertEqual(model.dictation.state, .idle)
    }

    func testWordsHeardAfterSendingDoNotRefillTheDraft() async throws {
        let service = ListeningDictationService()
        let model = ChatSessionModel(
            store: RecordingPersistence(),
            gateway: RuntimeGateGateway(),
            dictation: OfflineDictationModel(service: service))

        model.startDictation()
        await waitUntil { model.dictation.state == .recording }
        service.emit(.transcript("book a table"))
        model.send()
        service.emit(.transcript("book a table for two"))

        XCTAssertEqual(model.draft, "")
    }

    private func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end {
            await Task.yield()
        }
    }
}

@MainActor
private final class ListeningDictationService: OfflineDictationService {
    private var eventHandler: (@MainActor (OfflineDictationEvent) -> Void)?
    var didStop = false

    func start(eventHandler: @escaping @MainActor (OfflineDictationEvent) -> Void) async throws {
        self.eventHandler = eventHandler
    }

    func stop() { self.didStop = true }

    func emit(_ event: OfflineDictationEvent) { self.eventHandler?(event) }
}
