import Foundation

/// A Hermes profile (`ProfileInfo` in the desktop's `types/hermes.ts`, `GET /api/profiles`).
struct ProfileInfo: Identifiable, Hashable {
    let name: String
    /// Presentation-only label (profile.yaml `display_name`).
    var displayName: String?
    /// The root profile (named "default"): it can't be deleted, and renaming it only sets a display name.
    var isDefault = false
    var model: String?
    var provider: String?
    var description: String?
    var gatewayRunning = false
    /// The profile's directory on the host.
    var path: String?
    /// It keeps its own `.env`.
    var hasEnv = false
    var skillCount = 0
    /// The Bot Mode title (profile.yaml `ui_meta['hermes-bots'].title`).
    var botTitle: String?

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
        displayName = LenientField.text(row["display_name"])
        isDefault = (row["is_default"] as? Bool) ?? (name == "default")
        model = LenientField.text(row["model"])
        provider = LenientField.text(row["provider"])
        description = LenientField.text(row["description"])
        gatewayRunning = LenientField.bool(row["gateway_running"])
        path = LenientField.text(row["path"])
        hasEnv = LenientField.bool(row["has_env"])
        skillCount = max(0, LenientField.int(row["skill_count"]))
        botTitle = LenientField.text(row["bot_title"])
    }

    /// "model · provider", as the desktop's detail names the profile's model; nil when no model is set.
    var modelSummary: String? {
        guard let model else { return nil }
        return provider.map { "\(model) · \($0)" } ?? model
    }
}

/// Profile names as Hermes accepts them (`create-profile-dialog.tsx`, `hermes_cli/profiles.py`).
enum ProfileName {
    static let hint = "Lowercase letters, digits, hyphens, and underscores. Must start with a letter or digit."

    /// `^[a-z0-9][a-z0-9_-]{0,63}$` after trimming.
    static func isValid(_ name: String) -> Bool {
        let scalars = name.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
        guard let first = scalars.first, scalars.count <= 64, isAlphanumeric(first) else { return false }
        return scalars.dropFirst().allSatisfy { isAlphanumeric($0) || $0 == "_" || $0 == "-" }
    }

    /// The desktop's live `slug` sanitizer: lowercase, every run of other characters becomes one "-", no leading
    /// "-". A trailing "-" stays so the name remains typeable.
    static func sanitize(_ raw: String) -> String {
        var out = String.UnicodeScalarView()
        var pendingDash = false
        for scalar in raw.lowercased().unicodeScalars {
            if isAlphanumeric(scalar) {
                if pendingDash, !out.isEmpty { out.append("-") }
                pendingDash = false
                out.append(scalar)
            } else {
                pendingDash = true
            }
        }
        if pendingDash, !out.isEmpty { out.append("-") }
        return String(out)
    }

    private static func isAlphanumeric(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar)
    }
}

/// A profile's SOUL.md (`GET /api/profiles/:name/soul`). `exists` is false when the file was never written.
struct ProfileSoul: Hashable {
    var content: String
    var exists: Bool

    init(content: String, exists: Bool) {
        self.content = content
        self.exists = exists
    }

    init(response: JSON) {
        content = response["content"] as? String ?? ""
        exists = LenientField.optionalBool(response["exists"]) ?? !content.isEmpty
    }
}

/// `GET /api/profiles/active`: `active` is the sticky default `hermes profile use` writes (what new CLI runs and
/// gateways pick up); `current` is the profile this dashboard itself runs on.
struct ProfileActivity: Hashable {
    var active: String
    var current: String

    init(active: String = "default", current: String = "default") {
        self.active = active
        self.current = current
    }

    init(response: JSON) {
        active = LenientField.text(response["active"]) ?? "default"
        current = LenientField.text(response["current"]) ?? "default"
    }
}

/// What `POST /api/profiles` made.
struct CreatedProfile: Hashable {
    var name: String
    var path: String?
    /// The create request wrote the SOUL.md it carried (older backends ignore it).
    var soulSet: Bool

    init(response: JSON, requested: String) {
        name = LenientField.text(response["name"]) ?? requested
        path = LenientField.text(response["path"])
        soulSet = LenientField.bool(response["soul_set"])
    }
}

/// What `PATCH /api/profiles/:name` did. Renaming the root profile only sets `displayName`; its id stays "default".
struct RenamedProfile: Hashable {
    var name: String
    var displayName: String?

    init(response: JSON, requested: String) {
        name = LenientField.text(response["name"]) ?? requested
        displayName = LenientField.text(response["display_name"])
    }
}

/// What `DELETE /api/profiles/:name` did. A pending identity settlement still deleted the directory; Hermes names
/// the command that finishes it.
struct ProfileDeletion: Hashable {
    var settlementPending: Bool
    var retryCommand: String?

    init(response: JSON) {
        settlementPending = LenientField.bool(response["settlement_pending"])
        retryCommand = LenientField.text(response["retry_command"])
    }
}

extension Notification.Name {
    /// A profile was created, renamed, deleted, imported or made the default here; profile lists may reload.
    static let hermesProfilesDidChange = Notification.Name("HermesProfilesDidChange")
}

