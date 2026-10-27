import SwiftUI

// The board's pieces: column tones, the identity avatar, the card, and a column of cards.

enum KanbanTone {
    /// The desktop's column tones (`COLUMN_META`).
    static func color(_ column: String) -> Color {
        switch column {
        case "triage", "done": return Theme.Text.tertiary
        case "todo": return Theme.Text.secondary
        case "scheduled": return rgb(0xa7, 0x8b, 0xfa)
        case "ready": return rgb(0x60, 0xa5, 0xfa)
        case "running": return rgb(0x34, 0xd3, 0x99)
        case "blocked": return rgb(0xf8, 0x71, 0x71)
        case "review": return rgb(0xfb, 0xbf, 0x24)
        case "archived": return Theme.Text.quaternary
        default: return Theme.Text.secondary
        }
    }

    static func icon(_ column: String) -> String {
        switch column {
        case "triage": return "tray"
        case "todo": return "circle"
        case "scheduled": return "clock"
        case "ready": return "play.circle"
        case "running": return "arrow.triangle.2.circlepath"
        case "blocked": return "exclamationmark.circle"
        case "review": return "eye"
        case "done": return "checkmark.circle"
        case "archived": return "archivebox"
        default: return "circle"
        }
    }

    static func severity(_ severity: String?) -> Color {
        switch severity {
        case "critical", "error": return Theme.destructive
        default: return Theme.Semantic.attention
        }
    }

    private static func rgb(_ red: Double, _ green: Double, _ blue: Double) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255)
    }
}

/// A profile's initials on its identity hue; the default profile is neutral.
struct KanbanAvatar: View {
    let name: String
    var size: CGFloat = 18

    var body: some View {
        Text(Self.initials(name))
            .font(.system(size: size * 0.45, weight: .semibold))
            .foregroundStyle(hue ?? Theme.Text.secondary)
            .frame(width: size, height: size)
            .background((hue ?? Theme.Text.quaternary).opacity(0.22), in: Circle())
            .accessibilityHidden(true)
    }

    private var hue: Color? {
        guard !name.isEmpty, name != "default" else { return nil }
        let sum = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
        return Color(hue: Double(sum % 12) / 12, saturation: 0.55, brightness: 0.78)
    }

    static func initials(_ name: String) -> String {
        let parts = name.split(whereSeparator: { " _-./".contains($0) })
        let first = parts.first?.first.map(String.init) ?? "?"
        let second = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + second).uppercased()
    }
}

/// The amber up-arrow and number of a raised priority; a muted bare number at 0.
struct KanbanPriority: View {
    let priority: Int

    var body: some View {
        if priority > 0 {
            Label("\(priority)", systemImage: "arrow.up")
                .labelStyle(.titleAndIcon)
                .foregroundStyle(Theme.Semantic.attention)
        } else {
            Text("\(priority)").foregroundStyle(Theme.Text.quaternary)
        }
    }
}

/// "working · 3m" for a running card, ticking while it shows.
struct KanbanRunClock: View {
    let task: KanbanTask

    var body: some View {
        if let start = task.currentRunStartedAt ?? task.startedAt {
            TimelineView(.periodic(from: .now, by: 5)) { context in
                Text("working · \(KanbanFormat.compactElapsed(context.date.timeIntervalSince1970 - Double(start)))")
                    .fontWeight(.medium)
                    .foregroundStyle(KanbanTone.color("running"))
            }
        }
    }
}

/// One card (`Card` in `board.tsx`): badges, title, preview, and the footer of who is on it and what it carries.
struct KanbanCardView: View {
    let task: KanbanTask
    let tenants: [String]
    let defaultAssignee: String
    let orchestrator: String
    var selected = false

