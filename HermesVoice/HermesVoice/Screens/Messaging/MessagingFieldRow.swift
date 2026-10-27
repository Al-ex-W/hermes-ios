import SwiftUI

/// One setup field (`MessagingField`): its label with a "Saved" mark, the help, and the input: a secure field for a
/// secret (showing only the saved value's masked preview), one row per entry for an allowlist. Its tools are the
/// docs link and, for a saved value that isn't a list, Clear (asked first by the page). What is typed goes to the
/// page's draft only.
struct MessagingFieldRow: View {
    let field: MessagingEnvField
    /// The unsaved value; nil while untouched.
    let draft: String?
    let clearing: Bool
    let onEdit: (String) -> Void
    let onClear: () -> Void
    @Environment(\.openURL) private var openURL

    var body: some View {
        let copy = MessagingCopy.copy(field)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.sm) {
                Text(verbatim: copy.label).hermesText(.rowTitle)
                if field.isSet {
                    Text("Saved").hermesText(.meta).fontWeight(.medium).foregroundStyle(Theme.primary)
                }
                Spacer(minLength: 0)
                tools
            }
            if !copy.help.isEmpty {
                Text(verbatim: copy.help).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            if field.isList {
                MessagingAllowlistEditor(field: field, label: copy.label, pending: draft, onEdit: onEdit)
            } else {
                input(placeholder: copy.placeholder, label: copy.label)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    @ViewBuilder private var tools: some View {
        if let url = field.url {
            Button { openURL(url) } label: { Image(systemName: "arrow.up.right.square") }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open docs")
        }
        // A list clears by removing its last entry and saving.
        if field.isSet, !field.isList {
            Button(role: .destructive, action: onClear) { Image(systemName: Theme.Icon.delete) }
                .buttonStyle(.borderless)
                .disabled(clearing)
                .accessibilityLabel("Clear \(field.key)")
        }
    }

    private func input(placeholder: String, label: String) -> some View {
        let prompt = field.isSet ? (field.savedPreview ?? "Replace current value") : placeholder
        let text = Binding(get: { draft ?? "" }, set: onEdit)
        return Group {
            if field.isPassword {
                SecureField(prompt, text: text)
            } else {
                TextField(prompt, text: text)
            }
        }
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .font(Theme.TextStyle.code.font)
        .submitLabel(.done)
        .accessibilityLabel(label)
    }
}

/// An allowlist (`AllowlistField`): one input per allowed user or ID, + to add and × to remove, saved as one
/// comma-separated value. A save changes the saved value, which re-seeds the rows.
struct MessagingAllowlistEditor: View {
    let field: MessagingEnvField
    let label: String
    let onEdit: (String) -> Void
    @State private var rows: MessagingAllowlistRows
    @State private var synced: String?
    @FocusState private var focused: Int?

    init(field: MessagingEnvField, label: String, pending: String?, onEdit: @escaping (String) -> Void) {
        self.field = field
        self.label = label
        self.onEdit = onEdit
        _rows = State(initialValue: MessagingAllowlistRows(pending ?? field.value))
        _synced = State(initialValue: field.value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            ForEach(Array(rows.rows.enumerated()), id: \.element.id) { index, row in
                HStack(spacing: Theme.Spacing.md) {
                    TextField("Enter an ID", text: Binding(get: { row.value }, set: { change(row.id, $0) }))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.TextStyle.code.font)
                        .focused($focused, equals: row.id)
                        .submitLabel(.next)
                        .onSubmit {
                            if !row.value.trimmingCharacters(in: .whitespaces).isEmpty { focused = rows.add() }
                        }
                        .accessibilityLabel("\(label) \(index + 1)")
                    Button {
                        rows.remove(row.id)
                        onEdit(rows.joined)
                    } label: {
                        Image(systemName: Theme.Icon.close)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.Text.tertiary)
                    .disabled(rows.isLone)
                    .accessibilityLabel("Remove")
                }
            }
            Button { focused = rows.add() } label: {
                Label("Add another", systemImage: "plus").hermesText(.button)
            }
            .buttonStyle(.borderless)
        }
        .onChange(of: field.value) { _, value in
            guard value != synced else { return }
            synced = value
            rows = MessagingAllowlistRows(value)
        }
    }

    private func change(_ id: Int, _ value: String) {
        rows.change(id, to: value)
        onEdit(rows.joined)
    }
}
