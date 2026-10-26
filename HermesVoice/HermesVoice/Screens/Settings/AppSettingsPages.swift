import SwiftUI
import UIKit
import UserNotifications

// MARK: - Appearance

/// The app's color mode (`MODE_OPTIONS`): follow the system, or always light or dark. Kept on this device.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case system, light, dark

    static let storageKey = "appearance.mode"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var icon: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var style: UIUserInterfaceStyle {
        switch self {
        case .system: return .unspecified
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// Applies the mode to every window, sheets included.
    @MainActor
    func apply() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows { window.overrideUserInterfaceStyle = style }
        }
    }
}

private struct HermesAppearance: ViewModifier {
    @AppStorage(AppearanceMode.storageKey) private var mode = AppearanceMode.system.rawValue

    func body(content: Content) -> some View {
        content.onChange(of: mode, initial: true) { _, value in
            (AppearanceMode(rawValue: value) ?? .system).apply()
        }
    }
}

extension View {
    /// Keeps the windows in the color mode chosen in Settings > Appearance; applied once at the root.
    func hermesAppearance() -> some View {
        modifier(HermesAppearance())
    }
}

/// Settings > Appearance: the color mode, and the chat display option the iPhone transcript honors (reasoning
/// blocks). The desktop's palettes, typography, window layout and pet don't apply here.
struct AppearanceSettingsView: View {
    @EnvironmentObject private var store: SettingsStore
    @AppStorage(AppearanceMode.storageKey) private var mode = AppearanceMode.system.rawValue
    let subpage: String?
    let anchor: String?

    var body: some View {
        Form {
            if subpage == "chat-display" {
                Section {
                    if store.phase == .loaded, store.field("display.show_reasoning") != nil {
                        ConfigFieldRow(key: "display.show_reasoning").id("display.show_reasoning")
                    } else if store.phase == .loading {
                        ProgressView().frame(maxWidth: .infinity)
                    }
                } footer: {
                    FormNote("Saved to the Hermes host, so other apps on it follow.")
                }
                .hermesFormRows()
            } else {
                Section {
                    Picker("Theme", selection: $mode) {
                        ForEach(AppearanceMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.icon).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: {
                    FormNote("Theme")
                } footer: {
                    FormNote("Light, dark, or follow the system. Kept on this iPhone.")
                }
                .hermesFormRows()
                .id("appearance.theme")
            }
        }
        .hermesForm()
        .settingsAnchor(anchor)
    }
}

// MARK: - Notifications

/// Settings > Notifications (`notifications-settings.tsx`, alerts only): which background alerts Hermes may send
/// this iPhone. Saved on this device and sent with the push registration (`NotificationPreferences`).
struct NotificationsSettingsView: View {
    @EnvironmentObject private var notifications: AlertNotifications
    let anchor: String?
    @State private var preferences = NotificationPreferences.load()

    private var blocked: Bool { notifications.authorization == .denied }

    var body: some View {
        Form {
            Section {
                Group {
                    toggle("Approval needed", "A command waits for your approval.", \.approval).id("notifications.approval")
                    toggle("Question asked", "Hermes asks you a question.", \.clarify).id("notifications.clarify")
                    toggle("Turn finished", "A reply finished while you were elsewhere.", \.turnDone).id("notifications.turn-done")
                }
                .disabled(blocked)
            } header: {
                FormNote("Alerts")
            } footer: {
                if blocked {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        FormNote("Notifications are off for this app in iOS Settings.", color: Theme.destructive)
                        Button("Open iOS Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) { UIApplication.shared.open(url) }
                        }
                        .hermesText(.button)
                    }
                } else {
                    FormNote("Approvals and questions can be answered from the notification.")
                }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .settingsAnchor(anchor)
    }

    private func toggle(_ title: String, _ description: String, _ path: WritableKeyPath<NotificationPreferences, Bool>) -> some View {
        SettingsRow(title: title, description: description) {
            Toggle(title, isOn: Binding(get: { preferences[keyPath: path] }, set: { on in
                preferences[keyPath: path] = on
                preferences.save()
            }))
            .labelsHidden()
        }
    }
}

// MARK: - Connection

/// Settings > Connection, this app's counterpart of the desktop's Gateways page: the dashboard it signs in to,
/// and signing out.
struct ConnectionSettingsView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Form {
            Section {
                LabeledContent("Address") {
                    Text(model.settings.dashboardURL).foregroundStyle(Theme.Text.tertiary).lineLimit(1).truncationMode(.middle)
                }
                LabeledContent("User") {
                    Text(model.settings.username).foregroundStyle(Theme.Text.tertiary)
                }
                Button("Sign out", role: .destructive) { model.signOut() }
                    .foregroundStyle(Theme.destructive)
            } header: {
                FormNote("Hermes dashboard")
            } footer: {
                FormNote("To reach Hermes away from home, serve the dashboard over Tailscale (`tailscale serve`) and turn on VPN On Demand in the Tailscale app, so this iPhone connects by itself.")
            }
            .hermesFormRows()
            .id("connection.address")
        }
        .hermesForm()
    }
}

// MARK: - About

/// Settings > About: this app's version and the host's (`GET /api/status`).
struct AboutSettingsView: View {
    @EnvironmentObject private var context: SettingsContext
    @State private var status: ConfigAPI.Status?
    @State private var failure: String?

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("HermesVoice", value: appVersion)
            } header: {
                FormNote("This app")
            }
            .hermesFormRows()
            Section {
                if let status {
                    LabeledContent("Hermes", value: status.version.nilIfEmpty ?? "Unknown")
                    if !status.releaseDate.isEmpty { LabeledContent("Released", value: status.releaseDate) }
                    if let current = status.configVersion, let latest = status.latestConfigVersion {
                        LabeledContent("Config version", value: current < latest ? "\(current) of \(latest)" : "\(current)")
                    }
                    LabeledContent("Gateway", value: status.gatewayRunning ? (status.gatewayState.map(SettingsText.prettyName) ?? "Running") : "Not running")
                    if let sessions = status.activeSessions { LabeledContent("Active sessions", value: "\(sessions)") }
                } else if let failure {
                    FormNote(failure, color: Theme.destructive)
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } header: {
                FormNote("Hermes host")
            } footer: {
                if let status, let current = status.configVersion, let latest = status.latestConfigVersion, current < latest {
                    FormNote("The host's config is older than this Hermes. Run `hermes config migrate` on the host.")
                } else {
                    FormNote("Update Hermes on the host with `hermes update`.")
                }
            }
            .hermesFormRows()
            .id("about.versions")
        }
        .hermesForm()
        .refreshable { await reload() }
        .task { await reload() }
    }

    private func reload() async {
        do {
            status = try await context.api.status()
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
    }
}

