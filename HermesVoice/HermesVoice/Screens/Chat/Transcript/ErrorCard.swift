import SwiftUI
import UIKit

/// A failed turn (`ErrorCardHeadline`): what went wrong in plain words for the layer and code that failed, the raw
/// error behind a Details disclosure, and the recovery actions that fit it.
struct ErrorCard: View {
    let error: TurnError
    @Environment(\.transcriptActions) private var actions
    @State private var showDetails = false

    var body: some View {
        let copy = ErrorCopy.text(for: error)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(copy.title).fontWeight(.medium)
                Text(copy.body)
                if let resets = error.resetsAt, resets > Date() {
                    Text("Limit resets at \(resets.formatted(date: .omitted, time: .shortened))").opacity(0.8)
                }
            }
            .hermesText(.caption)
            .fixedSize(horizontal: false, vertical: true)
            if !error.message.isEmpty, error.message != copy.body {
                Button {
                    showDetails.toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: Theme.Icon.disclosure)
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(showDetails ? 90 : 0))
                        Text("Details")
                    }
                    .hermesText(.meta)
                    .opacity(0.75)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showDetails {
                    Text(error.message)
                        .font(.system(size: 10.5, design: .monospaced))
                        .opacity(0.75)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            TranscriptFlowLayout(spacing: Theme.Spacing.sm) {
                ForEach(error.recovery, id: \.self) { recovery in
                    Button(ErrorCopy.label(recovery)) { actions.recover(recovery, error) }
                        .buttonStyle(ErrorActionStyle())
                }
                Button("Copy error details") { UIPasteboard.general.string = ErrorCopy.diagnostics(error) }
                    .buttonStyle(ErrorActionStyle())
            }
        }
        .foregroundStyle(Theme.Semantic.red)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.destructive.opacity(0.07), in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.widget)
                .strokeBorder(Theme.destructive.opacity(0.35), lineWidth: Theme.hairlineWidth)
        }
        .accessibilityElement(children: .contain)
    }
}

private struct ErrorActionStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .hermesText(.button)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.destructive.opacity(configuration.isPressed ? 0.16 : 0.09), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }
}

/// The error card's words (`error-surface-copy.ts` and the `assistant.thread.error*` tables): the code's copy when
/// there is one, else the layer's, else generic. Without a descriptor, Hermes' own sentence is the body.
enum ErrorCopy {
    static func text(for error: TurnError) -> (title: String, body: String) {
        let provider = error.providerLabel ?? error.provider ?? "The AI service"
        if error.layer == .auth, error.authKind == "oauth" {
            return ("Your \(provider) sign-in expired", "Your \(provider) sign-in has expired or was revoked. Sign in again to keep chatting.")
        }
        if error.layer == .auth, error.authKind == "api_key" {
            return ("\(provider) rejected your API key", "The key saved for \(provider) is invalid or was revoked. Update it, then retry.")
        }
        if let code = error.code, let copy = codes(provider)[code] { return copy }
        guard let layer = error.layer else { return ("Hermes couldn't finish this reply", error.message) }
        return layers[layer] ?? ("Hermes couldn't finish this reply", error.message)
    }

    static func label(_ recovery: ErrorRecovery) -> String {
        switch recovery {
        case .retry: return "Retry"
        case .compress: return "Compress conversation"
        case .chooseModel: return "Choose a model"
        case .switchProvider: return "Switch provider"
        case .editMessage: return "Edit message"
        case .startNewSession: return "Start new session"
        }
    }

    /// The plain-text blob behind "Copy error details".
    static func diagnostics(_ error: TurnError) -> String {
        var lines = ["── Hermes error details ──", "time: \(ISO8601DateFormatter().string(from: Date()))"]
        if let layer = error.layer { lines.append("layer: \(layer.rawValue)") }
        if let code = error.code { lines.append("code: \(code)") }
        if error.layer != nil { lines.append("retryable: \(error.retryable)") }
        if let resets = error.resetsAt { lines.append("resets_at: \(ISO8601DateFormatter().string(from: resets))") }
        if let provider = error.provider { lines.append("provider: \(provider)") }
        if let model = error.model { lines.append("model: \(model)") }
        lines.append("error: \(error.message)")
        return lines.joined(separator: "\n")
    }

