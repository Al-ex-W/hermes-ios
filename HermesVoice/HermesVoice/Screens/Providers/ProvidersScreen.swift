import SwiftUI

/// Settings › Providers, for the signed-in dashboard (an entry point that needs no client of its own).
struct ProvidersPage: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        if let client = model.client {
            ProvidersScreen(client: client)
        } else {
            ContentUnavailableView("Not signed in", systemImage: "key", description: Text("Sign in to the Hermes dashboard first."))
                .navigationTitle("Providers")
        }
    }
}

/// Settings › Providers (`providers-settings.tsx`): accounts to sign in to, then the API-key and custom-endpoint
/// pages. The desktop's Local models view isn't here (no local runtime on a phone).
struct ProvidersScreen: View {
    let client: DashboardClient
    @StateObject private var scopes = ProfileScopeModel()
    /// The profile the page edits; nil is the dashboard's own.
    @State private var scope: String?
    @State private var accounts: [OAuthAccount]?
    @State private var loadError: String?
    @State private var showOthers = false
    @State private var opened: OAuthAccount?
    @State private var confirmingDisconnect: OAuthAccount?
    @State private var disconnecting: String?
    @State private var failure: String?

    var body: some View {
        Form {
            ProfileScopeSection(profiles: scopes.profiles, dashboardProfile: scopes.dashboardProfile, scope: $scope)
            accountSections
            Section {
                NavigationLink {
                    APIKeysScreen(client: client, profile: scope)
                } label: {
                    PageRow(title: "API keys", detail: "Paste a key for OpenRouter, Anthropic, Gemini, DeepSeek and more.",
                            systemImage: "key")
                }
                NavigationLink {
                    CustomEndpointsScreen(client: client, profile: scope)
                } label: {
                    PageRow(title: "Custom endpoints",
                            detail: "Point Hermes at any OpenAI-compatible endpoint (vLLM, llama.cpp, Ollama, …).",
                            systemImage: "point.3.connected.trianglepath.dotted")
                }
            } header: {
                FormNote("Have an API key instead?")
            }
            .hermesFormRows()
        }
        .hermesForm()
        .navigationTitle("Providers")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .task { await scopes.load(client) }
        .task(id: scope) { await load() }
        .refreshable { await load() }
        .sheet(item: $opened) { account in
            AccountSheet(client: client, account: account, profile: scope, onChange: { changed() }) {
                try await client.disconnectOAuth(account.id, profile: scope)
                changed()
            }
        }
        .confirmationDialog("Remove \(confirmingDisconnect?.title ?? "")?",
                            isPresented: Binding(get: { confirmingDisconnect != nil }, set: { if !$0 { confirmingDisconnect = nil } }),
                            titleVisibility: .visible, presenting: confirmingDisconnect) { account in
            Button("Disconnect", role: .destructive) { Task { await disconnect(account) } }
        } message: { account in
            Text("Hermes deletes the stored \(account.title) credentials for this profile. Chats that use it stop working until you sign in again.")
        }
        .failureAlert($failure)
    }

    // MARK: Accounts

