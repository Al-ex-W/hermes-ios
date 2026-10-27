import SwiftUI
import UIKit

/// The desktop's spawn tree (`app/agents/index.tsx`, the `/agents` overlay): every subagent the chats here
/// delegated to, live ones from every session and finished ones for the session the user is in, grouped by
/// delegation, with status, model, elapsed time, tools, tokens, the newest stream lines and the files they
/// touched. The desktop's per-child controls from the composer's status stack (steer, stop, the live transcript,
/// opening the child's session) are on each row's menu and swipe actions; stopping asks first.
struct AgentsScreen: View {
    /// What the screen needs from the shell.
    struct Context {
        /// The app-wide store (one per connection, made with the shell so it hears frames before this opens).
        let store: AgentsStore
        /// Opens a stored session (id, profile) in the detail column.
        let openSession: (_ sessionID: String, _ profile: String?) -> Void
    }

    let context: Context
    @ObservedObject private var store: AgentsStore
    @State private var expanded: [String: Bool] = [:]
    @State private var detail: AgentDetailTarget?
    @State private var confirmation: CapabilityConfirmation?

    init(context: Context) {
        self.context = context
        _store = ObservedObject(wrappedValue: context.store)
    }

    var body: some View {
        let tree = store.tree
        content(tree)
            .background(Theme.background)
            .navigationTitle("Spawn tree")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if store.refreshing {
                        ProgressView().accessibilityLabel("Refreshing agents")
                    } else {
                        Button { Task { await store.refresh(manual: true) } } label: { Image(systemName: Theme.Icon.retry) }
                            .accessibilityLabel("Refresh agents")
                    }
                }
            }
            .onAppear { store.startPolling() }
            .onDisappear { store.stopPolling() }
            .sheet(item: $detail) { target in
                AgentDetailSheet(store: store, target: target, openSession: open)
            }
            .capabilityConfirmation($confirmation)
            .capabilityNotice($store.notice)
    }

    @ViewBuilder private func content(_ tree: [AgentNode]) -> some View {
        if tree.isEmpty {
            ContentUnavailableView {
                Label("No live subagents", systemImage: AgentGlyph.symbol)
            } description: {
                Text("When a turn delegates work, child agents stream their progress here.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .refreshable { await store.refresh(manual: true) }
        } else {
            let summary = AgentTree.Summary(tree)
            // Ticks only while something runs: the elapsed timers and "updated" ages move with it.
            TimelineView(.periodic(from: .now, by: summary.active > 0 ? 1 : 3600)) { timeline in
                list(tree, summary: summary, now: timeline.date)
            }
        }
    }

    private func list(_ tree: [AgentNode], summary: AgentTree.Summary, now: Date) -> some View {
        List {
            Section {
                AgentSummaryLine(summary: summary)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } header: {
                FormNote("Live subagent activity for the current turn.")
            }
            ForEach(AgentTree.groups(tree)) { group in
                Section {
                    ForEach(AgentTree.rows(group.nodes)) { item in
                        row(item.node, depth: item.depth, now: now)
                    }
                } header: {
                    if !group.isSingle { AgentGroupHeader(group: group) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .refreshable { await store.refresh(manual: true) }
    }

    private func row(_ node: AgentNode, depth: Int, now: Date) -> some View {
        let agent = node.agent
        let isOpen = isExpanded(node, depth: depth)
        return AgentRow(agent: agent, depth: depth, open: isOpen, now: now)
            .contentShape(Rectangle())
            .onTapGesture { expanded[node.id] = !isOpen }
            .listRowInsets(EdgeInsets(top: Theme.Spacing.md, leading: Theme.Spacing.page + CGFloat(depth) * 16,
                                      bottom: Theme.Spacing.md, trailing: Theme.Spacing.page))
            .listRowBackground(Theme.background)
            .listRowSeparatorTint(Theme.Hairline.tertiary)
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if agent.isLive {
                    Button { askToStop(agent) } label: { Label("Stop", systemImage: Theme.Icon.stop) }
                        .tint(Theme.destructive)
                }
                if let child = agent.childSessionID {
                    Button { open(child, store.profile(of: agent)) } label: {
                        Label("Open session", systemImage: "bubble.left")
                    }
                    .tint(Theme.primary)
                }
            }
            .contextMenu { menu(agent) }
            .onChange(of: agent.isLive) { _, live in if live { expanded[node.id] = true } }
    }

    @ViewBuilder private func menu(_ agent: AgentProgress) -> some View {
        if let child = agent.childSessionID {
            Button { open(child, store.profile(of: agent)) } label: { Label("Open session", systemImage: "bubble.left") }
        }
        if let parent = store.parentStoredSession(of: agent) {
            Button { open(parent, store.profile(of: agent)) } label: {
                Label("Open parent chat", systemImage: "bubble.left.and.bubble.right")
            }
        }
        if agent.isLive {
            Button { detail = AgentDetailTarget(agent: agent, steering: false) } label: {
                Label("Live transcript", systemImage: "text.alignleft")
            }
            Button { detail = AgentDetailTarget(agent: agent, steering: true) } label: {
                Label("Steer", systemImage: "steeringwheel")
            }
        }
        Button { UIPasteboard.general.string = agent.goal } label: { Label("Copy goal", systemImage: Theme.Icon.copy) }
        if agent.isLive {
            Divider()
            Button(role: .destructive) { askToStop(agent) } label: { Label("Stop", systemImage: Theme.Icon.stop) }
        }
    }

    /// Open by default while running and for the first two levels (`SubagentRow`'s initial state).
    private func isExpanded(_ node: AgentNode, depth: Int) -> Bool {
        expanded[node.id] ?? (node.agent.isLive || depth < 2)
    }

    private func askToStop(_ agent: AgentProgress) {
        confirmation = AgentDetailSheet.stopConfirmation(agent, store: store)
    }

    private func open(_ sessionID: String, _ profile: String?) {
        detail = nil
        context.openSession(sessionID, profile)
    }
}

/// The counts line: agents, active, failed (tinted), tools, files, tokens, cost.
private struct AgentSummaryLine: View {
    let summary: AgentTree.Summary

    var body: some View {
        summary.parts.enumerated().reduce(Text("")) { line, item in
            let part = Text(item.element)
                .foregroundColor(item.element == summary.failedPart ? Theme.destructive : Theme.Text.tertiary)
            return item.offset == 0 ? part : line + Text(" · ").foregroundColor(Theme.Text.tertiary) + part
        }
        .hermesText(.meta)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// "DELEGATION 1 · 3 workers · 2 active".
private struct AgentGroupHeader: View {
    let group: AgentTree.Group

    var body: some View {
        let workers = Text("\(group.nodes.count) workers")
        let title = (group.index > 0 ? Text("Delegation \(group.index) ") : Text(""))
            + Text("· ").foregroundColor(Theme.Text.quaternary) + workers
        let active = group.activeWorkers
        (active > 0 ? title + Text(" · \(active) active").foregroundColor(Theme.primary) : title)
            .hermesText(.label)
            .textCase(.uppercase)
            .foregroundStyle(Theme.Text.tertiary)
    }
}

/// The status glyph of the chat's tool rows: a spinner while live, red when it failed or was interrupted, green
/// when done.
struct AgentGlyph: View {
    static let symbol = Theme.Icon.symbol(codicon: "hubot")
    let status: AgentStatus

    var body: some View {
        switch status {
        case .running, .queued:
            ProgressView()
                .controlSize(.mini)
                .frame(width: Theme.IconSize.sm, height: Theme.IconSize.sm)
                .accessibilityLabel(status == .queued ? "Queued" : "Running")
        case .failed, .interrupted:
            Image(systemName: Theme.Icon.error)
                .font(.system(size: Theme.IconSize.sm - 1))
                .foregroundStyle(Theme.destructive)
                .accessibilityLabel("Failed")
        case .completed:
            Image(systemName: "checkmark.circle")
                .font(.system(size: Theme.IconSize.sm - 1))
                .foregroundStyle(Theme.Semantic.success)
                .accessibilityLabel("Done")
        }
    }
}

/// One subagent (`SubagentRow`): goal, subtitle, a running timer, its newest stream lines (10 open, 2 closed)
/// and, open, the files it wrote (+) and read (·).
struct AgentRow: View {
    let agent: AgentProgress
    var depth = 0
    var open = true
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(alignment: .top, spacing: Theme.Spacing.md) {
                AgentGlyph(status: agent.status)
                    .frame(height: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(agent.goal)
                        .hermesText(.rowTitle)
                        .foregroundStyle(agent.isLive ? Theme.Text.secondary : Theme.Text.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    let subtitle = AgentFormat.subtitle(agent, now: now)
                    if !subtitle.isEmpty {
                        Text(subtitle)
                            .hermesText(.meta)
                            .foregroundStyle(Theme.Text.tertiary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if agent.isLive {
                    Text(TranscriptElapsed.format(agent.durationSeconds ?? now.timeIntervalSince(agent.startedAt)))
                        .hermesText(.meta)
                        .monospacedDigit()
                        .foregroundStyle(Theme.midground.opacity(0.7))
                        .padding(.top, 3)
                }
            }
            let lines = Array(agent.stream.suffix(open ? 10 : 2))
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, entry in
                        AgentStreamLine(entry: entry, active: agent.isLive && index == lines.count - 1)
                    }
                }
                .padding(.leading, Theme.IconSize.sm + Theme.Spacing.md)
                .textSelection(.enabled)
            }
            if open { files }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(open ? "Shows less" : "Shows more")
    }

    @ViewBuilder private var files: some View {
        let lines = agent.filesWritten.map { "+ \($0)" } + agent.filesRead.map { "· \($0)" }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                Text("Files")
                    .hermesText(.meta)
                    .textCase(.uppercase)
                    .foregroundStyle(Theme.Text.quaternary)
                ForEach(Array(lines.prefix(8).enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Text.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if lines.count > 8 {
                    Text("+\(lines.count - 8) more files")
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Theme.Text.quaternary)
                }
            }
            .padding(.leading, Theme.IconSize.sm + Theme.Spacing.md)
            .textSelection(.enabled)
        }
    }
}

/// One stream line: tools in mono with a dot, progress quiet, thinking with an ellipsis, the summary with a
/// check; errors in red without a glyph.
private struct AgentStreamLine: View {
    let entry: AgentStreamEntry
    let active: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            glyph.frame(width: 10, alignment: .center)
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(entry.text)
                    .font(entry.kind == .tool ? .system(size: 10.5, design: .monospaced) : .system(size: 11.5))
                    .foregroundStyle(color)
                    .fixedSize(horizontal: false, vertical: true)
                if active {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(width: 10, height: 10)
                        .accessibilityLabel("Streaming")
                }
            }
        }
    }

    @ViewBuilder private var glyph: some View {
        if entry.isError {
            Color.clear.frame(width: 4, height: 4)
        } else {
            switch entry.kind {
            case .tool: Circle().fill(Theme.Text.secondary.opacity(0.75)).frame(width: 5, height: 5)
            case .summary:
                Image(systemName: "checkmark.circle").font(.system(size: 9)).foregroundStyle(Theme.Semantic.success)
            case .thinking: Text("…").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.Text.tertiary)
            case .progress: Circle().fill(Theme.Text.tertiary).frame(width: 4, height: 4)
            }
        }
    }

    private var color: Color {
        if entry.isError { return Theme.destructive }
        switch entry.kind {
        case .progress: return Theme.Text.tertiary
        case .summary, .tool: return Theme.Text.secondary
        case .thinking: return Theme.Text.tertiary
        }
    }
}
