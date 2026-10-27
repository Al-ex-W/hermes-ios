import Combine
import Foundation
import os
import UIKit
import UserNotifications

private let notificationLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "Notifications")

// MARK: - Payload

/// A background alert from the Hermes Voice plugin: an approval or a question waiting in a session, or a turn that
/// finished. The push is `{aps: {alert: {title, body}, category, thread-id, sound}, hermes: {kind, session_id, profile,
/// request_id, choices, questions}}`; the app posts the same shape locally for follow-ups.
struct AlertPush: Equatable, Sendable {
    enum Kind: String, Sendable {
        case approval
        case clarify
        case turnDone = "turn_done"
    }

    let kind: Kind
    /// The stored session it is about (`thread-id` too).
    let sessionID: String
    let profile: String?
    /// The server request waiting on the answer (approval, clarify).
    let requestID: String?
    /// The approval choices Hermes honors for this command; `deny` is always among them.
    let choices: [ApprovalChoice]
    /// The clarify questions still waiting, in order.
    let questions: [ClarifyQuestion]
    let title: String
    let body: String

    init(kind: Kind, sessionID: String, profile: String? = nil, requestID: String? = nil, choices: [ApprovalChoice] = [],
         questions: [ClarifyQuestion] = [], title: String = "Hermes", body: String = "") {
        self.kind = kind
        self.sessionID = sessionID
        self.profile = profile
        self.requestID = requestID
        self.choices = kind == .approval ? Self.honored(choices) : []
        self.questions = questions
        self.title = title
        self.body = body
    }

    /// Reads a notification's `userInfo`; nil when it isn't a Hermes alert (or names no session).
    init?(userInfo: [AnyHashable: Any]) {
        guard let hermes = userInfo["hermes"].map(JSONValue.init(any:)), case .object = hermes,
              let kind = hermes["kind"]?.stringValue.flatMap(Kind.init(rawValue:)) else { return nil }
        let aps = userInfo["aps"].map(JSONValue.init(any:)) ?? .null
        guard let sessionID = Self.text(hermes["session_id"]) ?? Self.text(aps["thread-id"]) else { return nil }
        let alert = aps["alert"] ?? .null
        let offered = hermes["choices"]?.arrayValue?.compactMap(\.stringValue).map(ApprovalChoice.init(rawValue:))
        let questions = (hermes["questions"]?.arrayValue ?? []).compactMap { item -> ClarifyQuestion? in
            guard let qid = Self.text(item["qid"]) else { return nil }
            let choices = item["choices"]?.arrayValue?.compactMap(\.stringValue)
            return ClarifyQuestion(qid: qid, question: item["question"]?.stringValue ?? "",
                                   choices: choices?.isEmpty == false ? choices : nil,
                                   multiSelect: item["multi_select"]?.boolValue)
        }
        self.init(kind: kind, sessionID: sessionID, profile: Self.text(hermes["profile"]),
                  requestID: Self.text(hermes["request_id"]), choices: offered ?? ApprovalChoice.allCases,
                  questions: questions, title: Self.text(alert["title"]) ?? "Hermes",
                  body: alert["body"]?.stringValue ?? alert.stringValue ?? "")
    }

    /// The notification category that carries this kind's actions.
    var category: String {
        switch kind {
        case .approval: return AlertCategory.approval
        case .clarify: return AlertCategory.clarify
        case .turnDone: return AlertCategory.turnDone
        }
    }

    /// The push's shape, for a notification the app posts itself.
    var userInfo: [AnyHashable: Any] {
        var hermes: [String: JSONValue] = ["kind": .string(kind.rawValue), "session_id": .string(sessionID)]
        if let profile { hermes["profile"] = .string(profile) }
        if let requestID { hermes["request_id"] = .string(requestID) }
        if kind == .approval { hermes["choices"] = .array(choices.map { .string($0.rawValue) }) }
        if kind == .clarify {
            hermes["questions"] = .array(questions.map { question in
                var item: [String: JSONValue] = ["qid": .string(question.qid), "question": .string(question.question)]
                if let choices = question.choices { item["choices"] = .array(choices.map(JSONValue.string)) }
                if let multiSelect = question.multiSelect { item["multi_select"] = .bool(multiSelect) }
                return .object(item)
            })
        }
        let aps: JSONValue = ["alert": ["title": .string(title), "body": .string(body)], "category": .string(category),
                              "thread-id": .string(sessionID)]
        return ["aps": aps.anyValue, "hermes": JSONValue.object(hermes).anyValue]
    }

