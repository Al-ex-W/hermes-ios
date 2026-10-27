import Foundation
import UIKit

/// A gateway connection the app can close while it is in the background (`GatewayConnection`).
@MainActor
protocol GatewayPausing: AnyObject {
    func pauseForBackground()
    func resumeFromBackground()
}

/// Whether the app keeps its `/api/ws` connection while in the background. The Hermes Voice plugin alerts this phone
/// (approval or question waiting, turn done) only while no client is attached to the session, and Hermes counts a
/// client as attached as long as its socket is open, which an app iOS suspended never closes by itself. So the
/// connection closes when the app goes to the background with no call, and on return to the foreground it redials
/// and re-attaches the open chats through `GatewayConnection`'s re-attach and replay, so no event is lost. A call
/// (ringing, starting, or live, even in the background) keeps the connection: its chat stays attached and shows what
/// is said.
@MainActor
final class GatewayLifecycle {
    enum Phase: Equatable { case foreground, background }

    private(set) var phase: Phase
    private(set) var callActive = false
    private weak var connection: GatewayPausing?

    init(phase: Phase) {
        self.phase = phase
    }

    /// The connection is closed for the background.
    var paused: Bool { phase == .background && !callActive }

    /// A new sign-in's connection; it starts paused when the app is in the background with no call.
    func use(_ connection: GatewayPausing?) {
        self.connection = connection
        apply()
    }

    func setPhase(_ phase: Phase) {
        guard phase != self.phase else { return }
        self.phase = phase
        apply()
    }

    func setCallActive(_ active: Bool) {
        guard active != callActive else { return }
        callActive = active
        apply()
    }

    private func apply() {
        if paused {
            connection?.pauseForBackground()
        } else {
            connection?.resumeFromBackground()
        }
    }

    /// The phase iOS reports now (a VoIP push or a notification action launches the app in the background).
    static var currentPhase: Phase {
        UIApplication.shared.applicationState == .background ? .background : .foreground
    }

    /// A few seconds of background time, so the socket's close frame goes out before iOS suspends the app.
    static func lingerForClose(seconds: Double = 2) {
        let task = Linger()
        task.id = UIApplication.shared.beginBackgroundTask(withName: "Hermes gateway close") {
            MainActor.assumeIsolated { task.end() }
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            task.end()
        }
    }

    private final class Linger {
        var id = UIBackgroundTaskIdentifier.invalid

        @MainActor func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}
