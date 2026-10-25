import Foundation
import PushKit

/// The VoIP push registration that lets Hermes ring this phone: PushKit at launch, and the token sent to the
/// Hermes Voice plugin (`POST /api/plugins/hermes_voice/devices`) once signed in.
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
    @Published private(set) var upload: Upload = .notSent
    /// A new token arrived.
    var onToken: ((String) -> Void)?
    /// A VoIP push arrived (nil when it carries no usable call). The handler must report a call to CallKit before
    /// it returns, and call the completion once that is done.
    var onIncoming: ((CallPush?, @escaping () -> Void) -> Void)?
    private var registry: PKPushRegistry?

    /// Registers for VoIP pushes. Called at launch, so a push that launched the app is delivered.
    func start() {
        guard registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    /// Sends the token to the plugin on `client`'s dashboard.
    func send(to client: DashboardClient) async {
        guard let token else { return }
        upload = .sending
        do {
            try await VoicePluginAPI.registerDevice(client, voipToken: token, environment: Self.environment,
                                                    bundleID: Bundle.main.bundleIdentifier ?? "")
            if self.token == token { upload = .sent(Date()) }
        } catch {
            if self.token == token { upload = .failed(error.localizedDescription) }
        }
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
        let token = pushCredentials.token.map { String(format: "%02x", $0) }.joined()
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
