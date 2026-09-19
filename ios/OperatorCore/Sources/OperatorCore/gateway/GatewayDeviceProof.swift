import CryptoKit
import Foundation

public struct GatewayDeviceIdentity: Codable, Equatable, Sendable {
    public let deviceID: String
    public let publicKey: Data
    public let privateKey: Data
    public let createdAtMilliseconds: Int64

    public init(
        privateKey: Curve25519.Signing.PrivateKey = .init(),
        createdAtMilliseconds: Int64 = Int64(Date().timeIntervalSince1970 * 1000))
    {
        self.privateKey = privateKey.rawRepresentation
        self.publicKey = privateKey.publicKey.rawRepresentation
        self.deviceID = SHA256.hash(data: self.publicKey)
            .map { String(format: "%02x", $0) }
            .joined()
        self.createdAtMilliseconds = createdAtMilliseconds
    }

    public func signingKey() throws -> Curve25519.Signing.PrivateKey {
        try Curve25519.Signing.PrivateKey(rawRepresentation: self.privateKey)
    }
}

public struct GatewayConnectChallenge: Codable, Equatable, Sendable {
    public let nonce: String
    public let issuedAtMilliseconds: Int64

    public init(nonce: String, issuedAtMilliseconds: Int64) {
        self.nonce = nonce
        self.issuedAtMilliseconds = issuedAtMilliseconds
    }

    private enum CodingKeys: String, CodingKey {
        case nonce
        case issuedAtMilliseconds = "ts"
    }
}

public struct GatewaySignedDevice: Codable, Equatable, Sendable {
    public let id: String
    public let publicKey: String
    public let signature: String
    public let signedAt: Int64
    public let nonce: String
}

public struct GatewayDeviceProof: Equatable, Sendable {
    public let signedPayload: String
    public let device: GatewaySignedDevice

    public static func make(
        identity: GatewayDeviceIdentity,
        challenge: GatewayConnectChallenge,
        token: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String]) throws -> GatewayDeviceProof
    {
        let payload = [
            "v2",
            identity.deviceID,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(challenge.issuedAtMilliseconds),
            token,
            challenge.nonce,
        ].joined(separator: "|")
        let signature = try identity.signingKey().signature(for: Data(payload.utf8))
        return GatewayDeviceProof(
            signedPayload: payload,
            device: GatewaySignedDevice(
                id: identity.deviceID,
                publicKey: identity.publicKey.base64URLEncodedString(),
                signature: signature.base64URLEncodedString(),
                signedAt: challenge.issuedAtMilliseconds,
                nonce: challenge.nonce))
    }

    public static func makeV3(
        identity: GatewayDeviceIdentity,
        challenge: GatewayConnectChallenge,
        token: String,
        clientID: String,
        clientMode: String,
        role: String,
        scopes: [String],
        platform: String,
        deviceFamily: String) throws -> GatewayDeviceProof
    {
        let payload = [
            "v3",
            identity.deviceID,
            clientID,
            clientMode,
            role,
            scopes.joined(separator: ","),
            String(challenge.issuedAtMilliseconds),
            token,
            challenge.nonce,
            platform.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            deviceFamily.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
        ].joined(separator: "|")
        let signature = try identity.signingKey().signature(for: Data(payload.utf8))
        return GatewayDeviceProof(
            signedPayload: payload,
            device: GatewaySignedDevice(
                id: identity.deviceID,
                publicKey: identity.publicKey.base64URLEncodedString(),
                signature: signature.base64URLEncodedString(),
                signedAt: challenge.issuedAtMilliseconds,
                nonce: challenge.nonce))
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        self.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
