import SwiftUI

/// Messaging (`app/messaging/index.tsx`): every messaging platform of the profile with its status, and per platform
/// its setup, pairing requests and approved users. The desktop's master/detail becomes push navigation: a platform
/// opens its page on this stack. "Applies to" picks the profile whose gateway the page configures (hidden with one
/// profile); it starts on `context.profile`, and each profile gets its own state. Place it inside a
/// `NavigationStack`.
struct MessagingScreen: View {
    let context: MessagingContext
    @StateObject private var scopes = ProfileScopeModel()
    /// A profile picked under "Applies to"; nil follows `context.profile`.
    @State private var picked: String?

    init(context: MessagingContext) {
        self.context = context
    }

    var body: some View {
        let profile = picked ?? context.profile
        MessagingPlatformsList(api: context.messaging(profile: profile), scopes: scopes, scope: scopeSelection)
            .id(profile ?? "")
            .task { await scopes.load(context.client) }
    }

    /// The selected profile's name; the dashboard's own when nothing is scoped. Picking the starting profile again
    /// drops the override.
    private var scopeSelection: Binding<String> {
        Binding(get: { picked ?? context.profile ?? scopes.dashboardProfile },
                set: { picked = $0 == (context.profile ?? scopes.dashboardProfile) ? nil : $0 })
    }
}

/// The platforms of one profile.
private struct MessagingPlatformsList: View {
    @StateObject private var store: MessagingStore
    @ObservedObject var scopes: ProfileScopeModel
    let scope: Binding<String>

    @State private var query = ""
    @State private var filter: MessagingTone?
    @State private var opened: String?
    @State private var confirmingClearPending = false

    init(api: MessagingAPI, scopes: ProfileScopeModel, scope: Binding<String>) {
        _store = StateObject(wrappedValue: MessagingStore(api: api))
        self.scopes = scopes
        self.scope = scope
    }

    var body: some View {
        content
            .hermesForm()
            .searchable(text: $query, prompt: "Search messaging...")
            .navigationTitle("Messaging")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar { toolbar }
            .task { await store.refreshAll() }
            .task { await store.keepFresh() }
            .refreshable { await store.refreshAll() }
            .navigationDestination(item: $opened) { id in
                MessagingPlatformDetail(store: store, platformID: id)
            }
            .confirmationDialog("Clear all pending pairing requests?", isPresented: $confirmingClearPending,
                                titleVisibility: .visible) {
                Button("Clear pending", role: .destructive) { Task { await store.clearPending() } }
            } message: {
                Text("Everyone waiting to be let in on any platform of this profile is dropped. They can ask again.")
            }
            // A pushed platform page asks, toasts and alerts on its own: this page only while it shows.
            .opsConfirm(whileShown($store.confirmation))
            .failureAlert(whileShown($store.failure))
            .opsToast(whileShown($store.notice))
    }

    private func whileShown<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { opened == nil ? binding.wrappedValue : nil }, set: { binding.wrappedValue = $0 })
    }

    @ViewBuilder private var content: some View {
        if let platforms = store.platforms {
            List {
                if scopes.profiles.count > 1 { scopeSection }
                if store.restartNeeded { MessagingRestartSection(store: store) }
                platformSection(platforms)
            }
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Messaging platforms failed to load", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.refreshAll() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        } else {
            List { OpsLoaderRow() }
        }
    }

    /// Which profile's gateway this page configures (`SettingsProfileScope`).
    private var scopeSection: some View {
        Section {
            Picker("Applies to", selection: scope) {
                ForEach(scopes.profiles) { profile in
                    Text(ProfileScopeSection.label(profile)).tag(profile.name)
                }
            }
        }
        .hermesFormRows()
    }

    private func platformSection(_ platforms: [MessagingPlatform]) -> some View {
        let visible = store.visible(tone: filter, query: query)
        return Section {
            ForEach(visible) { platform in
                Button { opened = platform.id } label: {
                    MessagingPlatformRow(platform: platform, pendingCount: store.pairing.pending(for: platform.id).count)
                }
                .foregroundStyle(Theme.Text.primary)
            }
            if visible.isEmpty {
                Text(platforms.isEmpty ? "No messaging platforms on this Hermes." : "No matches")
                    .foregroundStyle(Theme.Text.tertiary)
            }
        } header: {
            if let filter = activeFilter { FormNote(filter.filterLabel) }
        }
        .hermesFormRows()
    }

    /// A filter whose last platform changed state falls back to All.
    private var activeFilter: MessagingTone? {
        filter.flatMap { store.presentTones.contains($0) ? $0 : nil }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            if store.presentTones.count > 1 {
                Menu {
                    Picker("Status", selection: $filter) {
                        Text("All").tag(MessagingTone?.none)
                        ForEach(store.presentTones) { tone in
                            Text(tone.filterLabel).tag(MessagingTone?.some(tone))
                        }
                    }
                } label: {
                    Image(systemName: activeFilter == nil ? Theme.Icon.filter : "line.3.horizontal.decrease.circle.fill")
                }
                .accessibilityLabel("Status filter")
            }
            Menu {
                Button { Task { await store.confirmRestart() } } label: {
                    Label(store.gatewayBusy ? "Restarting…" : "Restart gateway", systemImage: "arrow.clockwise")
                }
                .disabled(store.gatewayBusy || store.platforms == nil)
                if !store.pairing.pending.isEmpty {
                    Button(role: .destructive) { confirmingClearPending = true } label: {
                        Label("Clear pending requests", systemImage: Theme.Icon.delete)
                    }
                }
            } label: {
                Image(systemName: Theme.Icon.more)
            }
            .accessibilityLabel("More")
        }
    }
}

/// A platform in the list: its mark, name and state, how many people wait to be let in, and the status dot.
private struct MessagingPlatformRow: View {
    let platform: MessagingPlatform
    let pendingCount: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            MessagingPlatformAvatar(platformID: platform.id, name: platform.name)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(platform.name).hermesText(.rowTitle).lineLimit(1)
                Text(MessagingCopy.stateLabel(platform.enabled ? platform.state : "disabled"))
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Someone is waiting to be let in: the only way the list says so before the platform opens.
            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .hermesText(.meta)
                    .fontWeight(.medium)
                    .monospacedDigit()
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xxs)
                    .foregroundStyle(Theme.Semantic.attention)
                    .background(Theme.Semantic.attention.opacity(0.12), in: Capsule())
                    .accessibilityLabel("\(pendingCount) pending pairing \(pendingCount == 1 ? "request" : "requests")")
            }
            OpsDot(color: platform.tone.color)
            Image(systemName: Theme.Icon.disclosure)
                .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The banner a saved change leaves until the gateway restarts (`restartNeeded`).
struct MessagingRestartSection: View {
    @ObservedObject var store: MessagingStore

    var body: some View {
        Section {
            MessagingBanner(text: "Saved. Restart the messaging gateway so the new settings take effect.")
            Button { Task { await store.confirmRestart() } } label: {
                HStack(spacing: Theme.Spacing.md) {
                    if store.gatewayBusy { ProgressView().controlSize(.small) }
                    Text(store.gatewayBusy ? "Restarting…" : "Restart now")
                }
            }
            .disabled(store.gatewayBusy)
        }
        .hermesFormRows()
    }
}
