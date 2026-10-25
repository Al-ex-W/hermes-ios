import Foundation

/// What the composer needs from a chat: its live session, whether a turn runs or a prompt holds it, and the calls
/// the send decision tree (`SendController`) routes to. `ChatModel` conforms; tests use a fake.
@MainActor
protocol ChatSending: AnyObject {
    /// The live (runtime) session id; nil until the chat is attached.
    var runtimeSessionID: String? { get }
    /// A turn is running.
    var isBusy: Bool { get }
    /// A clarify card waits on this session.
    var hasPendingClarify: Bool { get }
    /// An approval, sudo, secret or vault prompt holds the turn: typing can't answer it, and a correction can't
    /// reach the model past it.
    var hasBlockingPrompt: Bool { get }
    /// Answers the pending clarify with "none of these", so its tool returns and the words that follow are routed
    /// as an ordinary message.
    func skipPendingClarify() async
    /// Sends a prompt carrying `attachments` (staged on the live session); true once Hermes accepted it. The prompt
    /// text is `StagedAttachment.promptText(text, attachments)`.
    func submit(_ text: String, attachments: [StagedAttachment]) async -> Bool
    /// Corrects the running turn with `text` (`session.redirect`).
    func redirect(_ text: String) async -> RedirectOutcome
    /// Stops the running turn (`session.interrupt`).
    func interrupt() async
    /// Runs a slash command now, a turn running or not; true when it ran.
    func runSlash(_ command: String) async -> Bool
    /// Stages an attachment on the live session (attaching first), for the next `submit`.
    func stage(_ attachment: PendingAttachment) async throws -> StagedAttachment
}

/// How a correction of the running turn ended.
enum RedirectOutcome: Equatable {
    /// The live request restarted with the correction.
    case redirected
    /// Hermes holds it for the next model call (compression, the build window).
    case queued
    /// No turn to correct (it already ended).
    case rejected
    /// The call failed.
    case failed

    /// The correction reaches the model.
    var delivered: Bool { self == .redirected || self == .queued }

    init(_ status: CorrectionStatus) {
        switch status {
        case .redirected: self = .redirected
        case .queued: self = .queued
        case .rejected, .unknown: self = .rejected
        }
    }
}

/// An attachment picked in the composer, not yet on the gateway.
enum PendingAttachment: Hashable {
    /// A photo: staged into the session's attached images (`image.attach_bytes`).
    case image(Data, filename: String)
    /// Any other file: staged into the session workspace (`file.attach`), referenced from the prompt.
    case file(Data, filename: String, mime: String)

    var filename: String {
        switch self {
        case let .image(_, filename), let .file(_, filename, _): return filename
        }
    }

    var isImage: Bool {
        if case .image = self { return true }
        return false
    }
}

/// An attachment Hermes holds for the session's next prompt.
struct StagedAttachment: Hashable {
    enum Kind: Hashable { case image, file }

    let kind: Kind
    /// The name Hermes stored it under.
    let name: String
    /// What the prompt carries for it (`@file:…`); nil for an image, which rides the session's attached images.
    let refText: String?

    /// The prompt for `text` with `attachments`: their refs, a blank line, then the text (the desktop's
    /// `buildContextText`). An image without text asks what it shows.
    static func promptText(_ text: String, _ attachments: [StagedAttachment]) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let refs = attachments.compactMap(\.refText).filter { !$0.isEmpty }.joined(separator: "\n")
        let joined = [refs, text].filter { !$0.isEmpty }.joined(separator: "\n\n")
        if joined.isEmpty, attachments.contains(where: { $0.kind == .image }) { return "What do you see in this image?" }
        return joined
    }
}

/// Hermes refused to stage an attachment.
struct AttachmentError: LocalizedError {
    let message: String

    var errorDescription: String? { message }
}

extension GatewayClient {
    /// Stages `attachment` on the live session `sessionID`: a photo as base64 bytes (`image.attach_bytes`), a file
    /// as a data URL (`file.attach`, whose `ref_text` the prompt must carry). Never `/api/files/upload`.
    func stage(_ attachment: PendingAttachment, sessionID: String, profile: String? = nil) async throws -> StagedAttachment {
        switch attachment {
        case let .image(data, filename):
            let result: AttachedImageResult
            do {
                result = try await imageAttachBytes(.init(
                    sessionId: sessionID, profile: profile, contentBase64: data.base64EncodedString(), filename: filename
                ))
            } catch let error as GatewayDecodingError {
                guard error.raw["attached"]?.boolValue == true else { throw error }
                return StagedAttachment(kind: .image, name: Self.leaf(error.raw["path"]?.stringValue) ?? filename, refText: nil)
            }
            guard result.attached else { throw AttachmentError(message: result.message ?? "Couldn't attach \(filename).") }
            return StagedAttachment(kind: .image, name: Self.leaf(result.path) ?? result.name ?? filename, refText: nil)
        case let .file(data, filename, mime):
            let dataURL = "data:\(mime.isEmpty ? "application/octet-stream" : mime);base64,\(data.base64EncodedString())"
            let result: FileAttachResult
            do {
                result = try await fileAttach(.init(sessionId: sessionID, profile: profile, dataUrl: dataURL, name: filename))
            } catch let error as GatewayDecodingError {
                guard error.raw["attached"]?.boolValue == true, let ref = error.raw["ref_text"]?.stringValue, !ref.isEmpty else { throw error }
                return StagedAttachment(kind: .file, name: error.raw["name"]?.stringValue ?? filename, refText: ref)
            }
            guard result.attached, !result.refText.isEmpty else { throw AttachmentError(message: "Couldn't attach \(filename).") }
            return StagedAttachment(kind: .file, name: result.name, refText: result.refText)
        }
    }

    private static func leaf(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }
}
