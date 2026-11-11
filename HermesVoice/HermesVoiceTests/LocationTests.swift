import CoreLocation
import XCTest
@testable import HermesVoice

/// A scripted location source: the test sets what iOS allows and what a fix request answers.
@MainActor
final class StubLocationSource: LocationSource {
    var access: LocationAccess
    var precise = true
    var onChange: (() -> Void)?
    var next: LocationAnswer
    private(set) var whenInUseRequests = 0
    private(set) var alwaysRequests = 0
    private(set) var fixRequests = 0
    /// While set, a fix request waits until `release()`.
    var holding = false
    private var held: [CheckedContinuation<Void, Never>] = []

    init(access: LocationAccess = .whenInUse, next: LocationAnswer = .fix(LocationTests.fix)) {
        self.access = access
        self.next = next
    }

    func requestWhenInUse() { whenInUseRequests += 1 }
    func requestAlways() { alwaysRequests += 1 }

    func currentFix(timeout: TimeInterval) async -> LocationAnswer {
        fixRequests += 1
        if holding { await withCheckedContinuation { held.append($0) } }
        return next
    }

    func release() {
        holding = false
        held.forEach { $0.resume() }
        held = []
    }

    /// iOS changed what the app may do (the user answered its question, or changed it in iOS Settings).
    func set(_ access: LocationAccess, precise: Bool = true) {
        self.access = access
        self.precise = precise
        onChange?()
    }
}

