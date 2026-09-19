import CryptoKit
import Foundation
import OSLog

public protocol CredentialDataStore: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public struct GatewayInstallationCredentials: Codable, Equatable, Sendable {
    public let identity: GatewayDeviceIdentity
    public let instanceID: String
    public let gatewayToken: String

    public init(identity: GatewayDeviceIdentity, instanceID: String, gatewayToken: String) {
        self.identity = identity
        self.instanceID = instanceID
        self.gatewayToken = gatewayToken
    }
}

public enum GatewayInstallationVaultError: Error, Equatable, Sendable {
    case corruptCredentials
}

public actor GatewayInstallationVault {
    private let store: any CredentialDataStore
    private let makeIdentity: @Sendable () -> GatewayDeviceIdentity
    private let makeInstanceID: @Sendable () -> String
    private let makeToken: @Sendable () -> String
    private let logger = Logger(subsystem: "app.operator.ios", category: "credential-vault")
    private var cached: GatewayInstallationCredentials?

    public init(
        store: any CredentialDataStore,
        identity: @escaping @Sendable () -> GatewayDeviceIdentity = { GatewayDeviceIdentity() },
        instanceID: @escaping @Sendable () -> String = { UUID().uuidString.lowercased() },
        token: @escaping @Sendable () -> String = { GatewayInstallationVault.makeRandomToken() })
    {
        self.store = store
        self.makeIdentity = identity
        self.makeInstanceID = instanceID
        self.makeToken = token
    }

    public func loadOrCreate() async throws -> GatewayInstallationCredentials {
        if let cached {
            return cached
        }
        if let stored = try await self.store.load() {
            guard let credentials = try? JSONDecoder().decode(
                GatewayInstallationCredentials.self,
                from: stored),
                Self.isValid(credentials)
            else {
                self.logger.error("[credentials] stored installation identity is corrupt")
                throw GatewayInstallationVaultError.corruptCredentials
            }
            self.cached = credentials
            self.logger.info("[credentials] restored stable installation identity")
            return credentials
        }

        let credentials = GatewayInstallationCredentials(
            identity: self.makeIdentity(),
            instanceID: self.makeInstanceID(),
            gatewayToken: self.makeToken())
        guard Self.isValid(credentials) else {
            throw GatewayInstallationVaultError.corruptCredentials
        }
        let data = try JSONEncoder().encode(credentials)
        try await self.store.save(data)
        self.cached = credentials
        self.logger.info("[credentials] created stable installation identity")
        return credentials
    }

    private static func isValid(_ credentials: GatewayInstallationCredentials) -> Bool {
        guard !credentials.instanceID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !credentials.gatewayToken.isEmpty,
              let key = try? credentials.identity.signingKey()
        else {
            return false
        }
        let rebuilt = GatewayDeviceIdentity(
            privateKey: key,
            createdAtMilliseconds: credentials.identity.createdAtMilliseconds)
        return rebuilt.deviceID == credentials.identity.deviceID
            && rebuilt.publicKey == credentials.identity.publicKey
    }

    public static func makeRandomToken() -> String {
        let key = SymmetricKey(size: .bits256)
        let data = key.withUnsafeBytes { Data($0) }
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
