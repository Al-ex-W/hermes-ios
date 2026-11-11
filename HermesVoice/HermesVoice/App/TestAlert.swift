import Foundation

/// Settings > Notifications' test alert as its row shows it: a real push the Hermes Voice plugin sends this iPhone
/// (`POST /devices/test`), from asking for it to what the user did with it.
struct TestAlertState: Equatable {
    enum Phase: Equatable {
        /// Asking the plugin.
        case sending
        /// The plugin pushes it in a few seconds (time to lock the phone or leave the app).
        case scheduled
        /// APNs accepted it.
        case sent
        /// It showed on this iPhone while the app was in front.
        case arrived
        /// The user answered or opened it.
        case answered
        case failed
    }

    var kind: AlertPush.Kind
    /// The plugin's id for the test, once it answered.
    var id: String?
    var phase: Phase
    /// The line under the row.
    var message: String

    var failed: Bool { phase == .failed }
    /// A test is on its way: the row waits rather than send another.
    var busy: Bool { phase == .sending || phase == .scheduled }

    static let asking = "Asking Hermes to send it…"
    static let noToken = "iOS hasn't given this iPhone a push token yet, so Hermes can't reach it. Try again in a moment."
    static let lost = "Hermes didn't say what became of the test notification."
    static let arrived = "The test notification arrived on this iPhone."

    /// The row's hint before any test: what the button does.
    static func hint(delay: TimeInterval) -> String {
        "Hermes sends a real push to this iPhone \(Int(delay)) s after you tap, so you can lock it or leave the app first. Answering a test runs nothing."
    }

    static func asking(_ kind: AlertPush.Kind) -> TestAlertState {
        TestAlertState(kind: kind, id: nil, phase: .sending, message: asking)
    }

    static func failed(_ kind: AlertPush.Kind, _ message: String, id: String? = nil) -> TestAlertState {
        TestAlertState(kind: kind, id: id, phase: .failed, message: message)
    }

    /// This state after the plugin said `result`. What this iPhone saw itself (the push arriving, the user's answer)
    /// isn't taken back by the plugin's slower "sent", and another test's result changes nothing.
    func applying(_ result: TestAlertResult) -> TestAlertState {
        if let id, id != result.id { return self }
        var next = TestAlertState(kind: result.kind, id: result.id, phase: phase, message: result.message)
        switch result.status {
        case .scheduled:
            next.phase = .scheduled
        case .sent:
            if phase == .arrived || phase == .answered { return TestAlertState(kind: kind, id: result.id, phase: phase, message: message) }
            next.phase = .sent
        case .answered:
            if phase == .answered { return TestAlertState(kind: kind, id: result.id, phase: phase, message: message) }
            next.phase = .answered
        case .failed:
            next.phase = .failed
        }
        return next
    }

    /// This state once `push` (a test alert) showed on this iPhone.
    func arrived(_ push: AlertPush) -> TestAlertState {
        guard push.isTest, id == nil || id == push.testID, phase != .answered, phase != .failed else { return self }
        return TestAlertState(kind: push.kind, id: push.testID ?? id, phase: .arrived, message: Self.arrived)
    }
}

/// The test row of Settings > Notifications: the line under the button, whether it reports a problem, and whether
/// a test is on its way (the button and the kind picker wait).
struct TestAlertRow: Equatable {
    let message: String
    let isError: Bool
    let busy: Bool

    init(_ state: TestAlertState?, delay: TimeInterval) {
        message = state?.message ?? TestAlertState.hint(delay: delay)
        isError = state?.failed ?? false
        busy = state?.busy ?? false
    }

    /// The kind as the picker names it.
    static func title(_ kind: AlertPush.Kind) -> String {
        switch kind {
        case .approval: return "Approval"
        case .clarify: return "Question"
        case .turnDone: return "Turn finished"
        }
    }
}

/// What the user did with a test alert: the action the plugin is told (`POST /devices/test/{id}/answer`; never a
/// reply's text) and the line that confirms it on this iPhone.
struct TestAlertAnswer: Equatable {
    let action: String
    let summary: String

    /// Nil for an intent that answers nothing (an action of another kind's alert, a reply that can't be sent).
    static func of(_ intent: AlertIntent) -> TestAlertAnswer? {
        switch intent {
        case .open:
            return TestAlertAnswer(action: "open", summary: "Test notification opened. A real one opens its chat.")
        case let .answer(.approval(choice)):
            return TestAlertAnswer(action: choice.rawValue,
                                   summary: "Test approval answered: \(label(choice)). Nothing was run.")
        case let .answer(.clarify(_, text)):
            let shown = text.count > 80 ? text.prefix(79) + "…" : Substring(text)
            return TestAlertAnswer(action: "reply", summary: "Test question answered: “\(shown)”.")
        case .unanswerable, .ignore:
            return nil
        }
    }

    /// The choice as its notification action names it.
    private static func label(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: return "Run"
        case .session: return "Allow for session"
        case .always: return "Always allow"
        case .deny: return "Reject"
        case let .unknown(value): return value
        }
    }
}
