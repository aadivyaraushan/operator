import AVFAudio
import Speech

/// What one recognition callback said, as plain values that can cross to the
/// main thread. The Speech result object itself cannot.
struct DictationRecognitionUpdate: Equatable, Sendable {
    let transcript: String?
    let isFinal: Bool
    let failed: Bool
}

/// The callbacks iOS runs on its own threads: the two permission prompts, the
/// audio tap and the recognition result. They are built here, outside any
/// main-thread-only type, on purpose. A closure written inside a `@MainActor`
/// type is treated as main-thread-only too, and Swift 6 stops the app when
/// iOS then calls it from a background thread. That crashed the app the
/// first time the speech prompt was answered.
enum DictationSystemCallbacks {
    static func speechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let status = SFSpeechRecognizer.authorizationStatus()
        guard status == .notDetermined else { return status }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { @Sendable status in
                continuation.resume(returning: status)
            }
        }
    }

    static func microphonePermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { @Sendable granted in
                    continuation.resume(returning: granted)
                }
            }
        case .granted:
            return true
        default:
            return false
        }
    }

    /// Runs on the audio thread for every buffer the microphone produces.
    static func tap(feeding request: SFSpeechAudioBufferRecognitionRequest) -> AVAudioNodeTapBlock {
        { [weak request] buffer, _ in
            request?.append(buffer)
        }
    }

    /// Runs on a Speech queue. Reads what it needs from the result there, then
    /// hands plain values to the main thread.
    static func recognitionHandler(
        deliver: @escaping @MainActor @Sendable (DictationRecognitionUpdate) -> Void
    ) -> @Sendable (SFSpeechRecognitionResult?, (any Error)?) -> Void {
        { result, error in
            let update = DictationRecognitionUpdate(
                transcript: result?.bestTranscription.formattedString,
                isFinal: result?.isFinal == true,
                failed: error != nil)
            Task { @MainActor in deliver(update) }
        }
    }
}
