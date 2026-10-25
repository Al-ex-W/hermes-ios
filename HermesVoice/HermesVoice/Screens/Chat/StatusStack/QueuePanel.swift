import SwiftUI

/// The local queue (the desktop's `queue-panel.tsx`): prompts waiting for the turn to end, each editable in the
/// composer, steerable into the live turn when a redirect can carry it, sendable now, or deletable. After Stop
/// the queue is paused until resumed.
struct QueuePanel: View {
    @ObservedObject var sender: SendController
    @ObservedObject var composer: ComposerModel
    let busy: Bool
    @State private var expanded: Set<UUID> = []

    var body: some View {
        if !sender.queue.isEmpty {
            StatusSection(icon: sender.parked ? "pause.circle" : "square.stack", label: label, expanded: true) {
                if sender.parked {
                    Button("Resume") { Task { await sender.resume() } }
                        .buttonStyle(.plain)
                        .hermesText(.label)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityHint("Paused by Stop. Resumes sending the queued turns.")
                }
            } content: {
                ForEach(sender.queue) { entry in row(entry) }
            }
        }
    }

    private var label: String {
        sender.parked ? "\(sender.queue.count) Queued — paused" : "\(sender.queue.count) Queued"
    }

    private func row(_ entry: SendController.QueuedPrompt) -> some View {
        let editing = sender.editingID == entry.id
        let preview = Self.preview(entry)
        let long = preview.count > 140 || preview.contains("\n")
        return StatusRow(highlighted: editing) {
            Image(systemName: "text.bubble")
                .font(.system(size: Theme.IconSize.xs))
                .foregroundStyle(Theme.Text.tertiary)
        } content: {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(preview)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.primary)
                    .lineLimit(expanded.contains(entry.id) ? 12 : 2)
                    .onTapGesture { if long { toggle(entry.id) } }
                if !entry.attachments.isEmpty || editing {
                    HStack(spacing: Theme.Spacing.sm) {
                        if !entry.attachments.isEmpty {
                            Text("\(entry.attachments.count) attachment\(entry.attachments.count == 1 ? "" : "s")")
                        }
                        if editing {
                            Text("Editing in composer").foregroundStyle(Theme.midground)
                        }
                    }
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
                }
            }
        } trailing: {
            HStack(spacing: 0) {
                StatusRowButton(systemImage: Theme.Icon.rename, label: "Edit") { composer.edit(entry.id) }
                    .disabled(sender.editingID != nil && !editing)
                if busy, entry.isSteerable {
                    StatusRowButton(systemImage: "steeringwheel", label: "Steer — redirect the live turn now") {
                        Task { await sender.steerNow(entry.id) }
                    }
                    .disabled(editing)
                }
                StatusRowButton(systemImage: "arrow.turn.down.left", label: busy ? "Send next" : "Send") {
                    Task { await sender.sendNow(entry.id) }
                }
                .disabled(editing)
                StatusRowButton(systemImage: Theme.Icon.close, label: "Delete") { sender.remove(entry.id) }
            }
        }
    }

    private func toggle(_ id: UUID) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }

    static func preview(_ entry: SendController.QueuedPrompt) -> String {
        let text = (entry.display ?? entry.text).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return text }
        return entry.attachments.isEmpty ? "Empty turn" : "Attachment-only turn"
    }
}
