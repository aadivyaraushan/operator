import Foundation

struct ModelSetupConfiguration: Equatable, Sendable {
    let hasConfiguredModel: Bool
}

struct ModelSetupWizardDeviceCode: Decodable, Equatable, Sendable {
    let code: String
    let expiresInMinutes: Int?
    let message: String?
}

struct ModelSetupWizardStep: Decodable, Equatable, Sendable {
    let id: String
    let type: String
    let title: String?
    let message: String?
    let executor: String?
    let externalURL: URL?
    let deviceCode: ModelSetupWizardDeviceCode?

    private enum CodingKeys: String, CodingKey {
        case id
        case type
        case title
        case message
        case executor
        case externalURL = "externalUrl"
        case deviceCode
    }
}

struct ModelSetupActivation: Decodable, Equatable, Sendable {
    let modelRef: String
    let gatewayRestartRequired: Bool?
}

struct ModelSetupWizardResult: Decodable, Equatable, Sendable {
    let sessionID: String?
    let done: Bool
    let step: ModelSetupWizardStep?
    let status: String?
    let error: String?
    let modelActivation: ModelSetupActivation?

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case done
        case step
        case status
        case error
        case modelActivation
    }
}

protocol ModelSetupGateway: Sendable {
    func configuration() async throws -> ModelSetupConfiguration
    func startDeviceCode(sessionID: String) async throws -> ModelSetupWizardResult
    func next(sessionID: String, answeringStepID: String?) async throws -> ModelSetupWizardResult
    func verifyActivation(_ activation: ModelSetupActivation) async throws
    func cancel(sessionID: String) async
    func disconnect() async
}

enum ModelSetupState: Equatable {
    case checking
    case needsSignIn
    case starting
    case awaitingAuthorization(ModelSetupWizardStep)
    case restarting
    case ready
    case unavailable
    case failed(String)
}