extension DashboardClient {
    /// Every profile on the host, the default one first.
    func profiles() async throws -> [ProfileInfo] {
        let result = try await request("GET", "/api/profiles") as? JSON
        let profiles = (result?["profiles"] as? [JSON] ?? []).compactMap(ProfileInfo.init(row:))
        return profiles.filter(\.isDefault) + profiles.filter { !$0.isDefault }
    }

    /// The host's sticky default profile and the dashboard's own.
    func profileActivity() async throws -> ProfileActivity {
        ProfileActivity(response: try await request("GET", "/api/profiles/active") as? JSON ?? [:])
    }

    /// Makes `name` the sticky default (`hermes profile use`): new CLI runs and gateways use it. The running
    /// dashboard keeps its own profile. Returns the stored name.
    @discardableResult
    func setDefaultProfile(_ name: String) async throws -> String {
        let result = try await request("POST", "/api/profiles/active", body: ["name": name]) as? JSON
        return LenientField.text(result?["active"]) ?? name
    }

    /// Creates a profile, cloning config, skills and SOUL.md from `cloneFrom` (nil: a blank profile). A non-empty
    /// `soul` replaces the persona; an older backend that ignores it in the create request gets it in a second call.
    func createProfile(name: String, cloneFrom: String?, soul: String? = nil) async throws -> CreatedProfile {
        let soul = soul.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        var body: JSON = ["name": name, "clone_from": cloneFrom.map { $0 as Any } ?? NSNull()]
        if let soul { body["soul"] = soul }
        let result = try await request("POST", "/api/profiles", body: body) as? JSON ?? [:]
        var created = CreatedProfile(response: result, requested: name)
        if let soul, !created.soulSet {
            try await saveProfileSoul(created.name, content: soul)
            created.soulSet = true
        }
        return created
    }

    /// Renames a profile (its directory, wrapper script and sessions move with it). For the root profile the new
    /// name is a display name only.
    func renameProfile(_ name: String, to newName: String) async throws -> RenamedProfile {
        let result = try await request("PATCH", "/api/profiles/\(try Self.segment(name))", body: ["new_name": newName])
        return RenamedProfile(response: result as? JSON ?? [:], requested: newName)
    }

    /// Deletes a profile's directory for good. The root profile can't be deleted.
    func deleteProfile(_ name: String) async throws -> ProfileDeletion {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased() != "default" else { throw DashboardError.rpc("The default profile can't be deleted.") }
        let result = try await request("DELETE", "/api/profiles/\(try Self.segment(trimmed))")
        return ProfileDeletion(response: result as? JSON ?? [:])
    }

    func profileSoul(_ name: String) async throws -> ProfileSoul {
        ProfileSoul(response: try await request("GET", "/api/profiles/\(try Self.segment(name))/soul") as? JSON ?? [:])
    }

    /// Writes SOUL.md whole (atomically on the host).
    func saveProfileSoul(_ name: String, content: String) async throws {
        _ = try await request("PUT", "/api/profiles/\(try Self.segment(name))/soul", body: ["content": content])
    }

    /// Exports a profile as a `.tar.gz` in Hermes' managed export folder on the host and returns its path there.
    /// The archive can carry the profile's credentials, so it stays on the host.
    func exportProfile(_ name: String) async throws -> String {
        let result = try await request("POST", "/api/profiles/\(try Self.segment(name))/export",
                                       body: ["extra_files": JSON(), "output": ""]) as? JSON
        guard let archive = LenientField.text(result?["archive"]) else { throw DashboardError.rpc("Hermes didn't name the archive.") }
        return archive
    }

    /// Imports a profile archive that is already on the host (`archive` is its path there). `name` overrides the
    /// name inside the archive. Returns the new profile's name.
    func importProfile(archive: String, name: String? = nil) async throws -> String {
        let name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        let body: JSON = ["archive": archive, "name": name.map { $0 as Any } ?? NSNull()]
        let result = try await request("POST", "/api/profiles/import", body: body) as? JSON
        return LenientField.text(result?["name"]) ?? name ?? ""
    }

    /// One path segment as is: `url(_:query:)` percent-encodes it, but a "/" would split the route.
    static func segment(_ value: String) throws -> String {
        guard !value.isEmpty, !value.contains("/") else {
            throw DashboardError.rpc("“\(value)” can't be addressed on the dashboard.")
        }
        return value
    }
}

/// Lenient readers for dashboard JSON rows: a missing or mistyped field reads as empty.
enum LenientField {
    /// Trimmed text; nil when missing, not a string, or blank.
    static func text(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func int(_ value: Any?) -> Int { optionalInt(value) ?? 0 }

    /// A JSON number (not a boolean), or a numeric string.
    static func optionalInt(_ value: Any?) -> Int? {
        if let number = value as? NSNumber, !isBoolean(number) { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func bool(_ value: Any?) -> Bool { (value as? NSNumber)?.boolValue ?? false }

    /// A JSON boolean; nil for anything else.
    static func optionalBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    /// The non-blank strings of a JSON array.
    static func strings(_ value: Any?) -> [String] {
        (value as? [Any] ?? []).compactMap { text($0) }
    }

    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
}
