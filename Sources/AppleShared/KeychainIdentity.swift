import CryptoKit
import Foundation
import Security

struct DeviceIdentity: Codable {
    let id: UUID
    let privateKey: Data
    var publicKey: String {
        get throws { try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: privateKey).publicKey.rawRepresentation.base64EncodedString() }
    }
}

enum KeychainIdentity {
    private static let account = "device-identity-v1"
    private static let service = "NPV.DeviceIdentity"

    private static func baseQuery() throws -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account,
         kSecAttrAccessGroup as String: try AppEnvironment.keychainGroup,
         kSecAttrSynchronizable as String: false]
    }

    static func load() throws -> DeviceIdentity? {
        var query = try baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw EnvironmentError.keychain(status) }
        guard let data = result as? Data else { throw EnvironmentError.malformedIdentity }
        return try decode(data)
    }

    static func createIfMissing() throws -> DeviceIdentity {
        if let existing = try load() { return existing }
        let identity = DeviceIdentity(id: UUID(), privateKey: Curve25519.KeyAgreement.PrivateKey().rawRepresentation)
        var query = try baseQuery()
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        query[kSecValueData as String] = try JSONEncoder().encode(identity)
        let status = SecItemAdd(query as CFDictionary, nil)
        if status == errSecDuplicateItem, let existing = try load() { return existing }
        guard status == errSecSuccess else { throw EnvironmentError.keychain(status) }
        return identity
    }

    static func persistentReference() throws -> Data {
        var query = try baseQuery()
        query[kSecReturnPersistentRef as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw EnvironmentError.keychain(status) }
        return data
    }

    static func load(reference: Data) throws -> DeviceIdentity {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecValuePersistentRef as String: reference,
                                   kSecAttrAccessGroup as String: try AppEnvironment.keychainGroup,
                                   kSecReturnData as String: true]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data else { throw EnvironmentError.keychain(status) }
        return try decode(data)
    }

    private static func decode(_ data: Data) throws -> DeviceIdentity {
        guard let identity = try? JSONDecoder().decode(DeviceIdentity.self, from: data), identity.privateKey.count == 32,
              (try? identity.publicKey) != nil else { throw EnvironmentError.malformedIdentity }
        return identity
    }
}
