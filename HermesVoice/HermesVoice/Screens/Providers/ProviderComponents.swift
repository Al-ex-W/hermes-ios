import SafariServices
import SwiftUI
import UIKit

/// A small status tag beside a title (the desktop's `PanelPill` and the provider rows' "Connected" tag).
struct StatusTag: View {
    enum Tone { case good, muted, accent, warning }

    let text: String
    var tone: Tone = .muted
    var systemImage: String?

    init(_ text: String, tone: Tone = .muted, systemImage: String? = nil) {
        self.text = text
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: 9, weight: .semibold))
            }
            Text(text).hermesText(.meta).fontWeight(.medium)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xxs)
        .foregroundStyle(foreground)
        .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
        .fixedSize()
    }

    private var foreground: Color {
        switch tone {
        case .good, .accent: return Theme.primary
        case .muted: return Theme.Text.tertiary
        case .warning: return Theme.Semantic.attention
        }
    }

    private var background: Color {
        switch tone {
        case .good, .accent: return Theme.primary.opacity(0.1)
        case .muted: return Theme.Fill.quaternary
        case .warning: return Theme.Semantic.attention.opacity(0.12)
        }
    }
}

/// A value to read or copy: a host command, a path, a sign-in code.
struct CopyableText: View {
    let text: String
    var monospaced = true
    @State private var copied = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.md) {
            Text(text)
                .font(monospaced ? Theme.TextStyle.code.font : Theme.TextStyle.body.font)
                .foregroundStyle(Theme.Text.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                UIPasteboard.general.string = text
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : Theme.Icon.copy)
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(copied ? Theme.primary : Theme.Text.tertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(copied ? "Copied" : "Copy")
        }
    }
}

/// A web page in an in-app Safari sheet, so the app stays in front (and keeps polling) while the user signs in.
struct SafariSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        return SFSafariViewController(url: url, configuration: configuration)
    }

    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

/// A page to show in a `SafariSheet` (`sheet(item:)` needs an identity).
struct WebPage: Identifiable, Hashable {
    let url: URL
    var id: String { url.absoluteString }
}

/// A secret typed on the phone: never autocorrected, capitalised or suggested; Return submits.
struct SecretInput: View {
    let title: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    var body: some View {
        SecureField(title, text: $text)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .font(Theme.TextStyle.code.font)
            .submitLabel(.done)
            .onSubmit(onSubmit)
    }
}

/// The desktop's "Applies to" chooser (`SettingsProfileScope`): which profile's credentials and endpoints the page
/// reads and writes. Nil is the dashboard's own profile. Hidden with fewer than two profiles.
struct ProfileScopeSection: View {
    let profiles: [ProfileInfo]
    /// The profile the dashboard runs on (`GET /api/profiles/active`, `current`).
    let dashboardProfile: String
    @Binding var scope: String?

    var body: some View {
        if profiles.count > 1 {
            Section {
                Picker("Applies to", selection: selection) {
                    ForEach(profiles) { profile in
                        Text(Self.label(profile)).tag(profile.name)
                    }
                }
            } footer: {
                FormNote("Keys, accounts and endpoints are kept per profile. New chats in other profiles don't see these.")
            }
            .hermesFormRows()
        }
    }

    private var selection: Binding<String> {
        Binding(get: { scope ?? dashboardProfile },
                set: { scope = $0 == dashboardProfile ? nil : $0 })
    }

    /// The Bot Mode title when set, else the display name, else the name (`settingsScopeLabel`).
    static func label(_ profile: ProfileInfo) -> String {
        profile.botTitle ?? profile.label
    }
}

/// Loads the profile list and the dashboard's own profile for `ProfileScopeSection`. Failures leave it hidden.
@MainActor
final class ProfileScopeModel: ObservableObject {
    @Published private(set) var profiles: [ProfileInfo] = []
    @Published private(set) var dashboardProfile = "default"

    func load(_ client: DashboardClient) async {
        async let list = try? client.profiles()
        async let activity = try? client.profileActivity()
        if let list = await list { profiles = list }
        if let activity = await activity { dashboardProfile = activity.current }
    }
}

extension Error {
    /// The text an alert shows for a failed dashboard call.
    var dashboardMessage: String {
        if case let .http(code, body)? = self as? DashboardError {
            return DashboardDetail.message(body) ?? "Hermes answered \(code)."
        }
        return localizedDescription
    }
}

/// FastAPI error bodies (`{"detail": "…"}` or a list of validation errors) as one sentence.
enum DashboardDetail {
    static func message(_ body: String) -> String? {
        guard let data = body.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? JSON else {
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty || trimmed.hasPrefix("<") ? nil : String(trimmed.prefix(240))
        }
        if let detail = LenientField.text(object["detail"]) { return detail }
        if let rows = object["detail"] as? [JSON] {
            let messages = rows.compactMap { LenientField.text($0["msg"]) }
            if !messages.isEmpty { return messages.joined(separator: " ") }
        }
        return LenientField.text(object["message"]) ?? LenientField.text(object["error"])
    }
}

/// An alert for the last failure; `nil` hides it.
struct FailureAlert: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.alert("Hermes", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(message ?? "")
        }
    }
}

extension View {
    func failureAlert(_ message: Binding<String?>) -> some View {
        modifier(FailureAlert(message: message))
    }
}
