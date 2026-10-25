import Foundation

/// The phone's side of `/api/plugins/hermes_voice/phone`: JSON text frames both ways, plus binary PCM speech.

/// How a call began, as the hello tells the plugin.
enum CallInitiator: String, Codable {
    /// The user pressed the call button in a chat.
    case user
    /// Hermes rang the phone (`start_call`) and the VoIP push brought the app up.
    case push
}

/// The first frame on every connection, reconnects included.
struct PhoneHello: Equatable {
    let callID: String
    var sessionID: String?
    var title: String?
    let initiatedBy: CallInitiator
    var appVersion: String = PhoneHello.currentAppVersion

    static var currentAppVersion: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(version) (\($0))" } ?? version
    }
}

/// phone → plugin.
enum PhoneMessage: Equatable {
    case hello(PhoneHello)
    /// The push arrived and CallKit is ringing.
    case ringing
    case answered
    /// The user declined before answering.
    case declined
    /// An utterance was heard to the end.
    case played(String)
    case userTurn(UserTurn)
    case ping
    case bye(String?)

    var type: String {
        switch self {
        case .hello: return "hello"
        case .ringing: return "ringing"
        case .answered: return "answered"
        case .declined: return "declined"
        case .played: return "played"
        case .userTurn: return "user_turn"
        case .ping: return "ping"
        case .bye: return "bye"
        }
    }

    /// The frame's JSON text.
    func encoded() throws -> String {
        let data: Data
        switch self {
        case let .userTurn(turn):
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            data = try encoder.encode(turn)
        default:
            data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        return String(decoding: data, as: UTF8.self)
    }

    private var object: JSON {
        var object: JSON = ["type": type]
        switch self {
        case let .hello(hello):
            object["call_id"] = hello.callID
            object["session_id"] = hello.sessionID
            object["title"] = hello.title
            object["initiated_by"] = hello.initiatedBy.rawValue
            object["app_version"] = hello.appVersion
        case let .played(id):
            object["id"] = id
        case let .bye(reason):
            object["reason"] = reason
        case .ringing, .answered, .declined, .ping, .userTurn:
            break
        }
        return object
    }
}

/// How a call ended, as the plugin reports it (`ended {outcome}`, `cancel {reason}`).
enum CallOutcome: Equatable {
    case answered, noAnswer, declined, pushFailed, unreachable, lost, ttsFailed, endedByUser, endedByAgent, busy, notAllowed
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "answered": self = .answered
        case "no_answer": self = .noAnswer
        case "declined": self = .declined
        case "push_failed": self = .pushFailed
        case "unreachable": self = .unreachable
        case "lost": self = .lost
        case "tts_failed": self = .ttsFailed
        case "ended_by_user": self = .endedByUser
        case "ended_by_agent": self = .endedByAgent
        case "busy": self = .busy
        case "not_allowed": self = .notAllowed
        default: self = .other(raw)
        }
    }

    /// What to tell the user, or nil for an ordinary end.
    var message: String? {
        switch self {
        case .answered, .endedByUser, .endedByAgent, .declined: return nil
        case .noAnswer: return nil
        case .pushFailed, .unreachable: return "Hermes couldn't reach this iPhone for the call."
        case .lost: return "Lost the connection to Hermes."
        case .ttsFailed: return "Hermes couldn't speak: its text-to-speech failed. The call ended."
        case .busy: return "Hermes is already on a call in another chat."
        case .notAllowed: return "Hermes' voice call settings don't allow calls from this chat."
        case let .other(raw): return raw.isEmpty ? nil : "The call ended (\(raw))."
        }
    }
}

/// plugin → phone, and what became of the socket.
enum PluginMessage: Equatable {
    /// The hello was accepted. `ringing`: the call waits for the user to answer; `live`: it is on.
    case ready(callID: String?, ringing: Bool)
    /// Stop ringing: the call is over before it was answered.
    case cancel(String)
    case speechStart(id: String, text: String, sampleRate: Double)
    case audio(Data)
    /// `cancelled` or `error`: the utterance won't finish and its queued audio should be dropped.
    case speechEnd(id: String, cancelled: Bool, error: String?)
    case pong
    case ended(CallOutcome)

