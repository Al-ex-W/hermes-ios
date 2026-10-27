import SwiftUI

/// A device-code sign-in run by the dashboard (`POST …/oauth/:id/start`, then long-polls until the code is
/// approved). The phone only shows the code and the provider's page; Hermes saves the credentials on the host.
@MainActor
final class OAuthSignIn: ObservableObject {
    enum Phase: Equatable {
        case idle
        case starting
        case waiting(OAuthDeviceCode)
        case approved(OAuthPoll)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    /// When the code on screen stops working.
    @Published private(set) var codeExpiry: Date?
    let account: OAuthAccount
    let profile: String?
    private let client: DashboardClient
    private var task: Task<Void, Never>?
    /// Called once the account is connected.
    var onConnected: () -> Void = {}

    /// Seconds a long-poll holds (the dashboard caps it at 25; the client's request timeout is 30).
    static let longPoll = 20
    /// Connection failures in a row before the sign-in gives up.
    static let maxFailures = 5

    init(client: DashboardClient, account: OAuthAccount, profile: String?) {
        self.client = client
        self.account = account
        self.profile = profile
    }

    var isRunning: Bool {
        switch phase {
        case .starting, .waiting: return true
        default: return false
        }
    }

    func start() {
        stop()
        phase = .starting
        task = Task { [weak self] in await self?.run() }
    }

    /// Calls a pending sign-in off, so the dashboard doesn't save it after the user left.
    func stop() {
        task?.cancel()
        task = nil
        if case let .waiting(code) = phase {
            phase = .idle
            let client = client, profile = profile
            Task { await client.cancelOAuth(session: code.sessionID, profile: profile) }
        } else if phase == .starting {
            phase = .idle
        }
    }

