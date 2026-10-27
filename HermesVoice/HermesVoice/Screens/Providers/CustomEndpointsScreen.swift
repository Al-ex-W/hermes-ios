import SwiftUI

/// Providers › Custom endpoints (`custom-endpoints-settings.tsx`): OpenAI-compatible endpoints in the profile's
/// config. Their keys go to the host's `.env`; the list shows previews only.
struct CustomEndpointsScreen: View {
    let client: DashboardClient
    let profile: String?
    @State private var list: CustomEndpointList?
    @State private var loadError: String?
    @State private var editing: EditorTarget?
    @State private var confirmingDelete: CustomEndpoint?
    @State private var busy: String?
    @State private var failure: String?

    /// The editor sheet: a new endpoint or one from the list.
    struct EditorTarget: Identifiable {
        var endpoint: CustomEndpoint?
        var id: String { endpoint?.id ?? "\u{0}new" }
    }

    var body: some View {
        Form {
            if let list {
                Section {
                    ForEach(list.endpoints) { endpoint in
                        Button {
                            editing = EditorTarget(endpoint: endpoint)
                        } label: {
                            EndpointRow(endpoint: endpoint, busy: busy == endpoint.id)
                        }
                        .foregroundStyle(Theme.Text.primary)
                        .swipeActions(edge: .trailing) {
                            Button("Delete", role: .destructive) { confirmingDelete = endpoint }
                        }
                        .swipeActions(edge: .leading) {
                            if !endpoint.isCurrent {
                                Button("Use") { Task { await activate(endpoint) } }.tint(Theme.primary)
                            }
                        }
                        .contextMenu {
                            if !endpoint.isCurrent {
                                Button("Use as main model", systemImage: "checkmark.circle") { Task { await activate(endpoint) } }
                            }
                            Button("Delete", systemImage: Theme.Icon.delete, role: .destructive) { confirmingDelete = endpoint }
                        }
                    }
                    Button {
                        editing = EditorTarget(endpoint: nil)
                    } label: {
                        Label("Add endpoint", systemImage: "plus")
                    }
                } header: {
                    FormNote("Endpoints")
                } footer: {
                    FormNote(list.endpoints.isEmpty
                             ? "Point Hermes at any OpenAI-compatible endpoint (Zyphra, vLLM, llama.cpp, Ollama, etc)."
                             : "Swipe an endpoint to make it the main model or to delete it.")
                }
                .hermesFormRows()
            } else if let loadError {
                Section {
                    Text(loadError).foregroundStyle(Theme.destructive)
                    Button("Try again") { Task { await load() } }
                }
                .hermesFormRows()
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }.hermesFormRows()
            }
        }
        .hermesForm()
        .navigationTitle("Custom endpoints")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { editing = EditorTarget(endpoint: nil) } label: { Image(systemName: "plus") }
                    .accessibilityLabel("Add endpoint")
                    .disabled(list == nil)
            }
        }
        .task(id: profile) { await load() }
        .refreshable { await load() }
        .sheet(item: $editing) { target in
            CustomEndpointEditor(client: client, profile: profile, endpoint: target.endpoint) { saved in
                list = saved
                NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
            }
        }
        .confirmationDialog("Delete \(confirmingDelete?.name ?? "")?",
                            isPresented: Binding(get: { confirmingDelete != nil }, set: { if !$0 { confirmingDelete = nil } }),
                            titleVisibility: .visible, presenting: confirmingDelete) { endpoint in
            Button("Delete", role: .destructive) { Task { await delete(endpoint) } }
        } message: { endpoint in
            Text(endpoint.isCurrent
                 ? "The endpoint and its key are removed, and the main model no longer runs on it."
                 : "The endpoint and its key are removed from this profile.")
        }
        .failureAlert($failure)
    }

    private func load() async {
        do {
            list = try await client.customEndpoints(profile: profile)
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if list == nil { loadError = error.dashboardMessage } else { failure = error.dashboardMessage }
        }
    }

    private func activate(_ endpoint: CustomEndpoint) async {
        busy = endpoint.id
        defer { busy = nil }
        do {
            try await client.activateCustomEndpoint(endpoint.id, profile: profile)
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
            await load()
        } catch {
            failure = "Couldn't switch to \(endpoint.name). \(error.dashboardMessage)"
        }
    }

    private func delete(_ endpoint: CustomEndpoint) async {
        busy = endpoint.id
        defer { busy = nil }
        do {
            list = try await client.deleteCustomEndpoint(endpoint.id, profile: profile)
            NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
        } catch {
            failure = "Couldn't delete \(endpoint.name). \(error.dashboardMessage)"
        }
    }
}

