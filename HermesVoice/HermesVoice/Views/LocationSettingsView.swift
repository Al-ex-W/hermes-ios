import SwiftUI
import UIKit

/// What Settings > Location says for one state of the switch and of the iOS permission: the status line, the
/// explanation under it, and what the user can do about it.
struct LocationSharingState: Equatable {
    enum Action: Equatable {
        case none
        /// Ask iOS for location access (it never asked, or the user chose "Allow Once" last time).
        case allow
        /// Ask iOS for "Always" (it asks once; after that only iOS Settings can change it, so that is offered too).
        case allowAlways
        case openSettings
    }

    /// "Off", "Sharing while the app is open" …
    let status: String
    /// The phone answers Hermes' requests: the indicator shows.
    let sharing: Bool
    let detail: String
    /// Sharing is on but can't work: shown as a problem.
    let isProblem: Bool
    let action: Action

    init(enabled: Bool, access: LocationAccess, precise: Bool) {
        switch (enabled, access) {
        case (false, _):
            self.init(status: "Off", sharing: false, isProblem: false, action: .none,
                      detail: "Hermes can't ask this iPhone where it is, and nothing is sent.")
        case (true, .notDetermined):
            self.init(status: "Waiting for permission", sharing: false, isProblem: false, action: .allow,
                      detail: "Nothing is shared until you allow location access when iOS asks.")
        case (true, .denied):
            self.init(status: "Blocked in iOS Settings", sharing: false, isProblem: true, action: .openSettings,
                      detail: "Location access is off for this app, so nothing is shared. Turn it on in iOS Settings "
                          + "(Location: While Using the App, or Always).")
        case (true, .restricted):
            self.init(status: "Restricted on this iPhone", sharing: false, isProblem: true, action: .none,
                      detail: "Location access is restricted on this iPhone (Screen Time or a device profile), so "
                          + "nothing is shared.")
        case (true, .whenInUse):
            self.init(status: "Sharing while the app is open", sharing: true, isProblem: false, action: .allowAlways,
                      detail: "Hermes gets an answer only while this app is on screen. With “Always” it also gets one "
                          + "while the app is in the background or the iPhone is locked, which is how a scheduled "
                          + "check, or a call with the screen off, reaches you."
                          + Self.approximate(precise))
        case (true, .always):
            self.init(status: "Sharing, also in the background", sharing: true, isProblem: false, action: .none,
                      detail: "Hermes can ask at any time. While the app is in the background iOS may still delay or "
                          + "drop a request (Low Power Mode, no connection, or after you force-quit the app)."
                          + Self.approximate(precise))
        }
    }

    private init(status: String, sharing: Bool, isProblem: Bool, action: Action, detail: String) {
        self.status = status
        self.sharing = sharing
        self.isProblem = isProblem
        self.action = action
        self.detail = detail
    }

    /// What reduced accuracy (Precise Location off) adds to the explanation.
    private static func approximate(_ precise: Bool) -> String {
        precise ? "" : " Precise Location is off for this app, so Hermes gets only an approximate position (within a "
            + "few kilometres); turn it on in iOS Settings for an exact one."
    }

    /// What is shared, with whom and when, under the switch. `host`: the Hermes host the app is signed in to.
    static func disclosure(host: String?) -> String {
        let whom = host.map { "your own Hermes host (\($0))" } ?? "your own Hermes host"
        return "When your Hermes agent asks, this iPhone sends its current position: latitude, longitude, how accurate "
            + "the fix is, its time, and speed and heading when known. It goes only to \(whom), and only when Hermes "
            + "asks; the app never sends it on its own. The host keeps only the latest position, in memory, for a "
            + "short time (30 minutes unless you change it there)."
    }

    /// "Last sent" on the page.
    static func lastSent(_ date: Date?, now: Date = Date(), locale: Locale = .current, calendar: Calendar = .current) -> String {
        guard let date else { return "Nothing sent yet" }
        var format = Date.FormatStyle(date: calendar.isDate(date, inSameDayAs: now) ? .omitted : .abbreviated, time: .shortened)
        format.locale = locale
        format.calendar = calendar
        format.timeZone = calendar.timeZone
        return date.formatted(format)
    }
}

/// Settings > Location: "Share location with Hermes" (off by default), what is shared and with whom, what iOS
/// allows, and when a position was last sent.
struct LocationSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var location: LocationSharing
    let anchor: String?

    private var state: LocationSharingState {
        LocationSharingState(enabled: location.enabled, access: location.access, precise: location.precise)
    }

    var body: some View {
        let state = state
        Form {
            Section {
                SettingsRow(title: "Share location with Hermes", description: "Let your Hermes agent ask this iPhone where it is.") {
                    Toggle("Share location with Hermes", isOn: Binding(get: { location.enabled }, set: { location.setEnabled($0) }))
                        .labelsHidden()
                        .accessibilityIdentifier("location.sharing")
                }
                .id("location.sharing")
            } footer: {
                FormNote(LocationSharingState.disclosure(host: model.settings.dashboardBase?.host))
            }
            .hermesFormRows()

            Section {
                LabeledContent("Status") {
                    HStack(spacing: Theme.Spacing.sm) {
                        if state.sharing {
                            Image(systemName: "location.fill").foregroundStyle(Theme.primary)
                                .accessibilityLabel("Sharing")
                        }
                        Text(state.status).foregroundStyle(state.isProblem ? Theme.destructive : Theme.Text.tertiary)
                    }
                }
                .accessibilityIdentifier("location.status")
                LabeledContent("Last sent") {
                    Text(LocationSharingState.lastSent(location.lastSent)).foregroundStyle(Theme.Text.tertiary)
                }
                .accessibilityIdentifier("location.last-sent")
                switch state.action {
                case .none:
                    EmptyView()
                case .allow:
                    Button("Allow location access…") { location.requestBackgroundAccess() }
                case .allowAlways:
                    Button("Allow in the background…") { location.requestBackgroundAccess() }
                    Button("Open iOS Settings") { openSettings() }
                case .openSettings:
                    Button("Open iOS Settings") { openSettings() }
                }
            } header: {
                FormNote("This iPhone")
            } footer: {
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    FormNote(state.detail, color: state.isProblem ? Theme.destructive : Theme.Text.tertiary)
                    if location.enabled, let problem = location.lastProblem {
                        FormNote(problem)
                    }
                }
            }
            .hermesFormRows()
        }
        .hermesForm()
        .settingsAnchor(anchor)
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }
}