    /// The same clarify with only `remaining` still waiting, the first of them as its text.
    func asking(_ remaining: [ClarifyQuestion]) -> AlertPush {
        let next = remaining.first
        let choices = next?.choices.map { "\n" + $0.joined(separator: " · ") } ?? ""
        return AlertPush(kind: kind, sessionID: sessionID, profile: profile, requestID: requestID, questions: remaining,
                         title: title, body: (next?.question ?? body) + choices)
    }

    /// The offered choices Hermes knows, and always `deny` (as the approval card shows them).
    private static func honored(_ offered: [ApprovalChoice]) -> [ApprovalChoice] {
        var choices = offered.filter { if case .unknown = $0 { return false } else { return true } }
        if !choices.contains(.deny) { choices.append(.deny) }
        return choices
    }

    private static func text(_ value: JSONValue?) -> String? {
        guard let string = value?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }
}

// MARK: - Categories and actions

/// The categories the plugin's alerts name (`aps.category`).
enum AlertCategory {
    static let approval = "HERMES_APPROVAL"
    static let clarify = "HERMES_CLARIFY"
    static let turnDone = "HERMES_TURN_DONE"
}

/// The actions on the alerts. "Always" is offered only on the approval card inside the app.
enum AlertAction {
    static let run = "HERMES_APPROVE_ONCE"
    static let allowSession = "HERMES_APPROVE_SESSION"
    static let reject = "HERMES_REJECT"
    static let reply = "HERMES_CLARIFY_REPLY"
    static let open = "HERMES_OPEN"

    static func categories() -> Set<UNNotificationCategory> {
        // Approving or answering from the lock screen asks for Face ID / the passcode first; rejecting doesn't.
        let run = UNNotificationAction(identifier: run, title: "Run", options: [.authenticationRequired])
        let allowSession = UNNotificationAction(identifier: allowSession, title: "Allow for session",
                                                options: [.authenticationRequired])
        let reject = UNNotificationAction(identifier: reject, title: "Reject", options: [.destructive])
        let reply = UNTextInputNotificationAction(identifier: reply, title: "Reply", options: [.authenticationRequired],
                                                  textInputButtonTitle: "Send", textInputPlaceholder: "Your answer")
        let open = UNNotificationAction(identifier: open, title: "Open", options: [.foreground])
        return [
            UNNotificationCategory(identifier: AlertCategory.approval, actions: [run, allowSession, reject],
                                   intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: AlertCategory.clarify, actions: [reply, open], intentIdentifiers: [],
                                   options: []),
            UNNotificationCategory(identifier: AlertCategory.turnDone, actions: [open], intentIdentifiers: [], options: []),
        ]
    }
}

/// An answer given from a notification.
enum AlertReply: Equatable, Sendable {
    case approval(ApprovalChoice)
    /// The answer to one clarify question.
    case clarify(qid: String, text: String)

    /// The request's result, as its card would answer it.
    var result: [String: JSONValue] {
        switch self {
        case let .approval(choice): return ["choice": .string(choice.rawValue)]
        case let .clarify(qid, text): return ["answers": [qid: .string(text)]]
        }
    }
}

/// What the user did with an alert.
enum AlertIntent: Equatable {
    /// Open its session (a tap, or the Open action).
    case open
    case answer(AlertReply)
    /// The action can't answer this alert (why); the alert is posted again with that note, with its actions only
    /// when another try could work (`retry`: another approval choice, a reply that isn't empty). An alert that
    /// names no request, or a clarify that carries no questions (the host keeps previews off, or the questions
    /// didn't fit APNs' 4 KB), can only open the session.
    case unanswerable(String, retry: Bool)
    case ignore

    static func of(action: String, text: String?, push: AlertPush) -> AlertIntent {
        switch action {
        case UNNotificationDefaultActionIdentifier, AlertAction.open:
            return .open
        case AlertAction.run, AlertAction.allowSession, AlertAction.reject:
            guard push.kind == .approval else { return .ignore }
            let choice: ApprovalChoice = action == AlertAction.run ? .once : action == AlertAction.allowSession ? .session : .deny
            guard push.requestID != nil else { return .unanswerable("Open Hermes to answer this approval.", retry: false) }
            guard push.choices.contains(choice) else {
                return .unanswerable("Hermes doesn't offer “\(choice == .session ? "Allow for session" : "Run")” for this command. Open Hermes to answer.",
                                     retry: true)
            }
            return .answer(.approval(choice))
        case AlertAction.reply:
            guard push.kind == .clarify else { return .ignore }
            guard push.requestID != nil, let question = push.questions.first else {
                return .unanswerable("Open Hermes to answer this question.", retry: false)
            }
            let answer = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !answer.isEmpty else { return .unanswerable("The reply was empty.", retry: true) }
            return .answer(.clarify(qid: question.qid, text: answer))
        default:
            return .ignore
        }
    }
}

