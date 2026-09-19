import CryptoKit
import Foundation
import XCTest
@testable import OperatorCore

final class GatewayDeviceProofTests: XCTestCase {
    func testProofUsesCurrentOpenClawV2CompatibilityPayloadAndValidEd25519Signature() throws {
        let privateKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1 ... 32).map(UInt8.init)))
        let identity = GatewayDeviceIdentity(privateKey: privateKey, createdAtMilliseconds: 42)
        let challenge = GatewayConnectChallenge(nonce: "nonce-1", issuedAtMilliseconds: 1_725_000_000_000)

        let proof = try GatewayDeviceProof.make(
            identity: identity,
            challenge: challenge,
            token: "local-token",
            clientID: "openclaw-ios",
            clientMode: "ui",
            role: "operator",
            scopes: ["operator.read", "operator.write"])

        let expectedPayload = "v2|\(identity.deviceID)|openclaw-ios|ui|operator|operator.read,operator.write|1725000000000|local-token|nonce-1"
        XCTAssertEqual(proof.signedPayload, expectedPayload)
        XCTAssertEqual(proof.device.id, identity.deviceID)
        XCTAssertEqual(proof.device.nonce, "nonce-1")
        XCTAssertEqual(proof.device.signedAt, 1_725_000_000_000)
        XCTAssertTrue(try privateKey.publicKey.isValidSignature(
            XCTUnwrap(Data(base64URLEncoded: proof.device.signature)),
            for: Data(expectedPayload.utf8)))
    }

    func testConnectRequestCarriesProtocolFourTokenAndSignedDevice() throws {
        let identity = GatewayDeviceIdentity()
        let challenge = GatewayConnectChallenge(nonce: "server-nonce", issuedAtMilliseconds: 123)
        let request = try GatewayRequestFactory.connect(
            requestID: "connect-1",
            token: "secret",
            identity: identity,
            challenge: challenge,
            appVersion: "1.0",
            platform: "iOS 18.5.0",
            instanceID: "installation-1")

        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any])
        let params = try XCTUnwrap(object["params"] as? [String: Any])
        let auth = try XCTUnwrap(params["auth"] as? [String: Any])
        let client = try XCTUnwrap(params["client"] as? [String: Any])
        let device = try XCTUnwrap(params["device"] as? [String: Any])

        XCTAssertEqual(object["type"] as? String, "req")
        XCTAssertEqual(object["method"] as? String, "connect")
        XCTAssertEqual(params["minProtocol"] as? Int, 4)
        XCTAssertEqual(params["maxProtocol"] as? Int, 4)
        XCTAssertEqual(
            params["scopes"] as? [String],
            ["operator.admin", "operator.read", "operator.write"])
        XCTAssertEqual(auth["token"] as? String, "secret")
        XCTAssertEqual(client["id"] as? String, "openclaw-ios")
        XCTAssertEqual(client["version"] as? String, "1.0")
        XCTAssertEqual(client["platform"] as? String, "iOS 18.5.0")
        XCTAssertEqual(client["deviceFamily"] as? String, "iPhone")
        XCTAssertEqual(client["instanceId"] as? String, "installation-1")
        XCTAssertEqual(device["nonce"] as? String, "server-nonce")
    }

    func testChallengeDecodesCurrentNonceAndTimestampWireKeys() throws {
        let data = Data(#"{"type":"event","event":"connect.challenge","payload":{"nonce":"n-1","ts":1725000000123}}"#.utf8)

        let frame = try JSONDecoder().decode(
            GatewayEventFrame<GatewayConnectChallenge>.self,
            from: data)

        XCTAssertEqual(frame.type, "event")
        XCTAssertEqual(frame.event, "connect.challenge")
        XCTAssertEqual(frame.payload.nonce, "n-1")
        XCTAssertEqual(frame.payload.issuedAtMilliseconds, 1_725_000_000_123)
    }

    func testV3ProofBindsLowercasedPlatformAndDeviceFamily() throws {
        let identity = GatewayDeviceIdentity(createdAtMilliseconds: 1)
        let challenge = GatewayConnectChallenge(nonce: "node-nonce", issuedAtMilliseconds: 42)

        let proof = try GatewayDeviceProof.makeV3(
            identity: identity,
            challenge: challenge,
            token: "node-token",
            clientID: "node-host",
            clientMode: "node",
            role: "node",
            scopes: [],
            platform: "  iOS  ",
            deviceFamily: "iPhone")

        XCTAssertEqual(
            proof.signedPayload,
            "v3|\(identity.deviceID)|node-host|node|node||42|node-token|node-nonce|ios|iphone")
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64.append(String(repeating: "=", count: (4 - base64.count % 4) % 4))
        self.init(base64Encoded: base64)
    }
}