private struct EndpointRow: View {
    let endpoint: CustomEndpoint
    var busy = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(endpoint.name).hermesText(.rowTitle)
                    if endpoint.isCurrent { StatusTag("Main model", tone: .good, systemImage: "checkmark") }
                }
                Text(endpoint.model.isEmpty ? "No model" : endpoint.model)
                    .font(Theme.TextStyle.code.font)
                    .foregroundStyle(Theme.Text.secondary)
                    .lineLimit(1)
                Text(endpoint.baseURL)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if busy { ProgressView() }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
    }
}

/// Adds or edits one endpoint: URL, key, transport, model. "Test" asks the dashboard to try the endpoint and lists
/// the models it serves; Save stores the URL that actually answered.
struct CustomEndpointEditor: View {
    let client: DashboardClient
    let profile: String?
    let endpoint: CustomEndpoint?
    let onSaved: (CustomEndpointList) -> Void
    @State private var draft: CustomEndpointDraft
    @State private var models: [String]
    @State private var details: [EndpointModelDetail] = []
    @State private var probe: EndpointProbe?
    @State private var testing = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(client: DashboardClient, profile: String?, endpoint: CustomEndpoint?, onSaved: @escaping (CustomEndpointList) -> Void) {
        self.client = client
        self.profile = profile
        self.endpoint = endpoint
        self.onSaved = onSaved
        _draft = State(initialValue: endpoint.map(CustomEndpointDraft.init(editing:)) ?? CustomEndpointDraft())
        _models = State(initialValue: endpoint?.models ?? [])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("https://host:8000/v1", text: $draft.baseURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(Theme.TextStyle.code.font)
                    Picker("API", selection: $draft.apiMode) {
                        ForEach(EndpointAPIMode.allCases) { Text($0.title).tag($0) }
                    }
                } header: {
                    FormNote("Endpoint")
                }
                .hermesFormRows()

                Section {
                    if let saved = endpoint?.keyDisplay {
                        LabeledContent("Saved") {
                            Text(saved).font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    SecretInput(title: endpoint?.hasAPIKey == true ? "Paste a new key to replace it" : "API key (optional)",
                                text: $draft.apiKey)
                } header: {
                    FormNote("API key")
                } footer: {
                    FormNote("Only if the endpoint needs one. It's stored in the profile's .env on the Hermes host.")
                }
                .hermesFormRows()

                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if testing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(testing || draft.baseURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let probe {
                        Text(probe.summary)
                            .hermesText(.caption)
                            .foregroundStyle(probe.ok ? Theme.Text.secondary : Theme.destructive)
                    }
                }
                .hermesFormRows()

                Section {
                    if models.isEmpty {
                        TextField("Model name", text: $draft.model)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(Theme.TextStyle.code.font)
                    } else {
                        Picker("Model", selection: $draft.model) {
                            if !draft.model.isEmpty, !models.contains(draft.model) {
                                Text(draft.model).tag(draft.model)
                            }
                            ForEach(models, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.navigationLink)
                    }
                    TextField("Context length (optional)", text: $draft.contextLength)
                        .keyboardType(.numberPad)
                    Toggle("Discover models", isOn: $draft.discoverModels)
                    Toggle("Use as main model", isOn: $draft.makeDefault)
                } header: {
                    FormNote("Model")
                } footer: {
                    FormNote("Test the connection to list the endpoint's models. Discover models keeps that list current.")
                }
                .hermesFormRows()
            }
            .hermesForm()
            .navigationTitle(endpoint == nil ? "New endpoint" : endpoint?.name ?? "Endpoint")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView()
                    } else {
                        Button("Save") { Task { await save() } }
                            .disabled(draft.problem != nil)
                    }
                }
            }
            .failureAlert($failure)
            .interactiveDismissDisabled(saving || testing)
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        do {
            let result = try await client.probeCustomEndpoint(draft, profile: profile)
            probe = result
            if !result.models.isEmpty {
                models = result.models
                details = result.details
            }
            if result.ok {
                if draft.model.isEmpty, let first = result.models.first { draft.model = first }
                // Save the URL that served /models: chats post to it verbatim.
                if let resolved = result.resolvedBaseURL, resolved != draft.baseURL.trimmingCharacters(in: .whitespaces).trimmingSuffix("/") {
                    draft.baseURL = resolved
                }
            }
        } catch {
            failure = error.dashboardMessage
        }
    }

    private func save() async {
        if let problem = draft.problem {
            failure = problem
            return
        }
        saving = true
        defer { saving = false }
        do {
            let saved = try await client.saveCustomEndpoint(draft, models: models, details: details, profile: profile)
            draft.apiKey = ""
            onSaved(saved)
            dismiss()
        } catch {
            failure = "Couldn't save the endpoint. \(error.dashboardMessage)"
        }
    }
}
