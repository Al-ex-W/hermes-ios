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

        var errorDescription: String? {
            switch self {
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

    /// `POST /devices`: where the plugin sends the VoIP pushes that ring this phone.
    static func registerDevice(_ client: DashboardClient, voipToken: String, environment: String, bundleID: String) async throws {
        _ = try await call(client, "POST", "/devices", body: [
            "voip_token": voipToken, "environment": environment, "bundle_id": bundleID,
        ])
    }

    /// `POST /scribe-token`: a single-use ElevenLabs Scribe token, minted by the plugin with its API key.
    static func scribeToken(_ client: DashboardClient) async throws -> String {
        let result = try await call(client, "POST", "/scribe-token", body: [:])
        guard let token = (result as? JSON)?["token"] as? String, !token.isEmpty else {
            throw Failure.unexpected("no Scribe token")
        }
        return token
    }

    private static func call(_ client: DashboardClient, _ method: String, _ route: String, body: JSON? = nil) async throws -> Any {
        do {
            return try await client.request(method, path + route, body: body)
        } catch DashboardError.http(404, _) {
            throw Failure.notInstalled
        } catch DashboardError.signedOut {
            throw Failure.signedOut
        } catch let DashboardError.http(code, text) {
            let detail = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON)?["detail"] as? String
            throw Failure.unexpected("HTTP \(code)\(detail.map { ": \($0)" } ?? "")")
        } catch let error as URLError {
            throw Failure.unreachable(error.localizedDescription)
        }
    }
}
