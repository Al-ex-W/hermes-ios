import Foundation

/// The Hermes Voice plugin's HTTP routes on the dashboard (`/api/plugins/hermes_voice/…`), with the dashboard's
/// own cookie sign-in.
enum VoicePluginAPI {
    static let path = "/api/plugins/hermes_voice"

    /// What a check of the plugin found wrong.
    enum Failure: LocalizedError {
        /// The dashboard has no such route: the plugin isn't installed or enabled for this profile.
        case notInstalled
        case signedOut
        case unreachable(String)
        case unexpected(String)
        /// The plugin refused the request, in its own words (`detail`).
        case refused(String)

        var errorDescription: String? {
            switch self {
            case let .refused(detail):
                return detail
            case .notInstalled:
                return "Hermes has no voice calls: install and enable the hermes_voice plugin on the Hermes host, then restart its dashboard."
            case .signedOut:
                return "Signed out of the Hermes dashboard. Sign in again to make calls."
            case let .unreachable(detail):
                return "Can't reach Hermes (\(detail)). Check that Tailscale is connected."
            case let .unexpected(detail):
                return "The Hermes Voice plugin answered unexpectedly: \(detail)"
            }
        }
    }

    /// `GET /status`: checks the plugin is there before a call starts (and feeds the Calls settings).
    static func status(_ client: DashboardClient) async throws -> VoicePluginStatus {
        let result = try await call(client, "GET", "/status")
        guard let object = result as? JSON else { throw Failure.unexpected("no status") }
        return VoicePluginStatus(object)
    }

    /// `POST /devices`: where the plugin sends the VoIP pushes that ring this phone, and the alert token with the
    /// alerts it takes (`PushRegistration.deviceBody`).
    static func registerDevice(_ client: DashboardClient, body: JSON) async throws {
        _ = try await call(client, "POST", "/devices", body: body)
    }

    /// `POST /location`: this iPhone's answer to a location request that came by background push: a fix, or why it
    /// has none (`LocationSharing.handle`). The plugin's refusals (not registered, not sharing, nobody asked) come as
    /// `refused`, in its words.
    static func postLocation(_ client: DashboardClient, body: JSON) async throws {
        _ = try await call(client, "POST", "/location", body: body, refusals: true)
    }

    /// `POST /scribe-token`: a single-use ElevenLabs Scribe token, minted by the plugin with its API key.
    static func scribeToken(_ client: DashboardClient) async throws -> String {
        let result = try await call(client, "POST", "/scribe-token", body: [:])
        guard let token = (result as? JSON)?["token"] as? String, !token.isEmpty else {
            throw Failure.unexpected("no Scribe token")
        }
        return token
    }

    /// `POST /devices/test`: asks the plugin for a test alert push to this iPhone (`testAlertBody`). Throws
    /// `notInstalled` when the host's plugin has no such route (an older plugin, or none).
    static func testAlert(_ client: DashboardClient, body: JSON) async throws -> TestAlertResult {
        try testResult(await call(client, "POST", "/devices/test", body: body, refusals: true))
    }

    /// `GET /devices/test/{id}`: what became of a test alert (a delayed one's outcome).
    static func testAlertStatus(_ client: DashboardClient, id: String) async throws -> TestAlertResult {
        try testResult(await call(client, "GET", "/devices/test/\(id)", refusals: true))
    }

    /// `POST /devices/test/{id}/answer`: tells the plugin what the user did with the test alert (an approval choice,
    /// `reply` or `open`; never the reply's text).
    @discardableResult
    static func answerTestAlert(_ client: DashboardClient, id: String, action: String) async throws -> TestAlertResult {
        try testResult(await call(client, "POST", "/devices/test/\(id)/answer", body: ["action": action], refusals: true))
    }

    /// The `POST /devices/test` body: the tokens the plugin knows this iPhone by (as `POST /devices` sent them), the
    /// kind of alert and how long the plugin waits before it pushes. Nil without any token.
    static func testAlertBody(kind: AlertPush.Kind, voipToken: String?, alertToken: String?, delay: TimeInterval) -> JSON? {
        var body: JSON = ["kind": kind.rawValue, "delay_s": delay]
        if let voipToken, !voipToken.isEmpty { body["voip_token"] = voipToken }
        if let alertToken, !alertToken.isEmpty { body["alert_token"] = alertToken }
        return body.count > 2 ? body : nil
    }

    private static func testResult(_ answer: Any) throws -> TestAlertResult {
        guard let result = TestAlertResult(answer as? JSON) else { throw Failure.unexpected("no test result") }
        return result
    }

    /// `refusals`: a 4xx with a `detail` other than 404 is the plugin saying no in its own words (`refused`).
    private static func call(_ client: DashboardClient, _ method: String, _ route: String, body: JSON? = nil,
                             refusals: Bool = false) async throws -> Any {
        do {
            return try await client.request(method, path + route, body: body)
        } catch let DashboardError.http(404, text) {
            // The plugin's own 404 (a test it no longer keeps) names what is missing; the dashboard's says "Not Found".
            if refusals, let detail = Self.detail(text), detail != "Not Found" { throw Failure.refused(detail) }
            throw Failure.notInstalled
        } catch DashboardError.signedOut {
            throw Failure.signedOut
        } catch let DashboardError.http(code, text) {
            let detail = Self.detail(text)
            if refusals, (400..<500).contains(code), let detail { throw Failure.refused(detail) }
            throw Failure.unexpected("HTTP \(code)\(detail.map { ": \($0)" } ?? "")")
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
    }

    private static func detail(_ text: String) -> String? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)?["detail"] as? String
    }
}

/// What the plugin says about a test alert (`POST /devices/test` and `GET /devices/test/{id}`):
/// `{ok, test_id, kind, status, code, message, delay_s, action}`.
struct TestAlertResult: Equatable {
    enum Status: String {
        /// The plugin pushes it after `delay`.
        case scheduled
        /// APNs accepted it.
        case sent
        /// Nothing went out, or APNs refused it: `code` says which, `message` says it in words.
        case failed
        /// The phone told the plugin what the user did with it.
        case answered
    }

    let id: String
    let kind: AlertPush.Kind
    let status: Status
    /// `sent`, `scheduled`, `answered`, or why it failed (`not_registered`, `no_alert_token`, `apns_not_configured`,
    /// `off_on_host`, `off_on_phone`, `bad_token`, `wrong_environment`, `wrong_topic`, `bad_key`, `apns_unreachable`,
    /// `refused`).
    let code: String
    /// The plugin's sentence for the user.
    let message: String
    let delay: TimeInterval
    /// What the phone reported, once answered.
    let action: String?

    init(id: String, kind: AlertPush.Kind, status: Status, code: String, message: String, delay: TimeInterval = 0,
         action: String? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.code = code
        self.message = message
        self.delay = delay
        self.action = action
    }

    /// Nil unless it names a test, a kind and a status this app knows.
    init?(_ object: JSON?) {
        guard let object, let id = object["test_id"] as? String, !id.isEmpty,
              let kind = (object["kind"] as? String).flatMap(AlertPush.Kind.init(rawValue:)),
              let status = (object["status"] as? String).flatMap(Status.init(rawValue:)) else { return nil }
        self.init(id: id, kind: kind, status: status, code: object["code"] as? String ?? status.rawValue,
                  message: object["message"] as? String ?? "", delay: (object["delay_s"] as? NSNumber)?.doubleValue ?? 0,
                  action: object["action"] as? String)
    }
}
