import CoreLocation
import Foundation
import os

private let locationLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "Location")

// MARK: - What is sent

/// A position fix as it goes to Hermes: where, how accurate, when, and speed and heading when the phone knows them.
/// Nothing else leaves the phone.
struct LocationFix: Equatable, Sendable {
    var latitude: Double
    var longitude: Double
    /// Horizontal accuracy: the radius, in metres, the phone is within.
    var accuracy: Double
    var fixedAt: Date
    /// Metres a second, when moving.
    var speed: Double?
    /// Degrees from true north (0 ..< 360), when moving.
    var course: Double?

    init(latitude: Double, longitude: Double, accuracy: Double, fixedAt: Date, speed: Double? = nil, course: Double? = nil) {
        self.latitude = latitude
        self.longitude = longitude
        self.accuracy = accuracy
        self.fixedAt = fixedAt
        self.speed = speed
        self.course = course
    }

    /// Nil for a location Core Location marks as invalid (a negative accuracy).
    init?(_ location: CLLocation) {
        guard location.horizontalAccuracy >= 0, CLLocationCoordinate2DIsValid(location.coordinate) else { return nil }
        self.init(latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
                  accuracy: location.horizontalAccuracy, fixedAt: location.timestamp,
                  speed: location.speed >= 0 ? location.speed : nil,
                  course: location.course >= 0 && location.course < 360 ? location.course : nil)
    }

    /// `{latitude, longitude, accuracy_m, fixed_at, speed_mps?, course_deg?}`.
    var json: JSON {
        var object: JSON = ["latitude": latitude, "longitude": longitude, "accuracy_m": accuracy,
                            "fixed_at": ISO8601.string(fixedAt)]
        if let speed { object["speed_mps"] = speed }
        if let course { object["course_deg"] = course }
        return object
    }
}

/// Why the phone has no fix to give, as the plugin reads it (`error`).
enum LocationFailure: String, Error, Equatable, Sendable {
    /// Sharing is off in the app.
    case off
    /// iOS doesn't let the app use location now: denied, or "While Using the App" with the app in the background.
    case denied
    /// No position could be found.
    case unavailable
    case timeout
}

/// The phone's answer to "where are you?": a fix, or why not.
enum LocationAnswer: Equatable, Sendable {
    case fix(LocationFix)
    case failure(LocationFailure)

    /// The answer's fields: the fix's, or `{error}`.
    var json: JSON {
        switch self {
        case let .fix(fix): return fix.json
        case let .failure(failure): return ["error": failure.rawValue]
        }
    }
}

/// The background push the plugin asks with: `{aps: {content-available: 1}, hermes: {kind: "location_request",
/// request_id, profile}}`.
struct LocationRequestPush: Equatable, Sendable {
    let requestID: String

    init(requestID: String) {
        self.requestID = requestID
    }

    /// Nil when the push isn't a location request.
    init?(userInfo: [AnyHashable: Any]) {
        guard let hermes = userInfo["hermes"] as? [AnyHashable: Any], hermes["kind"] as? String == "location_request",
              let id = hermes["request_id"] as? String, !id.isEmpty else { return nil }
        self.init(requestID: id)
    }
}

// MARK: - iOS permission

/// What iOS lets the app do with location.
enum LocationAccess: String, Equatable, Sendable {
    case notDetermined, restricted, denied
    /// "While Using the App": only while the app is on screen.
    case whenInUse
    /// "Always": also while the app is in the background.
    case always

    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .restricted: self = .restricted
        case .denied: self = .denied
        case .authorizedWhenInUse: self = .whenInUse
        case .authorizedAlways: self = .always
        @unknown default: self = .denied
        }
    }

    /// iOS lets the app get a fix at all.
    var allowed: Bool { self == .whenInUse || self == .always }
}

/// Where fixes come from: Core Location, or a stub in tests.
@MainActor
protocol LocationSource: AnyObject {
    var access: LocationAccess { get }
    /// False when the user gave the app only an approximate location (Precise Location off).
    var precise: Bool { get }
    /// The permission or the precision changed.
    var onChange: (() -> Void)? { get set }
    /// Asks for "While Using the App" (iOS shows its question once).
    func requestWhenInUse()
    /// Asks for "Always" (iOS shows its question once, and only after While Using was granted).
    func requestAlways()
    /// One fresh fix, within `timeout` seconds.
    func currentFix(timeout: TimeInterval) async -> LocationAnswer
}

