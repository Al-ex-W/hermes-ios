import Foundation

/// The host's profiles and which one is the default, shared by the Profiles list and its detail pages. Every
/// change reloads the list and posts `hermesProfilesDidChange` so other profile lists (the sidebar's) can follow.
@MainActor
final class ProfilesStore: ObservableObject {
    @Published private(set) var profiles: [ProfileInfo]?
    @Published private(set) var activity = ProfileActivity()
    @Published private(set) var loadError: String?
    let client: DashboardClient

    init(client: DashboardClient) {
        self.client = client
    }

    func load() async {
        do {
            async let list = client.profiles()
            async let activity = try? client.profileActivity()
            let loaded = try await list
            profiles = loaded
            if let activity = await activity { self.activity = activity }
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if profiles == nil { loadError = error.dashboardMessage }
        }
    }

    func profile(named name: String) -> ProfileInfo? {
        profiles?.first { $0.name == name }
    }

    /// The sticky default (`hermes profile use`): what new CLI runs and gateways use.
    func isDefault(_ profile: ProfileInfo) -> Bool {
        Self.sameName(profile.name, activity.active)
    }

    /// The profile the dashboard itself runs on.
    func isDashboards(_ profile: ProfileInfo) -> Bool {
        Self.sameName(profile.name, activity.current)
    }

    /// Profiles matching `query` by name, display name or model (the desktop's search).
    func filtered(_ query: String) -> [ProfileInfo] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard let profiles else { return [] }
        guard !needle.isEmpty else { return profiles }
        return profiles.filter {
            $0.name.lowercased().contains(needle) || ($0.displayName ?? "").lowercased().contains(needle)
                || ($0.model ?? "").lowercased().contains(needle)
        }
    }

    // MARK: Changes

    /// Creates a profile and returns its name.
    func create(name: String, cloneFrom: String?, soul: String) async throws -> String {
        let created = try await client.createProfile(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                                                     cloneFrom: cloneFrom, soul: soul)
        await changed()
        return created.name
    }

    /// Renames a profile and returns its name afterwards (the root profile keeps "default" and gets a display name).
    func rename(_ profile: ProfileInfo, to newName: String) async throws -> String {
        let renamed = try await client.renameProfile(profile.name, to: newName.trimmingCharacters(in: .whitespacesAndNewlines))
        await changed()
        return renamed.name
    }

    func delete(_ profile: ProfileInfo) async throws -> ProfileDeletion {
        let deletion = try await client.deleteProfile(profile.name)
        await changed()
        return deletion
    }

    func makeDefault(_ profile: ProfileInfo) async throws {
        let active = try await client.setDefaultProfile(profile.name)
        activity.active = active
        await changed()
    }

    /// Exports the profile on the host and returns the archive's path there.
    func export(_ profile: ProfileInfo) async throws -> String {
        try await client.exportProfile(profile.name)
    }

    /// Imports an archive already on the host and returns the new profile's name.
    func importArchive(_ path: String, name: String?) async throws -> String {
        let imported = try await client.importProfile(archive: path.trimmingCharacters(in: .whitespacesAndNewlines), name: name)
        await changed()
        return imported
    }

    private func changed() async {
        NotificationCenter.default.post(name: .hermesProfilesDidChange, object: nil)
        await load()
    }

    /// Profile names compare case-insensitively on the host (`normalize_profile_name`).
    nonisolated static func sameName(_ lhs: String, _ rhs: String) -> Bool {
        lhs.trimmingCharacters(in: .whitespaces).lowercased() == rhs.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