// MARK: - Billing

/// Settings > Billing (`billing/`), read-only: the Nous Portal account's plan, credits, balance, payment method,
/// spending cap and auto-reload (`billing.state`, `subscription.state`). Changes happen in the portal.
struct BillingSettingsView: View {
    @EnvironmentObject private var context: SettingsContext
    @State private var billing: BillingStateResult?
    @State private var subscription: SubscriptionStateResult?
    @State private var loaded = false
    @State private var failure: String?

    var body: some View {
        Form {
            if !loaded {
                Section { ProgressView().frame(maxWidth: .infinity) }.hermesFormRows()
            } else if let failure {
                Section { FormNote(failure, color: Theme.destructive) }.hermesFormRows()
            } else if billing?.loggedIn != true && subscription?.loggedIn != true {
                Section {
                    FormNote("Billing is for Nous Portal accounts. Sign in to Nous Portal on the Hermes host to see it here.")
                }
                .hermesFormRows()
            } else {
                accountSection
                planSection
                paymentSection
            }
        }
        .hermesForm()
        .refreshable { await reload() }
        .task { await reload() }
    }

    private var accountSection: some View {
        Section {
            if let org = billing?.orgName ?? subscription?.orgName { LabeledContent("Organization", value: org) }
            if let role = billing?.role ?? subscription?.role { LabeledContent("Role", value: SettingsText.prettyName(role)) }
            if let balance = billing?.balanceDisplay { LabeledContent("Balance", value: balance) }
            if let error = billing?.error ?? subscription?.error { FormNote(error, color: Theme.destructive) }
        } header: {
            FormNote("Account")
        }
        .hermesFormRows()
        .id("billing.overview")
    }

    @ViewBuilder private var planSection: some View {
        let current = subscription?.current
        let usage = subscription?.usage ?? billing?.usage
        if current != nil || usage?.available == true {
            Section {
                if let plan = current?.tierName ?? usage?.planName { LabeledContent("Plan", value: plan) }
                if let credits = current?.creditsRemaining { LabeledContent("Credits left", value: credits) }
                if let total = usage?.totalSpendableDisplay { LabeledContent("Spendable", value: total) }
                if let renews = usage?.renewsDisplay { LabeledContent("Renews", value: renews) }
                if let pending = current?.pendingDowngradeDisplay { FormNote(pending) }
                if let cancel = current?.cancellationEffectiveDisplay { FormNote("Ends \(cancel).") }
            } header: {
                FormNote("Plan")
            }
            .hermesFormRows()
        }
    }

    @ViewBuilder private var paymentSection: some View {
        Section {
            if let method = billing?.paymentMethod {
                LabeledContent("Payment method", value: [method.brand, method.last4.map { "•••• \($0)" }, method.wallet, method.email]
                    .compactMap { $0 }.joined(separator: " ").nilIfEmpty ?? SettingsText.prettyName(method.kind.rawValue))
            } else if let card = billing?.card {
                LabeledContent("Card", value: card.display ?? card.masked)
            }
            if let cap = billing?.monthlyCap {
                LabeledContent("This month", value: "\(cap.spentDisplay) of \(cap.limitDisplay)")
            }
            if let reload = billing?.autoReload {
                LabeledContent("Auto-reload", value: reload.enabled ? "Below \(reload.thresholdDisplay), to \(reload.reloadToDisplay)" : "Off")
            }
            if let url = (billing?.portalUrl ?? subscription?.portalUrl).flatMap(URL.init(string:)) {
                Link("Manage in Nous Portal", destination: url)
            }
        } header: {
            FormNote("Payment")
        } footer: {
            FormNote("Plans, top-ups and payment methods are changed in the portal.")
        }
        .hermesFormRows()
    }

    private func reload() async {
        guard let gateway = context.gateway else {
            failure = "Not connected to Hermes."
            loaded = true
            return
        }
        do {
            async let billingState = gateway.billingState()
            async let subscriptionState = gateway.subscriptionState()
            billing = try await billingState
            subscription = try? await subscriptionState
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loaded = true
    }
}
