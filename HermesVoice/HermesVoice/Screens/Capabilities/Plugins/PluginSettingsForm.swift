import SwiftUI

/// A plugin's manifest `config_schema` as a form (`plugin-settings-form.tsx`): each value is drafted as text and
/// coerced to its type on Save. Non-secret values go over `plugins.manage settings`; a secret goes to the scoped
/// profile's `.env` and is never shown, kept or logged here (a stored one reads "Stored").
struct PluginSettingsSection: View {
    @ObservedObject var store: PluginsStore
    let plugin: AgentPlugin
    let profileLabel: String
    @State private var draft: [String: String] = [:]
    /// The fields the draft was seeded from: a refreshed row re-seeds it (a saved value is the new baseline).
    @State private var seededFrom: [PluginSetting]?
    @State private var error: String?

    private var fields: [PluginSetting] { plugin.settings }
    private var seed: [String: String] { PluginSettingsChanges.initialDraft(fields) }
    private var dirty: Bool { fields.contains { (draft[$0.key] ?? "") != (seed[$0.key] ?? "") } }

    var body: some View {
        Section {
            ForEach(fields) { field in
                fieldRow(field)
            }
            if let error {
                FormNote(error, color: Theme.destructive)
            }
            Button {
                Task { await save() }
            } label: {
                HStack {
                    Text("Save settings")
                    Spacer()
                    if store.isBusy(plugin) { ProgressView() }
                }
            }
            .disabled(!dirty || store.busy != nil || store.api == nil)
        } header: {
            FormNote("Settings")
        } footer: {
            FormNote("Saved to \(plugin.name)'s settings in \(profileLabel). Secrets go to the profile's .env.")
        }
        .hermesFormRows()
        .onAppear(perform: reseedIfNeeded)
        .onChange(of: fields) { _, _ in reseedIfNeeded() }
    }

    private func reseedIfNeeded() {
        guard seededFrom != fields else { return }
        seededFrom = fields
        draft = seed
        error = nil
    }

    private func binding(_ field: PluginSetting) -> Binding<String> {
        Binding(get: { draft[field.key] ?? "" }, set: { draft[field.key] = $0 })
    }

    @ViewBuilder private func fieldRow(_ field: PluginSetting) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            switch field.kind {
            case .boolean:
                Toggle(isOn: Binding(get: { draft[field.key] == "true" }, set: { draft[field.key] = $0 ? "true" : "false" })) {
                    title(field)
                }
            case .choice:
                Picker(selection: binding(field)) {
                    ForEach(field.choices, id: \.self) { Text($0).tag($0) }
                } label: {
                    title(field)
                }
                .pickerStyle(.menu)
            case .json:
                title(field)
                TextEditor(text: binding(field))
                    .font(Theme.TextStyle.code.font)
                    .frame(minHeight: 88)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityLabel(field.label)
            case .number:
                title(field)
                TextField(field.label, text: binding(field))
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .string:
                title(field)
                TextField(field.label, text: binding(field))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            case .secret:
                title(field)
                SecureField(field.hasValue ? "Stored. Enter a new value to replace it." : "Not set", text: binding(field))
                    .font(Theme.TextStyle.code.font)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }
            if let hint = hint(field) {
                Text(hint).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private func title(_ field: PluginSetting) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(field.label).foregroundStyle(Theme.Text.primary)
            if !field.required {
                Text("Optional").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
        }
    }

    private func hint(_ field: PluginSetting) -> String? {
        var parts: [String] = []
        if !field.description.isEmpty { parts.append(field.description) }
        if field.kind == .secret, let env = field.env { parts.append("Stored as \(env) in the profile's .env.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func save() async {
        let changes: PluginSettingsChanges
        do {
            changes = try PluginSettingsChanges.collect(fields, draft: draft)
        } catch {
            self.error = error.localizedDescription
            return
        }
        error = nil
        guard !changes.isEmpty else { return }
        if await store.saveSettings(plugin, changes) {
            // Secrets are never echoed back: clear them so the field reads "Stored".
            for field in fields where field.kind == .secret { draft[field.key] = "" }
        }
    }
}