    @ViewBuilder private var accountSections: some View {
        Section {
            if let accounts {
                if let featured = featured(accounts) {
                    accountRow(featured, featured: true)
                }
                ForEach(connected(accounts)) { accountRow($0) }
                if accounts.isEmpty {
                    Text("This Hermes offers no account sign-ins.").foregroundStyle(Theme.Text.tertiary)
                }
            } else if let loadError {
                Text(loadError).foregroundStyle(Theme.destructive)
                Button("Try again") { Task { await load() } }
            } else {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
        } header: {
            FormNote("Connect an account")
        } footer: {
            FormNote("Sign in with a subscription — no API key to copy. Hermes runs the sign-in and keeps the credentials on the host.")
        }
        .hermesFormRows()

        if let accounts, !others(accounts).isEmpty {
            // Nothing above them: the other providers are the list, not a disclosure.
            let alwaysOpen = connected(accounts).isEmpty && featured(accounts) == nil
            Section {
                if showOthers || alwaysOpen {
                    ForEach(others(accounts)) { accountRow($0) }
                }
                if !alwaysOpen {
                    Button {
                        withAnimation { showOthers.toggle() }
                    } label: {
                        Label(showOthers ? "Collapse" : (connected(accounts).isEmpty ? "Other providers" : "Connect another provider"),
                              systemImage: showOthers ? "chevron.up" : "chevron.down")
                            .hermesText(.caption)
                    }
                    .foregroundStyle(Theme.Text.secondary)
                }
            } header: {
                if showOthers || alwaysOpen { FormNote("Other providers") }
            }
            .hermesFormRows()
        }
    }

    private func accountRow(_ account: OAuthAccount, featured: Bool = false) -> some View {
        Button {
            opened = account
        } label: {
            AccountRow(account: account, featured: featured, busy: disconnecting == account.id)
        }
        .foregroundStyle(Theme.Text.primary)
        .swipeActions(edge: .trailing) {
            if account.isConnected, account.canDisconnect {
                Button("Disconnect", role: .destructive) { confirmingDisconnect = account }
            }
        }
        .contextMenu {
            if account.isConnected, account.canDisconnect {
                Button("Disconnect", systemImage: Theme.Icon.delete, role: .destructive) { confirmingDisconnect = account }
            }
        }
    }

    /// Nous leads while it isn't connected (the desktop's featured card).
    private func featured(_ accounts: [OAuthAccount]) -> OAuthAccount? {
        accounts.first { $0.id == OAuthAccount.featuredID && !$0.isConnected }
    }

    private func connected(_ accounts: [OAuthAccount]) -> [OAuthAccount] {
        accounts.filter { $0.isConnected }
    }

    private func others(_ accounts: [OAuthAccount]) -> [OAuthAccount] {
        let featuredID = featured(accounts)?.id
        return accounts.filter { !$0.isConnected && $0.id != featuredID }
    }

    // MARK: Actions

    private func load() async {
        do {
            accounts = try await client.oauthAccounts(profile: scope)
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            if accounts == nil { loadError = error.dashboardMessage } else { failure = error.dashboardMessage }
        }
    }

    private func changed() {
        NotificationCenter.default.post(name: .hermesModelOptionsDidChange, object: nil)
        Task { await load() }
    }

    private func disconnect(_ account: OAuthAccount) async {
        disconnecting = account.id
        defer { disconnecting = nil }
        do {
            try await client.disconnectOAuth(account.id, profile: scope)
            changed()
        } catch {
            failure = "Couldn't remove \(account.title). \(error.dashboardMessage)"
        }
    }
}

/// One account row: title, connected tag and how its sign-in works.
private struct AccountRow: View {
    let account: OAuthAccount
    var featured = false
    var busy = false

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(account.status.freeTier ? "\(account.title) · free tier" : account.title)
                        .hermesText(.rowTitle)
                        .lineLimit(2)
                    if account.isConnected {
                        StatusTag("Connected", tone: .good, systemImage: "checkmark")
                    } else if featured {
                        StatusTag("Recommended", tone: .accent)
                    }
                }
                Text(account.flowSubtitle)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Spacer(minLength: 0)
            if busy {
                ProgressView()
            } else {
                Image(systemName: account.signsInFromPhone ? Theme.Icon.disclosure : Theme.Icon.terminal)
                    .font(.system(size: Theme.IconSize.xs, weight: .semibold))
                    .foregroundStyle(Theme.Text.quaternary)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .contentShape(Rectangle())
    }
}

/// A row leading to a sub-page: icon, title and one line of what it holds.
struct PageRow: View {
    let title: String
    var detail: String?
    var systemImage: String

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(title)
                if let detail {
                    Text(detail).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            }
        } icon: {
            Image(systemName: systemImage)
        }
    }
}
