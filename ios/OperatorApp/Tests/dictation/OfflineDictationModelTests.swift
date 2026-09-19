import XCTest
@testable import OperatorApp

@MainActor
final class OfflineDictationModelTests: XCTestCase {
    func testTranscriptAppendsToExistingEditableDraft() async throws {
        let dictation = RecordingDictationService()
        let model = OfflineDictationModel(service: dictation)
        var draft = "Keep this note"

        model.start(draft: draft) { draft = $0 }
        await waitUntil { dictation.didStart }
        dictation.emit(.transcript("and add this"))

        XCTAssertEqual(draft, "Keep this note and add this")
        XCTAssertEqual(model.state, .recording)
    }

    func testUnavailableDictationPreservesDraftAndExplainsWhy() async throws {
        let dictation = RecordingDictationService()
        let model = OfflineDictationModel(service: dictation)
        var draft = "Do not lose this"

        model.start(draft: draft) { draft = $0 }
        await waitUntil { dictation.didStart }
        dictation.emit(.unavailable("On-device speech recognition is unavailable."))

        XCTAssertEqual(draft, "Do not lose this")
        XCTAssertEqual(model.state, .unavailable("On-device speech recognition is unavailable."))
    }

    func testStopStopsAudioAndReturnsToIdle() async throws {
        let dictation = RecordingDictationService()
        let model = OfflineDictationModel(service: dictation)

        model.start(draft: "") { _ in }
        await waitUntil { dictation.didStart }
        model.stop()

        XCTAssertTrue(dictation.didStop)
        XCTAssertEqual(model.state, .idle)
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
private final class RecordingDictationService: OfflineDictationService {
    private var eventHandler: (@MainActor (OfflineDictationEvent) -> Void)?
    var didStart = false
    var didStop = false

    func start(eventHandler: @escaping @MainActor (OfflineDictationEvent) -> Void) async throws {
        self.eventHandler = eventHandler
        self.didStart = true
    }

    func stop() {
        self.didStop = true
    }

    func emit(_ event: OfflineDictationEvent) {
        self.eventHandler?(event)
    }
}
