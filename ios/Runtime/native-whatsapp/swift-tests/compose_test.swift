import Foundation
import OperatorCore

@MainActor
private final class Presenter: WhatsAppComposePresenter {
    var decision: WhatsAppComposeDecision = .denied
    var requests: [WhatsAppComposeRequest] = []
    var cancels = 0
    func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision {
        requests.append(request)
        return decision
    }
    func cancel() { cancels += 1 }
}

private actor Sender: WhatsAppTextSending {
    var result: Result<NativeWhatsAppSendResult, Error> = .success(.init(outcome: "sent", messageId: "ack"))
    var calls: [WhatsAppComposeRequest] = []
    func send(_ request: WhatsAppComposeRequest, timeoutMilliseconds: Int) async throws -> NativeWhatsAppSendResult {
        calls.append(request)
        return try result.get()
    }
    func count() -> Int { calls.count }
}

@main
struct ComposeTests {
    static func main() async throws {
        let watchdog = Task {
            try await Task.sleep(for: .seconds(2))
            preconditionFailure("Confirmation timeout did not release the presenter")
        }
        try await deniedAndInactiveDoNotSend()
        try await alteredConfirmationDoesNotSend()
        try await confirmedSendsExactlyOnce()
        try await unknownIsNotClaimedSentOrFailed()
        try await timeoutCancelsAndDoesNotSend()
        watchdog.cancel()
        print("NATIVE_WHATSAPP_COMPOSE_SWIFT_PASS")
    }

    @MainActor static func deniedAndInactiveDoNotSend() async throws {
        let presenter = Presenter(); let sender = Sender()
        let denied = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { true })
        let deniedResult = await denied.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 1_000)
        precondition(deniedResult == .failure(code: "OWNER_DENIED", message: "WhatsApp message was not sent"))
        let countAfterDeny = await sender.count()
        precondition(countAfterDeny == 0)
        let inactive = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { false })
        _ = await inactive.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 1_000)
        let countAfterInactive = await sender.count()
        precondition(countAfterInactive == 0 && presenter.requests.count == 1)
    }

    @MainActor static func alteredConfirmationDoesNotSend() async throws {
        let presenter = Presenter(); let sender = Sender()
        presenter.decision = .confirmed(.init(recipientJID: "999@s.whatsapp.net", body: "changed"))
        let service = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { true })
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 1_000)
        precondition(result == .failure(code: "CONFIRMATION_MISMATCH", message: "WhatsApp message was not sent"))
        let count = await sender.count()
        precondition(count == 0)
    }

    @MainActor static func confirmedSendsExactlyOnce() async throws {
        let presenter = Presenter(); let sender = Sender()
        let request = WhatsAppComposeRequest(recipientJID: "12175550100@s.whatsapp.net", body: " exact body ")
        presenter.decision = .confirmed(request)
        let service = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { true })
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 1_000)
        let count = await sender.count()
        precondition(count == 1)
        guard case let .success(payload) = result else { preconditionFailure("expected sent") }
        precondition(payload.contains(#""outcome":"sent""#))
    }

    @MainActor static func unknownIsNotClaimedSentOrFailed() async throws {
        let presenter = Presenter(); let sender = Sender()
        presenter.decision = .confirmed(.init(recipientJID: "12175550100@s.whatsapp.net", body: " exact body "))
        await sender.setResult(.success(.init(outcome: "unknown", messageId: nil)))
        let service = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { true })
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 1_000)
        guard case let .success(payload) = result else { preconditionFailure("unknown is a successful, honest outcome") }
        precondition(payload.contains(#""outcome":"unknown""#) && !payload.contains(#""outcome":"sent""#) && !payload.contains(#""failed""#))
    }

    @MainActor static func timeoutCancelsAndDoesNotSend() async throws {
        let presenter = HangingPresenter(); let sender = Sender()
        let service = ForegroundWhatsAppComposeService(presenter: presenter, sender: sender, isAppActive: { true })
        let result = await service.handleNodeCommand("whatsapp.compose", paramsJSON: params, timeoutMilliseconds: 10)
        precondition(result == .failure(code: "TIMEOUT", message: "WhatsApp confirmation timed out"))
        let count = await sender.count()
        precondition(count == 0 && presenter.cancels == 1)
    }

    static let params = #"{"recipientJID":"12175550100@s.whatsapp.net","body":" exact body "}"#
}

private extension Sender { func setResult(_ value: Result<NativeWhatsAppSendResult, Error>) { result = value } }

@MainActor
private final class HangingPresenter: WhatsAppComposePresenter {
    var cancels = 0
    private var pending: CheckedContinuation<WhatsAppComposeDecision, Never>?
    func confirm(_ request: WhatsAppComposeRequest) async -> WhatsAppComposeDecision {
        await withCheckedContinuation { pending = $0 }
    }
    func cancel() { cancels += 1; let saved = pending; pending = nil; saved?.resume(returning: .denied) }
}
