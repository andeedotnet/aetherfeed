import Foundation
import Security

/// The login keychain for the one secret the app holds (the API key of an
/// OpenAI-compatible server). UserDefaults would keep it in cleartext in
/// `~/Library/Preferences`, readable by every process running as the user
/// and carried into backups.
///
/// Keychain access is bound to the app's code signature. Ad-hoc signed
/// builds change identity on every rebuild, so macOS may ask for
/// permission again after an update — hence every call degrades to `nil`
/// instead of throwing, and the caller keeps working without a key.
enum KeychainStore {
    private static let service = "net.andee.aetherfeed"

    /// Account name of the OpenAI-compatible API key; also the UserDefaults
    /// key it used to live under, which the settings store migrates away.
    static let openaiAPIKeyAccount = "openaiAPIKey"

    static func string(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// Storing an empty string removes the item — "no key configured".
    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        guard !value.isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(
            base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}