    private static let layers: [TurnError.Layer: (title: String, body: String)] = [
        .auth: ("Sign-in problem", "The AI service rejected your sign-in. Check the credentials for this provider, then send your message again."),
        .billing: ("Out of credits", "Your account has no credits left for this provider. Top up or switch provider, then send again."),
        .disk: ("Disk full", "Your disk is full, so Hermes could not save this conversation. Free some space, then retry."),
        .endpoint: ("Can't reach your model server", "Hermes can't reach your custom model server. Check that it is running, then send your message again."),
        .gateway: ("Hermes hit a problem", "Hermes hit an internal problem starting this reply. Send your message again; if it keeps happening, send diagnostics."),
        .provider: ("The AI service returned an error", "The AI service could not complete this request. Retry in a moment or switch provider."),
        .runtime: ("Hermes hit a problem", "Hermes hit an internal problem starting this reply. Send your message again; if it keeps happening, send diagnostics."),
        .streaming: ("The reply was cut off", "The connection dropped before the reply finished. Retry to send it again."),
    ]

    private static func codes(_ provider: String) -> [String: (title: String, body: String)] {
        [
            "auth": ("\(provider) rejected your sign-in", "The credentials saved for \(provider) were not accepted. Fix them in Settings or switch provider, then send your message again."),
            "auth_permanent": ("\(provider) rejected your sign-in", "The credentials saved for \(provider) are invalid or were revoked. Update them or switch provider, then send your message again."),
            "billing": ("Out of credits", "Your \(provider) account has no credits left. Top up or switch provider, then send again."),
            "rate_limit": ("The AI service is busy", "\(provider) is limiting requests right now. Wait a minute, then retry."),
            "upstream_rate_limit": ("The AI service is busy", "\(provider) is limiting requests right now. Wait a minute, then retry."),
            "overloaded": ("The AI service is overloaded", "\(provider) is having problems right now. Retry in a moment or switch provider."),
            "server_error": ("The AI service had a problem", "\(provider) returned a server error. Retry in a moment or switch provider."),
            "timeout": ("Could not reach the AI service", "\(provider) could not be reached or did not answer in time. Check your internet connection, then retry."),
            "stream_drop": ("The reply was cut off", "The connection dropped before the reply finished. Retry to send it again."),
            "no_reply": ("The reply didn't finish", "Hermes ended this turn without a reply. Retry to send it again."),
            "upstream_blocked": ("A firewall blocked the request", "A firewall or CDN in front of \(provider) blocked the request before it reached the model — your key is probably fine. Set a User-Agent header in the provider's extra headers, or switch provider, then send your message again."),
            "ssl_cert_verification": ("Secure connection failed", "Hermes could not verify the secure connection to \(provider). Check your network or proxy settings, or switch provider, then send your message again."),
            "context_overflow": ("This conversation is too long", "The conversation no longer fits the model. Compress it or start a new chat, then send again."),
            "payload_too_large": ("This message is too large", "The request was too big for the model. Compress the conversation or start a new chat, then send again."),
            "model_not_found": ("This model is not available", "\(provider) does not offer this model on your account. Choose another model, then send your message again."),
            "provider_policy_blocked": ("This model is blocked by your account settings", "\(provider) would not route this request under your account's data or privacy settings. Choose another model or switch provider."),
            "content_policy_blocked": ("The AI service declined this request", "\(provider) would not answer this message. Edit it and send again."),
            "format_error": ("The AI service rejected the request", "\(provider) did not accept how this request was built. Switch provider or send diagnostics so it can be looked into."),
            "truncated": ("The reply was cut short", "The model stopped before finishing. Retry to get a complete reply."),
            "invalid_response": ("The AI service sent an unreadable reply", "\(provider) returned something Hermes could not read. Retry in a moment."),
            "empty_response": ("The AI service sent an empty reply", "\(provider) returned nothing for this message. Retry in a moment."),
            "loop_error": ("Hermes got stuck in a loop", "The reply kept repeating the same steps, so Hermes stopped it. Retry, or start a new chat if it happens again."),
            "SESSION_NOT_OWNED": ("This chat is open somewhere else", "This chat is currently open in another Hermes window or terminal. Close it there and send your message again, or start a new chat here."),
            "disk_full": ("Disk full", "Your disk is full, so Hermes could not save this conversation. Free some space, then retry."),
        ]
    }
}
