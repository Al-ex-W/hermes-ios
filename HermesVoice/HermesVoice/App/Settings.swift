import Foundation
import Security

/// Where the app connects: the Hermes dashboard. The address lives in UserDefaults, the password in the Keychain.
/// (Calls go through the dashboard too, to the Hermes Voice plugin; how they listen is in CallSettings.)
struct ConnectionSettings: Equatable {
    var dashboardURL: String
    var username: String
    var password: String

    var dashboardBase: URL? { URL(string: dashboardURL.trimmingCharacters(in: .whitespaces).trimmingSuffix("/")) }

    static func load() -> ConnectionSettings {
        let defaults = UserDefaults.standard
        return ConnectionSettings(
            dashboardURL: defaults.string(forKey: "dashboardURL") ?? "",
            username: defaults.string(forKey: "username") ?? "",
            password: Keychain.read("password") ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(dashboardURL, forKey: "dashboardURL")
        defaults.set(username, forKey: "username")
        Keychain.write("password", password)
        // The separate Hermes Voice server (hermes-voice-mcp) is gone: forget its address and token.
        defaults.removeObject(forKey: "voiceServerURL")
        Keychain.write("voiceToken", "")
    }
}

enum Keychain {
    private static let service = Bundle.main.bundleIdentifier ?? "hermesvoice"

    static func read(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ key: String, _ value: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return }
        var add = query
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }
}

extension String {
    func trimmingSuffix(_ suffix: String) -> String {
        var result = self
        while result.hasSuffix(suffix) { result.removeLast(suffix.count) }
        return result
    }
}
