import Foundation
import OperatorCore
import Security

actor KeychainCredentialStore: CredentialDataStore {
    private let service: String
    private let account: String

    init(service: String, account: String = "installation") {
        self.service = service
        self.account = account
    }

    func load() async throws -> Data? {
        var query = self.baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError.status(status)
        }
        return data
    }

    func save(_ data: Data) async throws {
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            self.baseQuery as CFDictionary,
            attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.status(updateStatus)
        }
        var item = self.baseQuery
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(item as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.status(addStatus)
        }
    }

    func remove() async throws {
        let status = SecItemDelete(self.baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.status(status)
        }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: self.service,
            kSecAttrAccount as String: self.account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

private enum KeychainStoreError: Error {
    case status(OSStatus)
}
