import SwiftUI

/// New profile (`create-profile-dialog.tsx`): a name, a profile to clone from, and an optional SOUL.md.
struct CreateProfileSheet: View {
    @ObservedObject var store: ProfilesStore
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var cloneFrom: String? = "default"
    @State private var soul = ""
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("my-profile", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.TextStyle.code.font)
                        .onChange(of: name) { _, new in
                            let clean = ProfileName.sanitize(new)
                            if clean != new { name = clean }
                        }
                } header: {
                    FormNote("Name")
                } footer: {
                    FormNote(ProfileName.hint, color: invalid ? Theme.destructive : Theme.Text.tertiary)
                }
                .hermesFormRows()

                Section {
                    Picker("Clone from", selection: $cloneFrom) {
                        Text("None (blank)").tag(String?.none)
                        ForEach(store.profiles ?? []) { profile in
                            Text(profile.label).tag(String?.some(profile.name))
                        }
                    }
                } footer: {
                    FormNote("Copies config, skills, and SOUL.md from the selected source profile.")
                }
                .hermesFormRows()

                Section {
                    SoulTextEditor(text: $soul, placeholder: "The system prompt / persona for this profile.\nLeave blank to keep the \(cloneFrom == nil ? "empty" : "cloned") default.")
                        .frame(minHeight: 160)
                } header: {
                    FormNote("SOUL.md (optional)")
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle("New profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Create") { Task { await create() } }
                            .disabled(trimmed.isEmpty || invalid)
                    }
                }
            }
            .failureAlert($failure)
            .interactiveDismissDisabled(saving || !soul.isEmpty)
        }
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var invalid: Bool { !trimmed.isEmpty && !ProfileName.isValid(trimmed) }

    private func create() async {
        guard ProfileName.isValid(trimmed) else {
            failure = trimmed.isEmpty ? "Name is required." : "Invalid name. \(ProfileName.hint)"
            return
        }
        saving = true
        defer { saving = false }
        do {
            let created = try await store.create(name: trimmed, cloneFrom: cloneFrom, soul: soul)
            dismiss()
            onCreated(created)
        } catch {
            failure = "Couldn't create the profile. \(error.dashboardMessage)"
        }
    }
}

/// Rename (`rename-profile-dialog.tsx`). The root profile gets a free-text display name; its id stays "default".
struct RenameProfileSheet: View {
    @ObservedObject var store: ProfilesStore
    let profile: ProfileInfo
    let onRenamed: (String) -> Void
    @State private var name: String
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(store: ProfilesStore, profile: ProfileInfo, onRenamed: @escaping (String) -> Void) {
        self.store = store
        self.profile = profile
        self.onRenamed = onRenamed
        // Display-name mode starts from the current display name; "default" is the id, not a name.
        _name = State(initialValue: profile.isDefault ? (profile.displayName ?? "") : profile.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if profile.isDefault {
                        TextField("Display name", text: $name)
                    } else {
                        TextField("New name", text: $name)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.TextStyle.code.font)
                            .onChange(of: name) { _, new in
                                let clean = ProfileName.sanitize(new)
                                if clean != new { name = clean }
                            }
                    }
                } header: {
                    FormNote(profile.isDefault ? "Display name" : "New name")
                } footer: {
                    if profile.isDefault {
                        FormNote("Sets a display name shown across the app. The internal profile ID stays “default”.")
                    } else {
                        FormNote(ProfileName.hint + " Renaming moves the profile's directory, wrapper script and sessions"
                                 + (profile.gatewayRunning ? ", and stops its running gateway first." : "."),
                                 color: invalid ? Theme.destructive : Theme.Text.tertiary)
                    }
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle(profile.isDefault ? "Name this agent" : "Rename profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button(profile.isDefault ? "Save" : "Rename") { Task { await rename() } }
                            .disabled(trimmed.isEmpty || invalid)
                    }
                }
            }
            .failureAlert($failure)
            .interactiveDismissDisabled(saving)
        }
        .presentationDetents([.medium, .large])
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unchanged: Bool { !profile.isDefault && trimmed == profile.name }
    private var invalid: Bool { !profile.isDefault && !trimmed.isEmpty && !unchanged && !ProfileName.isValid(trimmed) }

    private func rename() async {
        if unchanged { return dismiss() }
        saving = true
        defer { saving = false }
        do {
            let renamed = try await store.rename(profile, to: trimmed)
            onRenamed(renamed)
            dismiss()
        } catch {
            failure = "Couldn't rename \(profile.label). \(error.dashboardMessage)"
        }
    }
}

/// Import a profile archive that is already on the Hermes host (Hermes exchanges paths, not bytes).
struct ImportProfileSheet: View {
    @ObservedObject var store: ProfilesStore
    let onImported: (String) -> Void
    @State private var path = ""
    @State private var name = ""
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("~/.hermes/exports/profile.tar.gz", text: $path)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.TextStyle.code.font)
                } header: {
                    FormNote("Archive on the host")
                } footer: {
                    FormNote("The path of a profile .tar.gz on the computer running Hermes, such as one made with Export.")
                }
                .hermesFormRows()

                Section {
                    TextField("Name from the archive", text: $name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.TextStyle.code.font)
                        .onChange(of: name) { _, new in
                            let clean = ProfileName.sanitize(new)
                            if clean != new { name = clean }
                        }
                } header: {
                    FormNote("Name (optional)")
                } footer: {
                    FormNote(invalid ? "Invalid name. \(ProfileName.hint)" : "Leave blank to use the name inside the archive.",
                             color: invalid ? Theme.destructive : Theme.Text.tertiary)
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle("Import profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Import") { Task { await importArchive() } }
                            .disabled(path.trimmingCharacters(in: .whitespaces).isEmpty || invalid)
                    }
                }
            }
            .failureAlert($failure)
            .interactiveDismissDisabled(saving)
        }
        .presentationDetents([.medium, .large])
    }

    private var invalid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && !ProfileName.isValid(trimmed)
    }

    private func importArchive() async {
        saving = true
        defer { saving = false }
        do {
            let imported = try await store.importArchive(path, name: name)
            dismiss()
            if !imported.isEmpty { onImported(imported) }
        } catch {
            failure = "Couldn't import the profile. \(error.dashboardMessage)"
        }
    }
}

/// A monospaced plain-text editor for SOUL.md (`CodeTextView`) with a placeholder.
struct SoulTextEditor: View {
    @Binding var text: String
    var placeholder = ""

    var body: some View {
        ZStack(alignment: .topLeading) {
            CodeTextView(text: $text)
            if text.isEmpty, !placeholder.isEmpty {
                Text(placeholder)
                    .font(CodeTextView.font)
                    .foregroundStyle(Theme.Text.quaternary)
                    .padding(.top, CodeTextView.inset.top)
                    .padding(.leading, CodeTextView.inset.left + 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
