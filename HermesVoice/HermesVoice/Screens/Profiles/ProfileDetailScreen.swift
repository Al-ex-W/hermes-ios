import SwiftUI
import UIKit

/// One profile (`ProfileDetail`): its model, skills and directory, its SOUL.md, and the profile actions.
struct ProfileDetailScreen: View {
    @ObservedObject var store: ProfilesStore
    /// Follows a rename.
    @State private var name: String
    @State private var renaming = false
    @State private var confirmingDelete = false
    @State private var confirmingExport = false
    @State private var busy: String?
    @State private var exported: String?
    @State private var notice: String?
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ProfilesStore, name: String) {
        self.store = store
        _name = State(initialValue: name)
    }

    var body: some View {
        Group {
            if let profile = store.profile(named: name) {
                form(profile)
            } else if store.profiles == nil {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.sidebar)
            } else {
                ContentUnavailableView("Profile not found", systemImage: Theme.Icon.profile,
                                       description: Text("“\(name)” is no longer on the host."))
            }
        }
        .navigationTitle(store.profile(named: name)?.label ?? name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .failureAlert($failure)
        .alert("Profile exported", isPresented: Binding(get: { exported != nil }, set: { if !$0 { exported = nil } })) {
            Button("Copy path") { UIPasteboard.general.string = exported }
            Button("OK", role: .cancel) {}
        } message: {
            Text("The archive is on the Hermes host:\n\(exported ?? "")")
        }
        .alert("Hermes", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) {
                if store.profiles != nil, store.profile(named: name) == nil { dismiss() }
            }
        } message: {
            Text(notice ?? "")
        }
    }

    private func form(_ profile: ProfileInfo) -> some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.lg) {
                    ProfileGlyph(profile: profile, size: 40)
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text(profile.label).font(.system(size: 17, weight: .semibold))
                        tags(profile)
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                if let path = profile.path {
                    CopyableText(text: path)
                }
            } footer: {
                if profile.displayName != nil {
                    FormNote("Profile ID: \(profile.name)")
                }
            }
            .hermesFormRows()

            Section {
                LabeledContent("Model") {
                    Text(profile.modelSummary ?? "Not set")
                        .font(profile.model == nil ? Theme.TextStyle.body.font : Theme.TextStyle.code.font)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Skills", value: "\(profile.skillCount)")
                if let description = profile.description {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text("Role").foregroundStyle(Theme.Text.primary)
                        Text(description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
            .hermesFormRows()

            Section {
                NavigationLink {
                    SoulEditorScreen(client: store.client, profile: profile.name)
                } label: {
                    Label("SOUL.md", systemImage: "doc.text")
                }
            } footer: {
                FormNote("The system prompt and persona instructions baked into this profile.")
            }
            .hermesFormRows()

            Section {
                if store.isDefault(profile) {
                    Label("Default profile", systemImage: "checkmark.circle.fill").foregroundStyle(Theme.primary)
                } else {
                    actionButton("Set as default", systemImage: "checkmark.circle", id: "default") {
                        try await store.makeDefault(profile)
                    }
                }
            } footer: {
                FormNote("The default is used when Hermes starts and for new CLI runs and gateways. Existing sessions stay in their profiles.")
            }
            .hermesFormRows()

            Section {
                Button { renaming = true } label: { Label("Rename…", systemImage: Theme.Icon.rename) }
                Button { confirmingExport = true } label: {
                    HStack {
                        Label("Export…", systemImage: "square.and.arrow.up")
                        if busy == "export" { Spacer(); ProgressView() }
                    }
                }
                .disabled(busy != nil)
            } footer: {
                if profile.isDefault {
                    FormNote("This is the root profile: it can't be deleted, and renaming it sets a display name.")
                }
            }
            .hermesFormRows()

            if !profile.isDefault {
                Section {
                    Button(role: .destructive) { confirmingDelete = true } label: {
                        HStack {
                            Label("Delete profile…", systemImage: Theme.Icon.delete)
                            if busy == "delete" { Spacer(); ProgressView() }
                        }
                    }
                    .foregroundStyle(Theme.destructive)
                    .disabled(busy != nil)
                }
                .hermesFormRows()
            }
        }
        .hermesForm()
        .refreshable { await store.load() }
        .sheet(isPresented: $renaming) {
            RenameProfileSheet(store: store, profile: profile) { name = $0 }
        }
        .confirmationDialog("Delete profile?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete \(profile.name)", role: .destructive) { Task { await delete(profile) } }
        } message: {
            Text("This deletes \(profile.name) and removes its directory\(profile.path.map { " \($0)" } ?? "") on the host. This cannot be undone.")
        }
        .confirmationDialog("Export \(profile.label)?", isPresented: $confirmingExport, titleVisibility: .visible) {
            Button("Export") { Task { await export(profile) } }
        } message: {
            Text("Hermes writes a .tar.gz of the profile to its export folder on the host. The archive can include the profile's credentials, so it stays on the host.")
        }
    }

    @ViewBuilder private func tags(_ profile: ProfileInfo) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if store.isDefault(profile) { StatusTag("Default", tone: .good) }
            if store.isDashboards(profile) { StatusTag("Dashboard", tone: .muted) }
            if profile.hasEnv { StatusTag(".env", tone: .muted) }
            if profile.gatewayRunning { StatusTag("Gateway running", tone: .muted, systemImage: "circle.fill") }
        }
    }

    private func actionButton(_ title: String, systemImage: String, id: String,
                              _ action: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                busy = id
                defer { busy = nil }
                do { try await action() } catch { failure = error.dashboardMessage }
            }
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                if busy == id { Spacer(); ProgressView() }
            }
        }
        .disabled(busy != nil)
    }

    private func delete(_ profile: ProfileInfo) async {
        busy = "delete"
        defer { busy = nil }
        do {
            let deletion = try await store.delete(profile)
            if deletion.settlementPending {
                notice = "\(profile.name) was deleted, but Hermes couldn't settle its identity yet."
                    + (deletion.retryCommand.map { " Run “\($0)” on the host to finish." } ?? "")
            } else {
                dismiss()
            }
        } catch {
            failure = "Couldn't delete \(profile.name). \(error.dashboardMessage)"
        }
    }

    private func export(_ profile: ProfileInfo) async {
        busy = "export"
        defer { busy = nil }
        do {
            exported = try await store.export(profile)
        } catch {
            failure = "Couldn't export \(profile.name). \(error.dashboardMessage)"
        }
    }
}