// MARK: - Answering

/// Answers an alert's request over a gateway connection, as its card would: `request.answer` with the result. An
/// approval that no open request matches any more (or a backend without `request.answer`) is resolved through
/// `approval.respond` by the stored session and the request id, never the oldest one waiting. One answer of a
/// clarify with several questions is locked with `clarify.lock`; the others keep waiting.
struct AlertResponder {
    enum Outcome: Equatable {
        case answered
        /// Hermes no longer waits for it (answered elsewhere, timed out or cancelled).
        case expired
        /// Answered; more questions wait (the alert for them).
        case more(AlertPush)
    }

    let gateway: GatewayClient
    /// Per call: a notification action has about half a minute in the background, sign-in and connecting included.
    var timeout: TimeInterval = 12

    /// `approval.respond` found no live session by that id: none can be waiting on an approval.
    static let sessionNotFound = 4001

    func answer(_ push: AlertPush, _ reply: AlertReply) async throws -> Outcome {
        guard let requestID = push.requestID else { return .expired }
        switch reply {
        case let .approval(choice):
            do {
                if try await requestAnswer(requestID, reply, push) { return .answered }
            } catch let error as GatewayRPCError {
                notificationLog.info("request.answer refused (\(error.code)); trying approval.respond")
            }
            do {
                let respond = try await gateway.approvalRespond(
                    .init(sessionId: push.sessionID, profile: push.profile, choice: choice.rawValue, requestId: requestID),
                    timeout: timeout
                )
                return respond.resolved > 0 ? .answered : .expired
            } catch let error as GatewayRPCError where error.code == Self.sessionNotFound {
                return .expired
            }
        case let .clarify(qid, text):
            if push.questions.count > 1 {
                do {
                    let lock = try await gateway.clarifyLock(
                        .init(requestId: requestID, questionId: qid, answer: .string(text), profile: push.profile),
                        timeout: timeout
                    )
                    if lock.status == .expired { return .expired }
                    let remaining = Set(lock.remaining ?? [])
                    guard !remaining.isEmpty else { return .answered }
                    // Questions the alert didn't carry are answered in the app.
                    return .more(push.asking(push.questions.filter { $0.qid != qid && remaining.contains($0.qid) }))
                } catch let error as GatewayRPCError where error.code == -32601 {
                    // A backend without per-question locks: the answer closes the request.
                }
            }
            return try await requestAnswer(requestID, reply, push) ? .answered : .expired
        }
    }

    /// True when the request took the answer, false when it had ended.
    private func requestAnswer(_ id: String, _ reply: AlertReply, _ push: AlertPush) async throws -> Bool {
        do {
            return try await gateway.requestAnswer(.init(id: id, result: reply.result, profile: push.profile),
                                                   timeout: timeout).status != .expired
        } catch is GatewayDecodingError {
            // Answered, in a shape outside the contract.
            return true
        }
    }
}

// MARK: - Notifications

/// Background alerts (non-VoIP APNs) from the Hermes Voice plugin: the alert token and opt-ins sent with the device
/// registration, the categories and their actions, answers sent from the lock screen (signing in silently first),
/// a tap opening the session, and banners in the foreground unless that session is on screen.
@MainActor
final class AlertNotifications: NSObject, ObservableObject {
    /// A session a tapped alert opens; the app shell takes it.
    struct SessionTarget: Equatable {
        let id: String
        let profile: String?
    }

    /// Whether iOS lets the app show notifications (for Settings > Notifications).
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published var openRequest: SessionTarget?

    private weak var model: AppModel?
    /// The chat on screen, set by the detail column.
    private weak var visibleChat: ChatModel?
    /// A sheet (Settings, Profiles) covers the detail column: the chat there isn't on screen.
    var covered = false
    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var started = false
    /// Opens the gateway connection an answer goes through; a fresh one, so a socket that died while the app was
    /// suspended can't swallow it.
    var connect: (DashboardClient) -> GatewayConnection = { GatewayConnection(client: $0) }