    var body: some View {
        let arc = KanbanArc.of(task, defaultAssignee: defaultAssignee)
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            badges
            Text(task.title.isEmpty ? task.id : task.title)
                .hermesText(.rowTitle)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            if let preview = task.preview {
                Text(preview)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
                    .lineLimit(2)
            }
            footer(arc)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? Theme.primary.opacity(0.08) : Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.icon))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.icon)
                .strokeBorder(selected ? Theme.ring : arcStroke(arc), lineWidth: selected || arc == .running || arc == .stale ? 1.5 : 1)
        }
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.icon, bottomLeadingRadius: Theme.Radius.icon)
                .fill(KanbanTone.color(task.status))
                .frame(width: 2.5)
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.icon))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(task.title.isEmpty ? task.id : task.title), \(KanbanColumns.label(task.status))")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func arcStroke(_ arc: KanbanArc?) -> Color {
        switch arc {
        case .running?: return KanbanTone.color("running").opacity(0.7)
        case .stale?: return Theme.Semantic.attention.opacity(0.8)
        default: return Theme.Hairline.tertiary
        }
    }

    @ViewBuilder private var badges: some View {
        let warning = task.warnings
        if task.tenant != nil || warning != nil || selected {
            HStack(spacing: Theme.Spacing.xs) {
                if let tenant = task.tenant { OpsPill(tenant) }
                if let warning {
                    Label("\(warning.count)", systemImage: Theme.Icon.warning)
                        .hermesText(.meta)
                        .foregroundStyle(KanbanTone.severity(warning.highestSeverity))
                        .accessibilityLabel("\(warning.count) diagnostics")
                }
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.primary)
                        .font(.system(size: Theme.IconSize.sm))
                }
            }
        }
    }

    private func footer(_ arc: KanbanArc?) -> some View {
        let unassignedReady = task.status == "ready" && task.assignee == nil
        let attached = task.assignee
            ?? (task.status == "ready" ? defaultAssignee : task.status == "triage" ? orchestrator : "")
        return HStack(spacing: Theme.Spacing.md) {
            if arc == .queued, !attached.isEmpty {
                HStack(spacing: Theme.Spacing.xs) {
                    KanbanAvatar(name: attached, size: 16)
                    Text((task.assignee == nil ? "→ " : "") + attached)
                        .fontWeight(.medium)
                        .lineLimit(1)
                }
                .foregroundStyle(KanbanTone.color(task.status))
            } else if let assignee = task.assignee {
                KanbanAvatar(name: assignee, size: 16)
            }
            if arc == .running { KanbanRunClock(task: task) }
            if arc == .stale {
                Text("no heartbeat").fontWeight(.medium).foregroundStyle(Theme.Semantic.attention)
            }
            if task.status == "blocked", let kind = task.blockKind {
                Label(kind, systemImage: "exclamationmark.octagon").foregroundStyle(Theme.destructive)
            }
            if unassignedReady, defaultAssignee.isEmpty {
                Label("won't run", systemImage: "bolt.slash").foregroundStyle(Theme.Semantic.attention)
            }
            Spacer(minLength: 0)
            if task.priority > 0 { KanbanPriority(priority: task.priority) }
            if let progress = task.progress {
                Label("\(progress.done)/\(progress.total)", systemImage: "checklist")
            }
            if task.commentCount > 0 { Label("\(task.commentCount)", systemImage: "bubble.left") }
            if task.linkCount > 0 { Label("\(task.linkCount)", systemImage: "link") }
            if task.assignee == nil, !unassignedReady, let created = KanbanFormat.ago(task.createdAt) {
                Text(created).foregroundStyle(Theme.Text.quaternary)
            }
            Text(task.shortID).monospaced().foregroundStyle(Theme.Text.quaternary)
        }
        .labelStyle(KanbanCompactLabel())
        .hermesText(.meta)
        .foregroundStyle(Theme.Text.tertiary)
        .lineLimit(1)
    }
}

/// Icon and title close together, as the card footer's meta reads.
struct KanbanCompactLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// A column header: tone dot, label, count.
struct KanbanColumnHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: Theme.Spacing.sm) {
            OpsDot(color: KanbanTone.color(name), size: 6)
            Text(KanbanColumns.label(name).uppercased())
                .hermesText(.label)
                .tracking(0.6)
                .foregroundStyle(Theme.Text.tertiary)
            Text("\(count)")
                .hermesText(.meta)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.quaternary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(KanbanColumns.help(name))
    }
}

/// What a card does when touched; supplied by the screen.
struct KanbanCardActions {
    var open: (KanbanTask) -> Void
    var toggleSelect: (KanbanTask) -> Void
    var move: (KanbanTask, String) -> Void
    var delete: (KanbanTask) -> Void
    var add: (String) -> Void
    /// Cards dropped on a column (ids as dragged).
    var drop: ([String], String) -> Bool
}

/// One column's cards in a vertical scroller (a page on iPhone, a lane on iPad), a drop target unless locked.
struct KanbanColumnView: View {
    @ObservedObject var store: KanbanStore
    let column: KanbanColumn
    let actions: KanbanCardActions
    var showsHeader = true
    var onCollapse: (() -> Void)?

    @State private var targeted = false

