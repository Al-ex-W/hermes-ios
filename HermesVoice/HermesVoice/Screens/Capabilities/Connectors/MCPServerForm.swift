import SwiftUI

/// "Connect to a custom MCP" (`add-dialog.tsx` + `add-server-form.tsx`), and the same fields to edit a saved
/// server. Env and header values are secure fields; while editing, a saved value shows only as the host's mask and
/// stays on the host unless a new one is typed. Nothing typed here is logged or kept by the app.
struct MCPServerForm: View {
    enum Mode: Hashable {
        case add
        case edit(String)
    }

    @ObservedObject var model: ConnectorsModel
    let mode: Mode
    /// Called with the server's name once it is saved.
    let onSaved: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var draft = MCPServerDraft()
    @State private var loaded = false
    @State private var loadError: String?
    @State private var paste = ""
    @State private var pasteFailed = false
    @State private var saving = false
    @State private var error: String?

    private var isEdit: Bool { if case .edit = mode { return true } else { return false } }

    private var nameTaken: Bool {
        guard !isEdit else { return false }
        return draft.nameTaken(in: model.names)
    }

    var body: some View {
        Group {
            if isEdit && !loaded {
                if let loadError {
                    ContentUnavailableView {
                        Label("Couldn't read the server", systemImage: Theme.Icon.error)
                    } description: {
                        Text(loadError)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                form
            }
        }
        .navigationTitle(isEdit ? "Edit \(draft.name.isEmpty ? "server" : draft.name)" : "Connect to a custom MCP")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !isEdit {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await save() } }
                        .disabled(!draft.isComplete || nameTaken || (isEdit && !loaded))
                }
            }
        }
        .interactiveDismissDisabled(saving)
        .task { if isEdit, !loaded { await load() } }
    }

    private var form: some View {
        Form {
            if !isEdit {
                Section {
                    TextField("npx -y @modelcontextprotocol/server-filesystem /path/to/dir", text: $paste, axis: .vertical)
                        .lineLimit(2...6)
                        .font(Theme.TextStyle.code.font)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: paste) { _, value in read(value) }
                } header: {
                    FormNote("Paste a command or a snippet")
                } footer: {
                    if pasteFailed { FormNote("Nothing here reads as a server. Fill the fields below instead.") }
                }
                .hermesFormRows()
            }

            Section {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .disabled(isEdit)
                    .foregroundStyle(isEdit ? Theme.Text.secondary : Theme.Text.primary)
            } header: {
                FormNote("Name")
            } footer: {
                if nameTaken { FormNote("That name is already used.", color: Theme.Semantic.red) }
            }
            .hermesFormRows()

            Section {
                Picker("Type", selection: $draft.transport) {
                    Text("STDIO").tag(MCPServerDraft.Transport.stdio)
                    Text("Streamable HTTP").tag(MCPServerDraft.Transport.http)
                }
                .pickerStyle(.segmented)
            } header: {
                FormNote("Type")
            } footer: {
                if draft.transport == .stdio {
                    FormNote("The command runs on the Hermes host.")
                }
            }
            .hermesFormRows()

            if draft.transport == .stdio { stdioFields } else { httpFields }

            if let error {
                Section {
                    Label(error, systemImage: Theme.Icon.error)
                        .foregroundStyle(Theme.Semantic.red)
                        .textSelection(.enabled)
                }
                .hermesFormRows()
            }
        }
        .hermesForm()
    }

    // MARK: STDIO

    @ViewBuilder private var stdioFields: some View {
        Section {
            TextField("Command to launch", text: $draft.command)
                .font(Theme.TextStyle.code.font)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            FormNote("Command to launch")
        }
        .hermesFormRows()

        Section {
            ForEach($draft.args) { $row in
                RowField(placeholder: "Argument", text: $row.value) { draft.args.removeAll { $0.id == row.id } }
            }
            Button("+ Add argument") { draft.args.append(.init()) }
        } header: {
            FormNote("Arguments")
        }
        .hermesFormRows()

        Section {
            ForEach($draft.env) { $row in
                PairField(pair: $row) { draft.env.removeAll { $0.id == row.id } }
            }
            Button("+ Add environment variable") { draft.env.append(.init()) }
        } header: {
            FormNote("Environment variables")
        }
        .hermesFormRows()

        Section {
            ForEach($draft.passthrough) { $row in
                RowField(placeholder: "KEY", text: $row.value) { draft.passthrough.removeAll { $0.id == row.id } }
            }
            Button("+ Add variable") { draft.passthrough.append(.init()) }
        } header: {
            FormNote("Environment variable passthrough")
        } footer: {
            FormNote("The server gets these from the host's own environment.")
        }
        .hermesFormRows()

        Section {
            TextField("Working directory", text: $draft.cwd)
                .font(Theme.TextStyle.code.font)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            FormNote("Working directory")
        }
        .hermesFormRows()
    }

    // MARK: HTTP

    @ViewBuilder private var httpFields: some View {
        Section {
            TextField("https://", text: $draft.url)
                .font(Theme.TextStyle.code.font)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        } header: {
            FormNote("URL")
        }
        .hermesFormRows()

        Section {
            ForEach($draft.headers) { $row in
                PairField(pair: $row) { draft.headers.removeAll { $0.id == row.id } }
            }
            Button("+ Add header") { draft.headers.append(.init()) }
        } header: {
            FormNote("Headers")
        }
        .hermesFormRows()

        Section {
            Picker("Auth", selection: $draft.auth) {
                Text("None").tag(MCPServerDraft.Auth.none)
                Text("OAuth").tag(MCPServerDraft.Auth.oauth)
                Text("Bearer token").tag(MCPServerDraft.Auth.bearer)
            }
            .pickerStyle(.segmented)
            if draft.auth == .bearer {
                SecretInput(title: draft.hasStoredBearer ? "Saved — type a new token to replace it" : "Bearer token",
                            text: $draft.bearer)
            }
        } header: {
            FormNote("Auth")
        } footer: {
            switch draft.auth {
            case .bearer: FormNote("The token goes to the host's .env; the config only references it.")
            case .oauth: FormNote("Authenticate from the server's page after saving.")
            case .none: EmptyView()
            }
        }
        .hermesFormRows()
    }

    // MARK: Actions

    private func read(_ text: String) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            pasteFailed = false
            return
        }
        guard let first = MCPImport.parse(text)?.first else {
            pasteFailed = true
            return
        }
        pasteFailed = false
        draft = MCPImport.draft(first, previous: draft)
    }

    private func load() async {
        guard case let .edit(name) = mode else { return }
        do {
            draft = try await model.editDraft(name)
            loaded = true
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.dashboardMessage
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        error = nil
        let name = MCPServerDraft.trim(draft.name)
        do {
            switch mode {
            case .add: try await model.create(draft)
            case let .edit(saved): try await model.update(saved, draft: draft)
            }
            onSaved(name)
            dismiss()
        } catch {
            guard !error.isCancellation else { return }
            self.error = error.dashboardMessage
        }
    }
}

/// One value row with its remove button.
private struct RowField: View {
    let placeholder: String
    @Binding var text: String
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            TextField(placeholder, text: $text)
                .font(Theme.TextStyle.code.font)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            RemoveRowButton(action: remove)
        }
    }
}

/// A key and a secret value. A kept value shows the host's mask as its placeholder; typing replaces it.
private struct PairField: View {
    @Binding var pair: MCPServerDraft.Pair
    let remove: () -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(spacing: Theme.Spacing.sm) {
                TextField("KEY", text: $pair.key)
                    .font(Theme.TextStyle.code.font)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField(placeholder, text: Binding(get: { pair.value }, set: { value in
                    pair.value = value
                    if !value.isEmpty { pair.kept = nil }
                }))
                .font(Theme.TextStyle.code.font)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            }
            RemoveRowButton(action: remove)
        }
    }

    private var placeholder: String {
        guard let kept = pair.kept else { return "value" }
        return kept.isEmpty ? "Saved (empty)" : "Saved: \(CredentialMask.display(kept) ?? kept)"
    }
}

private struct RemoveRowButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "minus.circle")
                .foregroundStyle(Theme.Text.tertiary)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Remove this row")
    }
}
