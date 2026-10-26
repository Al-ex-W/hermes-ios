import UserNotifications
import XCTest
@testable import HermesVoice

/// Background alerts: the plugin's payload, the categories and actions, the answers they send, and the device
/// registration that opts into them.
@MainActor
final class NotificationTests: XCTestCase {
    /// A push's `userInfo` as iOS hands it over (Foundation objects from the APNs JSON).
    private func userInfo(_ json: String) throws -> [AnyHashable: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [AnyHashable: Any])
    }

    private let approvalJSON = """
    {"aps": {"alert": {"title": "Approve command?", "body": "rm -rf build"}, "category": "HERMES_APPROVAL",
             "thread-id": "20261026_abc", "sound": "default"},
     "hermes": {"kind": "approval", "session_id": "20261026_abc", "profile": "work", "request_id": "srq-1",
                "choices": ["once", "deny"]}}
    """

    private func approval(choices: [ApprovalChoice] = ApprovalChoice.allCases, requestID: String? = "srq-1") -> AlertPush {
        AlertPush(kind: .approval, sessionID: "s1", profile: "work", requestID: requestID, choices: choices,
                  title: "Approve command?", body: "rm -rf build")
    }

    private let q1 = ClarifyQuestion(qid: "q1", question: "Which branch?", choices: ["main", "dev"], multiSelect: false)
    private let q2 = ClarifyQuestion(qid: "q2", question: "Why?", choices: nil, multiSelect: nil)

    private func clarify(_ questions: [ClarifyQuestion], requestID: String? = "srq-2") -> AlertPush {
        AlertPush(kind: .clarify, sessionID: "s1", profile: "work", requestID: requestID, questions: questions,
                  title: "Hermes asks", body: "Which branch?")
    }

    // MARK: Payload

    func testApprovalPayloadDecodes() throws {
        let push = try XCTUnwrap(AlertPush(userInfo: userInfo(approvalJSON)))
        XCTAssertEqual(push.kind, .approval)
        XCTAssertEqual(push.sessionID, "20261026_abc")
        XCTAssertEqual(push.profile, "work")
        XCTAssertEqual(push.requestID, "srq-1")
        XCTAssertEqual(push.choices, [.once, .deny])
        XCTAssertEqual(push.title, "Approve command?")
        XCTAssertEqual(push.body, "rm -rf build")
        XCTAssertEqual(push.category, "HERMES_APPROVAL")
    }

    func testApprovalChoicesKeepDenyAndDropUnknownOnes() throws {
        let offered = try XCTUnwrap(AlertPush(userInfo: userInfo("""
        {"aps": {"alert": {"title": "t", "body": "b"}},
         "hermes": {"kind": "approval", "session_id": "s1", "request_id": "r", "choices": ["session", "sometimes"]}}
        """)))
        XCTAssertEqual(offered.choices, [.session, .deny])
        let unnamed = try XCTUnwrap(AlertPush(userInfo: userInfo("""
        {"aps": {"alert": "b"}, "hermes": {"kind": "approval", "session_id": "s1", "request_id": "r"}}
        """)))
        XCTAssertEqual(unnamed.choices, [.once, .session, .always, .deny])
        XCTAssertEqual(unnamed.body, "b")
        XCTAssertEqual(unnamed.title, "Hermes")
    }

    func testClarifyPayloadDecodes() throws {
        let push = try XCTUnwrap(AlertPush(userInfo: userInfo("""
        {"aps": {"alert": {"title": "Hermes asks", "body": "Which branch?"}, "category": "HERMES_CLARIFY", "thread-id": "s1"},
         "hermes": {"kind": "clarify", "session_id": "s1", "request_id": "srq-2",
                    "questions": [{"qid": "q1", "question": "Which branch?", "choices": ["main", "dev"], "multi_select": false},
                                  {"qid": "q2", "question": "Why?", "choices": []},
                                  {"question": "no id"}]}}
        """)))
        XCTAssertEqual(push.kind, .clarify)
        XCTAssertEqual(push.requestID, "srq-2")
        XCTAssertEqual(push.questions, [q1, q2])
        XCTAssertEqual(push.choices, [])
        XCTAssertEqual(push.category, "HERMES_CLARIFY")
    }

    func testTurnDoneTakesTheSessionFromTheThread() throws {
        let push = try XCTUnwrap(AlertPush(userInfo: userInfo("""
        {"aps": {"alert": {"title": "Done", "body": "All tests pass."}, "category": "HERMES_TURN_DONE", "thread-id": "s9"},
         "hermes": {"kind": "turn_done", "profile": "default"}}
        """)))
        XCTAssertEqual(push.kind, .turnDone)
        XCTAssertEqual(push.sessionID, "s9")
        XCTAssertNil(push.requestID)
        XCTAssertEqual(push.category, "HERMES_TURN_DONE")
    }

    func testOtherPayloadsAreNotHermesAlerts() throws {
        XCTAssertNil(AlertPush(userInfo: try userInfo(#"{"aps": {"alert": "hi"}}"#)))
        XCTAssertNil(AlertPush(userInfo: try userInfo(#"{"aps": {"alert": "hi"}, "hermes": {"kind": "call", "session_id": "s1"}}"#)))
        XCTAssertNil(AlertPush(userInfo: try userInfo(#"{"aps": {"alert": "hi"}, "hermes": {"kind": "approval", "session_id": " "}}"#)))
        XCTAssertNil(AlertPush(userInfo: try userInfo(#"{"aps": {"alert": "hi"}, "hermes": "approval"}"#)))
    }

    func testPostedAlertCarriesThePushShape() throws {
        for push in [approval(choices: [.once, .session, .deny]), clarify([q1, q2]),
                     AlertPush(kind: .turnDone, sessionID: "s3", title: "Done", body: "ok")] {
            // A notification's userInfo must be a property list.
            let info = Dictionary(uniqueKeysWithValues: push.userInfo.map { ("\($0.key)", $0.value) })
            XCTAssertNoThrow(try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0))
            XCTAssertEqual(AlertPush(userInfo: push.userInfo), push)
        }
        let aps = JSONValue(any: approval().userInfo["aps"] as Any)
        XCTAssertEqual(aps["category"], "HERMES_APPROVAL")
        XCTAssertEqual(aps["thread-id"], "s1")
    }

    func testNextClarifyAsksItsFirstQuestion() {
        let next = clarify([q1, q2]).asking([q2])
        XCTAssertEqual(next.questions, [q2])
        XCTAssertEqual(next.body, "Why?")
        XCTAssertEqual(next.requestID, "srq-2")
        XCTAssertEqual(clarify([q1, q2]).asking([q1]).body, "Which branch?\nmain · dev")
    }

    // MARK: Categories and actions

    func testCategoriesOfferTheContractActions() throws {
        let categories = Dictionary(uniqueKeysWithValues: AlertAction.categories().map { ($0.identifier, $0) })
        XCTAssertEqual(Set(categories.keys), ["HERMES_APPROVAL", "HERMES_CLARIFY", "HERMES_TURN_DONE"])

        let approval = try XCTUnwrap(categories["HERMES_APPROVAL"])
        XCTAssertEqual(approval.actions.map(\.title), ["Run", "Allow for session", "Reject"], "Always only in the app")
        XCTAssertEqual(approval.actions.map(\.identifier), [AlertAction.run, AlertAction.allowSession, AlertAction.reject])
        XCTAssertTrue(approval.actions[0].options.contains(.authenticationRequired))
        XCTAssertTrue(approval.actions[1].options.contains(.authenticationRequired))
        XCTAssertTrue(approval.actions[2].options.contains(.destructive))

        let clarify = try XCTUnwrap(categories["HERMES_CLARIFY"])
        XCTAssertEqual(clarify.actions.map(\.identifier), [AlertAction.reply, AlertAction.open])
        XCTAssertTrue(clarify.actions[0] is UNTextInputNotificationAction)
        XCTAssertTrue(clarify.actions[1].options.contains(.foreground))

        let done = try XCTUnwrap(categories["HERMES_TURN_DONE"])
        XCTAssertEqual(done.actions.map(\.identifier), [AlertAction.open])
        XCTAssertTrue(done.actions[0].options.contains(.foreground))
    }

    func testApprovalActionsMapToChoices() {
        let push = approval()
        XCTAssertEqual(AlertIntent.of(action: AlertAction.run, text: nil, push: push), .answer(.approval(.once)))
        XCTAssertEqual(AlertIntent.of(action: AlertAction.allowSession, text: nil, push: push), .answer(.approval(.session)))
        XCTAssertEqual(AlertIntent.of(action: AlertAction.reject, text: nil, push: push), .answer(.approval(.deny)))
        XCTAssertEqual(AlertIntent.of(action: UNNotificationDefaultActionIdentifier, text: nil, push: push), .open)
        XCTAssertEqual(AlertIntent.of(action: UNNotificationDismissActionIdentifier, text: nil, push: push), .ignore)
        XCTAssertEqual(AlertIntent.of(action: AlertAction.reply, text: "yes", push: push), .ignore)
    }

    func testApprovalActionHermesDoesNotOfferIsNotSent() {
        let push = approval(choices: [.once, .deny])
        guard case .unanswerable = AlertIntent.of(action: AlertAction.allowSession, text: nil, push: push) else {
            return XCTFail("a session approval Hermes doesn't offer went out")
        }
        XCTAssertEqual(AlertIntent.of(action: AlertAction.reject, text: nil, push: push), .answer(.approval(.deny)))
        guard case .unanswerable = AlertIntent.of(action: AlertAction.run, text: nil, push: approval(requestID: nil)) else {
            return XCTFail("an approval without its request was answered")
        }
    }

    func testClarifyReplyAnswersTheFirstQuestion() {
        let push = clarify([q1, q2])
        XCTAssertEqual(AlertIntent.of(action: AlertAction.reply, text: "  dev \n", push: push),
                       .answer(.clarify(qid: "q1", text: "dev")))
        XCTAssertEqual(AlertIntent.of(action: AlertAction.open, text: nil, push: push), .open)
        XCTAssertEqual(AlertIntent.of(action: AlertAction.run, text: nil, push: push), .ignore)
        for (text, push) in [("   ", push), ("dev", clarify([])), ("dev", clarify([q1], requestID: nil))] {
            guard case .unanswerable = AlertIntent.of(action: AlertAction.reply, text: text, push: push) else {
                return XCTFail("\(text) was sent for \(push)")
            }
        }
        let done = AlertPush(kind: .turnDone, sessionID: "s1")
        XCTAssertEqual(AlertIntent.of(action: AlertAction.open, text: nil, push: done), .open)
        XCTAssertEqual(AlertIntent.of(action: AlertAction.run, text: nil, push: done), .ignore)
    }

    func testRepliesAnswerAsTheirCardsWould() {
        XCTAssertEqual(AlertReply.approval(.session).result, ["choice": "session"])
        XCTAssertEqual(AlertReply.clarify(qid: "q1", text: "dev").result, ["answers": ["q1": "dev"]])
    }

    // MARK: Answering

    private func respond(_ push: AlertPush, _ reply: AlertReply,
                         _ handlers: [String: (JSONValue) -> ScriptedGateway.Reply]) async throws -> (AlertResponder.Outcome, ScriptedGateway) {
        let gateway = ScriptedGateway()
        gateway.handlers = handlers
        let connection = gateway.connection()
        defer { connection.disconnect() }
        let outcome = try await AlertResponder(gateway: connection.client).answer(push, reply)
        return (outcome, gateway)
    }

    func testApprovalAnswersTheRequest() async throws {
        let (outcome, gateway) = try await respond(approval(), .approval(.once), [
            "request.answer": { _ in .result(["status": "ok"]) },
        ])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(gateway.calls("request.answer").map(\.params),
                       [["id": "srq-1", "result": ["choice": "once"], "profile": "work"]])
        XCTAssertTrue(gateway.calls("approval.respond").isEmpty)
    }

    func testApprovalTheRequestNoLongerHoldsGoesThroughApprovalRespond() async throws {
        let (outcome, gateway) = try await respond(approval(), .approval(.session), [
            "request.answer": { _ in .result(["status": "expired"]) },
            "approval.respond": { _ in .result(["resolved": 1]) },
        ])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(gateway.calls("approval.respond").map(\.params),
                       [["session_id": "s1", "profile": "work", "choice": "session", "request_id": "srq-1"]])
    }

    func testApprovalWithoutRequestAnswerGoesThroughApprovalRespond() async throws {
        // No request.answer handler: the scripted backend answers -32601.
        let (outcome, gateway) = try await respond(approval(), .approval(.deny), [
            "approval.respond": { _ in .result(["resolved": 1]) },
        ])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(gateway.calls("approval.respond").first?.params["choice"], "deny")
    }

    func testApprovalNobodyWaitsForHasExpired() async throws {
        let (resolvedNone, _) = try await respond(approval(), .approval(.once), [
            "request.answer": { _ in .result(["status": "expired"]) },
            "approval.respond": { _ in .result(["resolved": 0]) },
        ])
        XCTAssertEqual(resolvedNone, .expired)
        let (noSession, _) = try await respond(approval(), .approval(.once), [
            "request.answer": { _ in .result(["status": "expired"]) },
            "approval.respond": { _ in .error(4001, "session not found") },
        ])
        XCTAssertEqual(noSession, .expired)
    }

    func testApprovalRespondFailureIsReported() async throws {
        do {
            _ = try await respond(approval(), .approval(.once), [
                "request.answer": { _ in .result(["status": "expired"]) },
                "approval.respond": { _ in .error(5004, "approval store unavailable") },
            ])
            XCTFail("the failure was swallowed")
        } catch let error as GatewayRPCError {
            XCTAssertEqual(error.code, 5004)
        }
    }

    func testClarifyWithOneQuestionAnswersTheRequest() async throws {
        let (outcome, gateway) = try await respond(clarify([q1]), .clarify(qid: "q1", text: "dev"), [
            "request.answer": { _ in .result(["status": "ok"]) },
        ])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(gateway.calls("request.answer").map(\.params),
                       [["id": "srq-2", "result": ["answers": ["q1": "dev"]], "profile": "work"]])
        XCTAssertTrue(gateway.calls("clarify.lock").isEmpty)
    }

    func testClarifyRequestThatEndedHasExpired() async throws {
        let (outcome, _) = try await respond(clarify([q1]), .clarify(qid: "q1", text: "dev"), [
            "request.answer": { _ in .result(["status": "expired"]) },
        ])
        XCTAssertEqual(outcome, .expired)
    }

    func testClarifyWithMoreQuestionsLocksOneAndAsksTheNext() async throws {
        let (outcome, gateway) = try await respond(clarify([q1, q2]), .clarify(qid: "q1", text: "dev"), [
            "clarify.lock": { _ in .result(["status": "ok", "remaining": ["q2"]]) },
        ])
        XCTAssertEqual(outcome, .more(clarify([q1, q2]).asking([q2])))
        XCTAssertEqual(gateway.calls("clarify.lock").map(\.params),
                       [["request_id": "srq-2", "question_id": "q1", "answer": "dev", "profile": "work"]])
        XCTAssertTrue(gateway.calls("request.answer").isEmpty)

        // The other question was answered meanwhile (in the app): this lock resolves the request.
        let (last, _) = try await respond(clarify([q1, q2]), .clarify(qid: "q1", text: "dev"), [
            "clarify.lock": { _ in .result(["status": "ok", "remaining": []]) },
        ])
        XCTAssertEqual(last, .answered)
        let (expired, _) = try await respond(clarify([q1, q2]), .clarify(qid: "q1", text: "dev"), [
            "clarify.lock": { _ in .result(["status": "expired"]) },
        ])
        XCTAssertEqual(expired, .expired)
    }

    func testClarifyQuestionsTheAlertDidNotCarryAreLeftToTheApp() async throws {
        let (outcome, _) = try await respond(clarify([q1, q2]), .clarify(qid: "q1", text: "dev"), [
            "clarify.lock": { _ in .result(["status": "ok", "remaining": ["q3"]]) },
        ])
        guard case let .more(next) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertTrue(next.questions.isEmpty)
    }

    func testClarifyWithoutLocksAnswersTheRequest() async throws {
        let (outcome, gateway) = try await respond(clarify([q1, q2]), .clarify(qid: "q1", text: "dev"), [
            "request.answer": { _ in .result(["status": "ok"]) },
        ])
        XCTAssertEqual(outcome, .answered)
        XCTAssertEqual(gateway.calls("clarify.lock").count, 1)
        XCTAssertEqual(gateway.calls("request.answer").first?.params["result"], ["answers": ["q1": "dev"]])
    }

    func testAlertAnsweredOutsideClearsItsCard() async throws {
        let gateway = ScriptedGateway()
        let connection = gateway.connection()
        defer { connection.disconnect() }
        let center = PromptCenter(connection: connection)
        try await connection.connect()
        gateway.current.push(request: "srq-1", method: "approval", params: [
            "session_id": "r1", "request_id": "q1", "command": "ls", "description": "list", "choices": ["once", "deny"],
        ])
        gateway.current.push(request: "srq-2", method: "clarify", params: [
            "session_id": "r1", "questions": [["qid": "a", "question": "Which?", "choices": [], "multi_select": false]],
        ])
        await settle()
        XCTAssertEqual(center.prompts.map(\.id), ["srq-1", "srq-2"])
        // An approval's alert may name its queue entry rather than the server request.
        center.answeredOutside("q1")
        XCTAssertEqual(center.prompts.map(\.id), ["srq-2"])
        center.answeredOutside("srq-2")
        XCTAssertTrue(center.prompts.isEmpty)
    }

    // MARK: Registration

    private func body(_ body: JSON) -> JSONValue { JSONValue(any: body) }

    func testRegistrationCarriesTheAlertTokenAndOptIns() {
        let preferences = NotificationPreferences(approval: true, clarify: false, turnDone: true)
        XCTAssertEqual(body(PushRegistration.deviceBody(voipToken: "aa", environment: "sandbox", bundleID: "b",
                                                        alertToken: "bb", alerts: preferences)),
                       ["voip_token": "aa", "environment": "sandbox", "bundle_id": "b", "alert_token": "bb",
                        "alerts": ["approval": true, "clarify": false, "turn_done": true]])
    }

    func testRegistrationLeavesOutWhatIsNotKnownYet() {
        XCTAssertEqual(body(PushRegistration.deviceBody(voipToken: "aa", environment: "sandbox", bundleID: "b",
                                                        alertToken: nil, alerts: nil)),
                       ["voip_token": "aa", "environment": "sandbox", "bundle_id": "b"])
        // Opting out reaches the plugin before iOS hands over an alert token (it keeps one from an earlier launch).
        XCTAssertEqual(body(PushRegistration.deviceBody(voipToken: "aa", environment: "sandbox", bundleID: "b",
                                                        alertToken: nil, alerts: NotificationPreferences.none)),
                       ["voip_token": "aa", "environment": "sandbox", "bundle_id": "b",
                        "alerts": ["approval": false, "clarify": false, "turn_done": false]])
    }

    func testOptInsRegisterOnlyWhileIOSLetsTheAppNotify() {
        let preferences = NotificationPreferences(approval: true, clarify: true, turnDone: false)
        XCTAssertEqual(AlertNotifications.registered(preferences, status: .authorized), preferences)
        XCTAssertEqual(AlertNotifications.registered(preferences, status: .provisional), preferences)
        XCTAssertEqual(AlertNotifications.registered(preferences, status: .denied), NotificationPreferences.none)
        XCTAssertEqual(AlertNotifications.registered(preferences, status: .notDetermined), NotificationPreferences.none)
    }

    func testChangedOptInsAreSentAgain() {
        let push = PushRegistration()
        XCTAssertNil(push.alerts)
        XCTAssertTrue(push.setAlerts(NotificationPreferences.defaults))
        XCTAssertFalse(push.setAlerts(NotificationPreferences.defaults))
        XCTAssertTrue(push.setAlerts(NotificationPreferences.none))
        XCTAssertEqual(PushRegistration.hex(Data([0x0a, 0xff, 0x00])), "0aff00")
    }

    func testPreferencesAreSavedAndAnnounced() throws {
        let suite = "NotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(NotificationPreferences.load(from: defaults), NotificationPreferences.defaults)
        XCTAssertTrue(NotificationPreferences.defaults.approval && NotificationPreferences.defaults.clarify
                      && NotificationPreferences.defaults.turnDone)

        let changed = expectation(forNotification: NotificationPreferences.didChange, object: nil)
        let preferences = NotificationPreferences(approval: false, clarify: true, turnDone: false)
        NotificationPreferences.save(preferences, to: defaults)
        wait(for: [changed], timeout: 1)
        XCTAssertEqual(NotificationPreferences.load(from: defaults), preferences)
        XCTAssertEqual(preferences.alerts, ["approval": false, "clarify": true, "turn_done": false])
        XCTAssertTrue(preferences.anyEnabled)
        XCTAssertFalse(NotificationPreferences.none.anyEnabled)
    }

    // MARK: Foreground

    func testForegroundAlertIsQuietOnlyWhileItsSessionIsOnScreen() {
        let push = approval()
        XCTAssertEqual(AlertNotifications.presentation(for: push, sessionOnScreen: true), [])
        XCTAssertEqual(AlertNotifications.presentation(for: push, sessionOnScreen: false), [.banner, .list, .sound])
        XCTAssertEqual(AlertNotifications.presentation(for: nil, sessionOnScreen: true), [.banner, .list, .sound])
    }
}
