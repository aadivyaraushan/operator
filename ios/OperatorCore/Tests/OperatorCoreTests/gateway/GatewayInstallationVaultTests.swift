import CryptoKit
import Foundation
import XCTest
@testable import OperatorCore

final class GatewayInstallationVaultTests: XCTestCase {
    func testFirstLoadCreatesAndPersistsStableLocalCredentials() async throws {
        let store = MemoryCredentialStore()
        let fixedKey = try Curve25519.Signing.PrivateKey(
            rawRepresentation: Data((1 ... 32).map(UInt8.init)))
        let vault = GatewayInstallationVault(
            store: store,
            identity: { GatewayDeviceIdentity(privateKey: fixedKey, createdAtMilliseconds: 42) },
            instanceID: { "install-1" },
            token: { "gateway-token-1" })

        let first = try await vault.loadOrCreate()
        let second = try await vault.loadOrCreate()
        let restored = try await GatewayInstallationVault(store: store).loadOrCreate()

        XCTAssertEqual(first, second)
        XCTAssertEqual(restored, first)
        XCTAssertEqual(first.instanceID, "install-1")
        XCTAssertEqual(first.gatewayToken, "gateway-token-1")
        XCTAssertEqual(first.identity.deviceID, GatewayDeviceIdentity(privateKey: fixedKey).deviceID)
        let firstWriteCount = await store.writeCount()
        XCTAssertEqual(firstWriteCount, 1)
    }

    func testCorruptStoredCredentialsAreReportedInsteadOfSilentlyChangingIdentity() async throws {
        let store = MemoryCredentialStore(initial: Data("not-json".utf8))
        let vault = GatewayInstallationVault(store: store)

        do {
            _ = try await vault.loadOrCreate()
            XCTFail("corrupt credentials should fail")
        } catch let error as GatewayInstallationVaultError {
            XCTAssertEqual(error, .corruptCredentials)
        }
        let writeCount = await store.writeCount()
        XCTAssertEqual(writeCount, 0)
    }
}

private actor MemoryCredentialStore: CredentialDataStore {
    private var value: Data?
    private var writes = 0

    init(initial: Data? = nil) {
        self.value = initial
    }

    func load() async throws -> Data? {
        self.value
    }

    func save(_ data: Data) async throws {
        self.value = data
        self.writes += 1
    }

    func writeCount() -> Int {
        self.writes
    }
}
