import XCTest
@testable import HermesVoice

@MainActor
final class GatewayConnectionTests: XCTestCase {
    private var gateway: ScriptedGateway!

    override func setUp() async throws {
        gateway = ScriptedGateway()
    }

    override func tearDown() async throws {
        gateway = nil
    }

    // MARK: Handshake and calls

    func testHandshakeWaitsForReadyAndAdvertisesCapabilities() async throws {
        let connection = gateway.connection()
        try await connection.connect()

        XCTAssertEqual(connection.state, .connected)
        XCTAssertEqual(connection.replayEpoch, "epoch-1")
        XCTAssertTrue(connection.declinesNotShown)
        XCTAssertEqual(gateway.calls("client.capabilities").map(\.params), [["server_requests": true]])
    }

    func testOlderBackendWithoutDeclinesOrReady() async throws {
        gateway.declinesNotShown = false
        gateway.sendsReady = false
        let connection = gateway.connection { $0.readyTimeout = 0.1 }
        try await connection.connect()

        XCTAssertEqual(connection.state, .connected)
        XCTAssertNil(connection.replayEpoch)
        XCTAssertFalse(connection.declinesNotShown)
    }

    func testCallFailuresAreClassified() async throws {
        gateway.reachable = false
        let connection = gateway.connection()
        do {
            _ = try await connection.call("session.list")
            XCTFail("expected a failure")
        } catch {
            XCTAssertTrue(error.wasNotSent, "a dial failure never sent the call: \(error)")
        }

        gateway.reachable = true
        gateway.handlers["session.status"] = { _ in .error(4001, "session not found") }
        do {
            _ = try await connection.call("session.status", params: ["session_id": "r1"])
            XCTFail("expected a refusal")
        } catch let error as GatewayRPCError {
            XCTAssertEqual(error, GatewayRPCError(code: 4001, message: "session not found"))
            XCTAssertTrue(error.isRefusal)
        }

        gateway.handlers["session.usage"] = { _ in .silent }
        do {
            _ = try await connection.call("session.usage", params: [:], timeout: 0.1)
            XCTFail("expected a timeout")
        } catch {
            guard case DashboardError.timeout = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(connection.state, .disconnected, "a lost answer drops the socket")
        XCTAssertTrue(gateway.sockets[0].closedByClient)

        gateway.handlers["session.title"] = { _ in .silent }
        gateway.beforeReply["session.title"] = { $0.kill() }
        do {
            _ = try await connection.call("session.title", params: ["session_id": "r1"])
            XCTFail("expected a disconnect")
        } catch {
            guard case DashboardError.disconnected = error else { return XCTFail("\(error)") }
            XCTAssertFalse(error.wasNotSent)
        }
    }

    func testTypedClientDecodesAndKeepsRawOnMismatch() async throws {
        gateway.handlers["session.interrupt"] = { _ in .result(["status": "interrupted"]) }
        gateway.handlers["session.title"] = { _ in .result(["unexpected": true]) }
        let connection = gateway.connection()

        let interrupted = try await connection.client.sessionInterrupt(.init(sessionId: "r1"))
        XCTAssertEqual(interrupted.status, .interrupted)
        XCTAssertEqual(gateway.calls("session.interrupt").first?.params, ["session_id": "r1"])

        do {
            _ = try await connection.client.sessionTitle(.init(sessionId: "r1"))
            XCTFail("expected a decoding error")
        } catch let error as GatewayDecodingError {
            XCTAssertEqual(error.method, "session.title")
            XCTAssertEqual(error.raw, ["unexpected": true])
        }
    }

    func testAttachResultOutsideTheContractIsReadRaw() async throws {
        // No `messages`, `message_count` or `info`: the typed decode fails, the raw read still attaches.
        gateway.handlers["session.resume"] = { _ in
            .result(["session_id": "r1", "running": true, "inflight": ["user": "hi", "corrections": ["also this"]],
                     "queued": ["user": "next"]])
        }
        let connection = gateway.connection()
        let session = try await LiveSession.attach({ try await connection.client.sessionResume(.init(sessionId: "s1")) }, LiveSession.init)

        XCTAssertEqual(session, LiveSession(runtimeID: "r1", running: true, inflightPrompt: "hi",
                                            corrections: ["also this"], queuedPrompt: "next"))
    }

    // MARK: Reconnect re-attach and replay

    /// Connects, attaches `r1` (stored `s1`) for an owner and delivers live events up to `seq`.
    private func attached(_ connection: GatewayConnection, owner: RecordingOwner, through seq: Int) async throws {
        try await connection.connect()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        for n in stride(from: 1, through: seq, by: 1) {
            gateway.current.push(event: "message.delta", session: "r1", seq: n, payload: ["text": .string("\(n)")])
        }
        await waitUntil { connection.watermarks["r1"] == seq }
    }

    func testReconnectActivatesAndReplaysMissedEventsOnce() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        let log = EventLog(connection)
        try await attached(connection, owner: owner, through: 3)
        gateway.current.kill()
        XCTAssertEqual(connection.state, .disconnected)

        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1", running: true)) }
        gateway.handlers["session.events.since"] = { _ in
            .result(eventsSince([replayed("message.delta", session: "r1", seq: 4, payload: ["text": "4"]),
                                 replayed("message.delta", session: "r1", seq: 5, payload: ["text": "5"])], latest: 6))
        }
        // Live frames racing the replay: a duplicate of a replayed seq, and a newer one.
        gateway.beforeReply["session.events.since"] = { socket in
            socket.push(event: "message.delta", session: "r1", seq: 5, payload: ["text": "5"])
            socket.push(event: "message.delta", session: "r1", seq: 6, payload: ["text": "6"])
        }
        try await connection.connect()

        XCTAssertEqual(gateway.calls("session.activate").map(\.params),
                       [["session_id": "r1", "cols": 96, "omit_messages": true]])
        XCTAssertEqual(gateway.calls("session.events.since").map(\.params), [["session_id": "r1", "last_seen": 3]])
        XCTAssertTrue(gateway.calls("session.resume").isEmpty)
        XCTAssertEqual(log.seqs("r1"), [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(owner.reattached.map(\.runtimeID), ["r1"])
        XCTAssertEqual(owner.reattached.first?.running, true)
        XCTAssertEqual(owner.refetches, 0)
        XCTAssertEqual(connection.watermarks["r1"], 6)

        gateway.current.push(event: "message.delta", session: "r1", seq: 6, payload: ["text": "6"])
        gateway.current.push(event: "message.complete", session: "r1", seq: 7, payload: ["text": "done"])
        await waitUntil { log.seqs("r1").last == 7 }
        XCTAssertEqual(log.seqs("r1"), [1, 2, 3, 4, 5, 6, 7], "a live duplicate is dropped too")
    }

    func testReapedWhileBackgroundedResumesUnderANewRuntimeID() async throws {
        for code in [4007, 4001] {
            gateway = ScriptedGateway()
            let connection = gateway.connection()
            let owner = RecordingOwner()
            let log = EventLog(connection)
            try await attached(connection, owner: owner, through: 7)
            gateway.current.kill()

            gateway.handlers["session.activate"] = { params in
                params["session_id"] == "r1" ? .error(code, "session no longer live; retry resume") : .result(liveResult("r2"))
            }
            gateway.handlers["session.resume"] = { _ in .result(liveResult("r2")) }
            try await connection.connect()

            XCTAssertEqual(gateway.calls("session.resume").map(\.params),
                           [["session_id": "s1", "cols": 96, "source": "desktop", "omit_messages": true]], "code \(code)")
            XCTAssertTrue(gateway.calls("session.events.since").isEmpty, "a new runtime has nothing to replay")
            XCTAssertEqual(owner.reattached.map(\.runtimeID), ["r2"])
            XCTAssertEqual(owner.refetches, 1, "the events of the reaped runtime are lost")
            XCTAssertNil(connection.watermarks["r1"])
            XCTAssertNil(connection.watermarks["r2"], "the new runtime numbers its events from 1")

            gateway.current.push(event: "message.start", session: "r2", seq: 1)
            await waitUntil { log.seqs("r2") == [1] }

            // The tracking follows the new runtime id.
            gateway.current.kill()
            try await connection.connect()
            XCTAssertEqual(gateway.calls("session.activate").last?.params["session_id"], "r2")
            XCTAssertEqual(gateway.calls("session.events.since").last?.params, ["session_id": "r2", "last_seen": 1])
        }
    }

    func testRefusedReattachEndsTracking() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        try await attached(connection, owner: owner, through: 1)
        gateway.current.kill()

        gateway.handlers["session.activate"] = { _ in .error(4007, "session no longer live") }
        gateway.handlers["session.resume"] = { _ in .error(4007, "session not found") }
        try await connection.connect()

        XCTAssertEqual(owner.failures.count, 1)
        XCTAssertEqual(connection.state, .connected, "one session's refusal doesn't fail the connection")
        gateway.current.kill()
        try await connection.connect()
        XCTAssertEqual(gateway.calls("session.activate").count, 1, "an untracked session isn't re-attached")
    }

    func testEpochChangeSignalsRefetch() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        let log = EventLog(connection)
        try await attached(connection, owner: owner, through: 3)
        gateway.current.kill()

        gateway.epoch = "epoch-2"
        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }
        gateway.beforeReply["session.activate"] = { socket in
            socket.push(event: "message.start", session: "r1", seq: 1)
        }
        try await connection.connect()

