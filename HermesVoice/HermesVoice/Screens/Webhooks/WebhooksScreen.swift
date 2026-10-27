import SwiftUI

/// Webhooks (`app/webhooks/index.tsx`): the webhook receiver of `context.profile` and its subscriptions, each with the
/// URL to point a sender at. The desktop opens it as an overlay from the status bar's Webhooks item; its
/// master/detail becomes push navigation here, its dialogs sheets and alerts, its row menu swipe actions and a
/// context menu. A route's secret shows once, right after it is created. Place it inside a `NavigationStack`.
struct WebhooksScreen: View {
    let context: MessagingContext

    init(context: MessagingContext) {
        self.context = context
    }

    var body: some View {
        WebhooksList(context: context)
            .id(context.profile ?? "")
    }
}

private struct WebhooksList: View {
    @StateObject private var store: WebhooksStore
    @State private var query = ""
    @State private var opened: String?
    @State private var creating = false
    @State private var pendingDelete: WebhookRoute?

    init(context: MessagingContext) {
        _store = StateObject(wrappedValue: WebhooksStore(api: context.webhooks, messaging: context.messaging(profile: context.profile)))
    }

    var body: some View {
        content
            .hermesForm()
            .searchable(text: $query, prompt: "Search webhooks...")
            .navigationTitle("Webhooks")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { creating = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("New subscription")
                        .disabled(!store.enabled || store.enabling)
                }
            }
            .task { await store.load() }
            .refreshable { await store.load() }
            .navigationDestination(item: $opened) { name in
                WebhookDetailView(store: store, name: name) { route in
                    opened = nil
                    Task { await store.delete(route) }
                }
            }
            .sheet(isPresented: $creating) { WebhookCreateSheet(store: store) }
            .alert("Delete webhook", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                   presenting: pendingDelete) { route in
                Button("Delete", role: .destructive) { Task { await store.delete(route) } }
                Button("Cancel", role: .cancel) {}
            } message: { route in
                Text("This will permanently remove \(route.name). This cannot be undone.")
            }
            // A pushed subscription page asks and alerts on its own: this page only while it shows.
            .opsConfirm(whileShown($store.confirmation))
            .failureAlert(whileShown($store.failure))
            .opsToast(whileShown($store.notice))
    }

    private func whileShown<Value>(_ binding: Binding<Value?>) -> Binding<Value?> {
        Binding(get: { opened == nil ? binding.wrappedValue : nil }, set: { binding.wrappedValue = $0 })
    }

    @ViewBuilder private var content: some View {
        if store.snapshot != nil {
            List {
                WebhookBanners(store: store)
                if store.subscriptions.isEmpty {
                    Section {
                        ContentUnavailableView {
                            Label("No webhook subscriptions yet.", systemImage: "globe")
                        } actions: {
                            Button("New subscription") { creating = true }
                                .buttonStyle(.borderedProminent)
                                .disabled(!store.enabled || store.enabling)
                        }
                    }
                    .listRowBackground(Color.clear)
                } else {
                    subscriptions
                }
            }
        } else if let error = store.loadError {
            ContentUnavailableView {
                Label("Webhooks failed to load", systemImage: Theme.Icon.warning)
            } description: {
                Text(error)
            } actions: {
                Button("Try again") { Task { await store.load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        } else {
            List { OpsLoaderRow() }
        }
    }

    private var subscriptions: some View {
        let visible = store.visible(query)
        return Section {
            ForEach(visible) { route in
                Button { opened = route.name } label: { WebhookRow(route: route) }
                    .foregroundStyle(Theme.Text.primary)
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingDelete = route } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                        Button { Task { await store.setEnabled(route, !route.enabled) } } label: {
                            Label(route.enabled ? "Disable" : "Enable", systemImage: route.enabled ? "circle.slash" : "checkmark")
                        }
                    }
                    .contextMenu {
                        Button { Task { await store.setEnabled(route, !route.enabled) } } label: {
                            Label(route.enabled ? "Disable" : "Enable", systemImage: route.enabled ? "circle.slash" : "checkmark")
                        }
                        .disabled(store.toggling.contains(route.name))
                        Divider()
                        Button(role: .destructive) { pendingDelete = route } label: { Label("Delete", systemImage: Theme.Icon.delete) }
                    }
            }
            if visible.isEmpty {
                Text("No webhook subscriptions yet.").foregroundStyle(Theme.Text.tertiary)
            }
            Button { creating = true } label: { Label("New subscription", systemImage: "plus") }
                .disabled(!store.enabled || store.enabling)
        } header: {
            FormNote("Subscriptions (\(store.subscriptions.count))")
        } footer: {
            FormNote("Subscription changes hot-reload once the receiver is running. Disabled subscriptions reject incoming events.")
        }
        .hermesFormRows()
    }
}

/// The receiver is off, or enabling it still waits on a gateway restart.
private struct WebhookBanners: View {
    @ObservedObject var store: WebhooksStore

    var body: some View {
        if !store.enabled {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Label("Webhook receiver disabled", systemImage: "globe").hermesText(.rowTitle)
                    Text("Webhooks are their own gateway platform. Enable them here to accept incoming HTTP events; chat channels are only needed when a subscription delivers to Telegram, Discord, Slack, or another channel.")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                Button { store.confirmEnable() } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        if store.enabling { ProgressView().controlSize(.small) }
                        Text(store.enabling ? "Enabling..." : "Enable webhooks")
                    }
                }
                .disabled(store.enabling)
            }
            .hermesFormRows()
        }
        if store.restartNeeded {
            Section {
                MessagingBanner(text: store.restartError
                    ?? "Webhooks are enabled, but the gateway still needs a restart before the receiver can come online.")
                Button { Task { await store.confirmRestart() } } label: {
                    HStack(spacing: Theme.Spacing.md) {
                        if store.restarting { ProgressView().controlSize(.small) }
                        Text(store.restarting ? "Restarting..." : "Restart gateway")
                    }
                }
                .disabled(store.restarting)
            }
            .hermesFormRows()
        }
    }
}

private struct WebhookRow: View {
    let route: WebhookRoute

    var body: some View {
        HStack(spacing: Theme.Spacing.lg) {
            OpsDot(color: route.enabled ? Theme.Semantic.success : Theme.Text.quaternary)
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(verbatim: route.name).hermesText(.rowTitle).lineLimit(1)
                Text(verbatim: subtitle).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if !route.enabled { OpsPill("Disabled") }
            Image(systemName: Theme.Icon.disclosure)
                .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                .foregroundStyle(Theme.Text.quaternary)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityValue(route.enabled ? "Enabled" : "Disabled")
    }

    private var subtitle: String {
        var parts = [route.deliverLabel]
        parts.append(route.events.isEmpty ? "all events" : route.events.joined(separator: ", "))
        return parts.joined(separator: " · ")
    }
}
