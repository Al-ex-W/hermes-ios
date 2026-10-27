import SwiftUI

/// One subscription (`WebhookDetail`): where it delivers, which events and skills, the URL to copy, its description
/// and prompt. The row menu's Enable / Disable and Delete are in the toolbar menu here too.
struct WebhookDetailView: View {
    @ObservedObject var store: WebhooksStore
    let name: String
    /// Deletes a route the user confirmed here (and leaves this page).
    let delete: (WebhookRoute) -> Void
    @State private var confirmingDelete = false

    var body: some View {
        Group {
            if let route = store.route(name) {
                form(route)
            } else {
                ContentUnavailableView("Subscription unavailable", systemImage: Theme.Icon.warning,
                                       description: Text("It may have been deleted."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .hermesForm()
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .toolbar {
            if let route = store.route(name) {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { Task { await store.setEnabled(route, !route.enabled) } } label: {
                            Label(route.enabled ? "Disable" : "Enable", systemImage: route.enabled ? "circle.slash" : "checkmark")
                        }
                        .disabled(store.toggling.contains(route.name))
                        Divider()
                        Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                    } label: {
                        Image(systemName: Theme.Icon.more)
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .refreshable { await store.load() }
        .alert("Delete webhook", isPresented: $confirmingDelete, presenting: store.route(name)) { route in
            Button("Delete", role: .destructive) { delete(route) }
            Button("Cancel", role: .cancel) {}
        } message: { route in
            Text("This will permanently remove \(route.name). This cannot be undone.")
        }
        .opsConfirm($store.confirmation)
        .failureAlert($store.failure)
        .opsToast($store.notice)
    }

    private func form(_ route: WebhookRoute) -> some View {
        Form {
            Section {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(verbatim: route.name).hermesText(.rowTitle)
                    if route.deliverOnly { OpsPill("deliver only", tone: .warn) }
                    if !route.enabled { OpsPill("Disabled") }
                }
                LabeledContent("Deliver to", value: route.deliverLabel)
                LabeledContent("Events") {
                    if route.events.isEmpty {
                        Text("(all)").foregroundStyle(Theme.Text.tertiary)
                    } else {
                        pills(route.events)
                    }
                }
                if !route.skills.isEmpty {
                    LabeledContent("Skills") { pills(route.skills) }
                }
                LabeledContent("Secret") {
                    Text(route.secretSet ? "Set" : "None").foregroundStyle(Theme.Text.tertiary)
                }
                MessagingCopyRow(value: route.url)
            } footer: {
                if route.secretSet {
                    FormNote("The secret signs each delivery. It was shown once, when the subscription was created.")
                }
            }
            .hermesFormRows()
            if !route.description.isEmpty {
                Section {
                    Text(verbatim: route.description).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                } header: {
                    MessagingSectionTitle("Description")
                }
                .hermesFormRows()
            }
            if !route.prompt.isEmpty {
                Section {
                    OpsTextBlock(text: route.prompt)
                        .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.md,
                                                  bottom: Theme.Spacing.md, trailing: Theme.Spacing.md))
                } header: {
                    MessagingSectionTitle("Prompt")
                }
                .hermesFormRows()
            }
        }
    }

    private func pills(_ values: [String]) -> some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xs) {
            ForEach(values, id: \.self) { OpsPill($0) }
        }
    }
}

/// The new-subscription sheet, then the created route's URL and its secret (shown once, masked until revealed).
struct WebhookCreateSheet: View {
    @ObservedObject var store: WebhooksStore
    @Environment(\.dismiss) private var dismiss
    @State private var draft = WebhookDraft()
    @State private var creating = false
    @State private var created: WebhookCreated?
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Group {
                if let created { createdForm(created) } else { form }
            }
            .hermesForm()
            .navigationTitle(created == nil ? "New subscription" : "Subscription created")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                if created != nil {
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                } else {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(creating) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(creating ? "Creating..." : "Create") { Task { await create() } }
                            .disabled(creating)
                    }
                }
            }
        }
        // The secret shows only here: closing takes Done, never a stray swipe.
        .interactiveDismissDisabled(creating || created != nil)
    }

    private var form: some View {
        Form {
            Section {
                TextField("e.g. github-push", text: $draft.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($nameFocused)
                TextField("What this webhook does (optional)", text: $draft.description)
            } header: {
                MessagingSectionTitle("Name and description")
            }
            .hermesFormRows()
            Section {
                TextField("Instructions for the agent when this webhook fires (optional)", text: $draft.prompt, axis: .vertical)
                    .lineLimit(4...10)
            } header: {
                MessagingSectionTitle("Prompt")
            }
            .hermesFormRows()
            Section {
                LabeledContent("Events") {
                    TextField("comma-separated, leave empty for all", text: $draft.events)
                        .multilineTextAlignment(.trailing)
                }
                LabeledContent("Skills") {
                    TextField("comma-separated skill names (optional)", text: $draft.skills)
                        .multilineTextAlignment(.trailing)
                }
            }
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .hermesFormRows()
            Section {
                Picker("Deliver to", selection: $draft.deliver) {
                    ForEach(WebhookDelivery.options, id: \.self) { Text(WebhookDelivery.label($0)).tag($0) }
                }
                Toggle("Deliver payload only", isOn: $draft.deliverOnly)
            } footer: {
                FormNote("Payload only skips the agent and sends the event to the channel as is.")
            }
            .hermesFormRows()
            if let error {
                Section {
                    Text(verbatim: error).hermesText(.caption).foregroundStyle(Theme.destructive)
                }
                .hermesFormRows()
            }
        }
        .onAppear { nameFocused = true }
    }

    private func createdForm(_ created: WebhookCreated) -> some View {
        Form {
            Section {
                Text("Copy the secret now — it is only shown once.").hermesText(.caption).foregroundStyle(Theme.Text.secondary)
            }
            .hermesFormRows()
            Section {
                MessagingCopyRow(value: created.route.url)
            } header: {
                MessagingSectionTitle("Webhook URL")
            }
            .hermesFormRows()
            Section {
                MessagingSecretRow(secret: created.secret)
            } header: {
                MessagingSectionTitle("Secret (shown once)")
            } footer: {
                FormNote("Copied secrets stay on this phone and clear from the clipboard after two minutes.")
            }
            .hermesFormRows()
        }
    }

    private func create() async {
        guard !draft.trimmedName.isEmpty else {
            error = "Name required"
            return
        }
        creating = true
        error = nil
        defer { creating = false }
        do {
            created = try await store.create(draft)
            draft = WebhookDraft()
        } catch {
            if !error.isCancellation { self.error = "Failed to create: \(error.dashboardMessage)" }
        }
    }
}
