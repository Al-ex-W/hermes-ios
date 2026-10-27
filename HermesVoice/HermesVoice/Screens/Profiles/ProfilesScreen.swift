import SwiftUI

/// Profiles, for the signed-in dashboard (an entry point that needs no client of its own).
struct ProfilesPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let client = model.client {
            ProfilesScreen(client: client)
        } else {
            ContentUnavailableView("Not signed in", systemImage: Theme.Icon.profile,
                                   description: Text("Sign in to the Hermes dashboard first."))
                .navigationTitle("Profiles")
        }
    }
}

/// The desktop's Profiles view (`app/profiles/index.tsx`): every profile on the host with its model and skills;
/// new, import, and per profile rename, export, delete, make default and SOUL.md.
struct ProfilesScreen: View {
    @StateObject private var store: ProfilesStore
    @State private var query = ""
    @State private var creating = false
    @State private var importing = false
    /// The profile whose page is open. Held here rather than by the row, so a rename or reload that replaces the
    /// row doesn't close the page.
    @State private var opened: String?

    init(client: DashboardClient) {
        _store = StateObject(wrappedValue: ProfilesStore(client: client))
    }

    var body: some View {
        List {
            if let profiles = store.profiles {
                let visible = store.filtered(query)
                Section {
                    ForEach(visible) { profile in
                        Button {
                            opened = profile.name
                        } label: {
                            ProfileListRow(profile: profile, isDefault: store.isDefault(profile))
                        }
                        .foregroundStyle(Theme.Text.primary)
                    }
                    if visible.isEmpty {
                        Text(profiles.isEmpty ? "No profiles yet." : "No profiles match your search.")
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                } header: {
                    FormNote("\(profiles.count) \(profiles.count == 1 ? "profile" : "profiles")")
                } footer: {
                    FormNote("Profiles are independent Hermes environments: separate config, skills, and SOUL.md.")
                }
                .hermesFormRows()
            } else if let error = store.loadError {
                Section {
                    Text(error).foregroundStyle(Theme.destructive)
                    Button("Try again") { Task { await store.load() } }
                }
                .hermesFormRows()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.hermesFormRows()
            }
        }
        .hermesForm()
        .searchable(text: $query, prompt: "Search profiles")
        .navigationTitle("Profiles")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("New profile", systemImage: "plus") { creating = true }
                    Button("Import profile…", systemImage: "square.and.arrow.down") { importing = true }
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityLabel("Add profile")
                .disabled(store.profiles == nil)
            }
        }
        .task { await store.load() }
        .refreshable { await store.load() }
        .sheet(isPresented: $creating) {
            CreateProfileSheet(store: store) { opened = $0 }
        }
        .sheet(isPresented: $importing) {
            ImportProfileSheet(store: store) { opened = $0 }
        }
        .navigationDestination(item: $opened) { name in
            ProfileDetailScreen(store: store, name: name)
        }
    }
}

/// A profile's initial on a quiet disc (the desktop's `ProfileGlyph`).
struct ProfileGlyph: View {
    let profile: ProfileInfo
    var size: CGFloat = 28

    var body: some View {
        Text(String(profile.label.prefix(1)).uppercased())
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(Theme.Text.secondary)
            .frame(width: size, height: size)
            .background(Theme.Fill.secondary, in: Circle())
            .overlay {
                if profile.isDefault {
                    Circle().strokeBorder(Theme.Hairline.primary, lineWidth: Theme.hairlineWidth)
                }
            }
            .accessibilityHidden(true)
    }
}

private struct ProfileListRow: View {
    let profile: ProfileInfo
    let isDefault: Bool

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            ProfileGlyph(profile: profile)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(profile.label).hermesText(.rowTitle).lineLimit(1)
                    if isDefault { StatusTag("Default", tone: .good) }
                    if profile.gatewayRunning { StatusTag("Gateway", tone: .muted, systemImage: "circle.fill") }
                }
                Text(subtitle)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Image(systemName: Theme.Icon.disclosure)
                .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        let skills = "\(profile.skillCount) \(profile.skillCount == 1 ? "skill" : "skills")"
        return [profile.modelSummary ?? "No model set", skills].joined(separator: " · ")
    }
}