        XCTAssertEqual(connection.replayEpoch, "epoch-2")
        XCTAssertTrue(gateway.calls("session.events.since").isEmpty, "the old cursor means nothing in a new epoch")
        XCTAssertEqual(owner.refetches, 1)
        XCTAssertEqual(log.seqs("r1"), [1, 2, 3, 1], "the live frame of the new numbering is kept")
        XCTAssertEqual(connection.watermarks["r1"], 1)
    }

    func testEpochChangeSeenOnlyInReplaySignalsRefetch() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        try await attached(connection, owner: owner, through: 3)
        gateway.current.kill()

        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }
        gateway.handlers["session.events.since"] = { _ in .result(eventsSince([], latest: 0, epoch: "epoch-9")) }
        try await connection.connect()

        XCTAssertEqual(owner.refetches, 1)
        XCTAssertEqual(connection.replayEpoch, "epoch-9")
        XCTAssertNil(connection.watermarks["r1"])
    }

    func testTruncatedReplaySignalsRefetch() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        let log = EventLog(connection)
        try await attached(connection, owner: owner, through: 2)
        gateway.current.kill()

        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }
        gateway.handlers["session.events.since"] = { _ in
            .result(eventsSince([replayed("message.complete", session: "r1", seq: 600, payload: ["text": "done"])],
                                latest: 600, truncated: true))
        }
        try await connection.connect()

        XCTAssertEqual(owner.refetches, 1)
        XCTAssertEqual(log.seqs("r1"), [1, 2, 600])
    }

    func testFailedReplaySignalsRefetch() async throws {
        let connection = gateway.connection { $0.replayTimeout = 0.1 }
        let owner = RecordingOwner()
        try await attached(connection, owner: owner, through: 2)
        gateway.current.kill()

        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }
        gateway.handlers["session.events.since"] = { _ in .silent }
        try await connection.connect()

        XCTAssertEqual(owner.refetches, 1)
        XCTAssertEqual(connection.state, .connected, "a slow replay doesn't drop the socket")
    }

    func testSessionWithoutWatermarkRefetchesOnlyWhenItEmitted() async throws {
        let connection = gateway.connection()
        let quiet = RecordingOwner(), busy = RecordingOwner()
        try await connection.connect()
        connection.track(quiet, runtimeID: "r1", storedID: "s1", profile: nil)
        connection.track(busy, runtimeID: "r2", storedID: "s2", profile: "work")
        gateway.current.kill()

        gateway.handlers["session.activate"] = { params in .result(liveResult(params["session_id"]?.stringValue ?? "")) }
        gateway.handlers["session.events.since"] = { params in
            .result(eventsSince([], latest: params["session_id"] == "r2" ? 4 : 0))
        }
        try await connection.connect()

        XCTAssertEqual(Set(gateway.calls("session.events.since").map(\.params)), [
            ["session_id": "r1", "last_seen": 0], ["session_id": "r2", "profile": "work", "last_seen": 0],
        ])
        XCTAssertEqual(quiet.refetches, 0)
        XCTAssertEqual(busy.refetches, 1, "what it emitted can't be told apart from what is stored")
    }

    func testFramesWaitForTheHandshake() async throws {
        let connection = gateway.connection()
        let owner = RecordingOwner()
        let log = EventLog(connection)
        try await attached(connection, owner: owner, through: 1)
        gateway.current.kill()

        var seenDuringActivate: [Int] = []
        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }
        gateway.handlers["session.events.since"] = { _ in
            .result(eventsSince([replayed("message.delta", session: "r1", seq: 2)], latest: 3))
        }
        gateway.beforeReply["session.activate"] = { socket in
            socket.push(event: "message.delta", session: "r1", seq: 3)
            socket.push(event: "sessions.changed")
        }
        gateway.beforeReply["session.events.since"] = { _ in seenDuringActivate = log.seqs("r1") }
        try await connection.connect()

        XCTAssertEqual(seenDuringActivate, [1], "live frames are parked until the replay is in")
        XCTAssertEqual(log.seqs("r1"), [1, 2, 3])
        XCTAssertEqual(log.events.last?.type, "sessions.changed")
    }

    // MARK: Heartbeat

    func testHeartbeatTimeoutRecyclesTheSocket() async throws {
        gateway.answersPings = false
        let connection = gateway.connection {
            $0.heartbeatInterval = 0.05
            $0.heartbeatDeadline = 0.2
            $0.reconnectDelays = [0.05]
        }
        let owner = RecordingOwner()
        try await connection.connect()
        connection.track(owner, runtimeID: "r1", storedID: "s1", profile: nil)
        gateway.handlers["session.activate"] = { _ in .result(liveResult("r1")) }

        await waitUntil { self.gateway.sockets.count == 2 && connection.state == .connected }
        XCTAssertTrue(gateway.sockets[0].closedByClient)
        XCTAssertFalse(gateway.calls("gateway.ping").filter { $0.socket == 0 }.isEmpty)
        XCTAssertEqual(owner.reattached.map(\.runtimeID), ["r1"], "the reconnect re-attaches the session")
        connection.disconnect()
    }

    func testAnyInboundFrameKeepsTheSocketAlive() async throws {
        gateway.answersPings = false
        let connection = gateway.connection {
            $0.heartbeatInterval = 0.05
            $0.heartbeatDeadline = 0.25
        }
        try await connection.connect()
        for _ in 0..<12 {
            gateway.current.push(event: "sessions.changed")
            await settle(0.05)
        }
        XCTAssertTrue(gateway.sockets[0].isOpen)
        XCTAssertEqual(connection.state, .connected)

        await waitUntil { connection.state == .disconnected }
        XCTAssertTrue(gateway.sockets[0].closedByClient)
    }

    func testProbeDropsADeadSocket() async throws {
        let connection = gateway.connection { $0.probeTimeout = 0.1 }
        try await connection.connect()
        gateway.answersPings = false
        connection.probe()
        await waitUntil { connection.state == .disconnected }
    }

    func testSignOutClosesForGood() async throws {
        let connection = gateway.connection()
        try await connection.connect()
        gateway.handlers["session.usage"] = { _ in .silent }
        let call = Task { try await connection.call("session.usage", params: [:]) }
        await waitUntil { !self.gateway.calls("session.usage").isEmpty }
        connection.disconnect()

        do {
            _ = try await call.value
            XCTFail("expected a disconnect")
        } catch {
            guard case DashboardError.disconnected = error else { return XCTFail("\(error)") }
        }
        do {
            try await connection.connect()
            XCTFail("a closed connection doesn't reconnect")
        } catch {}
    }
}
