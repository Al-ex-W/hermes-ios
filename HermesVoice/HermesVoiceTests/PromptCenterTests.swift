import XCTest
@testable import HermesVoice

@MainActor
final class PromptCenterTests: XCTestCase {
    private var gateway: ScriptedGateway!
    private var connection: GatewayConnection!
    private var center: PromptCenter!

    override func setUp() async throws {
        gateway = ScriptedGateway()
        connection = gateway.connection()
        center = PromptCenter(connection: connection)
        try await connection.connect()
    }

    override func tearDown() async throws {
        connection.disconnect()
        center = nil
        connection = nil
        gateway = nil
    }

    private let approvalParams: JSONValue = [
        "session_id": "r1", "request_id": "q1", "command": "rm -rf build", "description": "recursive delete",
        "choices": ["once", "session", "always", "deny"], "tool_name": "terminal", "pattern_key": "rm",
    ]

    private func receive(_ id: String, _ method: String, _ params: JSONValue) async {
        gateway.current.push(request: id, method: method, params: params)
        await settle()
    }

    private func result(of id: String) -> JSONValue? {
        gateway.responses(to: id).last?["result"]
    }

    private func errorCode(of id: String) -> Int? {
        gateway.responses(to: id).last?["error"]?["code"]?.intValue
    }

    // MARK: Answers

    func testApprovalIsAnsweredWithChoice() async throws {
        await receive("srq-1", "approval", approvalParams)
        let prompt = try XCTUnwrap(center.prompts.first)
        XCTAssertEqual(prompt.sessionID, "r1")
        guard case let .approval(approval) = prompt.kind else { return XCTFail("\(prompt.kind)") }
        XCTAssertEqual(approval.choices, [.once, .session, .always, .deny])
        XCTAssertEqual(approval.requestID, "q1")
        XCTAssertEqual(center.prompts(for: ["r1"]).count, 1)
        XCTAssertTrue(center.prompts(for: ["r9"]).isEmpty)

        await center.approve("srq-1", .session)
        await settle()
        XCTAssertEqual(result(of: "srq-1"), ["choice": "session"])
        XCTAssertTrue(center.prompts.isEmpty)

        await receive("srq-2", "approval", approvalParams)
        await center.approve("srq-2", .once, all: true)
        await settle()
        XCTAssertEqual(result(of: "srq-2"), ["choice": "once", "all": true])
    }

    func testApprovalHidesChoicesHermesWontHonor() async throws {
        await receive("srq-1", "approval", approvalParams.setting("allow_permanent", false).setting("choices", ["once", "always"]))
        guard case let .approval(approval)? = center.prompts.first?.kind else { return XCTFail() }
        XCTAssertEqual(approval.choices, [.once, .deny])
    }

    func testClarifyAnswersKeepSkippedQuestionsAsNull() async throws {
        let params: JSONValue = ["session_id": "r1", "questions": [
            ["qid": "q0", "question": "Which?", "choices": ["A", "B"]],
            ["qid": "q1", "question": "Why?", "choices": .null],
        ]]
        await receive("srq-1", "clarify", params)
        await center.answerClarify("srq-1", answers: ["q0": "A", "q1": nil])
        await settle()
        XCTAssertEqual(result(of: "srq-1"), ["answers": ["q0": "A", "q1": .null]])

        await receive("srq-2", "clarify", params)
        await center.answerClarify("srq-2", answers: nil)
        await settle()
        XCTAssertEqual(result(of: "srq-2"), [:], "no answers cancels the whole set")
    }

    func testValueRequestsAreAnsweredWithValue() async throws {
        await receive("srq-1", "sudo", ["session_id": "r1", "command": "apt install x"])
        await receive("srq-2", "secret", ["session_id": "r1", "env_var": "API_KEY", "prompt": "Paste the key"])
        await receive("srq-3", "vault.code", ["session_id": "r1", "site": "example.com"])
        await receive("srq-4", "display.install.sudo", ["session_id": "", "profile_key": "default"])
        XCTAssertEqual(center.prompts.count, 4)
        XCTAssertNil(center.prompts.last?.sessionID, "an app-level prompt has no session")
        XCTAssertEqual(center.prompts(for: ["r9"]).map(\.id), ["srq-4"], "and shows in every chat")

        await center.answerValue("srq-1", "hunter2")
        await center.answerValue("srq-2", "")
        await settle()
        XCTAssertEqual(result(of: "srq-1"), ["value": "hunter2"])
        XCTAssertEqual(result(of: "srq-2"), ["value": ""])
        XCTAssertEqual(center.prompts.map(\.id), ["srq-3", "srq-4"])
    }

