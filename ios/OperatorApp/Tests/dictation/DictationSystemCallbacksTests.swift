import AVFAudio
import Speech
import XCTest
@testable import OperatorApp

/// iOS calls these from its own background threads. Each test does the same;
/// a callback that is secretly main-thread-only stops the process here, the
/// way it stopped the app on the phone.
final class DictationSystemCallbacksTests: XCTestCase {
    func testTheAudioTapRunsOffTheMainThread() async throws {
        let request = SFSpeechAudioBufferRecognitionRequest()
        let tap = DictationSystemCallbacks.tap(feeding: request)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        buffer.frameLength = 1_024

        let ran = self.expectation(description: "tap ran on a background thread")
        nonisolated(unsafe) let unsafeTap = tap
        nonisolated(unsafe) let unsafeBuffer = buffer
        DispatchQueue.global().async {
            XCTAssertFalse(Thread.isMainThread)
            unsafeTap(unsafeBuffer, AVAudioTime(hostTime: 0))
            ran.fulfill()
        }
        await self.fulfillment(of: [ran], timeout: 5)
    }

    func testARecognitionErrorReachesTheMainThreadAsPlainValues() async {
        let delivered = self.expectation(description: "update delivered")
        let handler = DictationSystemCallbacks.recognitionHandler { update in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(update, DictationRecognitionUpdate(transcript: nil, isFinal: false, failed: true))
            delivered.fulfill()
        }
        DispatchQueue.global().async {
            handler(nil, NSError(domain: "test", code: 1))
        }
        await self.fulfillment(of: [delivered], timeout: 5)
    }
}
