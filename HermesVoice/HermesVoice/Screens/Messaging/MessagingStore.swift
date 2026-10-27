import SwiftUI

/// The Messaging page's state for one profile (`app/messaging/index.tsx`): the platforms with their status, the
/// pairing requests and approved users, the unsaved setup drafts, and the gateway restart a saved change waits on.
/// A store belongs to one profile: switching profiles makes a new one, so no draft, row or late answer of one
/// profile reaches another. Drafts (tokens included) live only in memory and go once saved.
@MainActor
final class MessagingStore: ObservableObject {
    let api: MessagingAPI

    @Published private(set) var platforms: [MessagingPlatform]?
    @Published private(set) var loadError: String?
    @Published private(set) var pairing = PairingLists()
    /// Unsaved values per platform id, per env key.
    @Published private(set) var edits: [String: [String: String]] = [:]
    /// What is being written: `enabled:<id>`, `env:<id>` or `clear:<key>`.
    @Published private(set) var saving: String?
    /// The pairing row being approved.
    @Published private(set) var approving: String?
    @Published private(set) var testing: String?
    @Published private(set) var testResults: [String: MessagingTestResult] = [:]
    /// A saved credential or switch only takes effect after a gateway restart: the banner stays until one happens.
    @Published var restartNeeded = false
    @Published private(set) var gatewayBusy = false
    @Published var notice: OpsNotice?
    @Published var failure: String?
    @Published var confirmation: OpsConfirmation?

    private var platformsGeneration = 0
    private var pairingGeneration = 0
    /// How often the page re-reads status while it shows (the desktop's visible-tab poll).
    static let refreshInterval: TimeInterval = 6
    /// The wait before re-reading status after a restart or a live re-serve.
    static let settleDelay: TimeInterval = 4

    init(api: MessagingAPI) {
        self.api = api
    }

    func platform(_ id: String) -> MessagingPlatform? { platforms?.first { $0.id == id } }

    /// Only the tones some platform is in get a filter.
    var presentTones: [MessagingTone] {
        MessagingTone.filterOrder.filter { tone in platforms?.contains { $0.tone == tone } ?? false }
    }

    func visible(tone: MessagingTone?, query: String) -> [MessagingPlatform] {
        let tone = tone.flatMap { presentTones.contains($0) ? $0 : nil }
        return (platforms ?? []).filter { $0.matches(tone: tone, query: query) }
    }

    // MARK: Loading

    func refreshAll(silent: Bool = false) async {
        async let platforms: Void = refreshPlatforms(silent: silent)
        async let pairing: Void = refreshPairing()
        _ = await (platforms, pairing)
    }

    func refreshPlatforms(silent: Bool = false) async {
        platformsGeneration += 1
        let mine = platformsGeneration
        do {
            let rows = try await api.platforms()
            guard mine == platformsGeneration else { return }
            platforms = rows
            loadError = nil
        } catch {
            guard mine == platformsGeneration, !error.isCancellation, !silent else { return }
            if platforms == nil { loadError = error.dashboardMessage } else { failure = "Messaging platforms failed to load. \(error.dashboardMessage)" }
        }
    }

    /// Failures stay silent: an older backend without the route shows no rows rather than an error.
    func refreshPairing() async {
        pairingGeneration += 1
        let mine = pairingGeneration
        guard let lists = try? await api.pairing(), mine == pairingGeneration else { return }
        pairing = lists
    }

