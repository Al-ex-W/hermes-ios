import SwiftUI

/// The subagent a detail sheet shows; `steering` opens it with the steer field focused.
struct AgentDetailTarget: Identifiable {
    let agent: AgentProgress
    var steering = false

    var id: String { "\(agent.ownerSession)|\(agent.id)" }
}

/// One live subagent up close (the desktop status stack's detail: `SubagentControls`, the row, and
/// `SubagentTranscript`): steer it, stop it (asks first), and read the newest 16 KB of its transcript, polled
/// every 2 s.
struct AgentDetailSheet: View {
    @ObservedObject var store: AgentsStore
    let target: AgentDetailTarget
    let openSession: (_ sessionID: String, _ profile: String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft = ""
    @State private var pending = false
    @State private var tail: SubagentTailResult?
    @State private var tailRead = false
    @State private var confirmation: CapabilityConfirmation?
    @FocusState private var steerFocused: Bool

    static let tailInterval: TimeInterval = 2

    /// The row as the store has it now (frames keep arriving while the sheet shows).
    private var agent: AgentProgress {
        store.roster.agents(in: target.agent.ownerSession).first { $0.id == target.agent.id } ?? target.agent
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TimelineView(.periodic(from: .now, by: agent.isLive ? 1 : 3600)) { timeline in
                        AgentRow(agent: agent, open: true, now: timeline.date)
                    }
                }
                .hermesFormRows()
                if agent.isLive { controls }
                transcript
            }
            .hermesForm()
            .navigationTitle("Subagent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                if let child = agent.childSessionID {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Open session") { openSession(child, store.profile(of: agent)) }
                    }
                }
            }
            .task(id: target.id) { await pollTail() }
            .onAppear { if target.steering { steerFocused = true } }
            .capabilityConfirmation($confirmation)
            .capabilityNotice($store.notice)
        }
    }

    private var controls: some View {
        Section {
            TextField("Instructions for this subagent", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .focused($steerFocused)
                .submitLabel(.send)
                .onSubmit(steer)
                .disabled(pending)
            HStack {
                Button("Steer", action: steer)
                    .disabled(pending || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Spacer()
                Button("Stop", role: .destructive) {
                    confirmation = Self.stopConfirmation(agent, store: store)
                }
                .disabled(pending)
            }
            .buttonStyle(.borderless)
        } footer: {
            FormNote("Steering is read at the subagent's next checkpoint.")
        }
        .hermesFormRows()
    }

    @ViewBuilder private var transcript: some View {
        Section {
            if let tail, tail.available == true {
                Text(tail.text ?? "")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.Text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(tailRead ? "Live transcript unavailable" : "Waiting for activity")
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        } header: {
            Text("Extended transcript")
        } footer: {
            if tail?.truncated == true { FormNote("Showing the latest 16 KiB") }
        }
        .hermesFormRows()
    }

    private func steer() {
        let text = draft
        guard !pending, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        pending = true
        Task {
            if await store.steer(agent, text) { draft = "" }
            pending = false
        }
    }

    /// Reads the transcript tail every 2 s while the sheet shows (a finished child has none).
    private func pollTail() async {
        while !Task.isCancelled {
            do {
                let result = try await store.tail(agent)
                if !Task.isCancelled { tail = result }
            } catch {
                guard !error.isCancellation else { return }
                tail = nil
            }
            tailRead = true
            try? await Task.sleep(nanoseconds: UInt64(Self.tailInterval * 1_000_000_000))
        }
    }

    /// Asks before interrupting a live child.
    static func stopConfirmation(_ agent: AgentProgress, store: AgentsStore) -> CapabilityConfirmation {
        CapabilityConfirmation(title: "Stop this subagent?",
                               message: "“\(AgentRoster.compact(agent.goal, max: 80))” is interrupted now; the turn that delegated it goes on without it.",
                               action: "Stop") {
            await store.interrupt(agent)
        }
    }
}
