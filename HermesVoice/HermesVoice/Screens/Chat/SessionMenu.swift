import SwiftUI

/// The session a header menu acts on.
struct SessionMenuTarget: Equatable {
    var storedID: String
    /// The live session, when the chat is attached (rename and branch prefer it).
    var runtimeID: String?
    var title: String
    var profile: String?
    var pinned = false
    var unread = false
    var archived = false
    /// The session's workspace, so Move to project leaves out the project it is in.
    var cwd: String?
}

/// What the menu did, for the chat and the sidebar to follow.
enum SessionMenuEvent: Equatable {
    case renamed(String)
    case pinned(Bool)
    case unread(Bool)
    case archived(Bool)
    case deleted
    /// The conversation continues in a new session: open it.
    case branched(storedID: String, runtimeID: String, title: String)
    case moved(cwd: String)
}

/// A project a session can move into (`projects.list`), by its root folder.
struct SessionProject: Identifiable, Hashable {
    let id: String
    let name: String
    let root: String
}

/// The session actions of the desktop's `session-actions-menu.tsx`, over REST (`PATCH` / `DELETE
/// /api/sessions/:id`, the messages pages for export) and the gateway (`session.title`, `session.branch_whole` /
/// `session.branch` / `session.branch_stored`, `session.workspace.move`, `projects.list`).
@MainActor
struct SessionActions {
    let client: DashboardClient
    let connection: GatewayConnection

    private var gateway: GatewayClient { connection.client }

    /// Renames through `session.title` on the live session (it also persists a session Hermes hasn't stored yet);
    /// REST otherwise, and for clearing.
    func rename(_ target: SessionMenuTarget, to title: String) async throws -> String {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty, let runtimeID = target.runtimeID {
            do {
                return try await gateway.sessionTitle(.init(sessionId: runtimeID, profile: target.profile, title: title)).title
            } catch is GatewayDecodingError {
                return title
            } catch {
                // Mid-reconnect: REST still has the stored row.
            }
        }
        let result = try await patch(target, ["title": title]) as? JSON
        return result?["title"] as? String ?? title
    }

    func setPinned(_ target: SessionMenuTarget, _ pinned: Bool) async throws {
        _ = try await patch(target, ["pinned": pinned])
    }

    func setUnread(_ target: SessionMenuTarget, _ unread: Bool) async throws {
        _ = try await patch(target, ["unread": unread])
    }

    func setArchived(_ target: SessionMenuTarget, _ archived: Bool) async throws {
        _ = try await patch(target, ["archived": archived])
    }

    func delete(_ target: SessionMenuTarget) async throws {
        _ = try await client.request("DELETE", path(target), query: target.profile.map { ["profile": $0] } ?? [:])
    }

    /// The owning profile rides in the body: the dashboard opens that profile's store from it.
    private func patch(_ target: SessionMenuTarget, _ body: JSON) async throws -> Any {
        var body = body
        if let profile = target.profile { body["profile"] = profile }
        return try await client.request("PATCH", path(target), body: body)
    }

    private func path(_ target: SessionMenuTarget) -> String {
        "/api/sessions/\(target.storedID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? target.storedID)"
    }

    /// The whole conversation into a new session: from the live one (`session.branch_whole`, or `session.branch`
    /// on an older Hermes), else from the stored one (`session.branch_stored`).
    func branch(_ target: SessionMenuTarget) async throws -> SessionMenuEvent {
        let key = UUID().uuidString
        if let runtimeID = target.runtimeID {
            do {
                let result = try await gateway.sessionBranchWhole(.init(sessionId: runtimeID, profile: target.profile, idempotencyKey: key))
                return .branched(storedID: result.storedSessionId, runtimeID: result.sessionId, title: result.title)
            } catch let error as GatewayRPCError where error.code == -32601 {
                let result = try await Self.raw { try await gateway.sessionBranch(.init(sessionId: runtimeID, profile: target.profile, idempotencyKey: key)) }
                return try Self.branched(result)
            } catch let error as GatewayDecodingError {
                return try Self.branched(error.raw)
            }
        }
        do {
            let result = try await gateway.sessionBranchStored(.init(profile: target.profile, parentSessionId: target.storedID, cols: 96,
                                                                     source: "desktop", cwd: target.cwd, idempotencyKey: key))
            return .branched(storedID: result.storedSessionId, runtimeID: result.sessionId, title: target.title)
        } catch let error as GatewayDecodingError {
            return try Self.branched(error.raw)
        }
    }

    private static func raw<Result: Encodable>(_ call: () async throws -> Result) async throws -> JSONValue {
        do {
            return try JSONValue.encode(try await call())
        } catch let error as GatewayDecodingError {
            return error.raw
        }
    }

    private static func branched(_ raw: JSONValue) throws -> SessionMenuEvent {
        guard let runtimeID = raw["session_id"]?.stringValue, let storedID = raw["stored_session_id"]?.stringValue else {
            throw DashboardError.rpc("Hermes didn't open the branch.")
        }
        return .branched(storedID: storedID, runtimeID: runtimeID, title: raw["title"]?.stringValue ?? "")
    }

    /// Projects with a root folder, other than the one the session is in.
    func projects(for target: SessionMenuTarget) async -> [SessionProject] {
        guard let payload = try? await gateway.projectsList(.init(profile: target.profile)) else { return [] }
        let cwd = target.cwd.map(Self.normalized)
        return payload.projects.compactMap { project in
            guard project.archived != true else { return nil }
            let folders = project.folders ?? []
            let root = project.primaryPath ?? folders.first(where: { $0.isPrimary == true })?.path ?? folders.first?.path
            guard let root, !root.isEmpty else { return nil }
            if let cwd, cwd == Self.normalized(root) || cwd.hasPrefix(Self.normalized(root) + "/") { return nil }
            return SessionProject(id: project.id, name: project.name, root: root)
        }
    }

