import Foundation
import Security

enum KeychainStoreError: Error {
    case osStatus(OSStatus)
    case unexpectedData
}

enum KeychainStore {
    private static let service = "com.arystantelbay.arabar"

    static func set(_ value: String, for account: String,
                    update: (CFDictionary, CFDictionary) -> OSStatus = { SecItemUpdate($0, $1) },
                    add: (CFDictionary) -> OSStatus = { SecItemAdd($0, nil) }) throws {
        let data = Data(value.utf8)
        let baseQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let updateStatus = update(baseQuery as CFDictionary,
                                         [kSecValueData as String: data] as CFDictionary)
        if updateStatus == errSecSuccess { return }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainStoreError.osStatus(updateStatus)
        }
        var addQuery = baseQuery
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
        let status = add(addQuery as CFDictionary)
        guard status == errSecSuccess else { throw KeychainStoreError.osStatus(status) }
    }

    static func get(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func delete(account: String, deleteItem: (CFDictionary) -> OSStatus = { SecItemDelete($0) }) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = deleteItem(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func has(account: String) -> Bool {
        get(account: account) != nil
    }
}

enum KeychainAccount {
    static let anthropicAdminKey = "adminkey.anthropic"
    static let openaiAdminKey = "adminkey.openai"
}
