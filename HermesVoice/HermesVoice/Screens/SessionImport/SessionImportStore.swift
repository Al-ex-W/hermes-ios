import Foundation

/// The importer's state (`app/session-import/index.tsx`): the paged conversation list for the chosen source, a
/// preview per conversation, and the import itself. Previews and imports belong to the destination profile (whether
/// it already holds a copy), so changing it reads them again.
@MainActor
final class SessionImportStore: ObservableObject {
    enum Phase: Equatable {
        case loading
        case loaded
        case failed(String)
    }

    enum Preview: Equatable {
        case loading
        case loaded(SessionForeignPreviewResult)
        case failed(String)

        var result: SessionForeignPreviewResult? {
            if case let .loaded(result) = self { return result }
            return nil
        }
    }

    @Published private(set) var source = SessionImportSource.all
    @Published private(set) var rows: [ForeignSessionRow] = []
    @Published private(set) var phase = Phase.loading
    /// A list read is on its way (the rows already shown stay while a refresh reads them again).
    @Published private(set) var refreshing = false
    /// The machine the logs were read on (`socket.gethostname()` on the host).
    @Published private(set) var host: String?
    /// Logs skipped as empty, unreadable or too large, over the pages loaded.
    @Published private(set) var unreadable = 0
    @Published private(set) var nextOffset: Int?
    @Published private(set) var loadingMore = false
    @Published private(set) var previews: [String: Preview] = [:]
    /// The conversation being imported.
    @Published private(set) var importing: String?
    /// Why the last import failed, per conversation.
    @Published private(set) var importErrors: [String: String] = [:]
    /// The profile conversations go into; nil is the dashboard's own.
    @Published private(set) var destination: String?

    private let calls: ForeignSessionCalls
    /// Bumped on every new list, so an answer for an earlier source or refresh is dropped.
    private var generation = 0

    init(calls: ForeignSessionCalls, destination: String?) {
        self.calls = calls
        self.destination = destination
    }

    var hasMore: Bool { nextOffset != nil }

    func row(_ id: String) -> ForeignSessionRow? { rows.first { $0.id == id } }

    // MARK: List

    /// The first page for the current source (a refresh starts over).
    func load() async {
        generation += 1
        let generation = generation
        if rows.isEmpty { phase = .loading }
        refreshing = true
        loadingMore = false
        defer { if generation == self.generation { refreshing = false } }
        do {
            let page = try await calls.foreignList(source: source.foreign, offset: 0, profile: destination)
            guard generation == self.generation else { return }
            rows = SessionImportList.merge([], page.sessions ?? [])
            host = page.host.isEmpty ? nil : page.host
            unreadable = page.unreadable ?? 0
            nextOffset = page.nextOffset
            phase = .loaded
        } catch {
            guard generation == self.generation, !error.isCancellation else { return }
            rows = []
            nextOffset = nil
            unreadable = 0
            phase = .failed(error.localizedDescription)
        }
    }

    /// The next page, appended.
    func loadMore() async {
        guard let offset = nextOffset, !loadingMore, phase == .loaded else { return }
        let generation = generation
        loadingMore = true
        defer { if generation == self.generation { loadingMore = false } }
        do {
            let page = try await calls.foreignList(source: source.foreign, offset: offset, profile: destination)
            guard generation == self.generation else { return }
            rows = SessionImportList.merge(rows, page.sessions ?? [])
            unreadable += page.unreadable ?? 0
            nextOffset = page.nextOffset
        } catch {
            guard generation == self.generation, !error.isCancellation else { return }
            // The loaded pages stay; the button stays for another try.
            phase = .loaded
        }
    }

    /// Another source tab: the list starts over.
    func select(_ next: SessionImportSource) async {
        guard next != source else { return }
        source = next
        rows = []
        nextOffset = nil
        unreadable = 0
        await load()
    }

    /// Another destination profile: previews and import failures were about the old one.
    func setDestination(_ profile: String?) {
        guard profile != destination else { return }
        destination = profile
        previews = [:]
        importErrors = [:]
    }

    // MARK: Preview and import

    /// Reads a conversation's preview once; a failed one is read again when asked for again, and `force` reads it
    /// again whatever it holds.
    func loadPreview(_ id: String, force: Bool = false) async {
        if !force, let existing = previews[id], !isFailed(existing) { return }
        let profile = destination
        previews[id] = .loading
        do {
            let result = try await calls.foreignPreview(id: id, profile: profile)
            guard profile == destination else { return }
            previews[id] = .loaded(result)
        } catch {
            guard profile == destination, !error.isCancellation else { return }
            previews[id] = .failed(error.localizedDescription)
        }
    }

    private func isFailed(_ preview: Preview) -> Bool {
        if case .failed = preview { return true }
        return false
    }

    /// Imports the conversation (or finds the copy already made); the new session's id once done.
    func importSession(_ id: String) async -> SessionForeignImportResult? {
        guard importing == nil else { return nil }
        let profile = destination
        importing = id
        importErrors[id] = nil
        defer { importing = nil }
        do {
            let result = try await calls.foreignImport(id: id, profile: profile)
            // The next preview says it is in Hermes now.
            if case var .loaded(preview)? = previews[id] {
                preview.alreadyImported = result.sessionId
                previews[id] = .loaded(preview)
            }
            return result
        } catch {
            if !error.isCancellation { importErrors[id] = error.localizedDescription }
            return nil
        }
    }
}
