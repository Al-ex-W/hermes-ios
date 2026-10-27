import SwiftUI

/// Telegram's quick setup (`TelegramQrSetup`), adapted to a phone: the user is on the phone that has Telegram, so the
/// setup link opens Telegram right here; the QR code stays one tap away for another device. The status is polled
/// until Telegram confirms the bot; then the user reviews who may DM it and saves, which restarts the gateway.
struct MessagingTelegramSetup: View {
    @ObservedObject var store: MessagingStore
    let platform: MessagingPlatform
    @State private var state = TelegramSetupState()
    @State private var showQR = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                HStack(spacing: Theme.Spacing.sm) {
                    Text("Quick setup").hermesText(.rowTitle)
                    OpsPill("Recommended", tone: .good)
                }
                Text("Confirm in Telegram on this phone, or scan the QR code from another device. Hermes creates the bot and detects your Telegram user ID automatically.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            switch state.phase {
            case .idle:
                if let bot = state.connectedBot {
                    HStack(spacing: Theme.Spacing.sm) {
                        OpsPill("Connected", tone: .good)
                        Text(verbatim: "@\(bot)").font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                    }
                } else if platform.configured {
                    Text("Telegram credentials are already configured. A new setup or bot token will replace the current bot when you save.")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                }
                Button { Task { await start() } } label: { Label("Create bot", systemImage: "paperplane") }
                    .buttonStyle(.borderedProminent)
            case .starting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Starting…").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            case .waiting, .ready, .applying:
                EmptyView()
            }
            if let error = state.error {
                Text(verbatim: error).hermesText(.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
            }
            if let setup = state.setup {
                Divider()
                if state.phase == .waiting {
                    waiting(setup)
                } else {
                    ready
                }
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task(id: state.isPolling ? state.setup?.pairingID : nil) { await poll() }
    }

    private func waiting(_ setup: TelegramOnboardingStart) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                OpsPill("Waiting for Telegram…", tone: .warn)
                MessagingExpiryPill(expiresAt: setup.expiresAt)
            }
            Text("Open Telegram on this phone and confirm, or scan the QR code with Telegram on another device.")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.tertiary)
            HStack(spacing: Theme.Spacing.md) {
                Button { openURL(setup.deepLink) } label: { Label("Open Telegram", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderedProminent)
                Button("Cancel") { Task { await cancel() } }
                    .buttonStyle(.borderless)
            }
            Button { withAnimation { showQR.toggle() } } label: {
                Label(showQR ? "Hide QR code" : "QR code for another device", systemImage: "qrcode")
            }
            .buttonStyle(.borderless)
            if showQR {
                MessagingQRCode(payload: setup.qrPayload, label: "Telegram setup QR code")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var ready: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                OpsPill("Bot created", tone: .good)
                if let bot = state.botUsername {
                    Text(verbatim: "@\(bot)").font(Theme.TextStyle.code.font).foregroundStyle(Theme.Text.tertiary)
                }
            }
            HStack(spacing: Theme.Spacing.sm) {
                Text("Allowed users").hermesText(.label).foregroundStyle(Theme.Text.tertiary)
                if let owner = state.detectedOwnerID, state.allowedIDs.contains(owner) {
                    OpsPill("Owner detected", tone: .good)
                }
            }
            if state.allowedIDs.isEmpty {
                Text(TelegramSetupState.addAtLeastOne).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            ForEach(state.allowedIDs, id: \.self) { id in
                HStack(spacing: Theme.Spacing.md) {
                    Text(verbatim: id).font(Theme.TextStyle.code.font)
                    Spacer(minLength: 0)
                    Button { state.removeAllowedID(id) } label: { Image(systemName: Theme.Icon.close) }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.Text.tertiary)
                        .disabled(state.phase == .applying)
                        .accessibilityLabel("Remove \(id)")
                }
            }
            HStack(spacing: Theme.Spacing.md) {
                TextField("Telegram user ID", text: $state.newAllowedID)
                    .keyboardType(.numberPad)
                    .font(Theme.TextStyle.code.font)
                Button { state.addAllowedID() } label: { Label("Add", systemImage: "checkmark") }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            .disabled(state.phase == .applying)
            HStack(spacing: Theme.Spacing.md) {
                Button { Task { await apply() } } label: {
                    Label(state.phase == .applying ? "Saving…" : "Save and restart", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { Task { await cancel() } }
                    .buttonStyle(.borderless)
            }
            .disabled(state.phase == .applying)
        }
    }

    // MARK: Flow

    private func start() async {
        state.beginStart()
        showQR = false
        do {
            state.started(try await store.api.startTelegram())
        } catch {
            state.startFailed(error.dashboardMessage)
        }
    }

    /// Polls until Telegram confirms; a transient failure keeps polling with a hint, an expired pairing resets.
    private func poll() async {
        guard state.isPolling, let id = state.setup?.pairingID else { return }
        var delay = TelegramSetupState.firstPollDelay
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, state.isPolling, state.setup?.pairingID == id else { return }
            delay = TelegramSetupState.pollInterval
            do {
                let status = try await store.api.telegramStatus(id)
                guard !Task.isCancelled, state.setup?.pairingID == id else { return }
                if !state.polled(status) { return }
            } catch {
                guard !error.isCancellation, !Task.isCancelled, state.setup?.pairingID == id else { return }
                if !state.pollFailed(error, message: error.dashboardMessage) { return }
            }
        }
    }

    private func apply() async {
        guard let id = state.setup?.pairingID, state.beginApply() else { return }
        do {
            let result = try await store.api.applyTelegram(id, allowedUserIDs: state.allowedIDs)
            let bot = result.botUsername ?? state.botUsername
            state.applied(result)
            await store.onboardingApplied(result, platform: "Telegram", connectedBot: bot)
        } catch {
            state.applyFailed(error.dashboardMessage)
        }
    }

    private func cancel() async {
        let id = state.setup?.pairingID
        state.reset()
        showQR = false
        if let id { await store.api.cancelTelegram(id) }
    }
}

