import Foundation
import os
import PushKit

private let pushLog = Logger(subsystem: Bundle.main.bundleIdentifier ?? "HermesVoice", category: "PushRegistration")

/// The push registration with the Hermes Voice plugin (`POST /api/plugins/hermes_voice/devices`, once signed in):
/// the VoIP token that lets Hermes ring this phone (PushKit at launch) and, beside it, the APNs alert token with
/// the background alerts the user opted into (AlertNotifications).
@MainActor
final class PushRegistration: NSObject, ObservableObject {
    /// Where the token stands with Hermes.
    enum Upload: Equatable {
        case notSent
        case sending
        case sent(Date)
        case failed(String)
    }

    /// The VoIP token as hex, once PushKit has one.
    @Published private(set) var token: String?
    /// The APNs alert token as hex (`registerForRemoteNotifications`), once iOS has one.
    @Published private(set) var alertToken: String?
    @Published private(set) var upload: Upload = .notSent
    /// The alerts the plugin may push: the user's opt-ins while iOS lets the app notify, else none. Nil until
    /// AlertNotifications has read them, and a registration then leaves the plugin's stored ones as they are.
    private(set) var alerts: NotificationPreferences?
    /// A new token arrived.
    var onToken: ((String) -> Void)?
    /// A new alert token arrived.
    var onAlertToken: ((String) -> Void)?
    /// A VoIP push arrived (nil when it carries no usable call). The handler must report a call to CallKit before
    /// it returns, and call the completion once that is done.
    var onIncoming: ((CallPush?, @escaping () -> Void) -> Void)?
    private var registry: PKPushRegistry?
    /// Registrations go out one at a time, the latest state each; a change meanwhile sends again after.
    private var nextSend: DashboardClient?
    private var sending: Task<Void, Never>?

    /// Registers for VoIP pushes. Called at launch, so a push that launched the app is delivered.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Sends the tokens and opt-ins to the plugin on `client`'s dashboard (nothing before PushKit has a VoIP token:
    /// the plugin keeps devices by it).
    func send(to client: DashboardClient) async {
        guard token != nil else { return }
        nextSend = client
        if let sending { return await sending.value }
        let task = Task { @MainActor in
            while let client = self.nextSend {
                self.nextSend = nil
                await self.register(with: client)
            }
            self.sending = nil
        }
        sending = task
        await task.value
    }

    private func register(with client: DashboardClient) async {
        guard let token else { return }
        upload = .sending
        do {
            try await VoicePluginAPI.registerDevice(client, body: Self.deviceBody(
                voipToken: token, environment: Self.environment, bundleID: Bundle.main.bundleIdentifier ?? "",
                alertToken: alertToken, alerts: alerts
            ))
            if self.token == token { upload = .sent(Date()) }
        } catch {
            if self.token == token { upload = .failed(error.localizedDescription) }
        }
    }

    /// The `POST /devices` body: the VoIP token the plugin keeps the phone by, the alert token once iOS gave one, and
    /// the alerts it may push (`{approval, clarify, turn_done}`) once known. A key left out leaves the plugin's
    /// stored value: an alert token from an earlier launch still reaches this phone.
    nonisolated static func deviceBody(voipToken: String, environment: String, bundleID: String, alertToken: String?,
                                       alerts: NotificationPreferences?) -> JSON {
        var body: JSON = ["voip_token": voipToken, "environment": environment, "bundle_id": bundleID]
        if let alertToken { body["alert_token"] = alertToken }
        if let alerts { body["alerts"] = alerts.alerts }
        return body
    }

    /// The alerts to register; true when they changed (and need sending).
    @discardableResult
    func setAlerts(_ alerts: NotificationPreferences) -> Bool {
        guard alerts != self.alerts else { return false }
        self.alerts = alerts
        return true
    }

    /// `didRegisterForRemoteNotificationsWithDeviceToken`.
    func didRegisterForAlerts(deviceToken: Data) {
        let token = Self.hex(deviceToken)
        guard token != alertToken else { return }
        alertToken = token
        onAlertToken?(token)
    }

    /// `didFailToRegisterForRemoteNotificationsWithError`: no alert token (the VoIP one still rings).
    func didFailToRegisterForAlerts(_ error: Error) {
        pushLog.error("No APNs alert token: \(error.localizedDescription, privacy: .public)")
    }

    #if DEBUG
    /// Tests: the tokens PushKit and APNs would hand over (neither does in the Simulator's test host).
    func useTokens(voip: String?, alert: String?) {
        token = voip
        alertToken = alert
        upload = .notSent
    }
    #endif

    nonisolated static func hex(_ token: Data) -> String {
        token.map { String(format: "%02x", $0) }.joined()
    }

    #if DEBUG
    /// A push for testing without APNs (the Simulator gets no VoIP pushes): `hermesvoice://ring?call_id=…&session_id=…`
    /// with the payload's other keys (profile, mode, title) as query items too, e.g. from
    /// `xcrun simctl openurl booted "hermesvoice://ring?…"` with what the fake plugin's `debug/ring` returned.
    /// Handled exactly like a VoIP push. Returns whether the URL was one.
    @discardableResult
    func deliverDebugPush(_ url: URL) -> Bool {
        guard url.scheme == "hermesvoice", url.host == "ring",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        var payload: [AnyHashable: Any] = [:]
        for item in items { payload[item.name] = item.value ?? "" }
        onIncoming?(CallPush(payload: payload), {})
        return true
    }
    #endif

    /// The APNs environment this build's pushes come through: "sandbox" for development-signed builds (the
    /// provisioning profile's aps-environment), "production" for TestFlight and App Store builds, which carry none.
    static let environment: String = {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
              let plist = try? PropertyListSerialization.propertyList(from: data[start.lowerBound..<end.upperBound], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let aps = entitlements["aps-environment"] as? String else { return "production" }
        return aps == "development" ? "sandbox" : "production"
        #endif
    }()
}

extension PushRegistration: PKPushRegistryDelegate {
    nonisolated func pushRegistry(_ registry: PKPushRegistry, didUpdate pushCredentials: PKPushCredentials, for type: PKPushType) {
        guard type == .voIP else { return }
        let token = Self.hex(pushCredentials.token)
        MainActor.assumeIsolated {
            guard token != self.token else { return }
            self.token = token
            upload = .notSent
            onToken?(token)
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        guard type == .voIP else { return }
        MainActor.assumeIsolated {
            token = nil
            upload = .notSent
        }
    }

    nonisolated func pushRegistry(_ registry: PKPushRegistry, didReceiveIncomingPushWith payload: PKPushPayload,
                                  for type: PKPushType, completion: @escaping () -> Void) {
        MainActor.assumeIsolated {
            guard type == .voIP else { return completion() }
            let push = CallPush(payload: payload.dictionaryPayload)
            if let onIncoming {
                onIncoming(push, completion)
            } else {
                completion()
            }
        }
    }
}
