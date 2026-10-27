import SwiftUI

/// The folder new chats start in, per dashboard and profile (the desktop keeps it per gateway and profile in
/// its own storage, `browser-settings.ts`). A path on the host; nil leaves the host's default.
enum DefaultProjectFolder {
    private static func key(base: URL, profile: String?) -> String {
        let scope = profile?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? "default"
        return "settings.defaultProjectFolder.\(base.absoluteString)|\(scope)"
    }

    static func dir(base: URL, profile: String?, defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: key(base: base, profile: profile))?.trimmingCharacters(in: .whitespaces).nilIfEmpty
    }

    static func set(_ dir: String?, base: URL, profile: String?, defaults: UserDefaults = .standard) {
        let key = key(base: base, profile: profile)
        if let dir = dir?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            defaults.set(dir, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

/// Settings > Sessions (`sessions-settings.tsx`): auto-archive and the archived chats (restore or delete), and
/// the default project folder for new chats.
struct SessionsSettingsView: View {
    @EnvironmentObject private var context: SettingsContext
    @EnvironmentObject private var store: SettingsStore
    let subpage: String?
    let anchor: String?

    @State private var archived: [SessionInfo] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var deleting: SessionInfo?
    @State private var folder = ""

    var body: some View {
        Form {
            if subpage == "default-directory" {
                SettingsScopeNote()
                folderSection
            } else {
                retentionSection
                archivedSection
            }
        }
        .hermesForm()
        .settingsAnchor(anchor, ready: store.phase == .loaded)
        .refreshable { await reload() }
        .task {
            folder = DefaultProjectFolder.dir(base: context.client.base, profile: context.profile) ?? ""
            if subpage != "default-directory" { await reload() }
        }
        .confirmationDialog("Delete \(deleting?.displayTitle ?? "")?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { session in
            Button("Delete", role: .destructive) { Task { await delete(session) } }
        } message: { _ in
            Text("The chat and its transcript are deleted for good.")
        }
    }

    @ViewBuilder private var retentionSection: some View {
        if store.phase == .loaded, store.field("sessions.auto_archive") != nil {
            Section {
                ConfigFieldRow(key: "sessions.auto_archive")
                if store.value("sessions.auto_archive")?.truthy == true, store.field("sessions.auto_archive_days") != nil {
                    ConfigFieldRow(key: "sessions.auto_archive_days")
                }
            }
            .hermesFormRows()
            .id("sessions.auto-archive")
        }
    }

    private var archivedSection: some View {
        Section {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity)
            } else if archived.isEmpty {
                Text("No archived chats.").foregroundStyle(Theme.Text.tertiary)
            }
            ForEach(archived) { session in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(session.displayTitle).foregroundStyle(Theme.Text.primary).lineLimit(1)
                    if let date = session.lastActive {
                        Text(date.formatted(date: .abbreviated, time: .omitted)).hermesText(.caption)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { deleting = session }
                    Button("Restore") { Task { await restore(session) } }.tint(Theme.primary)
                }
            }
        } header: {
            FormNote("Archived chats")
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("Swipe a chat to restore it to the sidebar or delete it.") }
        }
        .hermesFormRows()
    }

    private var folderSection: some View {
        let fallback = store.value("terminal.cwd")?.displayText.nilIfEmpty
        return Section {
            TextField("Host default", text: $folder)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onSubmit(saveFolder)
            HStack {
                Button("Save", action: saveFolder)
                Spacer()
                Button("Clear", role: .destructive) {
                    folder = ""
                    saveFolder()
                }
            }
            .buttonStyle(.borderless)
        } header: {
            FormNote("Default project folder")
        } footer: {
            FormNote("A folder on the Hermes host that new chats from this iPhone start in"
                + (context.profile.map { " when the sidebar shows the “\($0)” profile" } ?? "")
                + ". Empty uses " + (fallback.map { "the host's working directory (\($0))." } ?? "the host's working directory."))
        }
        .hermesFormRows()
        .id("sessions.default-directory")
    }

    private func saveFolder() {
        // The key new chats read (ChatModel: the chat's profile, the sidebar's), so the folder is the one they use.
        DefaultProjectFolder.set(folder, base: context.client.base, profile: context.profile)
        folder = DefaultProjectFolder.dir(base: context.client.base, profile: context.profile) ?? ""
    }

    private func reload() async {
        do {
            archived = try await context.client.archivedSessions(profile: SidebarOptions.allProfiles)
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loaded = true
    }

    private func restore(_ session: SessionInfo) async {
        do {
            try await context.client.updateSession(session.id, profile: session.profile, archived: false)
            archived.removeAll { $0.id == session.id }
        } catch {
            failure = error.localizedDescription
        }
    }

    private func delete(_ session: SessionInfo) async {
        do {
            try await context.client.deleteSession(session.id, profile: session.profile)
            archived.removeAll { $0.id == session.id }
        } catch {
            failure = error.localizedDescription
        }
    }
}
