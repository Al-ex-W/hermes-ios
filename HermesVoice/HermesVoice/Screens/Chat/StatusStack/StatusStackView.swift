import SwiftUI

/// The card above the composer (the desktop's `ComposerStatusStack`): todos, live subagents, background processes,
/// the previous todo list once the live one retired, and the queue, grouped and divided by hairlines. Empty, it
/// takes no space.
struct StatusStackView: View {
    @ObservedObject var status: StatusStackModel
    @ObservedObject var composer: ComposerModel
    @ObservedObject var sender: SendController
    let busy: Bool
    @State private var openSubagent: String?
    @State private var steerDrafts: [String: String] = [:]
    @State private var openProcess: String?

    init(status: StatusStackModel, composer: ComposerModel, busy: Bool) {
        self.status = status
        self.composer = composer
        sender = composer.sender
        self.busy = busy
    }

    private var sections: [String] {
        var keys: [String] = []
        if !status.todos.isEmpty { keys.append("todo") }
        if !status.liveSubagents.isEmpty { keys.append("subagent") }
        if !status.processes.isEmpty { keys.append("background") }
        if !busy, status.todos.isEmpty, !status.previousTodos.isEmpty { keys.append("previous") }
        if !sender.queue.isEmpty { keys.append("queue") }
        return keys
    }