/// WhatsApp's QR pairing (the web dashboard's `WhatsAppOnboardingPanel`): the host runs the WhatsApp bridge and shows
/// its QR code here, for WhatsApp's Linked Devices to scan; once linked, Save and restart enables WhatsApp. WhatsApp
/// can't scan the screen of the phone it runs on, so the page says how to link an account on this phone.
struct MessagingWhatsAppSetup: View {
    @ObservedObject var store: MessagingStore
    let platform: MessagingPlatform
    @State private var state: WhatsAppSetupState
    @State private var confirmingRepair = false
    @Environment(\.openURL) private var openURL

    init(store: MessagingStore, platform: MessagingPlatform) {
        self.store = store
        self.platform = platform
        _state = State(initialValue: WhatsAppSetupState(configuredMode: platform.whatsappSetup?.mode))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(spacing: Theme.Spacing.md) {
                Button { Task { await start(resetSession: false) } } label: {
                    Label(state.phase == .starting ? "Starting…" : "Pair with QR", systemImage: "qrcode")
                }
                .buttonStyle(.borderedProminent)
                Button("Re-pair with QR") { confirmingRepair = true }
                    .buttonStyle(.bordered)
            }
            .disabled(state.busy)
            if platform.configured {
                Text("Existing WhatsApp settings are configured.").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                Text("Mode").hermesText(.label).foregroundStyle(Theme.Text.tertiary)
                Picker("Mode", selection: $state.mode) {
                    ForEach(WhatsAppMode.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Allowed WhatsApp numbers").hermesText(.label).foregroundStyle(Theme.Text.tertiary)
                TextField("15551234567,15557654321", text: $state.allowedUsers)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(Theme.TextStyle.code.font)
            }
            .disabled(state.inputsLocked)
            if let error = state.error {
                Text(verbatim: error).hermesText(.caption).foregroundStyle(Theme.destructive).textSelection(.enabled)
            }
            if let setup = state.setup {
                Divider()
                session(setup)
            }
        }
        .padding(.vertical, Theme.Spacing.xs)
        .task(id: state.isPolling ? state.setup?.pairingID : nil) { await poll() }
        .onChange(of: platform.whatsappSetup?.mode) { _, mode in state.adoptConfiguredMode(mode) }
        .alert("Replace the saved WhatsApp link?", isPresented: $confirmingRepair) {
            Button("Back up and re-pair", role: .destructive) { Task { await start(resetSession: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Use this if WhatsApp logged out or removed this linked device. Disable WhatsApp and restart the gateway first. The old session will be kept in a private backup. Scan the new QR from Linked Devices, then Save and restart to enable WhatsApp again.")
        }
    }

    @ViewBuilder private func session(_ setup: WhatsAppOnboardingSession) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if state.linked {
                OpsPill("Connected", tone: .good)
            } else {
                OpsPill(state.statusLabel, tone: .warn)
            }
            MessagingExpiryPill(expiresAt: setup.expiresAt)
        }
        Text(state.help).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
        if state.linked {
            linked(setup)
        } else {
            if let qr = setup.qrPayload {
                MessagingQRCode(payload: qr, label: "WhatsApp setup QR code").frame(maxWidth: .infinity)
                Text("Scan with WhatsApp Linked Devices, not the camera app. If the account is on this phone, open Messaging on another screen (the Hermes desktop or dashboard) and scan its code with this phone.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            } else {
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView().controlSize(.small)
                    Text("Waiting for WhatsApp to provide a QR code…").hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            }
            if state.phase == .waiting {
                Text("After saving, unknown DMs use Hermes pairing codes unless their number is already allowed.")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            Button("Cancel") { Task { await cancel() } }
                .buttonStyle(.borderless)
        }
    }

    private func linked(_ setup: WhatsAppOnboardingSession) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(verbatim: setup.linkedAccountLabel.map { "Linked as \($0)" } ?? "WhatsApp device linked").hermesText(.rowTitle)
                Text(state.linkedAccountDetail).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        Text("\(index + 1).").monospacedDigit()
                        Text(step)
                    }
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                }
            }
            if let chat = setup.chatURL {
                Button { openURL(chat) } label: { Label("Open chat link", systemImage: "arrow.up.right.square") }
                    .buttonStyle(.borderless)
            }
            HStack(spacing: Theme.Spacing.md) {
                Button { Task { await apply() } } label: {
                    Label(state.phase == .applying ? "Saving…" : "Save and restart", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
                Button("Cancel") { Task { await cancel() } }
                    .buttonStyle(.borderless)
            }
            .disabled(state.phase == .applying)
        }
    }

    private var steps: [String] {
        ["Save and restart the gateway.", state.messageInstruction,
         state.pairingInstruction(hasSavedAllowedUsers: platform.whatsappSetup?.allowedUsersSet ?? false)]
    }

    // MARK: Flow

    private func start(resetSession: Bool) async {
        state.beginStart()
        do {
            state.started(try await store.api.startWhatsApp(mode: state.mode, allowedUsers: state.allowedUsers,
                                                            resetSession: resetSession))
        } catch {
            state.startFailed(error.dashboardMessage)
        }
    }

    /// Polls until the device is linked; each answer may carry a fresh QR code (WhatsApp rotates it).
    private func poll() async {
        guard state.isPolling, let id = state.setup?.pairingID else { return }
        var delay = WhatsAppSetupState.firstPollDelay
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, state.isPolling, state.setup?.pairingID == id else { return }
            do {
                let session = try await store.api.whatsappStatus(id)
                guard !Task.isCancelled, state.setup?.pairingID == id else { return }
                if !state.polled(session) { return }
                delay = WhatsAppSetupState.pollInterval
            } catch {
                guard !error.isCancellation, !Task.isCancelled, state.setup?.pairingID == id else { return }
                if !state.pollFailed(error, message: error.dashboardMessage) { return }
                delay = WhatsAppSetupState.retryInterval
            }
        }
    }

    private func apply() async {
        guard let id = state.setup?.pairingID, state.beginApply() else { return }
        do {
            let result = try await store.api.applyWhatsApp(id, mode: state.mode, allowedUsers: state.allowedUsers)
            state.applied()
            await store.onboardingApplied(result, platform: "WhatsApp")
        } catch {
            state.applyFailed(error.dashboardMessage)
        }
    }

    private func cancel() async {
        let id = state.setup?.pairingID
        state.reset()
        if let id { await store.api.cancelWhatsApp(id) }
    }
}

/// How long a QR setup stays valid, counting down each second.
struct MessagingExpiryPill: View {
    let expiresAt: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            if let remaining = OnboardingTiming.remaining(expiresAt, now: context.date) {
                OpsPill("Expires in \(remaining)").monospacedDigit()
            } else if !expiresAt.isEmpty {
                OpsPill("Expired", tone: .bad)
            }
        }
    }
}
