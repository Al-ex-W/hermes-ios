import SwiftUI

/// A `delegate_task` fan-out as the agents it runs (`DelegateTool`): one bordered row per child with its goal,
/// model and time, and its latest activity under it; a child that reported its own session opens it. A call that
/// failed outright dispatched nothing, so it is the plain tool row that explains why.
struct DelegationCard: View {
    let delegation: Delegation
    @Environment(\.transcriptActions) private var actions

    var body: some View {
        if let call = delegation.call, call.done && call.status == .error || delegation.rows.isEmpty {
            ToolRow(call: call)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.toolRow) {
                ForEach(delegation.rows) { row in
                    if let child = row.childSessionID, let open = actions.openSession {
                        Button { open(child) } label: { DelegateRowView(row: row) }
                            .buttonStyle(.plain)
                            .accessibilityHint("Opens the agent's session")
                    } else {
                        DelegateRowView(row: row)
                    }
                }
            }
        }
    }
}

private struct DelegateRowView: View {
    let row: DelegateRow
    @State private var startedAt = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.sm) {
                glyph
                Text(row.goal)
                    .hermesText(.tool)
                    .foregroundStyle(Theme.Text.scaffold)
                    .lineLimit(1)
                if !meta.isEmpty {
                    Text(meta).hermesText(.meta).foregroundStyle(Theme.Text.scaffoldMeta).lineLimit(1)
                }
                Spacer(minLength: Theme.Spacing.xs)
                if row.status.isLive {
                    TranscriptElapsed(start: startedAt).hermesText(.meta).foregroundStyle(Theme.Text.scaffoldMeta).monospacedDigit()
                }
                Image(systemName: "person.2").font(.system(size: 9)).foregroundStyle(Theme.Text.scaffoldMeta)
            }
            if let activity = row.activity.last {
                Text(activity)
                    .hermesText(.tool)
                    .foregroundStyle(Theme.Text.scaffoldMeta)
                    .lineLimit(1)
                    .padding(.leading, Theme.IconSize.sm + Theme.Spacing.sm)
                    .id(activity)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: row.activity.last)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.md)
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.widget)
                .strokeBorder(Theme.Hairline.tertiary, lineWidth: Theme.hairlineWidth)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var glyph: some View {
        switch row.status {
        case .queued, .running:
            ScaffoldSpinner()
        case .failed, .interrupted:
            ScaffoldGlyph(symbol: Theme.Icon.error, color: Theme.Semantic.red)
        case .dispatched:
            // Parked, not watched: a spinner would claim a liveness nothing here can back up.
            Circle().fill(Theme.Text.tertiary).frame(width: 6, height: 6).frame(width: Theme.IconSize.sm, height: Theme.IconSize.sm)
        case .completed:
            ScaffoldGlyph(symbol: "checkmark.circle", color: Theme.Semantic.green)
        }
    }

    private var meta: String {
        var parts: [String] = []
        if let model = row.model, !model.isEmpty { parts.append(model.split(separator: "/").last.map(String.init) ?? model) }
        if !row.status.isLive, let duration = row.duration, duration > 0 { parts.append(ToolCall.formatDuration(duration)) }
        return parts.joined(separator: " · ")
    }
}
