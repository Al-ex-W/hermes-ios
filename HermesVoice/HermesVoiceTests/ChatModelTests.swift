import XCTest
@testable import HermesVoice

/// The chat model against a scripted gateway: what a new chat sends and how live corrections and photos show.
/// Its REST side points nowhere, so these stay with what a new chat does before Hermes stored anything.
@MainActor
final class ChatModelTests: XCTestCase {
    private var gateway: ScriptedGateway!
    private var connection: GatewayConnection!
    private var client: DashboardClient!

    override func setUp() async throws {
        gateway = ScriptedGateway()
        connection = gateway.connection()
        let settings = ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "test", password: "test")
        client = try DashboardClient(settings: settings)
        gateway.handlers["session.create"] = { _ in
            .result(["session_id": "r1", "stored_session_id": "s1", "message_count": 0, "messages": [], "info": ["running": false]])
        }
        gateway.handlers["prompt.submit"] = { _ in .result(["status": "streaming"]) }
        try await connection.connect()
    }

    override func tearDown() async throws {
        // The composer reads the new session's model state on its own; let that finish on this gateway.
        await settle(0.2)
        connection.disconnect()
    }

    private func newChat() -> ChatModel {
        ChatModel(client: client, connection: connection, summary: nil)
    }

    private var kinds: (ChatModel) -> [String] {
        { chat in chat.transcript.items.map { $0.isUser ? "user" : { if case .assistant = $0 { return "assistant" }; return "other" }($0) } }
    }

    func testSessionCreateCarriesTheEffortAndFastPickedBeforeIt() async {
        let chat = newChat()
        await chat.composer.setEffort("high")
        await chat.composer.setFast(true)
        XCTAssertTrue(gateway.calls("config.set").isEmpty)

        let sent = await chat.send("hi")
        XCTAssertTrue(sent)
        let params = gateway.calls("session.create").first?.params
        XCTAssertEqual(params?["reasoning_effort"], "high")
        XCTAssertEqual(params?["fast"], true)
        XCTAssertNil(chat.composer.pendingEffort)
        XCTAssertNil(chat.composer.pendingFast)
    }

    func testACorrectionHermesHoldsForTheNextTurnMovesBelowTheRunningOne() async {
        let chat = newChat()
        let sent = await chat.send("write a poem")
        XCTAssertTrue(sent)
        let socket = gateway.current
        socket.push(event: "message.start", session: "r1")
        socket.push(event: "message.delta", session: "r1", payload: ["text": "Roses are"])
        await waitUntil { chat.transcript.items.count == 2 }

        gateway.handlers["session.redirect"] = { _ in .result(["status": "queued"]) }
        let outcome = await chat.redirect("make it about cats")
        XCTAssertEqual(outcome, .queued)
        XCTAssertEqual(kinds(chat), ["user", "assistant"], "the running reply isn't split around it")
        XCTAssertEqual(chat.transcript.nextPrompts.map(\.text), ["make it about cats"])

        socket.push(event: "message.delta", session: "r1", payload: ["text": " red"])
        socket.push(event: "message.complete", session: "r1", payload: ["text": "Roses are red", "status": "complete"])
        await waitUntil { !chat.busy && chat.transcript.nextPrompts.isEmpty }
        XCTAssertEqual(kinds(chat), ["user", "assistant", "user"])
        XCTAssertEqual(chat.texts, ["write a poem", "Roses are red", "make it about cats"])
    }

    func testSentPhotosShowAsChipsOnTheBubble() async {
        let chat = newChat()
        gateway.handlers["image.attach_bytes"] = { _ in .result(["attached": true, "path": "/w/.hermes/images/shot.png", "count": 1]) }
        chat.composer.add(ComposerAttachment(pending: .image(Data([0xff, 0xd8]), filename: "shot.jpg")))
        chat.composer.draft = "what is this"
        await chat.composer.send()
        guard case let .user(message)? = chat.transcript.items.first else { return XCTFail("no bubble") }
        XCTAssertEqual(message.text, "what is this")
        XCTAssertEqual(message.attachments.map(\.kind), [.image])
        XCTAssertEqual(message.attachments.first?.label, "shot.png")
        XCTAssertEqual(gateway.calls("prompt.submit").first?.params["text"], "what is this", "the prompt carries no image line")
    }

    func testARemovedPhotoIsDetachedFromTheSession() async throws {
        let chat = newChat()
        let sent = await chat.send("hi")
        XCTAssertTrue(sent)
        gateway.handlers["image.attach_bytes"] = { _ in .result(["attached": true, "path": "/w/.hermes/images/shot.png", "count": 1]) }
        gateway.handlers["image.detach"] = { _ in .result(["detached": true, "count": 0]) }
        let staged = try? await chat.stage(.image(Data([1]), filename: "shot.jpg"))
        await chat.unstage(try XCTUnwrap(staged))
        XCTAssertEqual(gateway.calls("image.detach").first?.params, ["session_id": "r1", "path": "/w/.hermes/images/shot.png"])
    }

    // MARK: Session actions

    func testDeletingALiveSessionStopsAndClosesItFirst() async {
        let actions = SessionActions(client: client, connection: connection)
        gateway.handlers["session.interrupt"] = { _ in .error(4001, "session not found") }
        gateway.handlers["session.close"] = { _ in .result(["closed": true]) }
        _ = try? await actions.delete(SessionMenuTarget(storedID: "s1", runtimeID: "r1", title: "x"))
        XCTAssertEqual(gateway.calls.map(\.method).filter { $0.hasPrefix("session.") }, ["session.interrupt", "session.close"],
                       "a turn's lease would refuse the delete, and the store alone leaves the runtime running")
        XCTAssertEqual(gateway.calls("session.close").first?.params["session_id"], "r1")
    }

    func testBranchingASessionHermesLostFallsBackToTheStoredOne() async throws {
        let actions = SessionActions(client: client, connection: connection)
        gateway.handlers["session.branch_whole"] = { _ in .error(4001, "session not found") }
        gateway.handlers["session.branch_stored"] = { _ in
            .result(["session_id": "r9", "stored_session_id": "s9", "message_count": 2, "messages": [], "info": ["running": false]])
        }
        let event = try await actions.branch(SessionMenuTarget(storedID: "s1", runtimeID: "r1", title: "Chat"))
        guard case let .branched(storedID, runtimeID, _) = event else { return XCTFail("\(event)") }
        XCTAssertEqual([storedID, runtimeID], ["s9", "r9"])
        XCTAssertEqual(gateway.calls("session.branch_stored").first?.params["parent_session_id"], "s1")
    }
}
