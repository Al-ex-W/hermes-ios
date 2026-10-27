import Foundation

/// One task's sheet state (`drawer.tsx`): the detail, the worker log tail, the home-channel toggles and the work in
/// flight. Every write reloads the detail and tells the board, which nudges the dispatcher.
@MainActor
final class KanbanTaskModel: ObservableObject {
    let store: KanbanStore
    let taskID: String

    @Published private(set) var detail: KanbanTaskDetail?
    @Published private(set) var loadError: String?
    @Published private(set) var log: KanbanWorkerLog?
    @Published private(set) var homeChannels: [KanbanHomeChannel] = []
    @Published private(set) var estimate: KanbanEstimate?
    @Published private(set) var inspections: [Int: KanbanRunInspect] = [:]
    @Published private(set) var modelProviders: [KanbanModelProvider]?
    /// Keys of the actions in flight ("comment", "upload", "specify", "home:telegram", …).
    @Published private(set) var busy: Set<String> = []
    /// The outcome of the last specify / decompose, shown inline.
    @Published var auxMessage: (ok: Bool, text: String)?
    @Published var notice: OpsNotice?
    @Published var failure: String?
    /// A downloaded attachment to preview; the file is removed when the preview closes.
    @Published var preview: URL?

    private var generation = 0

    init(store: KanbanStore, taskID: String) {
        self.store = store
        self.taskID = taskID
    }

    var api: KanbanAPI { store.api }
    var task: KanbanTask? { detail?.task }
    var running: Bool { task?.status == "running" }

    // MARK: Loading

    func load() async {
        async let detail: Void = reload()
        async let homes: Void = loadHomeChannels()
        _ = await (detail, homes)
    }

    func reload() async {
        generation += 1
        let mine = generation
        let api = self.api
        do {
            async let detail = api.task(taskID)
            async let log = try? api.log(taskID)
            let (value, tail) = try await (detail, log)
            guard mine == generation else { return }
            self.detail = value
            if let tail { self.log = tail }
            loadError = nil
        } catch {
            guard mine == generation, !error.isCancellation else { return }
            if detail == nil { loadError = error.dashboardMessage }
        }
    }

    func loadHomeChannels() async {
        if let rows = try? await api.homeChannels(task: taskID) { homeChannels = rows }
    }