    // MARK: Declines

    func testWindowOwnedRequestsAreDeclinedNotShown() async throws {
        for (index, method) in ["window.read", "preview.read", "preview.act", "terminal.read", "tour"].enumerated() {
            await receive("srq-\(index)", method, ["session_id": "r1"])
            XCTAssertEqual(errorCode(of: "srq-\(index)"), 4404, method)
        }
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testWindowOwnedRequestsAreLeftToTheWindowByAnOlderBackend() async throws {
        connection.disconnect()
        gateway = ScriptedGateway()
        gateway.declinesNotShown = false
        connection = gateway.connection()
        center = PromptCenter(connection: connection)
        try await connection.connect()

        for (index, method) in ["window.read", "preview.act", "tour"].enumerated() {
            await receive("srq-\(index)", method, ["session_id": "r1"])
        }
        XCTAssertTrue(gateway.responses.isEmpty, "it settles on the first error, which would beat the desktop window")
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testUnknownRequestsGetMethodNotFound() async throws {
        await receive("srq-1", "mcp.setup.consent", ["session_id": "r1"])
        await receive("srq-2", "approval", ["session_id": "r1"])  // no request_id: outside the contract
        XCTAssertEqual(errorCode(of: "srq-1"), -32601)
        XCTAssertEqual(errorCode(of: "srq-2"), -32601)
        XCTAssertTrue(center.prompts.isEmpty)
    }

    // MARK: Withdrawals and reconnects

    func testRequestCancelRemovesTheCard() async throws {
        await receive("srq-1", "approval", approvalParams)
        await receive("srq-2", "sudo", ["session_id": "r1"])
        gateway.current.push(event: "request.cancel", session: "r1", seq: 1,
                             payload: ["id": "srq-1", "method": "approval", "reason": "timeout"])
        await settle()
        XCTAssertEqual(center.prompts.map(\.id), ["srq-2"])

        gateway.current.push(event: "session.reclaimed", payload: ["session_id": "r1", "stored_session_id": "s1", "reason": "ws_orphan_reap"])
        await settle()
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testOpenRequestsAreRedeliveredOnReattach() async throws {
        let owner = RecordingOwner()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        await receive("srq-1", "approval", approvalParams)
        await receive("srq-0", "sudo", ["session_id": "r1"])
        gateway.current.kill()

        let clarify: JSONValue = ["id": "srq-2", "method": "clarify", "params": [
            "session_id": "r1", "questions": [["qid": "q0", "question": "Go?", "choices": ["yes", "no"]]], "answers": ["q0": "yes"],
        ]]
        let open: JSONValue = ["id": "srq-1", "method": "approval", "params": approvalParams]
        gateway.handlers["session.activate"] = { _ in
            .result(liveResult("r1", running: true, extra: ["open_requests": [open, clarify], "status": "waiting"]))
        }
        gateway.handlers["session.events.since"] = { _ in .result(eventsSince([], latest: 0, open: [open, clarify])) }
        try await connection.connect()

        XCTAssertEqual(center.prompts.map(\.id), ["srq-1", "srq-2"], "srq-0 ended while away; srq-1 isn't doubled")
        guard case let .clarify(params)? = center.prompts.last?.kind else { return XCTFail() }
        XCTAssertEqual(params.answers, ["q0": "yes"], "answers locked before the reconnect come back")

        await center.approve("srq-1", .once)
        await settle()
        XCTAssertEqual(gateway.responses.last?.socket, 1, "answered on the new socket")
        XCTAssertEqual(result(of: "srq-1"), ["choice": "once"])
    }

    func testAnswerLostWithItsSocketIsSentAgain() async throws {
        let owner = RecordingOwner()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        await receive("srq-1", "approval", approvalParams)
        await center.approve("srq-1", .deny)
        gateway.current.kill()

        // Hermes lists the approval twice: as the open request and as the queue's pending entry.
        let open: JSONValue = ["id": "srq-1", "method": "approval", "params": approvalParams]
        gateway.handlers["session.activate"] = { _ in
            .result(liveResult("r1", extra: ["open_requests": [open],
                                             "pending_approval": ["request_id": "q1", "command": "rm -rf build"]]))
        }
        try await connection.connect()
        await settle()

        XCTAssertEqual(gateway.responses(to: "srq-1").count, 2)
        XCTAssertEqual(result(of: "srq-1"), ["choice": "deny"])
        XCTAssertTrue(center.prompts.isEmpty, "no card comes back for an answered request")
    }

    func testRequestThatArrivedJustBeforeAResumeEndsWhenUnlisted() async throws {
        await receive("srq-1", "approval", approvalParams)
        // The desktop answered it (no request.cancel follows an answer); the next resume doesn't list it.
        gateway.handlers["session.resume"] = { _ in .result(liveResult("r1")) }
        _ = try await connection.client.sessionResume(.init(sessionId: "s1"))
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testRestoredPendingApprovalIsAnsweredThroughApprovalRespond() async throws {
        gateway.handlers["session.resume"] = { _ in
            .result(liveResult("r1", extra: ["pending_approval": ["request_id": "q9", "command": "ls /", "allow_permanent": false]]))
        }
        gateway.handlers["approval.respond"] = { _ in .result(["resolved": 1]) }
        _ = try await connection.client.sessionResume(.init(sessionId: "s1"))

        let prompt = try XCTUnwrap(center.prompts.first)
        guard case let .approval(approval) = prompt.kind else { return XCTFail() }
        XCTAssertTrue(approval.restored)
        XCTAssertEqual(approval.choices, [.once, .session, .deny])

        await center.approve(prompt.id, .once)
        XCTAssertEqual(gateway.calls("approval.respond").map(\.params),
                       [["session_id": "r1", "choice": "once", "all": false, "request_id": "q9"]])
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testLiveRequestSupersedesTheRestoredCopy() async throws {
        let open: JSONValue = ["id": "srq-1", "method": "approval", "params": approvalParams]
        gateway.handlers["session.resume"] = { _ in
            .result(liveResult("r1", extra: ["pending_approval": ["request_id": "q1", "command": "rm -rf build"], "open_requests": [open]]))
        }
        _ = try await connection.client.sessionResume(.init(sessionId: "s1"))
        XCTAssertEqual(center.prompts.map(\.id), ["srq-1"])

        // A later snapshot without the approval clears a restored card.
        gateway.handlers["session.resume"] = { _ in
            .result(liveResult("r2", extra: ["pending_approval": ["command": "make"]]))
        }
        _ = try await connection.client.sessionResume(.init(sessionId: "s2"))
        XCTAssertEqual(center.prompts.filter(\.isRestoredApproval).count, 1)
        gateway.handlers["session.resume"] = { _ in .result(liveResult("r2")) }
        _ = try await connection.client.sessionResume(.init(sessionId: "s2"))
        XCTAssertEqual(center.prompts.map(\.id), ["srq-1"])
    }

    func testAnswerWithoutSocketGoesThroughRequestAnswer() async throws {
        await receive("srq-1", "approval", approvalParams)
        gateway.current.kill()
        XCTAssertEqual(connection.state, .disconnected)
        gateway.handlers["request.answer"] = { _ in .result(["status": "ok"]) }

        await center.approve("srq-1", .always)
        XCTAssertEqual(gateway.calls("request.answer").map(\.params), [["id": "srq-1", "result": ["choice": "always"]]])
        XCTAssertTrue(gateway.responses(to: "srq-1").isEmpty)
        XCTAssertTrue(center.prompts.isEmpty)
    }

    func testFailedAnswerKeepsTheCard() async throws {
        await receive("srq-1", "approval", approvalParams)
        gateway.current.kill()
        gateway.reachable = false

        await center.approve("srq-1", .once)
        let prompt = try XCTUnwrap(center.prompts.first)
        XCTAssertFalse(prompt.answering)
        XCTAssertNotNil(prompt.failure)
    }
}