    /// One text frame, or nil when it isn't one the phone knows.
    static func parse(_ text: String) -> PluginMessage? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? JSON else { return nil }
        let id = object["id"] as? String ?? ""
        switch object["type"] as? String {
        case "ready":
            return .ready(callID: object["call_id"] as? String, ringing: (object["state"] as? String) == "ringing")
        case "cancel":
            return .cancel(object["reason"] as? String ?? "")
        case "speech_start":
            let rate = (object["sample_rate"] as? NSNumber)?.doubleValue ?? 24_000
            return .speechStart(id: id, text: object["text"] as? String ?? "", sampleRate: rate)
        case "speech_end":
            let error = (object["error"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return .speechEnd(id: id, cancelled: (object["cancelled"] as? Bool) ?? false, error: error)
        case "pong":
            return .pong
        case "ended":
            return .ended(CallOutcome(object["outcome"] as? String ?? ""))
        default:
            return nil
        }
    }
}

/// The VoIP push the plugin sends to ring the phone.
struct CallPush: Equatable {
    let callID: String
    let sessionID: String?
    let profile: String?
    /// "sync" or "async": how the `start_call` that rang waits (only shown).
    let mode: String?
    let title: String?

    init(callID: String, sessionID: String?, profile: String?, mode: String?, title: String?) {
        self.callID = callID
        self.sessionID = sessionID
        self.profile = profile
        self.mode = mode
        self.title = title
    }

    /// Reads the push payload; nil without a usable call_id.
    init?(payload: [AnyHashable: Any]) {
        func string(_ key: String) -> String? {
            (payload[key] as? String).flatMap { $0.isEmpty ? nil : $0 }
        }
        guard let callID = string("call_id").flatMap(CallID.normalize) else { return nil }
        self.init(callID: callID, sessionID: string("session_id"), profile: string("profile"), mode: string("mode"), title: string("title"))
    }
}

/// `GET /api/plugins/hermes_voice/status`.
struct VoicePluginStatus: Equatable {
    /// The call holding Hermes' one call slot (`active_call`), so the call button can join it.
    struct ActiveCall: Equatable {
        let callID: String
        let sessionID: String?
        let title: String?
        /// "ringing" or "live".
        let state: String
        let initiatedBy: CallInitiator?

        /// Nil without a usable call_id.
        init?(_ object: JSON?) {
            guard let object, let callID = (object["call_id"] as? String).flatMap(CallID.normalize) else { return nil }
            self.callID = callID
            sessionID = (object["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            state = object["state"] as? String ?? ""
            initiatedBy = (object["initiated_by"] as? String).flatMap(CallInitiator.init(rawValue:))
        }
    }

    var calls: Int
    /// "elevenlabs" or "fake".
    var tts: String
    var h2: Bool
    var apnsConfigured: Bool
    var scribeConfigured: Bool
    var activeCall: ActiveCall?

    init(calls: Int = 0, tts: String = "", h2: Bool = false, apnsConfigured: Bool = false, scribeConfigured: Bool = false,
         activeCall: ActiveCall? = nil) {
        self.calls = calls
        self.tts = tts
        self.h2 = h2
        self.apnsConfigured = apnsConfigured
        self.scribeConfigured = scribeConfigured
        self.activeCall = activeCall
    }

    init(_ object: JSON) {
        let calls = object["calls"]
        self.init(
            calls: (calls as? NSNumber)?.intValue ?? (calls as? [Any])?.count ?? 0,
            tts: object["tts"] as? String ?? "",
            h2: object["h2"] as? Bool ?? false,
            apnsConfigured: object["apns_configured"] as? Bool ?? false,
            scribeConfigured: object["scribe_configured"] as? Bool ?? false,
            activeCall: ActiveCall(object["active_call"] as? JSON)
        )
    }

    /// Hermes can ring this phone: VoIP pushes need APNs credentials and the HTTP/2 client.
    var canRing: Bool { apnsConfigured && h2 }
}