    /// The worker log while it runs (the desktop polls it every few seconds).
    func pollLog() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(running ? 4 : 15))
            guard !Task.isCancelled else { return }
            if let tail = try? await api.log(taskID) { log = tail }
        }
    }

    func loadModelOptions() async {
        guard modelProviders == nil else { return }
        modelProviders = (try? await api.modelOptions()) ?? []
    }

    // MARK: Writes

    /// Runs one write under `key`, then reloads the detail and tells the board.
    @discardableResult
    private func write(_ key: String, _ action: () async throws -> Void) async -> Bool {
        guard !busy.contains(key) else { return false }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await action()
            await reload()
            store.didWrite(taskID)
            return true
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
            await reload()
            return false
        }
    }

    func isBusy(_ key: String) -> Bool { busy.contains(key) }

    func move(to status: String, summary: String? = nil) async {
        guard let task, task.status != status else { return }
        guard store.workflow.isDropTarget(status) || status == KanbanColumns.archived else {
            notice = OpsNotice(title: "Can’t move there", message: KanbanColumns.lockedReason(status))
            return
        }
        // Optimistic: the header shows the new column while the host decides.
        detail?.task.status = status
        await write("status") { try await api.patchTask(taskID, .move(to: status, summary: summary)) }
    }

    func saveBody(_ body: String) async {
        await write("body") { try await api.patchTask(taskID, KanbanTaskPatch(body: body)) }
    }

    func saveTitle(_ title: String) async -> Bool {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return await write("title") { try await api.patchTask(taskID, KanbanTaskPatch(title: trimmed)) }
    }

    func setPriority(_ priority: Int) async {
        await write("priority") { try await api.patchTask(taskID, KanbanTaskPatch(priority: priority)) }
    }

    func setModel(_ value: KanbanModelOverride) async {
        await write("model") { try await api.patchTask(taskID, KanbanTaskPatch(modelOverride: value)) }
    }

    /// Reassigns, reclaiming a running worker first (the explicit human recovery action; resets the failure streak).
    func reassign(_ profile: String?) async {
        await write("assignee") { try await api.reassign(taskID, profile: profile, reclaimFirst: true) }
    }

    func reclaim(reason: String? = nil) async {
        if await write("reclaim", { try await api.reclaim(taskID, reason: reason) }) {
            notice = OpsNotice(title: "Reclaimed", message: "\(KanbanTask.shortID(taskID)) is back in the queue.")
        }
    }

    func unblock() async {
        if await write("status", { try await api.patchTask(taskID, .move(to: "ready")) }) {
            notice = OpsNotice(title: "Unblocked \(KanbanTask.shortID(taskID))", message: "Task is ready for the next tick.")
        }
    }

    func comment(_ body: String) async -> Bool {
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        return await write("comment") { try await api.addComment(taskID, body: text) }
    }

    /// Posts the note, then reclaims, so the task restarts with the note in its context.
    func requeue(with note: String) async -> Bool {
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        let done = await write("comment") {
            try await api.addComment(taskID, body: text)
            try await api.reclaim(taskID)
        }
        if done { notice = OpsNotice(title: "Note posted — worker requeued") }
        return done
    }

    func addLink(parent: String, child: String) async {
        await write("links") { try await api.addLink(parent: parent, child: child) }
    }

    func removeLink(parent: String, child: String) async {
        await write("links") { try await api.removeLink(parent: parent, child: child) }
    }

    func upload(filename: String, contentType: String?, data: Data) async {
        await write("upload") {
            _ = try await api.uploadAttachment(task: taskID, filename: filename, contentType: contentType, data: data)
        }
    }

    func deleteAttachment(_ attachment: KanbanAttachment) async {
        await write("attachment:\(attachment.id)") { try await api.deleteAttachment(attachment.id) }
    }

    /// Downloads an attachment to a temporary file and previews it.
    func open(_ attachment: KanbanAttachment) async {
        let key = "download:\(attachment.id)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            let data = try await api.downloadAttachment(attachment.id)
            preview = try DashboardClient.temporaryFile(data, name: attachment.filename)
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
    }

    func toggleHome(_ channel: KanbanHomeChannel) async {
        let key = "home:\(channel.platform)"
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        let target = !channel.subscribed
        homeChannels = homeChannels.map { var row = $0; if row.platform == channel.platform { row.subscribed = target }; return row }
        do {
            try await api.setHomeSubscription(task: taskID, platform: channel.platform, subscribed: target)
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
        await loadHomeChannels()
    }

    func specify() async {
        guard !busy.contains("specify") else { return }
        busy.insert("specify")
        defer { busy.remove("specify") }
        do {
            let outcome = try await api.specify(taskID)
            auxMessage = outcome.ok
                ? (true, "Specified" + (outcome.newTitle.map { " — retitled: \($0)" } ?? ""))
                : (false, "Specify failed: \(outcome.reason ?? "unknown error")")
        } catch {
            if !error.isCancellation { auxMessage = (false, "Specify failed: \(error.dashboardMessage)") }
        }
        await reload()
        store.didWrite(taskID)
    }

    func decompose() async {
        guard !busy.contains("decompose") else { return }
        busy.insert("decompose")
        defer { busy.remove("decompose") }
        do {
            let outcome = try await api.decompose(taskID)
            if !outcome.ok {
                auxMessage = (false, "Decompose failed: \(outcome.reason ?? "unknown error")")
            } else if outcome.fanout, !outcome.childIDs.isEmpty {
                auxMessage = (true, "Decomposed into \(outcome.childIDs.count) children: \(outcome.childIDs.map(KanbanTask.shortID).joined(separator: ", "))")
            } else {
                auxMessage = (true, "Single task (no fanout)" + (outcome.newTitle.map { " — retitled: \($0)" } ?? ""))
            }
        } catch {
            if !error.isCancellation { auxMessage = (false, "Decompose failed: \(error.dashboardMessage)") }
        }
        await reload()
        store.didWrite(taskID)
    }

    /// A rough token and complexity estimate (an auxiliary-model call; asked for explicitly).
    func runEstimate() async {
        guard !busy.contains("estimate") else { return }
        busy.insert("estimate")
        defer { busy.remove("estimate") }
        do {
            let result = try await api.estimate(task: taskID)
            if result.ok { estimate = result } else { notice = OpsNotice(title: "Could not estimate", message: result.reason) }
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
        }
    }

    func inspect(_ run: KanbanRun) async {
        if let result = try? await api.inspectRun(run.id) { inspections[run.id] = result }
    }

    func terminate(_ run: KanbanRun) async {
        if await write("terminate:\(run.id)", { try await api.terminateRun(run.id, reason: "terminated from the phone") }) {
            notice = OpsNotice(title: "Run terminated", message: "The task returned to the queue.")
        }
    }

    func archive() async -> Bool {
        await write("archive") { try await api.patchTask(taskID, .move(to: KanbanColumns.archived)) }
    }

    func delete() async -> Bool {
        guard !busy.contains("delete") else { return false }
        busy.insert("delete")
        defer { busy.remove("delete") }
        do {
            try await api.deleteTask(taskID)
            store.didWrite(nil)
            return true
        } catch {
            if !error.isCancellation { failure = error.dashboardMessage }
            return false
        }
    }
}

