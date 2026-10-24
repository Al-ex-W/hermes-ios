import Foundation
import Security

/// Where the app connects: the Hermes dashboard and the Hermes Voice MCP server.
/// Addresses live in UserDefaults; the password and voice token live in the Keychain.
struct ConnectionSettings: Equatable {
    var dashboardURL: String
    var username: String
    var password: String
    var voiceServerURL: String
    var voiceToken: String
    /// Speech recognition locale for calls; "" chooses one from the preferred languages.
    var speechLocale: String

    static let voiceAddressExample = "https://machine.tailnet.ts.net:8443"

    var dashboardBase: URL? { URL(string: dashboardURL.trimmingCharacters(in: .whitespaces).trimmingSuffix("/")) }
    var voiceBase: URL? { Self.voiceURL(from: voiceServerURL) }
    var hasVoiceServer: Bool { voiceBase != nil && !voiceToken.isEmpty }

    /// The voice server address as a usable URL, or nil. Without a scheme, an IP literal gets http://
    /// (Tailscale certificates cover MagicDNS names only) and a host name gets https://.
    static func voiceURL(from address: String) -> URL? {
        var text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") {
            text = (isIPLiteral(hostPart(of: text)) ? "http://" : "https://") + text
        }
        guard var components = URLComponents(string: text.trimmingSuffix("/")),
              let scheme = components.scheme?.lowercased(), ["http", "https", "ws", "wss"].contains(scheme),
              let host = components.host, !host.isEmpty else { return nil }
        components.scheme = scheme
        return components.url
    }

    /// "100.64.0.1" from "100.64.0.1:8765/x", "[fd7a::1]" from "[fd7a::1]:8765".
    private static func hostPart(of address: String) -> String {
        let authority = address.prefix { $0 != "/" }
        if authority.hasPrefix("[") { return String(authority.prefix { $0 != "]" }) + "]" }
        return String(authority.prefix { $0 != ":" })
    }

    private static func isIPLiteral(_ host: String) -> Bool {
        if host.hasPrefix("[") { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } ?? false }
    }

    static func load() -> ConnectionSettings {
        let defaults = UserDefaults.standard
        return ConnectionSettings(
            dashboardURL: defaults.string(forKey: "dashboardURL") ?? "",
            username: defaults.string(forKey: "username") ?? "",
            password: Keychain.read("password") ?? "",
            voiceServerURL: defaults.string(forKey: "voiceServerURL") ?? "",
            voiceToken: Keychain.read("voiceToken") ?? "",
            speechLocale: defaults.string(forKey: "speechLocale") ?? ""
        )
    }

    func save() {
        let defaults = UserDefaults.standard
        defaults.set(dashboardURL, forKey: "dashboardURL")
        defaults.set(username, forKey: "username")
        defaults.set(voiceServerURL, forKey: "voiceServerURL")
        defaults.set(speechLocale, forKey: "speechLocale")
        Keychain.write("password", password)
        Keychain.write("voiceToken", voiceToken)
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
