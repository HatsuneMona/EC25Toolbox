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

/// File-backed credentials, readable only by the current user. Existing
/// Keychain items are copied in on first use and then removed, so forwarding
/// never raises a Keychain prompt again once a channel has been migrated.
@MainActor
final class SMSForwardingFileSecrets: SMSForwardingSecretStorage {
    private let fileURL: URL
    private let legacy: (any SMSForwardingSecretStorage)?
    private var cache: [String: SMSForwardingSecrets]?

    init(directory: URL, legacy: (any SMSForwardingSecretStorage)? = SMSForwardingKeychain()) {
        self.fileURL = directory.appendingPathComponent("secrets-v1.json")
        self.legacy = legacy
    }

    func read(id: UUID) throws -> SMSForwardingSecrets {
        var all = try load()
        if let found = all[id.uuidString] { return found }
        guard let legacy else { return SMSForwardingSecrets() }
        let old = try legacy.read(id: id)
        guard old != SMSForwardingSecrets() else { return old }
        all[id.uuidString] = old
        try write(all)
        // The copy is durable; a failed Keychain cleanup only leaves a stale item.
        try? legacy.delete(id: id)
        return old
    }

    func save(_ secrets: SMSForwardingSecrets, id: UUID) throws {
        var all = try load()
        all[id.uuidString] = secrets
        try write(all)
    }

    func delete(id: UUID) throws {
        var all = try load()
        guard all.removeValue(forKey: id.uuidString) != nil else { return }
        try write(all)
    }

    private func load() throws -> [String: SMSForwardingSecrets] {
        if let cache { return cache }
        guard FileManager.default.fileExists(atPath: fileURL.path) else { cache = [:]; return [:] }
        do {
            let loaded = try JSONDecoder().decode([String: SMSForwardingSecrets].self, from: Data(contentsOf: fileURL))
            cache = loaded
            return loaded
        } catch { throw SMSForwardingError.invalid("短信转发凭据文件无法读取，请检查后重新保存通道。") }
    }

    private func write(_ all: [String: SMSForwardingSecrets]) throws {
        let directory = fileURL.deletingLastPathComponent()
        let manager = FileManager.default
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let temp = directory.appendingPathComponent(".secrets-v1.\(UUID().uuidString).tmp")
            guard manager.createFile(atPath: temp.path, contents: try encoder.encode(all), attributes: [.posixPermissions: 0o600]) else {
                throw SMSForwardingError.persistence
            }
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temp)
            } else {
                try manager.moveItem(at: temp, to: fileURL)
            }
            cache = all
        } catch { throw SMSForwardingError.persistence }
    }
}