/// Core Location, one fix at a time (`requestLocation`): nothing runs between requests, so the app uses no
/// location, and no battery for it, unless Hermes asks.
@MainActor
final class CoreLocationSource: NSObject, LocationSource {
    var onChange: (() -> Void)?
    private let manager = CLLocationManager()
    /// Everyone waiting for the fix in flight.
    private var waiting: [UUID: CheckedContinuation<LocationAnswer, Never>] = [:]

    override init() {
        super.init()
        manager.delegate = self
        // Enough to tell which street the phone is on, and quick to get; a tighter fix takes the GPS longer.
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
    }

    var access: LocationAccess { LocationAccess(manager.authorizationStatus) }
    var precise: Bool { manager.accuracyAuthorization == .fullAccuracy }

    func requestWhenInUse() { manager.requestWhenInUseAuthorization() }
    func requestAlways() { manager.requestAlwaysAuthorization() }

    func currentFix(timeout: TimeInterval) async -> LocationAnswer {
        guard access.allowed else { return .failure(.denied) }
        let id = UUID()
        return await withCheckedContinuation { continuation in
            let first = waiting.isEmpty
            waiting[id] = continuation
            if first { manager.requestLocation() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard let self, let late = self.waiting.removeValue(forKey: id) else { return }
                if self.waiting.isEmpty { self.manager.stopUpdatingLocation() }
                late.resume(returning: .failure(.timeout))
            }
        }
    }

    private func finish(_ answer: LocationAnswer) {
        let all = waiting
        waiting = [:]
        for continuation in all.values { continuation.resume(returning: answer) }
    }
}

extension CoreLocationSource: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let fix = locations.last.flatMap(LocationFix.init)
        Task { @MainActor in self.finish(fix.map(LocationAnswer.fix) ?? .failure(.unavailable)) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        let denied = (error as? CLError)?.code == .denied
        Task { @MainActor in self.finish(.failure(denied ? .denied : .unavailable)) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in self.onChange?() }
    }
}

// MARK: - Sharing

/// "Share location with Hermes" (Settings > Location), off by default. While it is on, the user's own Hermes host may
/// ask this iPhone where it is (the plugin's `get_location` tool): over the call's socket during a call, else with a
/// background push that wakes the app, which then posts one fix to the plugin (`POST …/location`). The app never
/// sends a position on its own, and keeps none: only the time of the last one sent, for the settings page.
/// Whether the phone shares goes to the plugin with the device registration (`location: {enabled, background}`), so
/// turning it off tells the host at once.
@MainActor
final class LocationSharing: ObservableObject {
    /// The user's switch.
    @Published private(set) var enabled: Bool
    @Published private(set) var access: LocationAccess
    @Published private(set) var precise: Bool
    /// When a fix last went to Hermes.
    @Published private(set) var lastSent: Date?
    /// Why the last request got no fix, in words for the settings page; nil after one that did.
    @Published private(set) var lastProblem: String?

    /// What the registration says changed (the switch, or what iOS allows): it has to go to the plugin again.
    var onRegistrationChange: (() -> Void)?
    /// The dashboard client a background answer is posted with, signing in first when the push woke the app.
    var client: (() async throws -> DashboardClient)?
    /// The tokens the plugin knows this iPhone by (as the device registration sent them).
    var tokens: () -> (voip: String?, alert: String?) = { (nil, nil) }
    /// `POST /api/plugins/hermes_voice/location`.
    var post: (DashboardClient, JSON) async throws -> Void = { try await VoicePluginAPI.postLocation($0, body: $1) }
    /// How long a fix may take: the plugin's tool waits 20 s in all, push and sign-in included.
    var fixTimeout: TimeInterval = 10

    private let source: LocationSource
    private let defaults: UserDefaults
    private static let enabledKey = "location.sharing"
    private static let lastSentKey = "location.lastSent"

    init(source: LocationSource? = nil, defaults: UserDefaults = .standard) {
        let source = source ?? CoreLocationSource()
        self.source = source
        self.defaults = defaults
        enabled = defaults.bool(forKey: Self.enabledKey)
        access = source.access
        precise = source.precise
        lastSent = defaults.object(forKey: Self.lastSentKey) as? Date
        source.onChange = { [weak self] in self?.accessChanged() }
    }

    /// The phone answers requests: the switch is on and iOS allows location.
    var sharing: Bool { enabled && access.allowed }

    /// It also answers while the app isn't on screen.
    var sharingInBackground: Bool { sharing && access == .always }

    /// The device registration's `location`.
    var registration: [String: Bool] { ["enabled": sharing, "background": sharingInBackground] }

