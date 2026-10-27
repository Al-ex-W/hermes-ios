import Foundation

// The QR onboardings' state machines, kept free of views and the network so they can be tested: the views run
// the requests and feed the answers in.

/// Telegram "Quick setup" (`telegram-qr-setup.tsx`): the Nous setup service mints a bot on the user's behalf; the
/// phone opens its Telegram link (or another device scans the QR code), the status is polled until Telegram
/// confirms, the user reviews who may DM the bot, and the setup is applied (which saves and restarts the gateway).
struct TelegramSetupState: Equatable {
    enum Phase: Equatable { case idle, starting, waiting, ready, applying }

    static let pollInterval: TimeInterval = 2
    static let firstPollDelay: TimeInterval = 1.2
    static let pairingExpired = "Telegram pairing expired. Start a new QR setup to try again."
    static let addAtLeastOne = "Add at least one Telegram user ID."
    static let numericOnly = "Allowed Telegram user IDs must be numeric."

    private(set) var phase = Phase.idle
    private(set) var setup: TelegramOnboardingStart?
    private(set) var botUsername: String?
    /// The bot an apply just saved; outlives the reset so the card still says which bot is connected.
    private(set) var connectedBot: String?
    private(set) var allowedIDs: [String] = []
    private(set) var detectedOwnerID: String?
    var newAllowedID = ""
    var error: String?

    /// Numeric Telegram user ids, as the desktop accepts them.
    static func isUserID(_ value: String) -> Bool {
        (3...20).contains(value.count) && value.allSatisfy { $0.isASCII && $0.isNumber }
    }

    var isPolling: Bool { phase == .waiting && setup != nil }

    mutating func beginStart() {
        phase = .starting
        error = nil
        botUsername = nil
        connectedBot = nil
        allowedIDs = []
        detectedOwnerID = nil
        newAllowedID = ""
    }

    mutating func started(_ setup: TelegramOnboardingStart) {
        self.setup = setup
        phase = .waiting
    }

    mutating func startFailed(_ message: String) {
        phase = .idle
        error = message
    }

    /// A status answer. Returns whether to keep polling.
    mutating func polled(_ status: TelegramOnboardingStatus) -> Bool {
        guard phase == .waiting else { return false }
        switch status {
        case .waiting:
            error = nil
            return true
        case let .ready(bot, owner):
            phase = .ready
            botUsername = bot
            error = nil
            if let owner, Self.isUserID(owner) {
                detectedOwnerID = owner
                allowedIDs = [owner]
            }
            return false
        }
    }

    /// A failed poll: a 410 (expired or claimed) or a pairing past its expiry ends the setup; anything else is
    /// shown and polled again. Returns whether to keep polling.
    mutating func pollFailed(_ failure: Error, message: String, now: Date = Date()) -> Bool {
        guard phase == .waiting, let setup else { return false }
        if OnboardingTiming.isTerminal(failure) || OnboardingTiming.isExpired(setup.expiresAt, now: now) {
            reset()
            error = Self.pairingExpired
            return false
        }
        error = "Still waiting for Telegram. Retrying after: \(message)"
        return true
    }

    mutating func addAllowedID() {
        let trimmed = newAllowedID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isUserID(trimmed) else {
            error = Self.numericOnly
            return
        }
        error = nil
        if !allowedIDs.contains(trimmed) { allowedIDs.append(trimmed) }
        newAllowedID = ""
    }

    mutating func removeAllowedID(_ id: String) {
        allowedIDs.removeAll { $0 == id }
    }

    /// Whether the apply can go: a ready pairing and at least one allowed user.
    mutating func beginApply() -> Bool {
        guard setup != nil, phase == .ready else { return false }
        guard !allowedIDs.isEmpty else {
            error = Self.addAtLeastOne
            return false
        }
        phase = .applying
        error = nil
        return true
    }

    mutating func applied(_ result: OnboardingApplyResult) {
        let bot = result.botUsername ?? botUsername
        reset()
        connectedBot = bot
    }

    mutating func applyFailed(_ message: String) {
        phase = .ready
        error = message
    }

    mutating func reset() {
        setup = nil
        phase = .idle
        botUsername = nil
        allowedIDs = []
        detectedOwnerID = nil
        newAllowedID = ""
        error = nil
    }
}

/// WhatsApp QR pairing (the web dashboard's `WhatsAppOnboardingPanel`): the host runs the WhatsApp bridge in
/// pair-only mode and hands over its QR code, which WhatsApp's Linked Devices scans; once linked, the user saves
/// (which enables WhatsApp and restarts the gateway).
struct WhatsAppSetupState: Equatable {
    enum Phase: Equatable { case idle, starting, waiting, connected, applying }

    static let pollInterval: TimeInterval = 1.5
    static let retryInterval: TimeInterval = 2
    static let firstPollDelay: TimeInterval = 1
    static let expired = "WhatsApp QR setup expired. Start a new QR setup to try again."
    static let failed = "WhatsApp setup failed."

    private(set) var phase = Phase.idle
    private(set) var setup: WhatsAppOnboardingSession?
    var mode = WhatsAppMode.bot
    var allowedUsers = ""
    var error: String?

    init(configuredMode: WhatsAppMode? = nil) {
        mode = configuredMode ?? .bot
    }

    var isPolling: Bool { phase == .waiting && setup != nil }
    /// A pairing is being set up: the start buttons wait.
    var busy: Bool { [.starting, .waiting, .applying].contains(phase) }
    /// The mode and allowlist are fixed while the bridge pairs or saves.
    var inputsLocked: Bool { phase == .waiting || phase == .applying }
    var linked: Bool { phase == .connected || phase == .applying }

