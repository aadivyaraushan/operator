import AVFAudio
import Combine
import OSLog
import Speech

enum OfflineDictationEvent: Equatable {
    case transcript(String)
    case finished
    case unavailable(String)
}

enum OfflineDictationState: Equatable {
    case idle
    case requestingPermission
    case recording
    case unavailable(String)
}

@MainActor
protocol OfflineDictationService: AnyObject {
    func start(eventHandler: @escaping @MainActor (OfflineDictationEvent) -> Void) async throws
    func stop()
}

@MainActor
final class OfflineDictationModel: ObservableObject {
    @Published private(set) var state: OfflineDictationState = .idle

    private let service: any OfflineDictationService
    private var draftBeforeTranscript = ""
    private var lastRenderedDraft = ""

    init(service: any OfflineDictationService) {
        self.service = service
    }

    func start(draft: String, updateDraft: @escaping @MainActor (String) -> Void) {
        guard self.state != .recording, self.state != .requestingPermission else { return }

        self.draftBeforeTranscript = draft
        self.lastRenderedDraft = draft
        self.state = .requestingPermission
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.service.start { [weak self] event in
                    self?.handle(event, updateDraft: updateDraft)
                }
                if self.state == .requestingPermission {
                    self.state = .recording
                }
            } catch {
                self.state = .unavailable(Self.message(for: error))
            }
        }
    }

    func noteDraftChanged(_ draft: String) {
        guard self.state == .recording, draft != self.lastRenderedDraft else { return }
        self.draftBeforeTranscript = draft
    }

    func stop() {
        self.service.stop()
        self.state = .idle
    }

    private func handle(
        _ event: OfflineDictationEvent,
        updateDraft: @escaping @MainActor (String) -> Void
    ) {
        switch event {
        case let .transcript(text):
            // Words that arrive after the mic was turned off are dropped.
            guard self.state == .recording || self.state == .requestingPermission else { return }
            guard !text.isEmpty else { return }
            let separator = self.draftBeforeTranscript.isEmpty ? "" : " "
            let updatedDraft = self.draftBeforeTranscript + separator + text
            self.lastRenderedDraft = updatedDraft
            updateDraft(updatedDraft)
        case .finished:
            self.state = .idle
        case let .unavailable(message):
            self.state = .unavailable(message)
        }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? OfflineDictationError {
            return error.message
        }
        return "On-device dictation could not start. Try again."
    }
}

enum OfflineDictationError: Error {
    case speechPermissionDenied
    case microphonePermissionDenied
    case onDeviceRecognitionUnavailable
    case microphoneUnavailable

    var message: String {
        switch self {
        case .speechPermissionDenied:
            "Allow Speech Recognition to use on-device dictation."
        case .microphonePermissionDenied:
            "Allow Microphone access to use on-device dictation."
        case .onDeviceRecognitionUnavailable:
            "On-device speech recognition is unavailable for this language."
        case .microphoneUnavailable:
            "The microphone could not start. Try again."
        }
    }
}

@MainActor
final class AppleOnDeviceDictationService: NSObject, OfflineDictationService {
    private let audioEngine = AVAudioEngine()
    private let audioSession = AVAudioSession.sharedInstance()
    private let recognizer = SFSpeechRecognizer()
    private let logger = Logger(subsystem: "app.operator.ios", category: "dictation")
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var eventHandler: (@MainActor (OfflineDictationEvent) -> Void)?

    func start(eventHandler: @escaping @MainActor (OfflineDictationEvent) -> Void) async throws {
        guard self.task == nil else { return }
        guard await DictationSystemCallbacks.speechAuthorization() == .authorized else {
            self.logger.info("[dictation] not started: speech recognition not allowed")
            throw OfflineDictationError.speechPermissionDenied
        }
        guard await DictationSystemCallbacks.microphonePermission() else {
            self.logger.info("[dictation] not started: microphone not allowed")
            throw OfflineDictationError.microphonePermissionDenied
        }
        guard let recognizer = self.recognizer,
              recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition
        else {
            self.logger.info("[dictation] not started: recognizer available=\(self.recognizer?.isAvailable ?? false) onDevice=\(self.recognizer?.supportsOnDeviceRecognition ?? false) locale=\(self.recognizer?.locale.identifier ?? "none", privacy: .public)")
            throw OfflineDictationError.onDeviceRecognitionUnavailable
        }

        self.eventHandler = eventHandler
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = true
        self.request = request

        do {
            try self.audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try self.audioSession.setActive(true, options: .notifyOthersOnDeactivation)
            let input = self.audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            input.installTap(
                onBus: 0, bufferSize: 1_024, format: format,
                block: DictationSystemCallbacks.tap(feeding: request))
            self.audioEngine.prepare()
            try self.audioEngine.start()
            self.task = recognizer.recognitionTask(
                with: request,
                resultHandler: DictationSystemCallbacks.recognitionHandler { [weak self] update in
                    self?.handle(update)
                })
            self.logger.info("[dictation] on-device recording started")
        } catch {
            self.logger.error("[dictation] audio could not start errorType=\(String(reflecting: type(of: error)), privacy: .public)")
            self.stop()
            throw OfflineDictationError.microphoneUnavailable
        }
    }

    func stop() {
        self.request?.endAudio()
        self.task?.cancel()
        self.tearDownAudio()
        self.eventHandler = nil
        self.logger.info("[dictation] recording stopped")
    }

    private func handle(_ update: DictationRecognitionUpdate) {
        if let transcript = update.transcript, !transcript.isEmpty {
            self.eventHandler?(.transcript(transcript))
        }
        if update.failed {
            let eventHandler = self.eventHandler
            self.tearDownAudio()
            self.eventHandler = nil
            eventHandler?(.unavailable("On-device dictation stopped unexpectedly."))
            self.logger.error("[dictation] recognition stopped with an error")
        } else if update.isFinal {
            let eventHandler = self.eventHandler
            self.tearDownAudio()
            self.eventHandler = nil
            eventHandler?(.finished)
            self.logger.info("[dictation] recognition finished")
        }
    }

    private func tearDownAudio() {
        self.audioEngine.stop()
        self.audioEngine.inputNode.removeTap(onBus: 0)
        self.request = nil
        self.task = nil
        try? self.audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        // Hand the session back in the shape the app's sounds need; left on
        // "record" they would play silently.
        try? self.audioSession.setCategory(.ambient, options: .mixWithOthers)
    }
}