// MARK: - Activity prose

/// A `task_events` row as an operator-readable line (`eventText` on the desktop): known kinds get prose with the
/// payload folded in, unknown kinds their name and compact `key=value` detail.
enum KanbanEventText {
    static func describe(_ event: KanbanEvent) -> (label: String, detail: String?) {
        let column = { (key: String) in event.string(key).map(KanbanColumns.label) }
        switch event.kind {
        case "created":
            var label = "created"
            if let where_ = column("status") { label += " in \(where_)" }
            if let assignee = event.string("assignee") { label += " · assigned to \(assignee)" }
            return (label, nil)
        case "status":
            let reason = event.string("reason")
            let detail = reason == "parent_reopened" ? "parent \(event.string("parent") ?? "") reopened" : reason
            return ("moved to \(column("status") ?? "?")", detail)
        case "assigned":
            return (event.string("assignee").map { "assigned to \($0)" } ?? "unassigned", nil)
        case "commented":
            return ("comment by \(event.string("author") ?? "someone")", nil)
        case "claimed":
            return (event.string("source_status") == "review" ? "claimed by a review agent" : "claimed by a worker", nil)
        case "spawned":
            return ("worker started", event.payload["pid"]?.intValue.map { "pid \($0)" })
        case "completed":
            return ("completed", nil)
        case "blocked":
            return ("blocked — needs human input", event.string("reason"))
        case "unblocked":
            return ("unblocked → \(column("status") ?? "Ready")", nil)
        case "reclaimed":
            return ("reclaimed — returned to the queue", event.string("reason"))
        case "specified":
            return ("spec written by the triage agent", nil)
        case "promoted":
            return ("dependencies done — promoted to Ready", nil)
        case "scheduled":
            return ("scheduled for later", event.string("reason"))
        case "archived":
            return ("archived", nil)
        case "reprioritized":
            return ("priority set to \(event.payload["priority"]?.intValue.map(String.init) ?? "?")", nil)
        case "completion_blocked_hallucination":
            return ("⚠ Completion blocked — phantom card ids", phantoms(event))
        case "suspected_hallucinated_references":
            return ("⚠ Prose referenced phantom card ids", phantoms(event))
        default:
            let detail = event.payload.sorted { $0.key < $1.key }.compactMap { key, value -> String? in
                switch value {
                case let .string(text): return text.isEmpty ? nil : "\(key)=\(text)"
                case let .int(number): return "\(key)=\(number)"
                case let .double(number): return "\(key)=\(number)"
                case let .bool(flag): return "\(key)=\(flag)"
                default: return nil
                }
            }.joined(separator: " ")
            return (event.kind.replacingOccurrences(of: "_", with: " "), detail.isEmpty ? event.rawPayload : detail)
        }
    }

    private static func phantoms(_ event: KanbanEvent) -> String? {
        let ids = (event.payload["phantom_cards"] ?? event.payload["phantom_refs"])?.arrayValue?.compactMap(\.stringValue) ?? []
        return ids.isEmpty ? nil : ids.joined(separator: ", ")
    }

    /// `latest_summary` holds the newest run summary; a dashboard move writes an administrative one there, hidden.
    static func isAdminSummary(_ summary: String) -> Bool {
        summary.range(of: #"^status changed to \w+ \(dashboard/direct\)$"#, options: .regularExpression) != nil
    }

    /// The block kind's explanation.
    static func blockKindHelp(_ kind: String) -> String {
        switch kind {
        case "needs_input": return "The worker asked for human input."
        case "capability": return "The worker hit a capability wall it cannot get past."
        case "transient": return "The worker failed on a transient error."
        default: return "The worker reported a dependency it must wait on."
        }
    }
}