    /// The switch. On: iOS asks for "While Using the App" if it never did. Off: nothing is answered from now on,
    /// a fix in flight is dropped, and the host hears that sharing is off.
    func setEnabled(_ on: Bool) {
        guard on != enabled else { return }
        enabled = on
        defaults.set(on, forKey: Self.enabledKey)
        lastProblem = nil
        if on, access == .notDetermined { source.requestWhenInUse() }
        onRegistrationChange?()
    }

    /// Asks iOS for the next step up: "While Using the App" when it never asked (or the user allowed it once), then
    /// "Always", so requests are answered while the app is in the background.
    func requestBackgroundAccess() {
        guard enabled else { return }
        if access == .notDetermined { source.requestWhenInUse() } else { source.requestAlways() }
    }

    private func accessChanged() {
        let before = registration
        access = source.access
        precise = source.precise
        if registration != before { onRegistrationChange?() }
    }

    /// The answer to a request, whichever way it came: a fresh fix while sharing, else why not. The caller sends it.
    func answer() async -> LocationAnswer {
        guard enabled else { return .failure(.off) }
        guard access.allowed else { return .failure(.denied) }
        let answer = await source.currentFix(timeout: fixTimeout)
        // Turned off while the fix was on its way: it stays here.
        guard enabled else { return .failure(.off) }
        return answer
    }

    /// The answer for the call's socket (`location {id, …}`), noted as sent.
    func answerOnCall() async -> LocationAnswer {
        let answer = await answer()
        note(answer)
        return answer
    }

    /// A background push asked where the phone is: gets a fix and posts it to the plugin. True when the plugin took
    /// the answer.
    @discardableResult
    func handle(_ push: LocationRequestPush) async -> Bool {
        let answer = await answer()
        // The host asked although sharing is off here: what it has registered is stale, so it is told again.
        defer { if answer == .failure(.off) { onRegistrationChange?() } }
        let (voip, alert) = tokens()
        var body = answer.json
        body["request_id"] = push.requestID
        if let voip, !voip.isEmpty { body["voip_token"] = voip }
        if let alert, !alert.isEmpty { body["alert_token"] = alert }
        guard body["voip_token"] != nil || body["alert_token"] != nil else {
            lastProblem = "This iPhone isn't registered with Hermes yet, so it couldn't answer a location request."
            return false
        }
        do {
            guard let client else { throw DashboardError.signedOut }
            try await post(try await client(), body)
            note(answer)
            return true
        } catch {
            // The error's own words only: never the fix.
            locationLog.error("A location answer didn't reach Hermes: \(error.localizedDescription, privacy: .public)")
            if enabled { lastProblem = "Couldn't send the location to Hermes: \(error.localizedDescription)" }
            return false
        }
    }

    #if DEBUG
    /// A location request for testing without APNs: `hermesvoice://location-request?request_id=…` (the id the fake
    /// plugin's `debug/location-request` returned), e.g. with `xcrun simctl openurl booted "hermesvoice://…"`.
    /// Handled exactly like the background push; the Simulator hands a `content-available` payload from
    /// `xcrun simctl push` to background fetch instead of the app's remote-notification handler. Returns whether
    /// the URL was one.
    @discardableResult
    func deliverDebugRequest(_ url: URL) -> Bool {
        guard let request = Self.debugRequest(url) else { return false }
        Task { await handle(request) }
        return true
    }

    nonisolated static func debugRequest(_ url: URL) -> LocationRequestPush? {
        guard url.scheme == "hermesvoice", url.host == "location-request",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let id = items.first(where: { $0.name == "request_id" })?.value, !id.isEmpty else { return nil }
        return LocationRequestPush(requestID: id)
    }
    #endif

    /// What became of a request, for the settings page: when a fix went out, or why none did.
    private func note(_ answer: LocationAnswer) {
        switch answer {
        case .fix:
            let now = Date()
            lastSent = now
            defaults.set(now, forKey: Self.lastSentKey)
            lastProblem = nil
        case let .failure(failure):
            lastProblem = Self.problem(failure)
        }
    }

    /// What a request that got no fix says on the settings page.
    static func problem(_ failure: LocationFailure) -> String? {
        switch failure {
        case .off: return nil
        case .denied:
            return "Hermes asked, but iOS didn't let the app use location just then (the app was in the background "
                + "without “Always”, or location access is off)."
        case .unavailable: return "Hermes asked, but this iPhone couldn't find its position just then."
        case .timeout: return "Hermes asked, but this iPhone couldn't find its position in time."
        }
    }
}
