import Foundation
import OperatorCore
import OSLog

@MainActor
protocol MessageComposePresenter: AnyObject {
    var isAvailable: Bool { get }
    func present(recipients: [String], body: String) -> Bool
}

@MainActor
final class ForegroundMessageComposeService: GatewayNodeCommandHandler {
    private struct Parameters {
        let recipients: [String]
        let body: String
    }

    private let presenter: any MessageComposePresenter
    private let isAppActive: @MainActor @Sendable () -> Bool
    private let logger = Logger(subsystem: "app.operator.ios", category: "message-compose")

    init(
        presenter: any MessageComposePresenter,
        isAppActive: @escaping @MainActor @Sendable () -> Bool)
    {
        self.presenter = presenter
        self.isAppActive = isAppActive
    }

    func handleNodeCommand(
        _ command: String,
        paramsJSON: String?,
        timeoutMilliseconds _: Int?) async -> GatewayNodeCommandResult
    {
        guard command == "sms.compose" else {
            return .failure(code: "UNSUPPORTED_COMMAND", message: "This iPhone node does not support \(command)")
        }
        guard let parameters = Self.parameters(from: paramsJSON) else {
            self.logger.info("[message-compose] rejected invalid request shape")
            return .failure(code: "INVALID_REQUEST", message: "sms.compose requires only nonempty recipients and body")
        }
        guard self.isAppActive() else {
            self.logger.info("[message-compose] rejected while app inactive recipients=\(parameters.recipients.count)")
            return .failure(code: "APP_NOT_ACTIVE", message: "Open Operator to compose a message")
        }
        guard self.presenter.isAvailable else {
            self.logger.info("[message-compose] messaging unavailable recipients=\(parameters.recipients.count)")
            return .failure(code: "MESSAGING_UNAVAILABLE", message: "Text message composition is unavailable on this iPhone")
        }
        guard self.presenter.present(recipients: parameters.recipients, body: parameters.body) else {
            self.logger.info("[message-compose] presentation unavailable recipients=\(parameters.recipients.count)")
            return .failure(code: "PRESENTATION_UNAVAILABLE", message: "Operator could not present the message composer")
        }
        self.logger.info("[message-compose] presented system composer recipients=\(parameters.recipients.count) requiresUserSend=true")
        return .success(payloadJSON: #"{"deliveryVerified":false,"presented":true,"requiresUserSend":true,"sent":false}"#)
    }

    private static func parameters(from paramsJSON: String?) -> Parameters? {
        guard let paramsJSON,
              let value = try? JSONSerialization.jsonObject(with: Data(paramsJSON.utf8)),
              let object = value as? [String: Any],
              Set(object.keys) == ["recipients", "body"],
              let rawRecipients = object["recipients"] as? [Any],
              !rawRecipients.isEmpty,
              rawRecipients.allSatisfy({ $0 is String }),
              let body = object["body"] as? String,
              !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return nil }

        let recipients = rawRecipients
            .compactMap { $0 as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard recipients.allSatisfy({ !$0.isEmpty }) else { return nil }
        return Parameters(recipients: recipients, body: body)
    }
}
