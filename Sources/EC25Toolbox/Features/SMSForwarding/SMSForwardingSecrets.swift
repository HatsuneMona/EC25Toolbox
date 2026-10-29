import Foundation
import Security

@MainActor
protocol SMSForwardingSecretStorage {
    func read(id: UUID) throws -> SMSForwardingSecrets
    func save(_ secrets: SMSForwardingSecrets, id: UUID) throws
    func delete(id: UUID) throws
}

@MainActor
final class SMSForwardingKeychain: SMSForwardingSecretStorage {
    private let service = "ing.fuyaoskyrocket.ec25toolbox.sms-forwarding"
    private func query(_ id: UUID) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: id.uuidString]
    }
    func read(id: UUID) throws -> SMSForwardingSecrets {
        var request = query(id)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return SMSForwardingSecrets() }
        guard status == errSecSuccess, let data = result as? Data else { throw SMSForwardingError.keychain(status) }
        do { return try JSONDecoder().decode(SMSForwardingSecrets.self, from: data) }
        catch { throw SMSForwardingError.invalid("短信转发凭据无法解码，请重新保存通道。") }
    }
    func save(_ secrets: SMSForwardingSecrets, id: UUID) throws {
        let data = try JSONEncoder().encode(secrets)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(id) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(id)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(request as CFDictionary, nil)
            guard added == errSecSuccess else { throw SMSForwardingError.keychain(added) }
        } else if status != errSecSuccess { throw SMSForwardingError.keychain(status) }
    }
    func delete(id: UUID) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw SMSForwardingError.keychain(status) }
    }
}