    /// The saved mode, while nothing is being set up.
    mutating func adoptConfiguredMode(_ mode: WhatsAppMode?) {
        guard let mode, setup == nil, phase == .idle else { return }
        self.mode = mode
    }

    mutating func beginStart() {
        setup = nil
        phase = .starting
        error = nil
    }

    mutating func started(_ session: WhatsAppOnboardingSession) {
        setup = session
        if session.status == "error" {
            error = session.error ?? Self.failed
            setup = nil
            phase = .idle
        } else {
            phase = session.status == "connected" ? .connected : .waiting
        }
    }

    mutating func startFailed(_ message: String) {
        phase = .idle
        error = message
    }

    /// A status answer (it may carry a new QR code). Returns whether to keep polling.
    mutating func polled(_ session: WhatsAppOnboardingSession) -> Bool {
        guard phase == .waiting else { return false }
        setup = session
        switch session.status {
        case "connected":
            phase = .connected
            error = nil
            return false
        case "error", "cancelled", "expired":
            error = session.error ?? (session.status == "expired" ? Self.expired : Self.failed)
            setup = nil
            phase = .idle
            return false
        default:
            error = nil
            return true
        }
    }

    /// A failed poll: a 410 or a pairing past its expiry ends the setup; anything else is shown and polled again.
    mutating func pollFailed(_ failure: Error, message: String, now: Date = Date()) -> Bool {
        guard phase == .waiting, let setup else { return false }
        if OnboardingTiming.isTerminal(failure) || OnboardingTiming.isExpired(setup.expiresAt, now: now) {
            reset()
            error = Self.expired
            return false
        }
        error = "Still waiting for WhatsApp. Retrying after: \(message)"
        return true
    }

    mutating func beginApply() -> Bool {
        guard setup != nil, phase == .connected else { return false }
        phase = .applying
        error = nil
        return true
    }

    mutating func applied() {
        reset()
    }

    mutating func applyFailed(_ message: String) {
        phase = .connected
        error = message
    }

    mutating func reset() {
        setup = nil
        phase = .idle
        error = nil
    }

    /// The status pill while waiting.
    var statusLabel: String {
        switch setup?.status {
        case "installing": return "preparing"
        case "starting": return "starting"
        default: return "waiting"
        }
    }

    var help: String {
        if linked { return "WhatsApp is linked but Hermes is not listening yet. Save and restart the gateway to finish setup." }
        switch setup?.status {
        case "installing": return "Preparing the WhatsApp bridge. The QR code will appear here when it is ready."
        case "starting": return "Starting the WhatsApp pairing bridge. The QR code will appear here when it is ready."
        default:
            return "In WhatsApp on the phone with the account to link, open Settings › Linked Devices › Link a Device and scan this code. This QR is not a web address."
        }
    }

    var linkedAccountDetail: String {
        setup?.accountPhone != nil || setup?.accountID != nil
            ? "This is the WhatsApp account Hermes is now logged into."
            : "Hermes is logged into the WhatsApp account that scanned the QR code."
    }

    var messageInstruction: String {
        mode == .selfChat
            ? "After the restart, open Message Yourself on the linked account and send Hermes a message."
            : "After the restart, start a chat from another WhatsApp account with the linked account and send Hermes a message."
    }

    func pairingInstruction(hasSavedAllowedUsers: Bool) -> String {
        let blank = allowedUsers.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if blank, hasSavedAllowedUsers { return "Hermes will keep the saved WhatsApp allowlist." }
        if blank, mode == .selfChat { return "Self-chat mode will allow the linked account automatically when you save." }
        return "If no allowed numbers were entered, Hermes replies with a pairing code. Approve it on this page."
    }
}

/// The rows of an allowlist editor (`AllowlistField`): one input per allowed user or ID, saved as one
/// comma-separated value.
struct MessagingAllowlistRows: Equatable {
    struct Row: Equatable, Identifiable {
        let id: Int
        var value: String
    }

    private(set) var rows: [Row]
    private var nextID: Int

    init(_ raw: String?) {
        let entries = MessagingAllowlist.split(raw)
        let values = entries.isEmpty ? [""] : entries
        rows = values.enumerated().map { Row(id: $0.offset, value: $0.element) }
        nextID = values.count
    }

    /// The saved form: trimmed, unique, comma-separated.
    var joined: String { MessagingAllowlist.join(rows.map(\.value)) }

    /// Only one empty row: nothing to remove.
    var isLone: Bool { rows.count == 1 && rows[0].value.isEmpty }

    /// A pasted "123, 456" becomes one row per entry.
    mutating func change(_ id: Int, to value: String) {
        guard let index = rows.firstIndex(where: { $0.id == id }) else { return }
        let parts = value.contains(",") || value.contains("\n") ? MessagingAllowlist.split(value) : [value]
        var replacement: [Row] = []
        for (offset, part) in parts.enumerated() {
            replacement.append(offset == 0 ? Row(id: id, value: part) : Row(id: takeID(), value: part))
        }
        rows.replaceSubrange(index...index, with: replacement.isEmpty ? [Row(id: id, value: "")] : replacement)
    }

    /// Adds an empty row and returns its id (to focus it).
    @discardableResult
    mutating func add() -> Int {
        let id = takeID()
        rows.append(Row(id: id, value: ""))
        return id
    }

    mutating func remove(_ id: Int) {
        rows.removeAll { $0.id == id }
        if rows.isEmpty { rows = [Row(id: takeID(), value: "")] }
    }

    private mutating func takeID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}