    var body: some View {
        let sections = sections
        Group {
            if !sections.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(sections.enumerated()), id: \.element) { index, key in
                            section(key)
                                .hermesHairline(edges: index == 0 ? [] : .top)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .background(Theme.card, in: UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.composer,
                                                                     topTrailingRadius: Theme.Radius.composer))
                .overlay {
                    UnevenRoundedRectangle(topLeadingRadius: Theme.Radius.composer, topTrailingRadius: Theme.Radius.composer)
                        .strokeBorder(Theme.Hairline.tertiary, lineWidth: Theme.hairlineWidth)
                }
                .padding(.horizontal, Theme.Spacing.md)
            }
        }
        .onAppear { status.startPolling() }
        .onDisappear { status.stopPolling() }
        .task { await status.refresh() }
        .alert("Hermes", isPresented: Binding(get: { status.notice != nil }, set: { if !$0 { status.notice = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(status.notice ?? "")
        }
    }

    @ViewBuilder
    private func section(_ key: String) -> some View {
        switch key {
        case "todo": todoSection
        case "subagent": subagentSection
        case "background": backgroundSection
        case "previous": previousSection
        default: QueuePanel(sender: sender, composer: composer, busy: busy)
        }
    }

    // MARK: Todos

    private var todoSection: some View {
        let done = status.todos.filter { $0.status == .completed }.count
        let running = status.todos.contains { $0.status == .inProgress }
        return StatusSection(icon: "checklist", label: "Tasks \(done)/\(status.todos.count)", running: running, expanded: true) {
            ForEach(status.todos) { todo in todoRow(todo, historical: false) }
        }
    }

    private var previousSection: some View {
        let done = status.previousTodos.filter { $0.status == .completed }.count
        return StatusSection(icon: "checklist", label: "Previous tasks \(done)/\(status.previousTodos.count)") {
            ForEach(status.previousTodos) { todo in todoRow(todo, historical: true) }
        }
    }

    private func todoRow(_ todo: StatusStackModel.Todo, historical: Bool) -> some View {
        StatusRow(depth: todo.depth) {
            switch todo.status {
            case .inProgress where !historical:
                ProgressView().controlSize(.mini)
            case .inProgress, .pending:
                Image(systemName: "circle").foregroundStyle(Theme.Text.quaternary)
            case .completed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Semantic.success)
            case .cancelled:
                Image(systemName: "xmark.circle").foregroundStyle(Theme.Text.quaternary)
            }
        } content: {
            Text(todo.content)
                .hermesText(.caption)
                .foregroundStyle(todo.status == .completed || todo.status == .cancelled ? Theme.Text.tertiary : Theme.Text.primary)
                .strikethrough(todo.status == .cancelled)
                .lineLimit(2)
        } trailing: {
            EmptyView()
        }
        .font(.system(size: Theme.IconSize.xs))
        .accessibilityElement(children: .combine)
        .accessibilityValue(todo.status.rawValue.replacingOccurrences(of: "_", with: " "))
    }

    // MARK: Subagents

    private var subagentSection: some View {
        let live = status.liveSubagents
        return StatusSection(icon: "person.2", tint: Theme.Semantic.purple,
                             label: "\(live.count) Subagent\(live.count == 1 ? "" : "s")", running: true) {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 0) {
                    ForEach(live) { agent in subagentRow(agent, now: context.date) }
                }
            }
        }
    }

    private func subagentRow(_ agent: StatusStackModel.Subagent, now: Date) -> some View {
        let open = openSubagent == agent.id
        return VStack(alignment: .leading, spacing: 0) {
            StatusRow(highlighted: open) {
                ProgressView().controlSize(.mini).tint(Theme.Semantic.purple)
            } content: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(agent.goal.isEmpty ? "Subagent" : agent.goal)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    Text(agent.activity ?? agent.lastTool ?? (agent.status == .queued ? "Queued" : "Waiting for activity…"))
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                }
            } trailing: {
                Text(Self.elapsed(now.timeIntervalSince(agent.startedAt)))
                    .hermesText(.meta)
                    .monospacedDigit()
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .contentShape(Rectangle())
            .onTapGesture { openSubagent = open ? nil : agent.id }
            if open { subagentControls(agent) }
        }
    }

    private func subagentControls(_ agent: StatusStackModel.Subagent) -> some View {
        let draft = Binding(get: { steerDrafts[agent.id] ?? "" }, set: { steerDrafts[agent.id] = $0 })
        return HStack(spacing: Theme.Spacing.sm) {
            TextField("Message this subagent", text: draft)
                .hermesText(.caption)
                .textFieldStyle(.roundedBorder)
                .submitLabel(.send)
                .onSubmit { steer(agent, draft.wrappedValue) }
            Button("Steer") { steer(agent, draft.wrappedValue) }
                .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Stop", role: .destructive) { Task { await status.interrupt(agent) } }
        }
        .hermesText(.button)
        .buttonStyle(.borderless)
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.vertical, Theme.Spacing.sm)
    }

    private func steer(_ agent: StatusStackModel.Subagent, _ text: String) {
        Task {
            if await status.steer(agent, text) { steerDrafts[agent.id] = "" }
        }
    }

    // MARK: Background processes

    private var backgroundSection: some View {
        StatusSection(icon: "gearshape.2", label: "\(status.processes.count) Background", running: status.hasRunningProcess) {
            ForEach(status.processes) { process in processRow(process) }
        }
    }

    private func processRow(_ process: StatusStackModel.Process) -> some View {
        let open = openProcess == process.id
        return VStack(alignment: .leading, spacing: 0) {
            StatusRow(highlighted: open) {
                switch process.state {
                case .running: ProgressView().controlSize(.mini)
                case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.Semantic.success)
                case .failed: Image(systemName: Theme.Icon.error).foregroundStyle(Theme.Semantic.red)
                }
            } content: {
                HStack(spacing: Theme.Spacing.sm) {
                    Text(process.title)
                        .hermesText(.code)
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(1)
                    if process.state == .failed, let code = process.exitCode {
                        Text("exit \(code)").hermesText(.meta).foregroundStyle(Theme.Semantic.red)
                    }
                }
            } trailing: {
                if process.state == .running {
                    StatusRowButton(systemImage: Theme.Icon.stop, label: "Stop", role: .destructive) {
                        Task { await status.kill(process) }
                    }
                } else {
                    StatusRowButton(systemImage: Theme.Icon.close, label: "Dismiss") { status.dismiss(process) }
                }
            }
            .font(.system(size: Theme.IconSize.xs))
            .contentShape(Rectangle())
            .onTapGesture { if process.output != nil { openProcess = open ? nil : process.id } }
            if open, let output = process.output {
                ScrollView {
                    Text(output)
                        .hermesText(.code)
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
                .padding(Theme.Spacing.md)
                .background(Theme.Fill.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
                .padding(.horizontal, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xs)
            }
        }
    }

    static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return total < 60 ? "\(total)s" : total < 3600 ? "\(total / 60)m \(total % 60)s" : "\(total / 3600)h \(total % 3600 / 60)m"
    }
}
