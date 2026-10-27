import SwiftUI

/// A managed app's dialog (`hosted-dialog.tsx` with `accounts-section.tsx` and `connect-element.tsx`) as a sheet:
/// its state, the "Hermes can use" switch, an open sign-in, and its accounts with Reconnect and Disconnect. The
/// sign-in page opens over it in a browser sheet.
struct HostedConnectorSheet: View {
    @ObservedObject var model: ConnectorsModel
    let slug: String
    @State private var disconnecting: HostedAccount?
    @Environment(\.dismiss) private var dismiss

    private var app: HostedConnector? { model.hostedApp(slug) }
    private var card: ConnectorCard? { app.map(ConnectorCards.card) }
    private var busy: Bool { model.busy.contains(ConnectorCards.hostedKey(slug)) }

    var body: some View {
        NavigationStack {
            Group {
                if let app, let card {
                    content(app, card)
                } else {
                    ContentUnavailableView("Not available any more", systemImage: "powerplug",
                                           description: Text("This app left the account's catalog."))
                }
            }
            .navigationTitle(app?.name ?? MCPText.title(slug))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .sheet(item: $model.browser, onDismiss: { model.browserClosed() }) { page in
            SafariSheet(url: page.url).ignoresSafeArea()
        }
        .confirmationDialog("Disconnect \(disconnecting?.name ?? "")?",
                            isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }),
                            titleVisibility: .visible, presenting: disconnecting) { account in
            Button("Disconnect", role: .destructive) { Task { _ = await model.disconnectHosted(account) } }
        } message: { _ in
            Text("Hermes stops acting as this account. You can connect again at any time.")
        }
        .failureAlert($model.failure)
    }

    private func content(_ app: HostedConnector, _ card: ConnectorCard) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    HStack(spacing: Theme.Spacing.lg) {
                        ConnectorTile(name: app.name, size: 40)
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            ConnectorTitleLine(card: card)
                            ConnectorStateLabel(card: card)
                        }
                    }
                    if let description = app.description {
                        Text(description).hermesText(.body).foregroundStyle(Theme.Text.secondary)
                    }
                    if let line = card.reasonText ?? card.reason?.text {
                        Text(line).hermesText(.caption).foregroundStyle(ConnectorStyle.reasonTone(card.state))
                    }
                }
                .padding(.vertical, Theme.Spacing.xs)
                Toggle(isOn: Binding(get: { app.enabled && !app.orgLocked },
                                     set: { on in Task { await model.setHostedEnabled(app.slug, on) } })) {
                    Text("Hermes can use \(app.name)")
                }
                .disabled(app.orgLocked || busy)
            } footer: {
                if app.orgLocked {
                    FormNote("Off by your organisation.")
                } else {
                    FormNote("Nous apps follow your account, not the profile.")
                }
            }
            .hermesFormRows()

            if let operation = model.operations[app.slug], !operation.settled {
                connectSection(app, operation)
            }

            accountsSection(app, card)
        }
        .hermesForm()
        .refreshable { await model.reloadHosted() }
    }

    /// An open sign-in (`ConnectElement`): open its link again, or stop waiting.
    private func connectSection(_ app: HostedConnector, _ operation: HostedOperation) -> some View {
        let target = operation.target(app.slug)
        return Section {
            if target?.failed == true {
                FormNote("The sign-in did not finish.\(target?.detail.map { " \($0)" } ?? "")", color: Theme.destructive)
                Button("Try again") { Task { await model.connectHosted(app.slug, reconnect: true) } }
                    .disabled(busy)
            } else {
                HStack(spacing: Theme.Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text("Finish the sign-in in your browser.").foregroundStyle(Theme.Text.secondary)
                }
                if let url = target?.connectURL {
                    Button("Open the sign-in again") { model.browser = WebPage(url: url) }
                }
            }
            Button("Stop waiting", role: .cancel) { Task { await model.stopWaiting(app.slug) } }
        } header: {
            FormNote("Signing in")
        }
        .hermesFormRows()
    }

    /// The app's accounts (`AccountsSection`), active first, then newest; the one connect button below them.
    private func accountsSection(_ app: HostedConnector, _ card: ConnectorCard) -> some View {
        Section {
            if app.accounts.isEmpty {
                Text("Not connected yet. Sign in to \(app.name) in your browser.")
                    .foregroundStyle(Theme.Text.secondary)
            }
            ForEach(app.accounts) { account in
                HStack(spacing: Theme.Spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                        Text(account.name).foregroundStyle(Theme.Text.primary).lineLimit(1)
                        Text(account.statusWord + (account.active && app.accounts.count > 1 ? " · In use" : ""))
                            .hermesText(.caption)
                            .foregroundStyle(account.needsReconnect ? Theme.destructive : Theme.Text.tertiary)
                    }
                    Spacer(minLength: 0)
                    if account.needsReconnect {
                        Button("Reconnect") { Task { await model.connectHosted(app.slug, reconnect: true) } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(busy)
                    }
                }
                .swipeActions(edge: .trailing) {
                    Button("Disconnect", role: .destructive) { disconnecting = account }
                }
                .contextMenu {
                    Button("Disconnect", systemImage: Theme.Icon.delete, role: .destructive) { disconnecting = account }
                }
            }
            if !app.retiredAccounts.isEmpty {
                FormNote("\(app.retiredAccounts.count) replaced sign-in\(app.retiredAccounts.count == 1 ? "" : "s") kept for history.")
            }
            if card.verb == .connect || card.verb == .turnBackOn || (app.connected && !app.orgLocked && app.enabled) {
                Button {
                    Task {
                        if card.verb == .turnBackOn {
                            await model.setHostedEnabled(app.slug, true)
                        } else {
                            await model.connectHosted(app.slug, reconnect: false)
                        }
                    }
                } label: {
                    HStack {
                        Text(card.verb == .turnBackOn ? "Turn back on" : app.accounts.isEmpty ? "Connect" : "Connect another account")
                        Spacer()
                        if busy { ProgressView() }
                    }
                }
                .disabled(busy || model.operations[app.slug].map { !$0.settled } == true)
            }
        } header: {
            FormNote("Accounts")
        } footer: {
            FormNote("Swipe an account to disconnect it.")
        }
        .hermesFormRows()
    }
}
