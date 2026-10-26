import SwiftUI

/// The selected memory provider's own settings under Memory Provider (`ProviderConfigPanel`, the declared
/// surface of `/api/memory/providers/<name>/config`). Values are edited as text and saved together; a secret is
/// write-only: it shows as set, and only a newly typed value is sent.
struct MemoryProviderPanel: View {
    @EnvironmentObject private var context: SettingsContext
    let provider: String

    @State private var config: ConfigAPI.MemoryProvider?
    @State private var drafts: [String: String] = [:]
    @State private var saving = false
    @State private var failure: String?
    @State private var saved = false

    /// The values that differ from what's stored; a secret only when one was typed.
    static func changes(_ fields: [ConfigAPI.MemoryProvider.Field], drafts: [String: String]) -> [String: String] {
        var changes: [String: String] = [:]
        for field in fields {
            guard let draft = drafts[field.key] else { continue }
            if field.kind == .secret {
                if !draft.trimmingCharacters(in: .whitespaces).isEmpty { changes[field.key] = draft }
            } else if draft != field.value {
                changes[field.key] = draft
            }
        }
        return changes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack {
                Text("\(config?.label ?? provider) settings").hermesText(.label).foregroundStyle(Theme.Text.secondary)
                Spacer()
                if let docs = config?.docsURL.flatMap(URL.init(string:)) { Link("Docs", destination: docs).hermesText(.button) }
            }
            if let config {
                if config.fields.isEmpty {
                    Text("Nothing to configure.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
                ForEach(config.fields) { field in fieldRow(field) }
                if !config.fields.isEmpty {
                    HStack {
                        Button("Save provider settings") { Task { await save(config) } }
                            .disabled(saving || Self.changes(config.fields, drafts: drafts).isEmpty)
                        if saving { ProgressView() }
                        if saved { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
                    }
                    .buttonStyle(.borderless)
                    .hermesText(.button)
                }
            } else if failure == nil {
                ProgressView()
            }
            if let failure { Text(failure).hermesText(.caption).foregroundStyle(Theme.destructive) }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task(id: provider) { await reload() }
    }

    @ViewBuilder private func fieldRow(_ field: ConfigAPI.MemoryProvider.Field) -> some View {
        let binding = Binding(get: { drafts[field.key] ?? (field.kind == .secret ? "" : field.value) },
                              set: { drafts[field.key] = $0; saved = false })
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            switch field.kind {
            case .bool:
                Toggle(field.label, isOn: Binding(get: { JSONValue.string(binding.wrappedValue).truthy },
                                                  set: { binding.wrappedValue = $0 ? "true" : "false" }))
            case .select:
                Picker(field.label, selection: binding) {
                    ForEach(field.options, id: \.value) { Text($0.label).tag($0.value) }
                }
                .pickerStyle(.menu)
            case .secret:
                Text(field.label).foregroundStyle(Theme.Text.primary)
                SecureField(field.isSet ? "Set. Type to replace." : (field.placeholder.nilIfEmpty ?? "Not set"), text: binding)
            case .json:
                Text(field.label).foregroundStyle(Theme.Text.primary)
                TextField(field.placeholder.nilIfEmpty ?? "{}", text: binding, axis: .vertical)
                    .font(Theme.TextStyle.code.font)
                    .lineLimit(2...8)
            case .number:
                Text(field.label).foregroundStyle(Theme.Text.primary)
                TextField(field.placeholder.nilIfEmpty ?? "Not set", text: binding).keyboardType(.decimalPad)
            case .text:
                Text(field.label).foregroundStyle(Theme.Text.primary)
                TextField(field.placeholder.nilIfEmpty ?? "Not set", text: binding)
            }
            if !field.description.isEmpty {
                Text(field.description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
    }

    private func reload() async {
        do {
            config = try await context.api.memoryProvider(provider)
            drafts = [:]
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
    }

    private func save(_ config: ConfigAPI.MemoryProvider) async {
        let changes = Self.changes(config.fields, drafts: drafts)
        guard !changes.isEmpty else { return }
        saving = true
        defer { saving = false }
        do {
            try await context.api.saveMemoryProvider(provider, values: changes)
            await reload()
            saved = true
        } catch {
            var message = error.localizedDescription
            for secret in changes.values { message = CredentialMask.scrub(message, secret: secret) }
            failure = message
        }
    }
}