    private func run() async {
        let code: OAuthDeviceCode
        do {
            code = try await client.startOAuth(account.id, profile: profile)
        } catch {
            if !error.isCancellation, !Task.isCancelled { phase = .failed(error.dashboardMessage) }
            return
        }
        guard !Task.isCancelled else {
            await client.cancelOAuth(session: code.sessionID, profile: profile)
            return
        }
        let expiry = Date().addingTimeInterval(TimeInterval(code.expiresIn))
        codeExpiry = expiry
        phase = .waiting(code)
        let deadline = expiry.addingTimeInterval(30)
        var failures = 0
        while !Task.isCancelled {
            do {
                let poll = try await client.pollOAuth(account.id, session: code.sessionID, profile: profile, wait: Self.longPoll)
                failures = 0
                if poll.isFinished {
                    // Approved as the sheet closed: the credentials are saved all the same, so lists still reload.
                    if poll.state == .approved { onConnected() }
                    guard !Task.isCancelled else { return }
                    phase = poll.state == .approved ? .approved(poll) : .failed(poll.failureText)
                    return
                }
            } catch {
                if error.isCancellation || Task.isCancelled { return }
                failures += 1
                if error.isRefusal || failures >= Self.maxFailures {
                    phase = .failed(error.dashboardMessage)
                    await client.cancelOAuth(session: code.sessionID, profile: profile)
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
            if Date() > deadline {
                phase = .failed(OAuthPoll(state: .expired).failureText)
                await client.cancelOAuth(session: code.sessionID, profile: profile)
                return
            }
        }
    }
}

/// One account: its status, how to sign in (a code approved from the phone, or a command on the host), and
/// disconnecting.
struct AccountSheet: View {
    let account: OAuthAccount
    let onChange: () -> Void
    /// Removes the account's credentials on the host.
    let disconnect: () async throws -> Void
    @StateObject private var signIn: OAuthSignIn
    @State private var page: WebPage?
    @State private var confirmingDisconnect = false
    @State private var disconnecting = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    init(client: DashboardClient, account: OAuthAccount, profile: String?,
         onChange: @escaping () -> Void, disconnect: @escaping () async throws -> Void) {
        self.account = account
        self.onChange = onChange
        self.disconnect = disconnect
        _signIn = StateObject(wrappedValue: OAuthSignIn(client: client, account: account, profile: profile))
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection
                if account.signsInFromPhone {
                    signInSections
                } else {
                    hostSection
                }
                if account.isConnected, signIn.phase == .idle { disconnectSection }
            }
            .hermesForm()
            .navigationTitle(account.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDone ? "Done" : "Cancel") { dismiss() }
                }
            }
            .confirmationDialog("Remove \(account.title)?", isPresented: $confirmingDisconnect, titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) { Task { await runDisconnect() } }
            } message: {
                Text("Hermes deletes the stored \(account.title) credentials for this profile. Chats that use it stop working until you sign in again.")
            }
            .failureAlert($failure)
        }
        .sheet(item: $page) { page in
            SafariSheet(url: page.url).ignoresSafeArea()
        }
        .onAppear {
            signIn.onConnected = onChange
            // An account not signed in yet starts right away, as on the desktop.
            if account.signsInFromPhone, !account.isConnected, signIn.phase == .idle { signIn.start() }
        }
        .onDisappear { signIn.stop() }
    }

    private var isDone: Bool {
        if case .approved = signIn.phase { return true }
        return !signIn.isRunning
    }

    // MARK: Status

    private var statusSection: some View {
        Section {
            LabeledContent("Status") {
                if account.status.freeTier {
                    StatusTag("Free tier", tone: .muted)
                } else if account.isConnected {
                    StatusTag("Connected", tone: .good, systemImage: "checkmark")
                } else {
                    Text("Not connected").foregroundStyle(Theme.Text.tertiary)
                }
            }
            if let tier = account.status.accountTier {
                LabeledContent("Plan", value: tier)
            }
            if let source = account.status.sourceLabel ?? account.status.source, account.status.loggedIn {
                LabeledContent("From") { Text(source).foregroundStyle(Theme.Text.tertiary).lineLimit(1).truncationMode(.middle) }
            }
            if let preview = account.status.tokenPreview, account.status.loggedIn {
                LabeledContent("Token") { Text("…\(preview)").font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary) }
            }
            if let error = account.status.error {
                Text(error).hermesText(.caption).foregroundStyle(Theme.destructive)
            }
        } footer: {
            FormNote(account.flowSubtitle)
        }
        .hermesFormRows()
    }

    // MARK: Device-code sign-in

    @ViewBuilder private var signInSections: some View {
        switch signIn.phase {
        case .idle:
            Section {
                Button(account.isConnected ? "Sign in again" : "Sign in") { signIn.start() }
            }
            .hermesFormRows()
        case .starting:
            Section {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Starting sign-in with \(account.title)…").foregroundStyle(Theme.Text.secondary)
                }
            }
            .hermesFormRows()
        case let .waiting(code):
            waitingSections(code)
        case let .approved(poll):
            Section {
                Label("\(account.title) connected", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.primary)
                if let email = poll.accountEmail {
                    LabeledContent("Account", value: email)
                }
                if let model = poll.model {
                    LabeledContent("Default model") { Text(model).font(Theme.TextStyle.code.font) }
                }
                ForEach(poll.handoffLines, id: \.self) { line in
                    Text(line).hermesText(.caption).foregroundStyle(Theme.Text.secondary)
                }
            }
            .hermesFormRows()
        case let .failed(message):
            Section {
                Text(message).foregroundStyle(Theme.destructive)
                Button("Try again") { signIn.start() }
            }
            .hermesFormRows()
        }
    }

    @ViewBuilder private func waitingSections(_ code: OAuthDeviceCode) -> some View {
        Section {
            HStack {
                Text(code.userCode)
                    .font(.system(size: 28, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    UIPasteboard.general.string = code.userCode
                } label: {
                    Image(systemName: Theme.Icon.copy).foregroundStyle(Theme.Text.tertiary)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Copy code")
            }
            Button {
                // The page asks for the code; it is on the clipboard by the time the page loads.
                UIPasteboard.general.string = code.userCode
                page = WebPage(url: code.verificationURL)
            } label: {
                Label("Open sign-in page", systemImage: "arrow.up.right.square")
            }
        } header: {
            FormNote("Your code")
        } footer: {
            FormNote("Approve this code on \(code.verificationURL.host ?? "the provider's page"). Opening the page copies the code. You can also open \(code.verificationURL.absoluteString) on another device.")
        }
        .hermesFormRows()
        Section {
            HStack(spacing: Theme.Spacing.md) {
                ProgressView()
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Waiting for approval…").foregroundStyle(Theme.Text.secondary)
                    if let expiry = signIn.codeExpiry { ExpiryText(expires: expiry) }
                }
            }
        } footer: {
            FormNote("Hermes connects automatically once the code is approved. Closing this cancels the sign-in.")
        }
        .hermesFormRows()
    }

    // MARK: Signed in on the host

    @ViewBuilder private var hostSection: some View {
        Section {
            if let command = account.cliCommand {
                CopyableText(text: command)
            }
            if let docs = account.docsURL {
                Button {
                    page = WebPage(url: docs)
                } label: {
                    Label("Documentation", systemImage: "book")
                }
            }
        } header: {
            FormNote("Sign in on the Hermes host")
        } footer: {
            FormNote("\(account.title) signs in with its own command in a terminal on the computer running Hermes. Hermes picks the credentials up from there.")
        }
        .hermesFormRows()
    }

    // MARK: Disconnect

    @ViewBuilder private var disconnectSection: some View {
        Section {
            if account.canDisconnect {
                Button(role: .destructive) { confirmingDisconnect = true } label: {
                    HStack {
                        Text("Disconnect")
                        if disconnecting { Spacer(); ProgressView() }
                    }
                }
                .foregroundStyle(Theme.destructive)
                .disabled(disconnecting)
            } else {
                if let command = account.disconnectCommand {
                    CopyableText(text: command)
                }
            }
        } footer: {
            if !account.canDisconnect {
                FormNote(account.disconnectHint ?? "\(account.title) is managed by its own CLI. Remove it there.")
            }
        }
        .hermesFormRows()
    }
}

extension AccountSheet {
    private func runDisconnect() async {
        disconnecting = true
        defer { disconnecting = false }
        do {
            try await disconnect()
            dismiss()
        } catch {
            failure = "Couldn't remove \(account.title). \(error.dashboardMessage)"
        }
    }
}

/// "Expires in 12:34", ticking.
private struct ExpiryText: View {
    let expires: Date

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let left = max(0, Int(expires.timeIntervalSince(context.date)))
            Text(left > 0 ? "Code expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Code expired")
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.tertiary)
                .monospacedDigit()
        }
    }
}
