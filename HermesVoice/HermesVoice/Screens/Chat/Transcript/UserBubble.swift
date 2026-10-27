import SwiftUI

/// The user's prompt (the desktop's `user-message.tsx` in its touch layout): a bubble on the right, its attachments
/// as chips below it, then its actions: Edit (the prompt opens in the composer, and sending it re-runs the chat from
/// there) and, at the end, Stop on the prompt whose turn runs, else Restore checkpoint (runs the conversation again
/// from this prompt, after a confirmation). Pressed, the bubble offers Copy beside the same actions. A line said on
/// a call keeps the green speaker style and has no actions.
struct UserBubble: View {
    let message: UserMessage
    /// The prompt whose turn runs now: Stop takes Restore's place.
    var stoppable = false
    @Environment(\.transcriptActions) private var actions
    @State private var confirmingRestore = false

    static let restoreTitle = "Restore to this checkpoint?"
    static let restoreBody = "Everything after this prompt is removed from the conversation, and the prompt runs again from here."
    static let restoreConfirm = "Restore & rerun"

    private var hasBody: Bool { !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsStop: Bool { stoppable && actions.stop != nil }
    /// Restore needs words to run again, and isn't offered where Stop is.
    private var showsRestore: Bool { !showsStop && actions.restore != nil && hasBody }

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            if let spoken = message.spoken {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Semantic.green)
                    Text(spoken)
                        .hermesText(.conversation)
                        .foregroundStyle(Theme.Text.primary)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.vertical, Theme.Spacing.md)
                .background(Theme.Semantic.green.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
            } else if hasBody {
                Text(message.text)
                    .hermesText(.conversation)
                    .foregroundStyle(Theme.Text.primary)
                    .hermesBubble()
                    .contextMenu { menu }
            }
            if !message.attachments.isEmpty {
                TranscriptFlowLayout(alignment: .trailing) {
                    ForEach(message.attachments, id: \.ref) { ref in
                        AttachmentChip(ref: ref)
                    }
                }
            }
            if message.spoken == nil { actionRow }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
        .confirmationDialog(Self.restoreTitle, isPresented: $confirmingRestore, titleVisibility: .visible) {
            Button(Self.restoreConfirm, role: .destructive) { actions.restore?(message) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(Self.restoreBody)
        }
    }

    /// Touch has no hover: Edit, and Stop or Restore, stay under the bubble.
    @ViewBuilder private var actionRow: some View {
        if actions.edit != nil || showsStop || showsRestore {
            HStack(spacing: 0) {
                if let edit = actions.edit {
                    actionButton("Edit message", systemImage: Theme.Icon.rename) { edit(message) }
                }
                if showsStop, let stop = actions.stop {
                    actionButton("Stop", systemImage: Theme.Icon.stop, action: stop)
                } else if showsRestore {
                    actionButton("Restore checkpoint", systemImage: Theme.Icon.restore) { confirmingRestore = true }
                }
            }
            .padding(.top, -Theme.Spacing.sm)
        }
    }

    private func actionButton(_ label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Text.secondary)
                .frame(width: 44, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private var menu: some View {
        Button("Copy", systemImage: Theme.Icon.copy) { UIPasteboard.general.string = message.text }
        if let edit = actions.edit {
            Button("Edit message", systemImage: Theme.Icon.rename) { edit(message) }
        }
        if showsStop, let stop = actions.stop {
            Button("Stop", systemImage: Theme.Icon.stop, action: stop)
        } else if showsRestore {
            Button("Restore checkpoint", systemImage: Theme.Icon.restore) { confirmingRestore = true }
        }
    }
}

/// A reference sent with a prompt, as a chip: its kind's glyph and the file's name (or the URL's host).
struct AttachmentChip: View {
    let ref: AttachmentRef

    var body: some View {
        Label {
            Text(ref.label).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: Self.symbol(ref.kind)).font(.system(size: 10))
        }
        .labelStyle(ChipLabelStyle())
        .contextMenu {
            Button("Copy", systemImage: Theme.Icon.copy) { UIPasteboard.general.string = ref.value }
        }
    }

    static func symbol(_ kind: AttachmentRef.Kind) -> String {
        switch kind {
        case .file: return "doc.text"
        case .folder: return "folder"
        case .url: return "link"
        case .image: return "photo"
        case .tool: return Theme.Icon.tool
        case .line: return "number"
        case .terminal: return Theme.Icon.terminal
        case .session: return "bubble.left.and.bubble.right"
        }
    }
}

/// Files Hermes delivered with `MEDIA:` tags, as chips under the reply.
struct MediaChips: View {
    let media: [MediaRef]
    @Environment(\.transcriptActions) private var actions

    var body: some View {
        TranscriptFlowLayout {
            ForEach(media, id: \.path) { ref in
                Group {
                    if let open = actions.openMedia {
                        Button { open(ref) } label: { chip(ref) }.buttonStyle(.plain)
                    } else {
                        chip(ref)
                    }
                }
                .contextMenu {
                    Button("Copy path", systemImage: Theme.Icon.copy) { UIPasteboard.general.string = ref.path }
                }
            }
        }
    }

    private func chip(_ ref: MediaRef) -> some View {
        Label {
            Text(ref.name).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: Self.symbol(ref.kind)).font(.system(size: 10))
        }
        .labelStyle(ChipLabelStyle())
    }

    static func symbol(_ kind: MediaRef.Kind) -> String {
        switch kind {
        case .image: return "photo"
        case .audio: return "waveform"
        case .video: return "film"
        case .document: return "doc.richtext"
        case .other: return "doc"
        }
    }
}

/// The chip shape shared by attachments and media: soft control fill, hairline, near-square corners.
struct ChipLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Theme.Spacing.xs) {
            configuration.icon.foregroundStyle(Theme.Text.tertiary)
            configuration.title.foregroundStyle(Theme.Text.secondary)
        }
        .hermesText(.caption)
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(maxWidth: 240)
        .background(Theme.Fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.icon))
        .hermesOutline(radius: Theme.Radius.icon)
    }
}
