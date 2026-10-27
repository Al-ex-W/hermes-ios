import SwiftUI

/// The Webhooks page's state for one profile (`app/webhooks/index.tsx`): whether the receiver is on, the
/// subscriptions, and the restart enabling it waits on. Every write re-reads the list from the host.
@MainActor
final class WebhooksStore: ObservableObject {
    let api: WebhooksAPI
    /// The gateway lifecycle routes of the same profile (a restart after enabling).
    let messaging: MessagingAPI

    @Published private(set) var snapshot: WebhooksSnapshot?
    @Published private(set) var loadError: String?
    @Published private(set) var enabling = false
    @Published var restartNeeded = false
    @Published private(set) var restartError: String?
    @Published private(set) var restarting = false
    /// Routes with an enable switch in flight.
    @Published private(set) var toggling: Set<String> = []
    @Published var notice: OpsNotice?
    @Published var failure: String?
    @Published var confirmation: OpsConfirmation?

    private var generation = 0

    init(api: WebhooksAPI, messaging: MessagingAPI) {
        self.api = api
        self.messaging = messaging
    }

    var enabled: Bool { snapshot?.enabled ?? false }
    var subscriptions: [WebhookRoute] { snapshot?.subscriptions ?? [] }

    func route(_ name: String) -> WebhookRoute? { snapshot?.route(name) }

    func visible(_ query: String) -> [WebhookRoute] { subscriptions.filter { $0.matches(query) } }

    // MARK: Loading

    func load(silent: Bool = false) async {
        generation += 1
        let mine = generation
        do {
            let snapshot = try await api.list()
            guard mine == generation else { return }
            self.snapshot = snapshot
            loadError = nil
        } catch {
            guard mine == generation, !error.isCancellation, !silent else { return }
            if snapshot == nil { loadError = error.dashboardMessage } else { failure = "Webhooks failed to load. \(error.dashboardMessage)" }
        }
    }

    private func reloadLater() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(MessagingStore.settleDelay))
            await self?.load(silent: true)
        }
    }

    // MARK: Receiver

    /// Enabling writes config and restarts the gateway, so it asks first.
    func confirmEnable() {
        confirmation = OpsConfirmation(title: "Enable webhooks?",
                                       message: "Hermes turns on the webhook receiver and restarts the gateway. Messaging platforms disconnect briefly and running turns are interrupted.",
                                       confirmLabel: "Enable webhooks", destructive: false) { [weak self] in
            await self?.enable()
        }
    }

    func enable() async {
        guard !enabling else { return }
        enabling = true
        restartNeeded = false
        restartError = nil
        defer { enabling = false }
        do {
            let result = try await api.enable()
            await load(silent: true)
            if result.restartStarted {
                notice = OpsNotice(title: "Webhooks enabled; gateway restarting...")
                reloadLater()
            } else {
                let detail = result.restartError.map { ": \($0)" } ?? "."
                restartNeeded = true
                restartError = "Gateway restart failed\(detail)"
                failure = restartError
            }
        } catch {
            if !error.isCancellation { failure = "Gateway restart failed. \(error.dashboardMessage)" }
        }
    }

    func confirmRestart() async {
        let shared = (try? await messaging.gatewayStatus())?.sharedWith
        confirmation = OpsConfirmation(
            title: shared == nil ? "Restart the gateway?" : "Restart the shared gateway?",
            message: shared.map { "All bots on this device reconnect: \($0.joined(separator: ", "))" }
                ?? "Messaging platforms disconnect briefly and running turns are interrupted.",
            confirmLabel: shared == nil ? "Restart gateway" : "Restart all") { [weak self] in
            await self?.restartGateway()
        }
    }

    func restartGateway() async {
        guard !restarting else { return }
        restarting = true
        defer { restarting = false }
        do {
            let started = try await messaging.restartGateway()
            guard started.ok else { throw DashboardError.rpc(started.message ?? "The gateway restart didn't start.") }
            if await watch(started.name) {
                restartNeeded = false
                restartError = nil
                reloadLater()
            } else {
                restartNeeded = true
                restartError = "Gateway restart failed"
            }
        } catch {
            if !error.isCancellation {
                restartNeeded = true
                restartError = "Gateway restart failed: \(error.dashboardMessage)"
            }
        }
    }

    private func watch(_ action: String) async -> Bool {
        var poll = GatewayActionWatch.poll()
        var step = OpsActionPoll.Step.wait
        while step == .wait {
            try? await Task.sleep(for: .seconds(OpsActionPoll.interval))
            if Task.isCancelled { break }
            do {
                step = poll.record(try await messaging.actionStatus(action))
            } catch {
                if error.isCancellation { break }
                step = poll.recordFailure()
            }
        }
        return GatewayActionWatch.succeeded(poll)
    }

    // MARK: Subscriptions

    /// Creates a route; throws so the form can stay open. The answer holds the one-time secret.
    func create(_ draft: WebhookDraft) async throws -> WebhookCreated {
        guard !draft.trimmedName.isEmpty else { throw DashboardError.rpc("Name required") }
        let created = try await api.create(draft)
        notice = OpsNotice(title: "Created", message: created.route.name)
        await load(silent: true)
        return created
    }

    /// Paints the switch at once; the host's list has the last word.
    func setEnabled(_ route: WebhookRoute, _ enabled: Bool) async {
        guard !toggling.contains(route.name) else { return }
        toggling.insert(route.name)
        defer { toggling.remove(route.name) }
        if let index = snapshot?.subscriptions.firstIndex(where: { $0.name == route.name }) {
            snapshot?.subscriptions[index].enabled = enabled
        }
        do {
            try await api.setEnabled(route.name, enabled)
            notice = OpsNotice(title: enabled ? "Enabled: \"\(route.name)\"" : "Disabled: \"\(route.name)\"")
            await load(silent: true)
        } catch {
            await load(silent: true)
            if !error.isCancellation { failure = "Failed to turn \"\(route.name)\" \(enabled ? "on" : "off"). \(error.dashboardMessage)" }
        }
    }

    /// Deletes a route the caller confirmed.
    func delete(_ route: WebhookRoute) async {
        do {
            try await api.delete(route.name)
            notice = OpsNotice(title: "Webhook deleted", message: route.name)
            await load(silent: true)
        } catch {
            if !error.isCancellation { failure = "Failed to delete \"\(route.name)\". \(error.dashboardMessage)" }
        }
    }
}