    /// Re-reads status every few seconds while the caller's task runs (a screen's `.task`).
    func keepFresh() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(Self.refreshInterval))
            guard !Task.isCancelled else { return }
            await refreshAll(silent: true)
        }
    }

    private func refreshLater() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.settleDelay))
            await self?.refreshPlatforms(silent: true)
        }
    }

    // MARK: Drafts

    func draft(_ platformID: String) -> [String: String] { edits[platformID] ?? [:] }

    func edit(_ platformID: String, key: String, value: String) {
        edits[platformID, default: [:]][key] = value
    }

    func hasEdits(_ platform: MessagingPlatform) -> Bool {
        MessagingPlatformUpdate.changes(platform, draft: draft(platform.id)).hasChanges
    }

    /// A multiplexed named profile is re-served from its new config at once: re-read status once its adapter had a
    /// moment. Anything else needs a restart.
    private func settleAfterUpdate(hotServed: Bool) {
        if hotServed { refreshLater() } else { restartNeeded = true }
    }

    // MARK: Writes

    func setEnabled(_ platform: MessagingPlatform, _ enabled: Bool) async {
        guard saving == nil else { return }
        saving = "enabled:\(platform.id)"
        defer { saving = nil }
        do {
            var update = MessagingPlatformUpdate()
            update.enabled = enabled
            let result = try await api.update(platform.id, update)
            if let index = platforms?.firstIndex(where: { $0.id == platform.id }) {
                platforms?[index].enabled = enabled
                platforms?[index].state = enabled ? (platform.configured ? "pending_restart" : "not_configured") : "disabled"
            }
            settleAfterUpdate(hotServed: result.hotServed)
            notice = OpsNotice(title: "\(platform.name) \(enabled ? "enabled" : "disabled")",
                               message: result.hotServed ? "Applied to the running gateway." : "This change takes effect after a gateway restart.")
        } catch {
            if !error.isCancellation { failure = "Failed to update \(platform.name). \(error.dashboardMessage)" }
        }
    }

    func save(_ platform: MessagingPlatform) async {
        let update = MessagingPlatformUpdate.changes(platform, draft: draft(platform.id))
        guard update.hasChanges, saving == nil else { return }
        saving = "env:\(platform.id)"
        defer { saving = nil }
        do {
            let result = try await api.update(platform.id, update)
            // Re-read before dropping the drafts, so list editors re-seed from the saved value.
            await refreshPlatforms()
            edits[platform.id] = [:]
            settleAfterUpdate(hotServed: result.hotServed)
            notice = OpsNotice(title: "\(platform.name) setup saved",
                               message: result.hotServed ? "The running gateway is connecting with the new credentials."
                                   : "New credentials take effect after a gateway restart.")
        } catch {
            if !error.isCancellation { failure = "Failed to save \(platform.name). \(error.dashboardMessage)" }
        }
    }

    /// Removes a saved value (asked first by the caller).
    func clear(_ platform: MessagingPlatform, key: String) async {
        guard saving == nil else { return }
        saving = "clear:\(key)"
        defer { saving = nil }
        do {
            var update = MessagingPlatformUpdate()
            update.clearEnv = [key]
            let result = try await api.update(platform.id, update)
            edits[platform.id, default: [:]][key] = nil
            await refreshPlatforms()
            settleAfterUpdate(hotServed: result.hotServed)
            notice = OpsNotice(title: "\(key) cleared", message: "\(platform.name) setup was updated.")
        } catch {
            if !error.isCancellation { failure = "Failed to clear \(key). \(error.dashboardMessage)" }
        }
    }

    func test(_ platform: MessagingPlatform) async {
        guard testing == nil else { return }
        testing = platform.id
        defer { testing = nil }
        do {
            testResults[platform.id] = try await api.test(platform.id)
        } catch {
            if !error.isCancellation { failure = "Could not test \(platform.name). \(error.dashboardMessage)" }
        }
    }

    // MARK: Pairing

    /// Paints at once from a snapshot, then lets the host's list have the last word; a failure restores the row.
    func approve(_ user: PairingUser) async {
        guard user.requestID != nil, approving == nil else { return }
        let snapshot = pairing
        approving = user.id
        pairing.pending.removeAll { $0.id == user.id }
        defer { approving = nil }
        do {
            try await api.approve(user)
            notice = OpsNotice(title: "\(user.label) approved", message: "They are recognized automatically on their next message.")
            await refreshPairing()
        } catch {
            pairing = snapshot
            guard !error.isCancellation else { return }
            // 429: the code path's brute-force lockout, which only waiting lifts.
            if case let .http(code, _)? = error as? DashboardError, code == 429 {
                failure = "Too many failed approvals — this platform is locked out. Try again later."
            } else {
                failure = "Failed to approve \(user.label). \(error.dashboardMessage)"
            }
        }
    }

    /// Revokes a user the caller confirmed.
    func revoke(_ user: PairingUser) async {
        let snapshot = pairing
        pairing.approved.removeAll { $0.id == user.id }
        do {
            try await api.revoke(user)
            notice = OpsNotice(title: "\(user.label) revoked", message: user.platform)
            await refreshPairing()
        } catch {
            pairing = snapshot
            if !error.isCancellation { failure = "Failed to revoke \(user.label). \(error.dashboardMessage)" }
        }
    }

    func clearPending() async {
        do {
            let cleared = try await api.clearPending()
            notice = OpsNotice(title: "Cleared \(cleared) pending \(cleared == 1 ? "request" : "requests")")
            await refreshPairing()
        } catch {
            if !error.isCancellation { failure = "Could not clear pending requests. \(error.dashboardMessage)" }
        }
    }

    // MARK: Gateway

    /// Asks before restarting, naming every bot a shared gateway would take down with it.
    func confirmRestart() async {
        let shared = (try? await api.gatewayStatus())?.sharedWith
        confirmation = OpsConfirmation(
            title: shared == nil ? "Restart the gateway?" : "Restart the shared gateway?",
            message: shared.map { "All bots on this device reconnect: \($0.joined(separator: ", "))" }
                ?? "Messaging platforms disconnect briefly and running turns are interrupted.",
            confirmLabel: shared == nil ? "Restart gateway" : "Restart all") { [weak self] in
            await self?.restartGateway()
        }
    }

    func confirmStart() {
        confirmation = OpsConfirmation(title: "Start the gateway?",
                                       message: "Hermes starts the messaging gateway for this profile, which connects the enabled platforms.",
                                       confirmLabel: "Start gateway", destructive: false) { [weak self] in
            await self?.startGateway()
        }
    }

    func restartGateway() async {
        guard !gatewayBusy else { return }
        gatewayBusy = true
        defer { gatewayBusy = false }
        do {
            let started = try await api.restartGateway()
            guard started.ok else { throw DashboardError.rpc(started.message ?? "The gateway restart didn't start.") }
            if await watch(started.name) {
                restartNeeded = false
                notice = OpsNotice(title: "Gateway restarted")
                refreshLater()
            } else {
                restartNeeded = true
                failure = "Gateway restart failed. Try again; if it still fails, check the gateway log in Command Center."
            }
        } catch {
            if !error.isCancellation { failure = "Gateway restart failed. \(error.dashboardMessage)" }
        }
    }

    func startGateway() async {
        guard !gatewayBusy else { return }
        gatewayBusy = true
        defer { gatewayBusy = false }
        do {
            let started = try await api.startGateway()
            guard started.ok else { throw DashboardError.rpc(started.message ?? "The gateway didn't start.") }
            if await watch(started.name) {
                notice = OpsNotice(title: "Gateway starting", message: "Platforms connect in a moment.")
                refreshLater()
            } else {
                failure = "The gateway didn't start. Check the gateway log in Command Center."
            }
        } catch {
            if !error.isCancellation { failure = "Failed to start the gateway. \(error.dashboardMessage)" }
        }
    }

    /// Follows a gateway action to its end (`GatewayActionWatch`); true when it came back without a failure.
    func watch(_ action: String) async -> Bool {
        var poll = GatewayActionWatch.poll()
        var step = OpsActionPoll.Step.wait
        while step == .wait {
            try? await Task.sleep(for: .seconds(OpsActionPoll.interval))
            if Task.isCancelled { break }
            do {
                step = poll.record(try await api.actionStatus(action))
            } catch {
                if error.isCancellation { break }
                step = poll.recordFailure()
            }
        }
        return GatewayActionWatch.succeeded(poll)
    }

    // MARK: Onboarding

    /// An onboarding saved its setup and asked the host to restart the gateway: watch that restart, and fall back to
    /// the banner when it couldn't start or failed.
    func onboardingApplied(_ result: OnboardingApplyResult, platform: String, connectedBot: String? = nil) async {
        await refreshPlatforms(silent: true)
        if result.restartStarted {
            let bot = connectedBot.map { "Connected: @\($0) · " } ?? ""
            notice = OpsNotice(title: "\(platform) setup saved", message: "\(bot)\(platform) saved; gateway restarting…")
            restartNeeded = false
            gatewayBusy = true
            let ok = await watch("gateway-restart")
            gatewayBusy = false
            if !ok {
                restartNeeded = true
                failure = "Hermes couldn't restart to apply your messaging settings. Try Restart again; if it still fails, check the gateway log in Command Center."
            }
            refreshLater()
        } else {
            restartNeeded = true
            let detail = result.restartError.map { ": \($0)" } ?? ""
            failure = "\(platform) saved; gateway restart failed\(detail)"
        }
    }
}
