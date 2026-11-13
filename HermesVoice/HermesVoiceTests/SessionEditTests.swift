import XCTest
@testable import HermesVoice

/// The identity an edit of a stored session carries (`DashboardClient.mutateSession`), without a server. The round
/// trip against the fake is in FakeHermesTests.
final class SessionEditTests: XCTestCase {
    func testASnapshotNeedsItsCountersToBeUsable() throws {
        let row: JSON = ["session_id": "s1", "exists": true, "runtime_revision": 4, "runtime_generation": 2]
        let snapshot = try XCTUnwrap(SessionMutationSnapshot(row: row))
        XCTAssertEqual([snapshot.revision, snapshot.generation ?? -1], [4, 2])
        XCTAssertTrue(snapshot.exists)

        // An absent session has revision zero and no generation.
        let absent = try XCTUnwrap(SessionMutationSnapshot(row: ["exists": false, "runtime_revision": 0,
                                                                 "runtime_generation": NSNull()]))
        XCTAssertFalse(absent.exists)
        XCTAssertNil(absent.generation)

        XCTAssertNil(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": 4]), "no generation")
        XCTAssertNil(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": -1, "runtime_generation": 0]))
        XCTAssertNil(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": 1.5, "runtime_generation": 0]))
        XCTAssertNil(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": true, "runtime_generation": 0]))
        XCTAssertNil(SessionMutationSnapshot(row: ["exists": "yes", "runtime_revision": 1, "runtime_generation": 0]))
        XCTAssertNil(SessionMutationSnapshot(row: [:]))
    }

    func testAnIdentityGoesIntoAPatchBodyAndADeleteQuery() throws {
        let snapshot = try XCTUnwrap(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": 7,
                                                                   "runtime_generation": 3]))
        let identity = SessionMutationIdentity(snapshot: snapshot, requestID: "r1")
        XCTAssertEqual(identity.fields["request_id"] as? String, "r1")
        XCTAssertEqual(identity.fields["expected_revision"] as? Int, 7)
        XCTAssertEqual(identity.fields["expected_generation"] as? Int, 3)
        XCTAssertEqual(identity.query, ["request_id": "r1", "expected_revision": "7", "expected_generation": "3"])

        // Two edits never share a request id, and it is a lowercase UUID like the desktop's.
        let one = SessionMutationIdentity(snapshot: snapshot), two = SessionMutationIdentity(snapshot: snapshot)
        XCTAssertNotEqual(one.requestID, two.requestID)
        XCTAssertNotNil(UUID(uuidString: one.requestID))
        XCTAssertEqual(one.requestID, one.requestID.lowercased())
    }

    func testAnEditWhoseAnswerNeverCameKeepsItsIdentityUntilItOrAnotherEditOfThatSessionGoesThrough() throws {
        let ledger = SessionMutationLedger()
        let snapshot = try XCTUnwrap(SessionMutationSnapshot(row: ["exists": true, "runtime_revision": 1,
                                                                   "runtime_generation": 0]))
        let pin = SessionMutationLedger.key(profile: nil, id: "s1", method: "PATCH", payload: ["pinned": true])
        let rename = SessionMutationLedger.key(profile: nil, id: "s1", method: "PATCH", payload: ["title": "x"])
        let other = SessionMutationLedger.key(profile: nil, id: "s2", method: "PATCH", payload: ["pinned": true])
        let elsewhere = SessionMutationLedger.key(profile: "work", id: "s1", method: "PATCH", payload: ["pinned": true])
        XCTAssertEqual(Set([pin, rename, other, elsewhere]).count, 4)
        XCTAssertEqual(pin, SessionMutationLedger.key(profile: nil, id: "s1", method: "PATCH", payload: ["pinned": true]))

        for key in [pin, rename, other, elsewhere] { ledger.keep(SessionMutationIdentity(snapshot: snapshot), for: key) }
        XCTAssertNotNil(ledger.pending(pin))

        ledger.drop(rename)
        XCTAssertNil(ledger.pending(rename))
        XCTAssertNotNil(ledger.pending(pin), "a refusal spends only its own edit")

        ledger.keep(SessionMutationIdentity(snapshot: snapshot), for: rename)
        ledger.settle(rename)
        XCTAssertNil(ledger.pending(rename))
        XCTAssertNil(ledger.pending(pin), "the session moved on: its other kept edits are behind")
        XCTAssertNotNil(ledger.pending(other))
        XCTAssertNotNil(ledger.pending(elsewhere), "the same id in another profile's store is another session")
    }

    func testOnlyTheDashboardsOwnVerdictMeansTheRouteIsMissing() {
        XCTAssertTrue(SessionMutationLedger.isMissingRoute(DashboardError.http(404, #"{"detail":"No such API endpoint: /api/x"}"#)))
        XCTAssertTrue(SessionMutationLedger.isMissingRoute(
            DashboardError.http(404, "Hermes headless backend (hermes serve): web UI disabled")))
        XCTAssertFalse(SessionMutationLedger.isMissingRoute(DashboardError.http(404, #"{"detail":"Not Found"}"#)))
        XCTAssertFalse(SessionMutationLedger.isMissingRoute(DashboardError.http(404, #"{"detail":"not_found"}"#)))
        XCTAssertFalse(SessionMutationLedger.isMissingRoute(DashboardError.http(500, "No such API endpoint")))
        XCTAssertFalse(SessionMutationLedger.isMissingRoute(DashboardError.timeout))
    }

    func testRefusalsAreToldInWordsAndAConflictIsKnown() {
        XCTAssertTrue(SessionMutationLedger.isConflict(DashboardError.http(409, #"{"detail":"revision_conflict"}"#)))
        XCTAssertTrue(SessionMutationLedger.isConflict(DashboardError.http(409, #"{"detail":"stale_generation"}"#)))
        XCTAssertFalse(SessionMutationLedger.isConflict(DashboardError.http(409, #"{"detail":"session_busy"}"#)))
        XCTAssertFalse(SessionMutationLedger.isConflict(DashboardError.http(400, "revision_conflict")))

        func words(_ code: Int, _ body: String) -> String {
            SessionMutationLedger.explained(DashboardError.http(code, body)).localizedDescription
        }
        XCTAssertTrue(words(409, #"{"detail":"client_upgrade_required: this app is out of sync"}"#).contains("newer HermesVoice"))
        XCTAssertTrue(words(409, #"{"detail":"session_busy"}"#).contains("busy"))
        XCTAssertTrue(words(409, #"{"detail":"runtime_coordination_required"}"#).contains("another Hermes window"))
        XCTAssertTrue(words(403, #"{"detail":"permission_denied"}"#).contains("isn't allowed"))
        // Anything else comes through as it was: a validation message is already in words.
        XCTAssertTrue(words(400, #"{"detail":"Title is too long"}"#).contains("Title is too long"))
        XCTAssertTrue(SessionMutationLedger.explained(DashboardError.timeout).isConnectionLoss)
    }
}
