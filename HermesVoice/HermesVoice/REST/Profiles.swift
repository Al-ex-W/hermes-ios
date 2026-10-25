import Foundation

/// A Hermes profile (`ProfileInfo` in the desktop's `types/hermes.ts`, `GET /api/profiles`).
struct ProfileInfo: Identifiable, Hashable {
    let name: String
    /// Presentation-only label (profile.yaml `display_name`).
    var displayName: String?
    var isDefault = false
    var model: String?
    var provider: String?
    var description: String?
    var gatewayRunning = false

    var id: String { name }
    var label: String { displayName ?? name }

    init(name: String, displayName: String? = nil, isDefault: Bool = false) {
        self.name = name
        self.displayName = displayName
        self.isDefault = isDefault
    }

    init?(row: JSON) {
        guard let name = row["name"] as? String, !name.isEmpty else { return nil }
        self.name = name
        displayName = Self.text(row["display_name"])
        isDefault = (row["is_default"] as? Bool) ?? (name == "default")
        model = Self.text(row["model"])
        provider = Self.text(row["provider"])
        description = Self.text(row["description"])
        gatewayRunning = (row["gateway_running"] as? Bool) ?? false
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else {
            return nil
        }
        return string
    }
}

extension DashboardClient {
    /// Every profile on the host, the default one first.
    func profiles() async throws -> [ProfileInfo] {
        let result = try await request("GET", "/api/profiles") as? JSON
        let profiles = (result?["profiles"] as? [JSON] ?? []).compactMap(ProfileInfo.init(row:))
        return profiles.filter(\.isDefault) + profiles.filter { !$0.isDefault }
    }
}