    private var locked: Bool { !store.workflow.isDropTarget(column.name) && column.name != KanbanColumns.archived }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                HStack {
                    KanbanColumnHeader(name: column.name, count: column.tasks.count)
                    Spacer(minLength: 0)
                    if let onCollapse {
                        Button(action: onCollapse) {
                            Image(systemName: "chevron.left").font(.system(size: Theme.IconSize.xs, weight: .semibold))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("Collapse \(KanbanColumns.label(column.name))")
                    }
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.bottom, Theme.Spacing.sm)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    if let lanes {
                        ForEach(lanes, id: \.assignee) { lane in
                            HStack(spacing: Theme.Spacing.xs) {
                                if lane.assignee != KanbanLanes.unassigned { KanbanAvatar(name: lane.assignee, size: 14) }
                                Text(lane.assignee)
                                Text("\(lane.tasks.count)").monospacedDigit()
                            }
                            .hermesText(.meta)
                            .foregroundStyle(Theme.Text.quaternary)
                            .padding(.top, Theme.Spacing.xs)
                            ForEach(lane.tasks) { card($0) }
                        }
                    } else {
                        ForEach(column.tasks) { card($0) }
                    }
                    if column.tasks.isEmpty {
                        Text("Empty")
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Text.quaternary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, Theme.Spacing.xxl)
                    }
                    if !locked, column.name != KanbanColumns.archived {
                        Button { actions.add(column.name) } label: {
                            Image(systemName: "plus")
                                .font(.system(size: Theme.IconSize.sm))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, Theme.Spacing.sm)
                                .overlay {
                                    RoundedRectangle(cornerRadius: Theme.Radius.icon)
                                        .strokeBorder(Theme.Hairline.secondary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                }
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.Text.tertiary)
                        .accessibilityLabel("New task in \(KanbanColumns.label(column.name))")
                    }
                }
                .padding(.horizontal, Theme.Spacing.xs)
                .padding(.bottom, 96)
            }
            .refreshable { await store.refresh() }
        }
        .padding(Theme.Spacing.sm)
        .background(targeted ? Theme.Fill.tertiary : Theme.Fill.quinary,
                    in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .dropDestination(for: String.self) { ids, _ in
            actions.drop(ids, column.name)
        } isTargeted: { over in
            targeted = over && !locked
        }
    }

    private var lanes: [(assignee: String, tasks: [KanbanTask])]? {
        guard store.lanesByProfile, column.name == "running", !column.tasks.isEmpty else { return nil }
        return KanbanBoard.lanes(column.tasks)
    }

    private func card(_ task: KanbanTask) -> some View {
        let selected = store.selected.contains(task.id)
        return KanbanCardView(task: task, tenants: store.board?.tenants ?? [], defaultAssignee: store.defaultAssignee,
                              orchestrator: store.orchestration?.resolvedOrchestratorProfile ?? "", selected: selected)
            .onTapGesture {
                if store.selecting { actions.toggleSelect(task) } else { actions.open(task) }
            }
            .draggable(task.id) {
                Text(task.title.isEmpty ? task.id : task.title)
                    .hermesText(.rowTitle)
                    .lineLimit(1)
                    .padding(Theme.Spacing.md)
                    .frame(width: 220, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.icon))
            }
            .contextMenu { menu(task, selected: selected) }
    }

    @ViewBuilder private func menu(_ task: KanbanTask, selected: Bool) -> some View {
        Button { actions.open(task) } label: { Label("Open", systemImage: "arrow.up.right.square") }
        Button { actions.toggleSelect(task) } label: {
            Label(selected ? "Deselect" : "Select", systemImage: selected ? "xmark" : "checkmark.circle")
        }
        let targets = store.targets(for: task)
        if !targets.isEmpty {
            Menu {
                ForEach(targets, id: \.self) { target in
                    Button { actions.move(task, target) } label: {
                        Label(KanbanColumns.label(target), systemImage: KanbanTone.icon(target))
                    }
                }
            } label: {
                Label("Move to", systemImage: "arrow.right")
            }
        }
        Divider()
        Button(role: .destructive) { actions.delete(task) } label: { Label("Delete", systemImage: Theme.Icon.delete) }
    }
}

/// A collapsed lane on iPad: a thin rail with the dot, the label sideways and the count. Still a drop target.
struct KanbanColumnRail: View {
    let column: KanbanColumn
    let expand: () -> Void
    let drop: ([String], String) -> Bool
    @State private var targeted = false

    var body: some View {
        Button(action: expand) {
            VStack(spacing: Theme.Spacing.sm) {
                OpsDot(color: KanbanTone.color(column.name), size: 6)
                    .padding(.top, Theme.Spacing.xs)
                Text(KanbanColumns.label(column.name).uppercased())
                    .hermesText(.label)
                    .tracking(0.6)
                    .foregroundStyle(Theme.Text.tertiary)
                    .fixedSize()
                    .rotationEffect(.degrees(90))
                    .frame(width: 20, height: 110)
                if !column.tasks.isEmpty {
                    Text("\(column.tasks.count)").hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                }
                Spacer(minLength: 0)
            }
            .frame(width: 36)
            .frame(maxHeight: .infinity)
            .padding(.vertical, Theme.Spacing.sm)
            .background(targeted ? Theme.Fill.tertiary : Theme.Fill.quinary,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Expand \(KanbanColumns.label(column.name))")
        .dropDestination(for: String.self) { ids, _ in drop(ids, column.name) } isTargeted: { targeted = $0 }
    }
}
