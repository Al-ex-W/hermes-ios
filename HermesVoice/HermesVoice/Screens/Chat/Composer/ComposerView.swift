import SwiftUI

/// The chat composer (the desktop's `app/chat/composer`): the `/` and `@` popover, the draft with its attachment
/// chips, and the controls row: "+" menu, model and effort pills, the context meter, Queue while a turn runs,
/// and Send, which turns into Stop when a turn runs and nothing is typed. Every send goes through the
/// `SendController` decision tree.
struct ComposerView: View {
    @ObservedObject var composer: ComposerModel
    @ObservedObject var sender: SendController
    let busy: Bool
    let status: StatusStackModel?
    let disabled: Bool
    @FocusState private var focused: Bool
    @State private var placeholder: String

    /// `busy`: the chat's turn is running. `status` adds the context meter. `newChat` picks a starter placeholder.
    init(composer: ComposerModel, busy: Bool, status: StatusStackModel? = nil, disabled: Bool = false, newChat: Bool = false) {
        self.composer = composer
        sender = composer.sender
        self.busy = busy
        self.status = status
        self.disabled = disabled
        _placeholder = State(initialValue: (newChat ? Self.starters : Self.followUps).randomElement() ?? "Message Hermes")
    }

    static let starters = ["What are we building?", "Give Hermes a task", "What's on your mind?", "Describe what you need",
                           "What should we tackle?", "Ask anything"]
    static let followUps = ["Send a follow-up", "Add more context", "Refine the request", "What's next?", "Keep it going",
                            "Push it further"]

    private var editing: Bool { composer.isEditingQueued || composer.editingMessage != nil }

    private var showsStop: Bool { busy && !composer.hasPayload && !editing }

    private var canSend: Bool {
        if composer.editingMessage != nil { return !disabled && composer.hasPayload }
        return !disabled && (composer.hasPayload || busy || (!sender.queue.isEmpty && !composer.isEditingQueued))
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.sm) {
            CompletionList(composer: composer)
            VStack(alignment: .leading, spacing: 0) {
                if composer.isEditingQueued {
                    editingBanner("Editing queued turn in composer") { composer.cancelEdit() }
                } else if composer.editingMessage != nil {
                    editingBanner("Editing message — sending it re-runs the chat from there") { composer.cancelMessageEdit() }
                }
                if !composer.attachments.isEmpty { attachmentStrip }
                TextField(placeholder, text: $composer.draft, axis: .vertical)
                    .lineLimit(1...8)
                    .hermesText(.conversation)
                    .foregroundStyle(Theme.Text.primary)
                    .tint(Theme.midground)
                    .focused($focused)
                    .padding(.horizontal, Theme.Spacing.lg)
                    .padding(.top, Theme.Spacing.md + 2)
                    .padding(.bottom, Theme.Spacing.xs)
                    .accessibilityLabel("Message")
                controls
            }
            .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.composer))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.composer)
                    .strokeBorder(focused ? Theme.ring.opacity(0.45) : Theme.Hairline.secondary, lineWidth: Theme.hairlineWidth)
            }
        }
        .task { await composer.refreshModel() }
        .alert("Hermes", isPresented: Binding(get: { composer.notice != nil }, set: { if !$0 { composer.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(composer.notice ?? "")
        }
    }

    private var controls: some View {
        HStack(spacing: 0) {
            AttachMenu(composer: composer, disabled: disabled || composer.editingMessage != nil)
            ModelPill(composer: composer, disabled: disabled)
            EffortPill(composer: composer, disabled: disabled)
            Spacer(minLength: Theme.Spacing.xs)
            if let status { ContextMeter(status: status) }
            if busy, composer.hasPayload, !editing {
                Button { composer.queue() } label: {
                    Image(systemName: "square.stack")
                        .font(.system(size: Theme.IconSize.sm, weight: .medium))
                        .foregroundStyle(Theme.Text.tertiary)
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel("Queue message")
            }
            Button { Task { await composer.send() } } label: {
                ZStack {
                    Circle().fill(canSend ? Theme.primary : Theme.Fill.secondary)
                    if showsStop {
                        RoundedRectangle(cornerRadius: 3).fill(Theme.primaryForeground).frame(width: 10, height: 10)
                    } else {
                        Image(systemName: editing ? "checkmark" : Theme.Icon.send)
                            .font(.system(size: Theme.IconSize.sm, weight: .semibold))
                            .foregroundStyle(canSend ? Theme.primaryForeground : Theme.Text.quaternary)
                    }
                }
                .frame(width: 28, height: 28)
                .frame(width: 36, height: 36)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel(showsStop ? "Stop" : composer.isEditingQueued ? "Save queued message"
                                : composer.editingMessage != nil ? "Send edited message" : "Send")
            .sensoryFeedback(.impact(weight: .light), trigger: sender.queue.count)
        }
        .padding(.horizontal, Theme.Spacing.xs)
        .padding(.bottom, Theme.Spacing.xs)
    }

    private func editingBanner(_ title: String, cancel: @escaping () -> Void) -> some View {
        HStack {
            Label(title, systemImage: Theme.Icon.rename)
                .hermesText(.meta)
                .foregroundStyle(Theme.midground)
            Spacer()
            Button("Cancel", action: cancel)
                .hermesText(.meta)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Text.tertiary)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.top, Theme.Spacing.md)
    }

    private var attachmentStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.sm) {
                ForEach(composer.attachments) { attachment in chip(attachment) }
            }
            .padding(.horizontal, Theme.Spacing.lg)
            .padding(.top, Theme.Spacing.md)
        }
    }

    private func chip(_ attachment: ComposerAttachment) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            if let data = attachment.thumbnail, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.row))
            } else {
                Image(systemName: attachment.pending.isImage ? "photo" : "doc")
                    .font(.system(size: Theme.IconSize.sm))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 28, height: 28)
            }
            Text(attachment.name)
                .hermesText(.meta)
                .foregroundStyle(Theme.Text.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 120, alignment: .leading)
            Button { composer.removeAttachment(attachment.id) } label: {
                Image(systemName: Theme.Icon.close)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Text.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(attachment.name)")
        }
        .padding(.leading, Theme.Spacing.xs)
        .padding(.trailing, Theme.Spacing.xxs)
        .padding(.vertical, Theme.Spacing.xs)
        .background(Theme.Fill.quaternary, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.bubble)
                .strokeBorder(Theme.Hairline.tertiary, lineWidth: Theme.hairlineWidth)
        }
    }
}