/// "Share location with Hermes": what is sent and how it is encoded, the switch and the iOS permission, the answer on
/// a call and to a background push, and what the settings page says in each state.
@MainActor
final class LocationTests: XCTestCase {
    /// Obviously fake coordinates.
    nonisolated static let fix = LocationFix(latitude: 59.0, longitude: 18.0, accuracy: 12.5,
                                             fixedAt: Date(timeIntervalSince1970: 1_790_000_000.25), speed: 1.4, course: 270)
    private var suite = ""
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suite = "LocationTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
        defaults = nil
    }

    private func sharing(_ source: StubLocationSource, enabled: Bool = true) -> LocationSharing {
        let sharing = LocationSharing(source: source, defaults: defaults)
        if enabled { sharing.setEnabled(true) }
        return sharing
    }

    private func object(_ text: String) throws -> NSDictionary {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? NSDictionary)
    }

    // MARK: What is sent

    func testAFixCarriesWhereHowAccurateAndWhenAndNothingElse() {
        XCTAssertEqual(Self.fix.json as NSDictionary, [
            "latitude": 59.0, "longitude": 18.0, "accuracy_m": 12.5, "fixed_at": "2026-09-21T14:13:20.250Z",
            "speed_mps": 1.4, "course_deg": 270.0,
        ])
        let still = LocationFix(latitude: 59.0, longitude: 18.0, accuracy: 65, fixedAt: Self.fix.fixedAt)
        XCTAssertEqual(Set(still.json.keys), ["latitude", "longitude", "accuracy_m", "fixed_at"])
    }

    func testACoreLocationFixIsTakenOnlyWhenItIsValid() throws {
        let coordinate = CLLocationCoordinate2D(latitude: 59.0, longitude: 18.0)
        let moving = CLLocation(coordinate: coordinate, altitude: 12, horizontalAccuracy: 8, verticalAccuracy: 4, course: 90,
                                speed: 3, timestamp: Self.fix.fixedAt)
        XCTAssertEqual(LocationFix(moving), LocationFix(latitude: 59.0, longitude: 18.0, accuracy: 8, fixedAt: Self.fix.fixedAt,
                                                        speed: 3, course: 90))
        // Standing still, Core Location reports speed and course as -1: they are left out.
        let still = CLLocation(coordinate: coordinate, altitude: 12, horizontalAccuracy: 8, verticalAccuracy: 4, course: -1,
                               speed: -1, timestamp: Self.fix.fixedAt)
        let fix = try XCTUnwrap(LocationFix(still))
        XCTAssertNil(fix.speed)
        XCTAssertNil(fix.course)
        let invalid = CLLocation(coordinate: coordinate, altitude: 0, horizontalAccuracy: -1, verticalAccuracy: -1,
                                 timestamp: Self.fix.fixedAt)
        XCTAssertNil(LocationFix(invalid))
    }

    func testTheAnswerOnACallIsALocationFrame() throws {
        XCTAssertEqual(try object(PhoneMessage.location(id: "r1", .fix(Self.fix)).encoded()), [
            "type": "location", "id": "r1", "latitude": 59.0, "longitude": 18.0, "accuracy_m": 12.5,
            "fixed_at": "2026-09-21T14:13:20.250Z", "speed_mps": 1.4, "course_deg": 270.0,
        ])
        for failure in [LocationFailure.off, .denied, .unavailable, .timeout] {
            XCTAssertEqual(try object(PhoneMessage.location(id: "r2", .failure(failure)).encoded()),
                           ["type": "location", "id": "r2", "error": failure.rawValue])
        }
    }

    func testTheRequestParsesFromTheSocketAndFromAPush() {
        XCTAssertEqual(PluginMessage.parse(#"{"type": "location_request", "id": "0123456789abcdef"}"#),
                       .locationRequest("0123456789abcdef"))
        XCTAssertNil(PluginMessage.parse(#"{"type": "location_request"}"#))
        let push: [AnyHashable: Any] = ["aps": ["content-available": 1],
                                        "hermes": ["kind": "location_request", "request_id": "abc", "profile": "default"]]
        XCTAssertEqual(LocationRequestPush(userInfo: push), LocationRequestPush(requestID: "abc"))
        XCTAssertNil(LocationRequestPush(userInfo: ["aps": ["content-available": 1], "hermes": ["kind": "location_request"]]))
        XCTAssertNil(LocationRequestPush(userInfo: ["aps": ["alert": ["title": "Hermes"]],
                                                    "hermes": ["kind": "approval", "request_id": "srq-1"]]))
        XCTAssertNil(LocationRequestPush(userInfo: [:]))
    }

    func testADebugURLStandsInForThePushInTheSimulator() throws {
        let url = try XCTUnwrap(URL(string: "hermesvoice://location-request?request_id=0123456789abcdef"))
        XCTAssertEqual(LocationSharing.debugRequest(url), LocationRequestPush(requestID: "0123456789abcdef"))
        for other in ["hermesvoice://location-request", "hermesvoice://ring?call_id=x", "https://example.com/?request_id=1"] {
            XCTAssertNil(LocationSharing.debugRequest(try XCTUnwrap(URL(string: other))), other)
        }
    }

    func testTheStatusSaysWhetherAPhoneShares() {
        let status = VoicePluginStatus(["tts": "fake", "location": ["enabled": true, "sharing": true, "phones": 1]])
        XCTAssertEqual(status.location?.sharing, true)
        XCTAssertEqual(status.location?.enabled, true)
        XCTAssertNil(VoicePluginStatus(["tts": "fake"]).location, "an older plugin has no get_location")
    }

    // MARK: The switch and the permission

    func testSharingIsOffUntilTheUserTurnsItOn() {
        let source = StubLocationSource(access: .notDetermined)
        let sharing = sharing(source, enabled: false)
        var changes = 0
        sharing.onRegistrationChange = { changes += 1 }
        XCTAssertFalse(sharing.enabled)
        XCTAssertFalse(sharing.sharing)
        XCTAssertEqual(sharing.registration, ["enabled": false, "background": false])
        XCTAssertEqual(source.whenInUseRequests, 0, "iOS isn't asked before the user turns sharing on")

        sharing.setEnabled(true)
        XCTAssertEqual(source.whenInUseRequests, 1)
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(sharing.registration, ["enabled": false, "background": false], "nothing is shared before iOS allows it")
        source.set(.whenInUse)
        XCTAssertTrue(sharing.sharing)
        XCTAssertEqual(sharing.registration, ["enabled": true, "background": false])
        XCTAssertEqual(changes, 2)
        sharing.setEnabled(true)
        XCTAssertEqual(changes, 2, "nothing changed")

        // The switch is remembered; iOS isn't asked again.
        let relaunched = LocationSharing(source: source, defaults: defaults)
        XCTAssertTrue(relaunched.enabled)
        XCTAssertEqual(source.whenInUseRequests, 1)
    }

    func testTheRegistrationFollowsWhatIOSAllows() {
        let source = StubLocationSource(access: .whenInUse)
        let sharing = sharing(source)
        var registrations: [[String: Bool]] = []
        sharing.onRegistrationChange = { registrations.append(sharing.registration) }
        source.set(.always)
        source.set(.always, precise: false)  // precision alone changes nothing the host is told
        source.set(.denied)
        source.set(.restricted)
        source.set(.whenInUse)
        sharing.setEnabled(false)
        source.set(.always)
        XCTAssertEqual(registrations, [
            ["enabled": true, "background": true], ["enabled": false, "background": false],
            ["enabled": true, "background": false], ["enabled": false, "background": false],
        ])
    }

    func testAlwaysIsAskedForOnlyOnceWhileUsingIsGranted() {
        let source = StubLocationSource(access: .notDetermined)
        let sharing = sharing(source, enabled: false)
        sharing.requestBackgroundAccess()
        XCTAssertEqual([source.whenInUseRequests, source.alwaysRequests], [0, 0], "off: iOS is asked nothing")
        sharing.setEnabled(true)
        sharing.requestBackgroundAccess()
        XCTAssertEqual([source.whenInUseRequests, source.alwaysRequests], [2, 0], "iOS grants Always only after While Using")
        source.set(.whenInUse)
        sharing.requestBackgroundAccess()
        XCTAssertEqual(source.alwaysRequests, 1)
    }

    func testThePushRegistrationCarriesTheLocationFlag() {
        let body = PushRegistration.deviceBody(voipToken: "aa", environment: "sandbox", bundleID: "b", alertToken: nil,
                                               alerts: nil, location: ["enabled": true, "background": false])
        XCTAssertEqual(body as NSDictionary, ["voip_token": "aa", "environment": "sandbox", "bundle_id": "b",
                                              "location": ["enabled": true, "background": false]])
        let push = PushRegistration()
        XCTAssertNil(push.location)
        XCTAssertTrue(push.setLocation(["enabled": true, "background": false]))
        XCTAssertFalse(push.setLocation(["enabled": true, "background": false]))
        XCTAssertTrue(push.setLocation(["enabled": false, "background": false]))
    }

    // MARK: Answering

    func testARequestIsAnsweredWithAFreshFixOnlyWhileSharing() async {
        let source = StubLocationSource(access: .whenInUse)
        let sharing = sharing(source, enabled: false)
        var answer = await sharing.answerOnCall()
        XCTAssertEqual(answer, .failure(.off))
        XCTAssertEqual(source.fixRequests, 0, "off: Core Location isn't touched")
        XCTAssertNil(sharing.lastSent)

        sharing.setEnabled(true)
        source.set(.denied)
        answer = await sharing.answerOnCall()
        XCTAssertEqual(answer, .failure(.denied))
        XCTAssertEqual(source.fixRequests, 0)
        XCTAssertNotNil(sharing.lastProblem)

        source.set(.whenInUse)
        answer = await sharing.answerOnCall()
        XCTAssertEqual(answer, .fix(Self.fix))
        XCTAssertEqual(source.fixRequests, 1)
        XCTAssertNotNil(sharing.lastSent)
        XCTAssertNil(sharing.lastProblem)
        XCTAssertNotNil(LocationSharing(source: source, defaults: defaults).lastSent, "the time is kept, never the position")

        source.next = .failure(.timeout)
        answer = await sharing.answerOnCall()
        XCTAssertEqual(answer, .failure(.timeout))
        XCTAssertEqual(sharing.lastProblem, LocationSharing.problem(.timeout))
    }

    func testTurningSharingOffDropsAFixOnItsWay() async {
        let source = StubLocationSource(access: .always)
        let sharing = sharing(source)
        source.holding = true
        let asking = Task { await sharing.answerOnCall() }
        await waitUntil { source.fixRequests == 1 }
        sharing.setEnabled(false)
        source.release()
        let answer = await asking.value
        XCTAssertEqual(answer, .failure(.off))
        XCTAssertNil(sharing.lastSent)
    }

    private func client() throws -> DashboardClient {
        try DashboardClient(settings: ConnectionSettings(dashboardURL: "http://127.0.0.1:9", username: "u", password: "p"))
    }

    func testABackgroundPushPostsTheFixWithTheRegisteredTokens() async throws {
        let source = StubLocationSource(access: .always)
        let sharing = sharing(source)
        let client = try client()
        var posted: [JSON] = []
        var signIns = 0
        sharing.client = {
            signIns += 1
            return client
        }
        sharing.tokens = { ("aa", "bb") }
        sharing.post = { used, body in
            XCTAssertTrue(used === client)
            posted.append(body)
        }
        let sent = await sharing.handle(LocationRequestPush(requestID: "req-1"))
        XCTAssertTrue(sent)
        XCTAssertEqual(signIns, 1)
        XCTAssertEqual(posted.count, 1)
        XCTAssertEqual(posted[0] as NSDictionary, [
            "request_id": "req-1", "voip_token": "aa", "alert_token": "bb", "latitude": 59.0, "longitude": 18.0,
            "accuracy_m": 12.5, "fixed_at": "2026-09-21T14:13:20.250Z", "speed_mps": 1.4, "course_deg": 270.0,
        ])
        XCTAssertNotNil(sharing.lastSent)

        // No fix: the plugin hears why, so the tool doesn't wait out its timeout.
        source.next = .failure(.unavailable)
        sharing.tokens = { (nil, "bb") }
        _ = await sharing.handle(LocationRequestPush(requestID: "req-2"))
        XCTAssertEqual(posted[1] as NSDictionary, ["request_id": "req-2", "alert_token": "bb", "error": "unavailable"])
        XCTAssertEqual(sharing.lastProblem, LocationSharing.problem(.unavailable))
    }

    func testAPushWhileSharingIsOffSendsNoPositionAndRegistersAgain() async throws {
        let source = StubLocationSource(access: .always)
        let sharing = sharing(source, enabled: false)
        let client = try client()
        var posted: [JSON] = []
        var registrations = 0
        sharing.client = { client }
        sharing.tokens = { ("aa", nil) }
        sharing.post = { _, body in posted.append(body) }
        sharing.onRegistrationChange = { registrations += 1 }
        _ = await sharing.handle(LocationRequestPush(requestID: "req-1"))
        XCTAssertEqual(posted.map { $0 as NSDictionary }, [["request_id": "req-1", "voip_token": "aa", "error": "off"]])
        XCTAssertEqual(source.fixRequests, 0)
        XCTAssertEqual(registrations, 1, "the host asked a phone that doesn't share: it is told so again")
        XCTAssertNil(sharing.lastSent)
        XCTAssertNil(sharing.lastProblem)
    }

    func testAPushThatCannotBeAnsweredSaysWhyWithoutThePosition() async throws {
        let source = StubLocationSource(access: .always)
        let sharing = sharing(source)
        var posts = 0
        sharing.post = { _, _ in posts += 1 }
        // Not registered: the plugin wouldn't know whose fix it is.
        sharing.client = { try self.client() }
        var sent = await sharing.handle(LocationRequestPush(requestID: "req-1"))
        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)
        XCTAssertEqual(sharing.lastProblem?.contains("isn't registered"), true)

        // Signed out, and the saved sign-in doesn't work.
        sharing.tokens = { ("aa", nil) }
        sharing.client = { throw DashboardError.signedOut }
        sent = await sharing.handle(LocationRequestPush(requestID: "req-2"))
        XCTAssertFalse(sent)
        XCTAssertEqual(posts, 0)

        // The plugin refuses (the request is too old, say).
        sharing.client = { try self.client() }
        sharing.post = { _, _ in throw VoicePluginAPI.Failure.refused("Nobody asked for this location") }
        sent = await sharing.handle(LocationRequestPush(requestID: "req-3"))
        XCTAssertFalse(sent)
        let problem = try XCTUnwrap(sharing.lastProblem)
        XCTAssertTrue(problem.contains("Nobody asked"), problem)
        XCTAssertFalse(problem.contains("59") || problem.contains("18"), problem)
        XCTAssertNil(sharing.lastSent)
    }

    // MARK: The settings page

    func testTheSettingSaysWhatEachStateMeans() {
        typealias State = LocationSharingState
        let off = State(enabled: false, access: .always, precise: true)
        XCTAssertEqual([off.status, off.detail], ["Off", "Hermes can't ask this iPhone where it is, and nothing is sent."])
        XCTAssertEqual([off.sharing, off.isProblem], [false, false])
        XCTAssertEqual(off.action, .none)

        let asking = State(enabled: true, access: .notDetermined, precise: true)
        XCTAssertEqual(asking.status, "Waiting for permission")
        XCTAssertEqual(asking.action, .allow)
        XCTAssertEqual([asking.sharing, asking.isProblem], [false, false])

        let denied = State(enabled: true, access: .denied, precise: true)
        XCTAssertEqual(denied.status, "Blocked in iOS Settings")
        XCTAssertEqual([denied.sharing, denied.isProblem], [false, true])
        XCTAssertEqual(denied.action, .openSettings)
        XCTAssertTrue(denied.detail.contains("nothing is shared"))

        let restricted = State(enabled: true, access: .restricted, precise: true)
        XCTAssertEqual([restricted.sharing, restricted.isProblem], [false, true])
        XCTAssertEqual(restricted.action, .none)

        let whileUsing = State(enabled: true, access: .whenInUse, precise: true)
        XCTAssertEqual(whileUsing.status, "Sharing while the app is open")
        XCTAssertEqual([whileUsing.sharing, whileUsing.isProblem], [true, false])
        XCTAssertEqual(whileUsing.action, .allowAlways)
        XCTAssertTrue(whileUsing.detail.contains("“Always”") && whileUsing.detail.contains("in the background"))
        XCTAssertFalse(whileUsing.detail.contains("approximate"))

        let always = State(enabled: true, access: .always, precise: true)
        XCTAssertEqual(always.status, "Sharing, also in the background")
        XCTAssertEqual(always.action, .none)
        XCTAssertTrue(always.detail.contains("delay or drop") && always.detail.contains("force-quit"))

        // Reduced accuracy is said wherever something is shared, and nowhere else.
        for access in [LocationAccess.whenInUse, .always] {
            XCTAssertTrue(State(enabled: true, access: access, precise: false).detail.contains("approximate position"))
        }
        XCTAssertFalse(State(enabled: true, access: .denied, precise: false).detail.contains("approximate"))
        XCTAssertFalse(State(enabled: false, access: .always, precise: false).detail.contains("approximate"))
    }

    func testTheSettingSaysWhatIsSharedWithWhomAndWhen() {
        let text = LocationSharingState.disclosure(host: "hermes.example.ts.net")
        for part in ["latitude, longitude", "how accurate", "speed and heading", "only to your own Hermes host (hermes.example.ts.net)",
                     "only when Hermes asks", "never sends it on its own", "in memory"] {
            XCTAssertTrue(text.contains(part), part)
        }
        XCTAssertTrue(LocationSharingState.disclosure(host: nil).contains("only to your own Hermes host,"))
    }

    func testLastSentIsATimeOrSaysNothingWasSent() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let locale = Locale(identifier: "en_US")
        let now = Date(timeIntervalSince1970: 1_790_000_000)  // 2026-09-21 14:13 UTC
        XCTAssertEqual(LocationSharingState.lastSent(nil), "Nothing sent yet")
        let today = LocationSharingState.lastSent(now.addingTimeInterval(-600), now: now, locale: locale, calendar: calendar)
        XCTAssertTrue(today.contains("2:03"), today)
        XCTAssertFalse(today.contains("Sep"), today)
        let earlier = LocationSharingState.lastSent(now.addingTimeInterval(-3 * 86400), now: now, locale: locale, calendar: calendar)
        XCTAssertTrue(earlier.contains("Sep 18") && earlier.contains("2:13"), earlier)
    }

    func testLocationHasItsOwnSettingsPage() {
        XCTAssertEqual(SettingsPageID.location.title, "Location")
        XCTAssertTrue(SettingsPageID.groups.contains { $0.contains(.location) })
        let found = SettingsSearch.filter(SettingsManifest.entries, query: "share location")
        XCTAssertEqual(found.first?.target.page, .location)
        XCTAssertEqual(found.first?.label, "Share location with Hermes")
    }

    func testTheAppDeclaresWhatItNeedsForLocation() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        for key in ["NSLocationWhenInUseUsageDescription", "NSLocationAlwaysAndWhenInUseUsageDescription"] {
            let text = try XCTUnwrap(info[key] as? String, key)
            XCTAssertTrue(text.contains("only to your") && text.contains("only when it asks"), text)
        }
        let modes = try XCTUnwrap(info["UIBackgroundModes"] as? [String])
        XCTAssertEqual(Set(modes), ["audio", "voip", "remote-notification"], "no continuous location in the background")
    }
}
