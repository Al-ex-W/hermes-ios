import SwiftUI

/// The user's prompt: a bubble on the right, its attachments as chips below it. A line said on a call keeps the
/// green speaker style.
struct UserBubble: View {
    let message: UserMessage

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
            } else if !message.text.isEmpty {
                Text(message.text)
                    .hermesText(.conversation)
                    .foregroundStyle(Theme.Text.primary)
                    .textSelection(.enabled)
                    .hermesBubble()
            }
            if !message.attachments.isEmpty {
                TranscriptFlowLayout(alignment: .trailing) {
                    ForEach(message.attachments, id: \.ref) { ref in
                        AttachmentChip(ref: ref)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
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