    private static func normalized(_ path: String) -> String {
        path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// Re-homes the session's workspace at the project's root.
    func move(_ target: SessionMenuTarget, to project: SessionProject) async throws -> String {
        do {
            return try await gateway.sessionWorkspaceMove(.init(profile: target.profile, sessionKey: target.storedID, cwd: project.root)).cwd
        } catch let error as GatewayDecodingError {
            return error.raw["cwd"]?.stringValue ?? project.root
        }
    }

    /// The transcript as JSON the way the desktop exports it, written to a temporary file to share.
    func export(_ target: SessionMenuTarget) async throws -> URL {
        var messages: [Any] = []
        var offset = 0
        let pageSize = 500
        var sessionID = target.storedID
        while true {
            var query = ["limit": "\(pageSize)", "offset": "\(offset)", "order": "oldest", "include_compacted": "true"]
            if let profile = target.profile { query["profile"] = profile }
            let page = try await client.request("GET", "\(path(target))/messages", query: query) as? JSON ?? [:]
            if let id = page["session_id"] as? String { sessionID = id }
            let rows = page["messages"] as? [Any] ?? []
            messages += rows
            let limit = (page["pagination"] as? JSON)?["limit"] as? Int
            guard let limit, !rows.isEmpty, rows.count >= limit else { break }
            offset += rows.count
        }
        let payload: JSON = [
            "exported_at": ISO8601DateFormatter().string(from: Date()),
            "session_id": sessionID,
            "title": target.title.isEmpty ? NSNull() : target.title,
            "session": NSNull(),
            "message_count": messages.count,
            "messages": messages,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(Self.filename(target))
        try data.write(to: url, options: .atomic)
        return url
    }

    /// `<title>-<id prefix>.json`, as the desktop names it.
    static func filename(_ target: SessionMenuTarget) -> String {
        func clean(_ value: String) -> String {
            let lowered = value.trimmingCharacters(in: .whitespaces).lowercased()
            let replaced = lowered.replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
            return String(replaced.trimmingCharacters(in: CharacterSet(charactersIn: "-")).prefix(48))
        }
        let title = clean(target.title)
        let id = String(clean(target.storedID).prefix(8))
        return "\(title.isEmpty ? "session" : title)-\(id.isEmpty ? "session" : id).json"
    }
}

/// The chat header's session menu: rename, pin, unread, move to project, branch, export, archive and delete.
struct SessionMenu: View {
    let target: SessionMenuTarget
    let actions: SessionActions
    var onEvent: (SessionMenuEvent) -> Void = { _ in }
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmingDelete = false
    @State private var projects: [SessionProject] = []
    @State private var exported: URL?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Menu {
            Button { newTitle = target.title; renaming = true } label: { Label("Rename…", systemImage: Theme.Icon.rename) }
            Button { run { try await actions.setPinned(target, !target.pinned); return .pinned(!target.pinned) } } label: {
                Label(target.pinned ? "Unpin" : "Pin", systemImage: target.pinned ? "pin.slash" : Theme.Icon.pin)
            }
            Button { run { try await actions.setUnread(target, !target.unread); return .unread(!target.unread) } } label: {
                Label(target.unread ? "Mark as read" : "Mark as unread",
                      systemImage: target.unread ? Theme.Icon.markRead : Theme.Icon.markUnread)
            }
            Menu {
                if projects.isEmpty {
                    Text("No other projects")
                } else {
                    ForEach(projects) { project in
                        Button(project.name) { run { .moved(cwd: try await actions.move(target, to: project)) } }
                    }
                }
            } label: {
                Label("Move to project", systemImage: "folder")
            }
            Button { run { try await actions.branch(target) } } label: { Label("Branch", systemImage: Theme.Icon.branch) }
            Button { export() } label: { Label("Export JSON", systemImage: Theme.Icon.export) }
            Divider()
            Button { run { try await actions.setArchived(target, !target.archived); return .archived(!target.archived) } } label: {
                Label(target.archived ? "Unarchive" : "Archive", systemImage: target.archived ? Theme.Icon.unarchive : Theme.Icon.archive)
            }
            Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete…", systemImage: Theme.Icon.delete) }
        } label: {
            Group {
                if working {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: Theme.Icon.more)
                }
            }
            .frame(width: 32, height: 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel("Session actions")
        .task(id: target.storedID) { projects = await actions.projects(for: target) }
        .alert("Rename session", isPresented: $renaming) {
            TextField("Title", text: $newTitle)
            Button("Rename") {
                let title = newTitle
                run { .renamed(try await actions.rename(target, to: title)) }
            }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete this session?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { run { try await actions.delete(target); return .deleted } }
        } message: {
            Text("“\(target.title.isEmpty ? "Untitled" : target.title)” and its messages are removed from Hermes. This can't be undone.")
        }
        .sheet(item: Binding(get: { exported.map(SharedFile.init) }, set: { if $0 == nil { exported = nil } })) { file in
            ShareSheet(items: [file.url])
                .presentationDetents([.medium, .large])
        }
        .alert("Hermes", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(failure ?? "")
        }
    }

    private func run(_ action: @escaping () async throws -> SessionMenuEvent) {
        Task {
            working = true
            defer { working = false }
            do {
                onEvent(try await action())
            } catch {
                if !error.isCancellation { failure = error.localizedDescription }
            }
        }
    }

    private func export() {
        Task {
            working = true
            defer { working = false }
            do {
                exported = try await actions.export(target)
            } catch {
                failure = "Couldn't export the session: \(error.localizedDescription)"
            }
        }
    }
}

private struct SharedFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// The system share sheet for an exported transcript.
private struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