    private var center: UNUserNotificationCenter { .current() }

    /// The opt-ins registered while iOS allows notifications in `status`; none otherwise.
    nonisolated static func registered(_ preferences: NotificationPreferences, status: UNAuthorizationStatus) -> NotificationPreferences {
        switch status {
        case .authorized, .provisional, .ephemeral: return preferences
        default: return .none
        }
    }

    /// Foreground presentation: nothing while the alert's session is on screen (its card or reply shows there).
    nonisolated static func presentation(for push: AlertPush?, sessionOnScreen: Bool) -> UNNotificationPresentationOptions {
        push != nil && sessionOnScreen ? [] : [.banner, .list, .sound]
    }

    func attach(to model: AppModel) {
        self.model = model
        model.push.onAlertToken = { [weak model] _ in model?.sendPushToken() }
        model.$signedIn
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in Task { await self?.sync(asking: true) } }
            .store(in: &subscriptions)
    }

    /// At launch, before `didFinishLaunching` returns, so an action that launched the app is delivered.
    func start() {
        guard !started else { return }
        started = true
        center.delegate = self
        center.setNotificationCategories(AlertAction.categories())
        UIApplication.shared.registerForRemoteNotifications()
        observers = [
            NotificationCenter.default.addObserver(forName: NotificationPreferences.didChange, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in await self?.sync(asking: true) }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                // Notifications may have been turned on or off in iOS Settings meanwhile.
                Task { @MainActor in await self?.sync(asking: false) }
            },
        ]
        Task { await sync(asking: false) }
    }

    /// Registers the opt-ins iOS lets through, asking for permission first when one is on, the user was never
    /// asked and the app is signed in (so the question comes once Hermes is set up).
    func sync(asking: Bool) async {
        guard let model else { return }
        let preferences = NotificationPreferences.load()
        var status = await center.notificationSettings().authorizationStatus
        if asking, preferences.anyEnabled, status == .notDetermined, model.signedIn {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        authorization = status
        if model.push.setAlerts(Self.registered(preferences, status: status)) { model.sendPushToken() }
    }

    // MARK: The session on screen

    func showing(_ chat: ChatModel) {
        visibleChat = chat
        guard let id = chat.storedID else { return }
        // Its alerts are read now.
        let ids = chat.sessionIDs.union([id])
        removeDelivered { ids.contains($0.sessionID) }
    }

    func hid(_ chat: ChatModel) {
        if visibleChat === chat { visibleChat = nil }
    }

    private func isOnScreen(_ sessionID: String) -> Bool {
        Self.onScreen(sessionID, chat: visibleChat, active: UIApplication.shared.applicationState == .active, covered: covered)
    }

    /// Whether `sessionID` is the chat on screen: the app is in front, no sheet covers the chat, and it's that one.
    static func onScreen(_ sessionID: String, chat: ChatModel?, active: Bool, covered: Bool) -> Bool {
        guard active, !covered, let chat else { return false }
        return chat.storedID == sessionID || chat.sessionIDs.contains(sessionID)
    }

    // MARK: Signing out and testing

    /// Signed out: the alerts already shown can't be answered any more (their command and question text goes too).
    func signedOut() {
        center.removeAllDeliveredNotifications()
    }

    /// Settings > Notifications' test: a local notification now, asking for permission first if iOS never asked.
    /// Nil when it went out, else why not.
    func sendTest() async -> String? {
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
            status = await center.notificationSettings().authorizationStatus
        }
        await sync(asking: false)
        guard Self.registered(.defaults, status: status).anyEnabled else {
            return "Notifications are off for this app in iOS Settings."
        }
        let content = UNMutableNotificationContent()
        content.title = "Hermes"
        content.body = "Notifications from Hermes reach this iPhone."
        content.sound = .default
        do {
            try await center.add(UNNotificationRequest(identifier: "hermes-test", content: content, trigger: nil))
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: Actions

    func handle(action: String, text: String?, push: AlertPush?) async {
        guard let push else { return }
        switch AlertIntent.of(action: action, text: text, push: push) {
        case .ignore:
            return
        case .open:
            open(push)
        case let .unanswerable(reason, retry):
            post(push, note: reason, actions: retry)
        case let .answer(reply):
            await answer(push, reply)
        }
    }

    private func open(_ push: AlertPush) {
        openRequest = SessionTarget(id: push.sessionID, profile: push.profile)
        if model?.signedIn == false { Task { await model?.restore() } }
    }

    private func answer(_ push: AlertPush, _ reply: AlertReply) async {
        let background = BackgroundTask(name: "Hermes alert answer")
        defer { background.end() }
        var opened: GatewayConnection?
        defer { opened?.disconnect() }
        do {
            let connection = connect(try await signedInClient())
            opened = connection
            let outcome = try await AlertResponder(gateway: connection.client).answer(push, reply)
            // The outcome's name only: a follow-up alert carries the conversation's questions.
            let summary = switch outcome {
            case .answered: "answered"
            case .expired: "expired"
            case .more: "answered, more waiting"
            }
            notificationLog.info("\(push.kind.rawValue, privacy: .public) alert: \(summary, privacy: .public)")
            switch outcome {
            case .answered:
                if let id = push.requestID { model?.prompts?.answeredOutside(id) }
                removeDelivered { $0.requestID == push.requestID }
            case .expired:
                if let id = push.requestID { model?.prompts?.answeredOutside(id) }
                post(push, note: "Hermes is no longer waiting for this answer.", actions: false)
            case let .more(next) where next.questions.isEmpty:
                post(next, note: "Open Hermes to answer the other questions.", actions: false)
            case let .more(next):
                post(next, note: "Next question", actions: true)
            }
        } catch DashboardError.timeout, DashboardError.disconnected {
            // The answer may have arrived; sending it again is harmless (an ended request takes none).
            notificationLog.error("\(push.kind.rawValue, privacy: .public) alert answer unconfirmed")
            post(push, note: "Hermes didn't confirm your answer. Open Hermes to check.", actions: true)
        } catch {
            notificationLog.error("\(push.kind.rawValue, privacy: .public) alert answer failed: \(error.localizedDescription, privacy: .public)")
            post(push, note: "Couldn't send your answer: \(error.localizedDescription)", actions: true)
        }
    }

    /// The dashboard client, signing in with the saved password when the action woke the app.
    private func signedInClient() async throws -> DashboardClient {
        guard let model else { throw DashboardError.signedOut }
        if !model.signedIn {
            // Launched in the background before the first unlock, the Keychain read came back empty.
            if model.settings.password.isEmpty { model.settings = ConnectionSettings.load() }
            await model.restore()
        }
        guard model.signedIn, let client = model.client else {
            throw model.error.map(DashboardError.rpc) ?? DashboardError.signedOut
        }
        return client
    }

    // MARK: Posting and clearing

    /// Posts `push` again, with `note` under its title; without its actions it only opens the session.
    private func post(_ push: AlertPush, note: String?, actions: Bool) {
        let content = UNMutableNotificationContent()
        content.title = push.title
        if let note { content.subtitle = note }
        content.body = push.body
        content.categoryIdentifier = actions ? push.category : ""
        content.threadIdentifier = push.sessionID
        content.userInfo = push.userInfo
        content.sound = .default
        let request = UNNotificationRequest(identifier: "hermes-followup-\(push.requestID ?? push.sessionID)",
                                            content: content, trigger: nil)
        center.add(request) { error in
            if let error { notificationLog.error("Can't post the alert again: \(error.localizedDescription, privacy: .public)") }
        }
    }

    private func removeDelivered(where matches: @escaping @Sendable (AlertPush) -> Bool) {
        center.getDeliveredNotifications { delivered in
            let ids = delivered.compactMap { notification -> String? in
                guard let push = AlertPush(userInfo: notification.request.content.userInfo), matches(push) else { return nil }
                return notification.request.identifier
            }
            guard !ids.isEmpty else { return }
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
        }
    }
}

extension AlertNotifications: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        let push = AlertPush(userInfo: notification.request.content.userInfo)
        Task { @MainActor in
            completionHandler(Self.presentation(for: push, sessionOnScreen: push.map { self.isOnScreen($0.sessionID) } ?? false))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let push = AlertPush(userInfo: response.notification.request.content.userInfo)
        let action = response.actionIdentifier
        let text = (response as? UNTextInputNotificationResponse)?.userText
        Task { @MainActor in
            await self.handle(action: action, text: text, push: push)
            completionHandler()
        }
    }
}

/// Background time for an answer sent from a notification action.
@MainActor
private final class BackgroundTask {
    private var id = UIBackgroundTaskIdentifier.invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
