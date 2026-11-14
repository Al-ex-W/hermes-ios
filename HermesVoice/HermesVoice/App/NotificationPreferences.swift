import Foundation

/// Which background alerts the Hermes Voice plugin may push to this phone (Settings > Notifications): an approval
/// waiting, a question (clarify) waiting, a turn that finished, and a message Hermes sends itself (`notify_user`).
/// Kept in UserDefaults and sent with the device registration (`POST /api/plugins/hermes_voice/devices`, `alerts`);
/// saving sends it again.
struct NotificationPreferences: Equatable, Codable {
    /// A command waits for approval.
    var approval: Bool
    /// Hermes asks a question (clarify).
    var clarify: Bool
    /// A turn finished while its session wasn't on screen.
    var turnDone: Bool
    /// Hermes notifies the user of its own accord (the plugin's `notify_user` tool), from any conversation.
    var message: Bool

    init(approval: Bool, clarify: Bool, turnDone: Bool, message: Bool = true) {
        self.approval = approval
        self.clarify = clarify
        self.turnDone = turnDone
        self.message = message
    }

    /// Saved before messages existed: those are on, as a kind the phone never named is on the plugin.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        approval = try container.decode(Bool.self, forKey: .approval)
        clarify = try container.decode(Bool.self, forKey: .clarify)
        turnDone = try container.decode(Bool.self, forKey: .turnDone)
        message = try container.decodeIfPresent(Bool.self, forKey: .message) ?? true
    }

    /// All on, as the desktop app's notification kinds start.
    static let defaults = NotificationPreferences(approval: true, clarify: true, turnDone: true, message: true)

    /// All off: what is registered while iOS doesn't let the app show notifications.
    static let none = NotificationPreferences(approval: false, clarify: false, turnDone: false, message: false)

    /// Posted on the main queue after `save`, so the registration goes out again.
    static let didChange = Notification.Name("HermesVoice.NotificationPreferences.didChange")

    private static let key = "notifications.preferences"

    var anyEnabled: Bool { approval || clarify || turnDone || message }

    /// The registration's `alerts` object.
    var alerts: [String: Bool] { ["approval": approval, "clarify": clarify, "turn_done": turnDone, "message": message] }

    /// The saved opt-ins, or the defaults before any were saved.
    static func load(from defaults: UserDefaults = .standard) -> NotificationPreferences {
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode(NotificationPreferences.self, from: data) else { return Self.defaults }
        return saved
    }

    /// Saves the opt-ins and posts `didChange`.
    static func save(_ preferences: NotificationPreferences, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
        let post = { NotificationCenter.default.post(name: didChange, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }

    func save(to defaults: UserDefaults = .standard) {
        Self.save(self, to: defaults)
    }
}
