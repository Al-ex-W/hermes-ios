import SwiftUI

/// One platform's page (`PlatformDetail` with its `PlatformActionBar`): status, the connection test, pairing
/// requests and approved users, the QR quick setup (Telegram, WhatsApp), how to get credentials, and the setup
/// fields (required, recommended, advanced). The action bar at the bottom switches the platform on or off and saves
/// the draft.
struct MessagingPlatformDetail: View {
    @ObservedObject var store: MessagingStore
    let platformID: String

    @State private var showAdvanced = false
    @State private var pendingRevoke: PairingUser?
    @State private var pendingClear: MessagingEnvField?
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if let platform = store.platform(platformID) {
                form(platform)
                    .safeAreaInset(edge: .bottom, spacing: 0) { actionBar(platform) }
            } else if store.platforms == nil {
                List { OpsLoaderRow() }
            } else {
                ContentUnavailableView("Platform unavailable", systemImage: Theme.Icon.warning,
                                       description: Text("This Hermes no longer lists it."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            }
        }
        .hermesForm()
        .navigationTitle(store.platform(platformID)?.name ?? "Messaging")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .refreshable { await store.refreshAll() }
        .task { await store.keepFresh() }
        .alert("Revoke access", isPresented: Binding(get: { pendingRevoke != nil }, set: { if !$0 { pendingRevoke = nil } }),
               presenting: pendingRevoke) { user in
            Button("Revoke", role: .destructive) { Task { await store.revoke(user) } }
            Button("Cancel", role: .cancel) {}
        } message: { user in
            Text("\(user.label) will lose access and stop being recognized on their next message.")
        }
        .alert("Clear \(pendingClear?.key ?? "")?", isPresented: Binding(get: { pendingClear != nil },
                                                                        set: { if !$0 { pendingClear = nil } }),
               presenting: pendingClear) { field in
            Button("Clear", role: .destructive) {
                guard let platform = store.platform(platformID) else { return }
                Task { await store.clear(platform, key: field.key) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Hermes removes the saved value from this profile's settings. The platform stops working until it is set again.")
        }
        .opsConfirm($store.confirmation)
        .failureAlert($store.failure)
        .opsToast($store.notice)
    }

    private func form(_ platform: MessagingPlatform) -> some View {
        let pending = store.pairing.pending(for: platform.id)
        let approved = store.pairing.approved(for: platform.id)
        let fields = platform.envVars.map { (field: $0, copy: MessagingCopy.copy($0)) }
        let required = fields.filter { $0.field.required }
        let recommended = fields.filter { !$0.field.required && !$0.copy.advanced }
        let advanced = fields.filter { !$0.field.required && $0.copy.advanced }
        return Form {
            if store.restartNeeded { MessagingRestartSection(store: store) }
            headerSection(platform)
            testSection(platform)
            if !pending.isEmpty { pendingSection(pending) }
            if !approved.isEmpty { approvedSection(approved) }
            if platform.id == "telegram" {
                Section {
                    MessagingTelegramSetup(store: store, platform: platform)
                } header: {
                    MessagingSectionTitle("Quick setup")
                }
                .hermesFormRows()
            }
            if platform.id == "whatsapp" {
                Section {
                    MessagingWhatsAppSetup(store: store, platform: platform)
                } header: {
                    MessagingSectionTitle("Pair with QR")
                }
                .hermesFormRows()
            }
            credentialsSection(platform)
            Section {
                if required.isEmpty {
                    Text("This platform does not need a token here. Use the setup guide above, then enable it below.")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                } else {
                    ForEach(required, id: \.field.key) { fieldRow(platform, $0.field) }
                }
            } header: {
                MessagingSectionTitle("Required")
            }
            .hermesFormRows()
            if !recommended.isEmpty {
                Section {
                    ForEach(recommended, id: \.field.key) { fieldRow(platform, $0.field) }
                } header: {
                    MessagingSectionTitle("Recommended")
                }
                .hermesFormRows()
            }
            if !advanced.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showAdvanced) {
                        ForEach(advanced, id: \.field.key) { fieldRow(platform, $0.field) }
                    } label: {
                        Text("Advanced (\(advanced.count))").hermesText(.label).foregroundStyle(Theme.Text.tertiary)
                    }
                }
                .hermesFormRows()
            }
        }
    }

    // MARK: Header

    private func headerSection(_ platform: MessagingPlatform) -> some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                    MessagingPlatformAvatar(platformID: platform.id, name: platform.name, size: 34)
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        Text(platform.name).hermesText(.rowTitle)
                        pills(platform)
                    }
                }
                if !platform.description.isEmpty {
                    Text(platform.description).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            }
            .padding(.vertical, Theme.Spacing.xs)
            hint(platform)
            if let message = platform.errorMessage {
                Label {
                    Text(message).hermesText(.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
                } icon: {
                    Image(systemName: Theme.Icon.error).foregroundStyle(Theme.destructive)
                }
            }
        }
        .hermesFormRows()
    }

    /// The state pill, plus only the actionable extras: needs setup, and a stopped gateway when the state doesn't
    /// already say so.
    private func pills(_ platform: MessagingPlatform) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            HStack(spacing: Theme.Spacing.xs) {
                OpsDot(color: platform.tone.color, size: 6)
                Text(MessagingCopy.stateLabel(platform.state))
            }
            .hermesText(.meta)
            .fontWeight(.medium)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .foregroundStyle(platform.tone == .muted ? Theme.Text.tertiary : platform.tone.color)
            .background(platform.tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
            if !platform.configured { OpsPill("Needs setup") }
            if !platform.gatewayRunning, platform.state != "gateway_stopped" { OpsPill("Messaging gateway stopped") }
        }
    }

    /// Where to point a client of a served profile, or what the platform waits on (`PlatformHint`). The desktop's
    /// status bar isn't here, so the gateway action sits under the hint.
    @ViewBuilder private func hint(_ platform: MessagingPlatform) -> some View {
        if let ingress = platform.ingressURL {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("Served on the shared gateway listener at").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                MessagingCopyRow(value: ingress)
            }
        } else if platform.enabled, platform.state != "connected" {
            if platform.state == "pending_restart" {
                Text("Restart the gateway to apply this change.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                Button { Task { await store.confirmRestart() } } label: {
                    Label(store.gatewayBusy ? "Restarting…" : "Restart gateway", systemImage: "arrow.clockwise")
                }
                .disabled(store.gatewayBusy)
            } else if !platform.gatewayRunning {
                Text("Start the gateway to connect.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                Button { store.confirmStart() } label: {
                    Label(store.gatewayBusy ? "Starting…" : "Start gateway", systemImage: "play")
                }
                .disabled(store.gatewayBusy)
            }
        }
    }

    // MARK: Test

    private func testSection(_ platform: MessagingPlatform) -> some View {
        Section {
            Button { Task { await store.test(platform) } } label: {
                HStack(spacing: Theme.Spacing.md) {
                    Label("Test connection", systemImage: "bolt.horizontal")
                    Spacer()
                    if store.testing == platform.id { ProgressView().controlSize(.small) }
                }
            }
            .disabled(store.testing != nil)
            if let result = store.testResults[platform.id] {
                Label {
                    Text(result.message).hermesText(.caption).foregroundStyle(Theme.Text.secondary).textSelection(.enabled)
                } icon: {
                    Image(systemName: result.ok ? (result.unreachable ? Theme.Icon.warning : "checkmark.circle") : Theme.Icon.error)
                        .foregroundStyle(result.ok ? (result.unreachable ? Theme.Semantic.attention : Theme.Semantic.success)
                                         : Theme.destructive)
                }
            }
        }
        .hermesFormRows()
    }

    // MARK: Pairing

    /// Only when someone is actually waiting: an empty card would be permanent chrome on a page about credentials.
    private func pendingSection(_ pending: [PairingUser]) -> some View {
        Section {
            ForEach(pending) { user in
                HStack(spacing: Theme.Spacing.md) {
                    pairingLabel(user)
                    Spacer(minLength: 0)
                    Button(store.approving == user.id ? "Approving..." : "Approve") { Task { await store.approve(user) } }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(store.approving != nil || user.requestID == nil)
                }
            }
        } header: {
            MessagingSectionTitle("Pending requests (\(pending.count))")
        }
        .hermesFormRows()
    }

    private func approvedSection(_ approved: [PairingUser]) -> some View {
        Section {
            ForEach(approved) { user in
                HStack(spacing: Theme.Spacing.md) {
                    pairingLabel(user)
                    Spacer(minLength: 0)
                    Button("Revoke") { pendingRevoke = user }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .accessibilityLabel("Revoke \(user.label)")
                }
                .swipeActions(edge: .trailing) {
                    Button(role: .destructive) { pendingRevoke = user } label: { Label("Revoke", systemImage: "person.badge.minus") }
                }
            }
        } header: {
            MessagingSectionTitle("Approved users (\(approved.count))")
        }
        .hermesFormRows()
    }

    private func pairingLabel(_ user: PairingUser) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(verbatim: user.label).hermesText(.rowTitle).lineLimit(1)
            // An unnamed requester is only a user id: showing it as both title and description repeats itself.
            if !user.detail.isEmpty {
                Text(verbatim: user.detail).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
            }
        }
    }

    // MARK: Credentials

    private func credentialsSection(_ platform: MessagingPlatform) -> some View {
        Section {
            Text(verbatim: MessagingCopy.intro(platform)).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            if let docs = platform.docsURL {
                Button { openURL(docs) } label: { Label("Open setup guide", systemImage: "arrow.up.right.square") }
            }
        } header: {
            MessagingSectionTitle("Get your credentials")
        }
        .hermesFormRows()
    }

    private func fieldRow(_ platform: MessagingPlatform, _ field: MessagingEnvField) -> some View {
        MessagingFieldRow(field: field,
                          draft: store.draft(platform.id)[field.key],
                          clearing: store.saving == "clear:\(field.key)",
                          onEdit: { store.edit(platform.id, key: field.key, value: $0) },
                          onClear: { pendingClear = field })
    }

    // MARK: Action bar

    private func actionBar(_ platform: MessagingPlatform) -> some View {
        let hasEdits = store.hasEdits(platform)
        let savingEnv = store.saving == "env:\(platform.id)"
        return HStack(spacing: Theme.Spacing.lg) {
            Toggle(isOn: Binding(get: { platform.enabled },
                                 set: { enabled in Task { await store.setEnabled(platform, enabled) } })) {
                Text(platform.enabled ? "Enabled" : "Disabled").hermesText(.label).foregroundStyle(Theme.Text.secondary)
            }
            .toggleStyle(.switch)
            .fixedSize()
            .disabled(store.saving == "enabled:\(platform.id)")
            .accessibilityLabel(platform.enabled ? "Disable \(platform.name)" : "Enable \(platform.name)")
            Spacer(minLength: 0)
            if hasEdits {
                Text("Unsaved changes").hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
            }
            Button { Task { await store.save(platform) } } label: {
                Label(savingEnv ? "Saving..." : "Save changes", systemImage: "square.and.arrow.down")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(!hasEdits || savingEnv)
        }
        .padding(.horizontal, Theme.Spacing.page)
        .padding(.vertical, Theme.Spacing.md)
        .background(Theme.sidebar)
        .hermesHairline(edges: .top)
    }
}
