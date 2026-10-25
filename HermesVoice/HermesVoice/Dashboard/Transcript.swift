import Foundation

// MARK: - Rows

/// One row of a chat transcript, in the order the desktop draws a turn: the prompt, then what Hermes thought, said
/// and did. `Transcript` builds them; the views in `Screens/Chat/Transcript` draw each case.
enum TranscriptItem: Identifiable, Hashable {
    case user(UserMessage)
    /// Reply text as markdown; its `MEDIA:` tags are lifted into the `media` row right after it.
    case assistant(AssistantText)
    /// A thinking block, shown as "Thought for Xs".
    case reasoning(Reasoning)
    /// Consecutive tool calls. A call that is the point of the turn (a file edit, a spoken line, a question) is a
    /// run of its own.
    case toolRun(ToolRun)
    /// A `delegate_task` fan-out, or children seen only through `subagent.*` events.
    case subagent(Delegation)
    case system(SystemNote)
    /// A failed turn, labelled by the layer that failed, with what can be done about it.
    case error(TurnError)
    case media(MediaGroup)
    /// The files a turn edited, at its end.
    case changedFiles(ChangedFiles)

    var id: String {
        switch self {
        case let .user(item): return item.id
        case let .assistant(item): return item.id
        case let .reasoning(item): return item.id
        case let .toolRun(item): return item.id
        case let .subagent(item): return item.id
        case let .system(item): return item.id
        case let .error(item): return item.id
        case let .media(item): return item.id
        case let .changedFiles(item): return item.id
        }
    }

    var isUser: Bool {
        if case .user = self { return true }
        return false
    }
}

struct UserMessage: Hashable {
    let id: String
    /// What the user wrote, without the reference lines lifted into `attachments`.
    var text: String
    var attachments: [AttachmentRef] = []
    /// The stored `messages.id`; nil for a prompt not yet read back from Hermes.
    var rowID: Int?
    var timestamp: Date?

    /// A line said on a call (`[Voice] …`, `[Voice, cut off] …`) without the marker Hermes reads. Merged queue slots
    /// (prompts joined by blank lines) are shown as they are.
    var spoken: String? {
        guard text.hasPrefix("[Voice"), !text.contains("\n\n"),
              let close = text.firstIndex(of: "]"), text[...close].range(of: "^\\[Voice(, [^\\]]+)?\\]$", options: .regularExpression) != nil
        else { return nil }
        return String(text[text.index(after: close)...]).trimmingCharacters(in: .whitespaces)
    }
}

/// A `@kind:value` reference sent with a prompt: an attached file or image, a folder, a URL, …
struct AttachmentRef: Hashable {
    enum Kind: String, CaseIterable {
        case file, folder, url, image, tool, line, terminal, session
    }

    var kind: Kind
    /// The path, URL or id, unquoted.
    var value: String
    /// The reference as written.
    var ref: String

    /// The chip's text: a file's name, a URL's host and path, else the value.
    var label: String {
        switch kind {
        case .file, .folder, .image:
            let name = value.split(separator: "/").last.map(String.init) ?? value
            return name.isEmpty ? value : name
        case .url:
            guard let url = URL(string: value), let host = url.host else { return value }
            return url.path.count > 1 ? host + url.path : host
        default:
            return value
        }
    }

    /// The first `@kind:value` in `text` that is the whole of it, or nil.
    init?(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard let match = Self.pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.range == NSRange(text.startIndex..., in: text),
              let kindRange = Range(match.range(at: 1), in: text), let valueRange = Range(match.range(at: 2), in: text),
              let kind = Kind(rawValue: String(text[kindRange]))
        else { return nil }
        let raw = String(text[valueRange])
        self.kind = kind
        value = Self.unquoted(raw)
        ref = text
    }

    static let pattern = try! NSRegularExpression(
        pattern: "@(file|folder|url|image|tool|line|terminal|session):(`[^`\\n]+`|\"[^\"\\n]+\"|'[^'\\n]+'|\\S+)"
    )

    private static func unquoted(_ raw: String) -> String {
        guard raw.count >= 2, let first = raw.first, let last = raw.last, first == last, "`\"'".contains(first) else {
            return raw
        }
        return String(raw.dropFirst().dropLast())
    }
}

struct AssistantText: Hashable {
    let id: String
    /// What Hermes wrote, `MEDIA:` tags included.
    var source: String {
        didSet { (markdown, media) = MediaRef.split(source) }
    }
    /// `source` without its `MEDIA:` tags.
    private(set) var markdown: String
    private(set) var media: [MediaRef]
    /// Still being written.
    var streaming = false
    /// Commentary sealed beside tool calls (`message.interim`), not the turn's final reply.
    var interim = false
    var rowID: Int?

    init(id: String, source: String, streaming: Bool = false, interim: Bool = false, rowID: Int? = nil) {
        self.id = id
        self.source = source
        (markdown, media) = MediaRef.split(source)
        self.streaming = streaming
        self.interim = interim
        self.rowID = rowID
    }
}

struct Reasoning: Hashable {
    let id: String
    var text: String
    var streaming = false
    var startedAt: Date?
    /// How long it ran, when it was watched live; nil from history.
    var duration: TimeInterval?
}

struct ToolRun: Hashable {
    let id: String
    var calls: [ToolCall]
    /// The turn is still working and nothing has come after this run.
    var live = false
}

struct ToolCall: Hashable, Identifiable {
    /// Unique in the transcript (providers repeat call ids across turns).
    var id: String
    /// The call id Hermes sends.
    var callID: String
    var name: String
    var args: [String: JSONValue] = [:]
    /// The gateway's short description of the call (`context`, `preview`).
    var context: String?
    var result: JSONValue?
    /// The result as text, when the session is verbose (`result_text`).
    var resultText: String?
    var summary: String?
    var inlineDiff: String?
    var duration: Double?
    var startedAt: Date?
    var completedAt: Date?
    /// Finished, with a result or without one (the turn ended first, or its completion was lost).
    var done = false
    /// Stopped by the user before it finished.
    var interrupted = false
}

struct Delegation: Hashable {
    let id: String
    /// The `delegate_task` call; nil when only `subagent.*` events reported the children.
    var call: ToolCall?
    var rows: [DelegateRow]
}

/// One delegated child: what it was asked, how it is doing and its latest activity.
struct DelegateRow: Hashable, Identifiable {
    enum Status: Hashable {
        case queued, running, completed, failed, interrupted
        /// Running in the background, but nothing here watches it (the turn that spawned it is over).
        case dispatched

        var isLive: Bool { self == .queued || self == .running }
        var isTerminal: Bool { self == .completed || self == .failed || self == .interrupted }
    }

    let id: String
    var goal: String
    var status: Status
    var model: String?
    /// Relayed activity, oldest first (the last few lines).
    var activity: [String] = []
    var duration: Double?
    var subagentID: String?
    /// The child's own session, when it reported one.
    var childSessionID: String?
    var taskIndex: Int?
}

struct SystemNote: Hashable {
    enum Kind: Hashable {
        /// A line from Hermes about the session (model changed, interrupted turn resumed, …).
        case notice
        /// A slash command's output.
        case slash(command: String)
        /// A correction steered into the running turn.
        case steer
        /// Background work finished; `report` is its result.
        case background(report: String?, process: Bool)
        /// The self-improvement review saved something (`label`: what it was).
        case review(label: String)
        /// A voice call started or ended.
        case call
        /// The user stopped the reply.
        case stopped
        case warning
    }

    let id: String
    var kind: Kind
    var text: String
    var timestamp: Date?
}

struct TurnError: Hashable {
    /// `agent/error_surface.py` layers.
    enum Layer: String, CaseIterable {
        case provider, endpoint, streaming, auth, billing, gateway, runtime, disk
    }

    let id: String
    /// nil when Hermes didn't say (an older backend, or a failure outside a turn).
    var layer: Layer?
    /// The failure code (`failure_reason` or a gateway site code), when known.
    var code: String?
    /// What Hermes reported, for the details disclosure.
    var message: String
    var retryable = true
    var provider: String?
    var providerLabel: String?
    var model: String?
    /// How the failing provider signs in (`api_key` or `oauth`), for auth failures.
    var authKind: String?
    /// When the provider's rate limit lifts.
    var resetsAt: Date?
    var recovery: [ErrorRecovery] = []
}

/// What the error card offers (`errorRecoveryPlan` in `lib/error-surface.ts`).
enum ErrorRecovery: String, Hashable, CaseIterable {
    case retry
    case compress
    case chooseModel
    case switchProvider
    case editMessage
    case startNewSession
}

struct MediaGroup: Hashable {
    let id: String
    var media: [MediaRef]
}

/// A file Hermes delivered with `MEDIA:<path>`.
struct MediaRef: Hashable {
    enum Kind: Hashable { case image, audio, video, document, other }

    var path: String

    var name: String {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        return name.isEmpty ? path : name
    }

    var kind: Kind {
        switch (path as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "svg", "tiff": return .image
        case "mp3", "wav", "m4a", "ogg", "opus", "flac", "aac": return .audio
        case "mp4", "mov", "webm", "mkv", "avi", "m4v": return .video
        case "pdf", "doc", "docx", "txt", "md", "csv", "xls", "xlsx", "ppt", "pptx", "json", "html", "rtf", "zip": return .document
        default: return .other
        }
    }
}

struct ChangedFiles: Hashable {
    let id: String
    var files: [ChangedFile]
}

struct ChangedFile: Hashable, Identifiable {
    /// As the tool reported it (absolute or repo-relative).
    var path: String
    var added: Int
    var removed: Int
    /// Every edit's diff, in order.
    var diffs: [String]

    var id: String { path }
    var name: String { path.split(separator: "/").last.map(String.init) ?? path }
}

/// A turn Hermes runs (or kept after it failed) as `session.resume` / `session.activate` report it (`inflight`,
/// `queued`), for a transcript that saw none of it live.
struct LiveTurnSnapshot: Equatable {
    struct Correction: Equatable {
        var text: String
        /// How much of the reply had streamed when it arrived (unicode scalars); nil from an older Hermes.
        var offset: Int?
    }

    var prompt: String?
    /// Everything the turn streamed so far.
    var reply = ""
    var streaming = false
    var corrections: [Correction] = []
    var error: String?
    var errorSurface: ErrorSurface?
    /// The prompt queued for the next turn.
    var queued: String?
}

extension LiveTurnSnapshot {
    init(_ inflight: InflightTurn?, queued: String?) {
        let offsets = inflight?.correctionOffsets
        let corrections = (inflight?.corrections ?? []).enumerated().map { index, text in
            Correction(text: text, offset: offsets.flatMap { $0.indices.contains(index) ? $0[index] : nil })
        }
        let surface = inflight?.errorSurface.flatMap { try? JSONValue.object($0).decode(ErrorSurface.self) }
        self.init(prompt: inflight?.user, reply: inflight?.assistant ?? "", streaming: inflight?.streaming ?? false,
                  corrections: corrections, error: inflight?.error?.trimmed.nonEmpty, errorSurface: surface, queued: queued)
    }
}

struct TodoItem: Hashable, Identifiable {
    let id: String
    var content: String
    /// pending, in_progress, completed or cancelled.
    var status: String
}

// MARK: - Reducer

/// The chat transcript as rows to draw: a stored page from `/api/sessions/:id/messages`, then the live gateway
/// events, folded the way the desktop folds them (`lib/chat-messages/hydration.ts` and the `use-message-stream`
/// handlers). No I/O, and the clock is injectable.
struct Transcript {
    var items: [TranscriptItem] = []
    /// Prompts for the turn after the running one (a correction Hermes held as the next turn, the prompt it has
    /// queued): drawn after `items`, and moved into them when the running turn ends, so its rows stay above them.
    private(set) var nextPrompts: [UserMessage] = []
    /// A turn is streaming: started, and not yet completed, failed or reported idle.
    private(set) var turnRunning = false
    /// The tool whose arguments the model is writing (`tool.generating`), until anything else arrives.
    private(set) var draftingTool: String?
    /// The session's task list (`todo.updated`); todo calls themselves stay out of the transcript.
    private(set) var todos: [TodoItem] = []
    private(set) var usage: Usage?
    private(set) var title: String?
    /// The newest event seq applied (the connection already drops replays).
    private(set) var lastSeq: Int?
    var now: () -> Date = Date.init

    private var liveAssistantID: String?
    private var liveReasoningID: String?
    private var liveRunID: String?
    /// The turn's rows follow this one (the last row when it started, or the newest correction); nil with
    /// `turnAnchored`: the transcript start.
    private var turnAnchor: String?
    private var turnAnchored = false
    /// Where the running turn began, which a correction doesn't move: what a reload must keep starts after it.
    private var turnStartAnchor: String?
    private var turnStartAnchored = false
    private var todoRevision = Int.min
    private var serial = 0
    /// Todo and reaction calls in flight: they show only if they fail.
    private var hiddenCalls: [String: ToolCall] = [:]
    /// What the last correction sealed, so a refused one can be taken back.
    private var correctionSeal: (id: String, assistant: String?, reasoning: String?, run: String?, anchor: String?, anchored: Bool)?

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// The rows to draw: the transcript, then the prompts waiting for the next turn.
    var rows: [TranscriptItem] { items + nextPrompts.map(TranscriptItem.user) }

    // MARK: Stored history

    /// Replaces the rows with a stored page (oldest first; a newest-first page is turned around). Turn state is
    /// kept, so live events of a turn still running continue after it. The rows named in `kept` (ones the page
    /// can't hold yet: prompts Hermes may not have stored, the turn still running) follow the stored ones in their
    /// order, and a stream whose row is kept goes on in it.
    /// With `live`, the turn Hermes runs is drawn after the page as far as it streamed (`project`); the ids of the
    /// rows that made are returned.
    @discardableResult
    mutating func load(history: [JSONValue], keeping kept: Set<String> = [], projecting live: LiveTurnSnapshot? = nil,
                       key: String = "live") -> Set<String> {
        var carried = kept.isEmpty ? [] : items.filter { kept.contains($0.id) }
        let running = runningTurnIDs
        let corrected = turnAnchored && turnStartAnchor != turnAnchor ? turnAnchor : nil
        let streams = (assistant: liveAssistantID, reasoning: liveReasoningID, run: liveRunID, hidden: hiddenCalls)
        var rows = history.compactMap(\.objectValue)
        if let first = rows.first.flatMap(Self.rowID), let last = rows.last.flatMap(Self.rowID), first > last { rows.reverse() }
        items = []
        liveAssistantID = nil
        liveReasoningID = nil
        liveRunID = nil
        turnAnchored = false
        turnAnchor = nil
        turnStartAnchored = false
        turnStartAnchor = nil
        hiddenCalls = [:]
        var turnStart = 0
        for (index, row) in rows.enumerated() {
            let key = Self.rowID(row).map { "row-\($0)" } ?? "row-i\(index)"
            switch row["role"]?.stringValue {
            case "user":
                guard row["display_kind"]?.stringValue != "hidden" else { continue }
                let text = Self.text(row["display_content"] ?? row["content"])
                guard text.range(of: "^\\[Background process \\S+ heartbeat #\\d+ ", options: .regularExpression) == nil else { continue }
                endStoredTurn(from: turnStart)
                appendPrompt(Self.userText(text), id: key, rowID: Self.rowID(row), timestamp: Self.date(row["timestamp"]))
                turnStart = items.count
            case "tool":
                guard row["display_kind"]?.stringValue != "hidden" else { continue }
                storeResult(row, key: key, from: turnStart)
            case "assistant":
                guard row["display_kind"]?.stringValue != "hidden" else { continue }
                storeAssistant(row, key: key)
            case "system":
                storeNotice(row, key: key)
            default:
                continue
            }
        }
        if !turnRunning { endStoredTurn(from: turnStart) }
        let before = Set(items.map(\.id))
        if let live {
            project(live, key: key, streams: !(streams.assistant.map(kept.contains) ?? false))
        }
        let projected = Set(items.map(\.id)).subtracting(before)
        let projectedStream = liveAssistantID
        guard !carried.isEmpty else { return projected }
        // Hermes saves a running turn's tool rounds as they finish, so the page may hold rows kept from the live
        // turn already: its copy takes their live state, and the live copy goes.
        if turnRunning { carried = merge(carried, intoStoredFrom: Self.storedTurnStart(items)) }
        let stored = Set(items.map(\.id))
        items += carried.filter { !stored.contains($0.id) }
        let present = Set(items.map(\.id))
        liveAssistantID = streams.assistant.flatMap { kept.contains($0) && present.contains($0) ? $0 : nil } ?? projectedStream
        liveReasoningID = streams.reasoning.flatMap { kept.contains($0) && present.contains($0) ? $0 : nil }
        liveRunID = streams.run.flatMap { kept.contains($0) && present.contains($0) ? $0 : nil }
        guard turnRunning else { return projected }
        hiddenCalls = streams.hidden
        // What is kept of the running turn follows its stored part, and a correction kept in it still leads what
        // the turn writes next.
        if !turnStartAnchored, let first = items.firstIndex(where: { running.contains($0.id) }) {
            turnStartAnchored = true
            turnStartAnchor = first > 0 ? items[first - 1].id : nil
        }
        if let corrected, present.contains(corrected) {
            turnAnchored = true
            turnAnchor = corrected
        }
        return projected
    }

    /// Draws a turn this transcript didn't watch from its snapshot (the desktop's `appendLiveSessionProjection`):
    /// its prompt unless the page holds it, the reply so far after what the page already holds of it, split at the
    /// corrections steered into it, a failure Hermes kept, and the prompt queued after it. `streams`: the reply's
    /// last part is still being written here, so later deltas go on in it.
    private mutating func project(_ live: LiveTurnSnapshot, key: String, streams: Bool) {
        let start = Self.storedTurnStart(items)
        let prompts = items[min(start, items.count)...].compactMap { item -> String? in
            if case let .user(message) = item { return Self.normalized(message.text) }
            return nil
        }
        func stored(_ text: String) -> Bool { prompts.contains(Self.normalized(Self.userText(text).text)) }
        let promptStored = live.prompt.map(stored) ?? true
        if let prompt = live.prompt, !promptStored {
            appendPrompt(Self.userText(prompt), id: "\(key)-prompt", rowID: nil, timestamp: now())
        }
        let turnStart = promptStored ? (items.indices.contains(start) ? items[start].id : items.last?.id) : items.last?.id
        // What the page holds of the reply (commentary saved with each tool round) isn't drawn twice.
        let reply = live.reply
        var cursor = reply.startIndex
        if promptStored {
            for case let .assistant(text) in items[min(start, items.count)...] {
                let saved = text.source.trimmed
                guard !saved.isEmpty, let range = reply.range(of: saved, range: cursor..<reply.endIndex),
                      reply[cursor..<range.lowerBound].allSatisfy(\.isWhitespace) else { break }
                cursor = range.upperBound
            }
        }
        var lastCorrection: String?
        func correct(_ correction: LiveTurnSnapshot.Correction, _ index: Int) {
            guard !stored(correction.text), !items.contains(where: { $0.id == "\(key)-correction-\(index)" }) else { return }
            appendPrompt(Self.userText(correction.text), id: "\(key)-correction-\(index)", rowID: nil, timestamp: now())
            lastCorrection = "\(key)-correction-\(index)"
        }
        let placed = !live.corrections.isEmpty && live.corrections.allSatisfy { $0.offset != nil } && live.error == nil
        if placed {
            for (index, correction) in live.corrections.enumerated() {
                let scalars = reply.unicodeScalars
                let boundary = scalars.index(scalars.startIndex, offsetBy: min(correction.offset ?? 0, scalars.count))
                if boundary > cursor {
                    let segment = String(reply[cursor..<boundary])
                    if !segment.trimmed.isEmpty {
                        items.append(.assistant(AssistantText(id: "\(key)-segment-\(index)", source: segment.trimmed, interim: true)))
                        syncMedia("\(key)-segment-\(index)")
                    }
                    cursor = boundary
                }
                correct(correction, index)
            }
        }
        // Only leading space goes: the next delta may start mid-word.
        let tail = String(reply[cursor...].drop(while: \.isWhitespace))
        let running = live.streaming && live.error == nil
        if !tail.trimmed.isEmpty {
            let id = "\(key)-reply"
            items.append(.assistant(AssistantText(id: id, source: running && streams ? tail : tail.trimmed,
                                                  streaming: running && streams)))
            syncMedia(id)
            if running && streams { liveAssistantID = id }
        }
        if !placed { for (index, correction) in live.corrections.enumerated() { correct(correction, index) } }
        // The page may hold the failure's card already (its failed-turn row).
        if let error = live.error, !items[min(start, items.count)...].contains(where: { if case .error = $0 { return true }; return false }) {
            appendError(Self.turnError(message: error, surface: live.errorSurface, id: "\(key)-error"))
        }
        guard running || turnRunning else { return }
        turnRunning = true
        turnStartAnchored = true
        turnStartAnchor = turnStart
        turnAnchored = true
        turnAnchor = lastCorrection ?? turnStart
        if let queued = live.queued { appendNextPrompt(queued, id: "\(key)-queued") }
    }

    /// The rows of the turn still running, which no stored page holds yet: everything after where it began,
    /// corrections and what streamed before them included.
    var runningTurnIDs: Set<String> {
        guard turnRunning else { return [] }
        return Set(items[min(turnStartIndex, items.count)...].map(\.id))
    }

    /// Where the newest stored turn starts in `items`: at its prompt. A user row right after tool work is a
    /// correction Hermes saved inside the turn, not the start of one (unless that work was stopped).
    private static func storedTurnStart(_ items: [TranscriptItem]) -> Int {
        var index = items.count - 1
        while index >= 0 {
            if items[index].isUser {
                let previous = items[..<index].last { item in
                    switch item {
                    case .media, .changedFiles: return false
                    case let .system(note): return note.kind == .stopped
                    default: return true
                    }
                }
                switch previous {
                case .toolRun?, .subagent?: break
                default: return index
                }
            }
            index -= 1
        }
        return 0
    }

    /// Folds kept live rows into the stored rows of the running turn (from `start`): a call the page holds takes
    /// the live call's state, a sealed text or thinking block it holds is dropped, and a live delegation replaces
    /// its stored card. Returns what is left to keep.
    private mutating func merge(_ live: [TranscriptItem], intoStoredFrom start: Int) -> [TranscriptItem] {
        var calls: [String: CallLocation] = [:]
        // How often the page holds each text, so a live copy only stands for one saved copy.
        var texts: [String: Int] = [:]
        var thoughts: [String: Int] = [:]
        for index in items.indices where index >= start {
            switch items[index] {
            case let .toolRun(run):
                for (position, call) in run.calls.enumerated() { calls[call.callID] = .run(item: index, call: position) }
            case let .subagent(delegation):
                if let call = delegation.call { calls[call.callID] = .delegation(item: index) }
            case let .assistant(text):
                texts[Self.normalized(text.source), default: 0] += 1
            case let .reasoning(reasoning):
                thoughts[Self.normalized(reasoning.text), default: 0] += 1
            default:
                break
            }
        }
        func saved(_ text: String, in counts: inout [String: Int]) -> Bool {
            let key = Self.normalized(text)
            guard let count = counts[key], count > 0 else { return false }
            counts[key] = count - 1
            return true
        }
        var dropped: Set<String> = []
        var left: [TranscriptItem] = []
        for item in live {
            switch item {
            case var .toolRun(run):
                run.calls = run.calls.filter { call in
                    guard let location = calls[call.callID], case .run = location else { return true }
                    modifyCall(location) { Self.adopt(call, into: &$0) }
                    return false
                }
                if run.calls.isEmpty {
                    dropped.insert(run.id)
                } else {
                    left.append(.toolRun(run))
                }
            case let .subagent(delegation):
                if let call = delegation.call, case let .delegation(index)? = calls[call.callID] {
                    items[index] = .subagent(delegation)
                    continue
                }
                left.append(item)
            case let .assistant(text) where !text.streaming && saved(text.source, in: &texts):
                dropped.insert(text.id)
            case let .reasoning(reasoning) where !reasoning.streaming && saved(reasoning.text, in: &thoughts):
                dropped.insert(reasoning.id)
            case let .media(group) where dropped.contains(String(group.id.dropLast("-media".count))):
                continue
            default:
                left.append(item)
            }
        }
        return left
    }

    /// A stored call takes what the live copy knows beyond it.
    private static func adopt(_ live: ToolCall, into stored: inout ToolCall) {
        stored.args.merge(live.args) { old, _ in old }
        stored.context = stored.context ?? live.context
        stored.result = stored.result ?? live.result
        stored.resultText = stored.resultText ?? live.resultText
        stored.summary = stored.summary ?? live.summary
        stored.inlineDiff = stored.inlineDiff ?? live.inlineDiff
        stored.duration = stored.duration ?? live.duration
        stored.startedAt = live.startedAt ?? stored.startedAt
        stored.completedAt = stored.completedAt ?? live.completedAt
        stored.done = stored.done || live.done
        stored.interrupted = live.interrupted
    }

    private mutating func storeAssistant(_ row: [String: JSONValue], key: String) {
        let kind = row["display_kind"]?.stringValue
        let timestamp = Self.date(row["timestamp"])
        if kind.map(Self.noticeKinds.contains) == true {
            if kind == "failed_turn", let error = Self.storedError(row["display_metadata"], id: "\(key)-error") {
                items.append(.error(error))
            }
            return storeNotice(row, key: key)
        }
        let reasoning = row["display_reasoning"]?.stringValue ?? row["reasoning"]?.stringValue
            ?? row["reasoning_content"]?.stringValue ?? Self.reasoningText(row["reasoning_details"])
        if let reasoning, !reasoning.trimmed.isEmpty {
            items.append(.reasoning(Reasoning(id: "\(key)-reasoning", text: reasoning)))
        }
        let reply = Self.text(row["display_content"] ?? row["content"]).trimmed
        let commentary = (row["display_commentary"]?.arrayValue ?? []).compactMap(\.stringValue).filter { !$0.trimmed.isEmpty }
        if !commentary.isEmpty, Self.normalized(commentary.joined(separator: "\n\n")) != Self.normalized(reply) {
            for (index, text) in commentary.enumerated() {
                items.append(.assistant(AssistantText(id: "\(key)-c\(index)", source: text, interim: true)))
            }
        }
        if !reply.isEmpty {
            let text = AssistantText(id: key, source: reply, rowID: Self.rowID(row))
            items.append(.assistant(text))
            if !text.media.isEmpty { items.append(.media(MediaGroup(id: "\(key)-media", media: text.media))) }
        }
        for (index, raw) in (row["tool_calls"]?.arrayValue ?? []).enumerated() {
            let call = Self.object(raw)
            let function = Self.object(call["function"])
            let callID = call["id"]?.stringValue ?? call["tool_call_id"]?.stringValue ?? "\(key)-call-\(index)"
            let name = call["name"]?.stringValue ?? function["name"]?.stringValue ?? "tool"
            var args = Self.object(function["arguments"])
            if args.isEmpty { args = Self.object(call["arguments"] ?? call["args"]) }
            insert(ToolCall(id: uniqueCallID(callID), callID: callID, name: name, args: args, startedAt: timestamp),
                   runID: "\(key)-run-\(index)")
        }
        if Self.object(row["display_metadata"])["interrupted"]?.boolValue == true {
            items.append(.system(SystemNote(id: "\(key)-stopped", kind: .stopped, text: "Response stopped")))
        }
    }

    /// A stored tool result: completes its call, or stands alone when the page holds no call for it.
    private mutating func storeResult(_ row: [String: JSONValue], key: String, from turnStart: Int) {
        let callID = row["tool_call_id"]?.stringValue
        let name = row["tool_name"]?.stringValue ?? row["name"]?.stringValue ?? "tool"
        let diff = Self.object(Self.object(row["display_metadata"])["tool_result_metadata"])["inline_diff"]?.stringValue
        let timestamp = Self.date(row["timestamp"])
        let result = Self.storedResult(row["content"])
        func fill(_ call: inout ToolCall) {
            call.result = result
            call.inlineDiff = diff ?? call.inlineDiff
            call.done = true
            call.completedAt = timestamp
        }
        if let location = openCall(callID ?? "", name: callID == nil ? name : nil, from: turnStart) {
            return modifyCall(location, fill)
        }
        var call = ToolCall(id: uniqueCallID(callID ?? key), callID: callID ?? key, name: name,
                            args: Self.object(row["args"]), startedAt: timestamp)
        let context = Self.text(row["context"]).trimmed
        if !context.isEmpty { call.context = context }
        fill(&call)
        guard !ToolCall.hiddenTools.contains(name) || call.failed else { return }
        insert(call, runID: "\(key)-run")
    }

    private mutating func storeNotice(_ row: [String: JSONValue], key: String) {
        let kind = row["display_kind"]?.stringValue
        let metadata = Self.object(row["display_metadata"])
        let content = Self.text(row["display_content"] ?? row["content"]).trimmed
        let displayText = metadata["display_text"]?.stringValue.flatMap { $0.trimmed.isEmpty ? nil : $0 }
        let note: SystemNote
        switch kind {
        case "model_switch":
            note = SystemNote(id: key, kind: .notice, text: "model changed")
        case "auto_continue":
            note = SystemNote(id: key, kind: .notice, text: "resumed interrupted turn")
        case "personality_switch":
            note = SystemNote(id: key, kind: .notice, text: "personality changed")
        case "async_delegation_complete":
            let count = metadata["task_count"]?.intValue
            let label = displayText ?? count.map { "\($0) background agent\($0 == 1 ? "" : "s") finished" } ?? "background agent work finished"
            note = SystemNote(id: key, kind: .background(report: Self.asyncResult(Self.text(row["content"])), process: false), text: label)
        case "process_complete":
            note = SystemNote(id: key, kind: .background(report: Self.asyncResult(Self.text(row["content"])), process: true),
                              text: displayText ?? "background process finished")
        default:
            guard !content.isEmpty else { return }
            note = SystemNote(id: key, kind: .notice, text: content)
        }
        var stamped = note
        stamped.timestamp = Self.date(row["timestamp"])
        items.append(.system(stamped))
    }

    /// A stored turn is over: calls left without a result are settled, and its edits are summed up.
    private mutating func endStoredTurn(from start: Int) {
        sealOpenCalls(from: start, interrupted: false)
        appendChangedFiles(from: start, id: "files-\(items[safe: start - 1]?.id ?? "start")")
    }

    // MARK: Local rows

    /// Adds a prompt the user just sent, before Hermes stores it: reference lines become chips, as they will when
    /// the stored copy is read back. Returns the row id.
    @discardableResult
    mutating func appendUser(_ text: String, id: String? = nil) -> String {
        let id = id ?? nextID("user")
        appendPrompt(Self.userText(text), id: id, rowID: nil, timestamp: now())
        return id
    }

    /// A slash command's output (`slash:` rows on the desktop).
    mutating func appendSlashOutput(command: String, output: String) {
        items.append(.system(SystemNote(id: nextID("slash"), kind: .slash(command: command), text: output.trimmed, timestamp: now())))
    }

    /// A correction redirecting the running turn, shown as the user's message (Hermes stores it as one): what
    /// streamed so far stays above it, and what the turn writes next follows it. Returns the row id.
    @discardableResult
    mutating func appendCorrection(_ text: String, id: String? = nil) -> String {
        let id = id ?? nextID("user")
        correctionSeal = (id, liveAssistantID, liveReasoningID, liveRunID, turnAnchor, turnAnchored)
        sealStreams()
        settleRun()
        appendPrompt(Self.userText(text), id: id, rowID: nil, timestamp: now())
        if turnRunning {
            turnAnchored = true
            turnAnchor = id
        }
        return id
    }

    /// Takes back a correction the turn refused. When nothing followed it, what it sealed streams on.
    mutating func withdrawCorrection(_ id: String) {
        let wasLast = items.last?.id == id
        remove(id: id)
        guard let seal = correctionSeal, seal.id == id else { return }
        correctionSeal = nil
        guard wasLast, turnRunning else { return }
        turnAnchor = seal.anchor
        turnAnchored = seal.anchored
        if let assistant = seal.assistant, modifyAssistant(assistant, { $0.streaming = true }) { liveAssistantID = assistant }
        if let reasoning = seal.reasoning, modifyReasoning(reasoning, { $0.streaming = true; $0.duration = nil }) {
            liveReasoningID = reasoning
        }
        if let run = seal.run, let index = items.lastIndex(where: { $0.id == run }), case var .toolRun(item) = items[index] {
            item.live = true
            items[index] = .toolRun(item)
            liveRunID = run
        }
    }

    /// A correction steered into the running turn.
    mutating func appendSteer(_ text: String) {
        items.append(.system(SystemNote(id: nextID("steer"), kind: .steer, text: text.trimmed, timestamp: now())))
    }

    mutating func appendNotice(_ text: String) {
        items.append(.system(SystemNote(id: nextID("notice"), kind: .notice, text: text.trimmed, timestamp: now())))
    }

    mutating func remove(id: String) {
        items.removeAll { $0.id == id }
        nextPrompts.removeAll { $0.id == id }
    }

    /// A prompt for the turn after the running one (Hermes queued it): drawn below the running turn, which keeps
    /// streaming above it. With no turn running it is an ordinary prompt row.
    mutating func appendNextPrompt(_ text: String, id: String) {
        let projected = Self.userText(text)
        guard turnRunning else { return appendPrompt(projected, id: id, rowID: nil, timestamp: now()) }
        guard !projected.text.isEmpty || !projected.refs.isEmpty, !nextPrompts.contains(where: { $0.id == id }) else { return }
        nextPrompts.append(UserMessage(id: id, text: projected.text, attachments: projected.refs, timestamp: now()))
    }

    /// Drops the row `id` and everything after it (a rewind re-runs the conversation from there). No turn runs
    /// once it is cut.
    mutating func truncate(from id: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items.removeSubrange(index...)
        nextPrompts = []
        liveAssistantID = nil
        liveReasoningID = nil
        liveRunID = nil
        hiddenCalls = [:]
        correctionSeal = nil
        draftingTool = nil
        turnRunning = false
        turnAnchored = false
        turnAnchor = nil
        turnStartAnchored = false
        turnStartAnchor = nil
    }

    private mutating func appendPrompt(_ projected: (text: String, refs: [AttachmentRef]), id: String, rowID: Int?, timestamp: Date?) {
        // The plugin's call announcements are instructions for Hermes; the chat only marks where a call began and ended.
        if let notice = Self.callNotice(projected.text) {
            items.append(.system(SystemNote(id: id, kind: .call, text: notice, timestamp: timestamp)))
            return
        }
        guard !projected.text.isEmpty || !projected.refs.isEmpty else { return }
        items.append(.user(UserMessage(id: id, text: projected.text, attachments: projected.refs, rowID: rowID, timestamp: timestamp)))
    }

    // MARK: Live events

    /// Folds one gateway event of this chat's session in. `seq` is the envelope's.
    mutating func apply(_ event: GatewayEvent, seq: Int? = nil) {
        if let seq { lastSeq = seq }
        switch event {
        case .messageStart:
            draftingTool = nil
            startTurn()
        case let .messageDelta(payload):
            draftingTool = nil
            appendText(payload.text)
        case let .messageInterim(payload):
            sealInterim(payload.text)
        case let .reasoningDelta(payload):
            draftingTool = nil
            appendReasoning(payload.text)
        case let .reasoningAvailable(payload):
            replaceReasoning(payload.text)
        case let .toolGenerating(payload):
            draftingTool = payload.name.isEmpty ? nil : payload.name
        case let .toolStart(payload):
            draftingTool = nil
            startTool(callID: payload.toolId, name: payload.name, args: payload.args ?? [:],
                      context: payload.context ?? payload.preview)
        case let .toolComplete(payload):
            draftingTool = nil
            completeTool(payload)
        case let .subagentSpawnRequested(payload):
            updateSubagent(payload, phase: .spawned)
        case let .subagentStart(payload):
            updateSubagent(payload, phase: .started)
        case let .subagentProgress(payload), let .subagentTool(payload):
            updateSubagent(payload, phase: .working)
        case .subagentThinking:
            break
        case let .subagentComplete(payload):
            updateSubagent(payload, phase: .finished)
        case let .todoUpdated(payload):
            setTodos(payload.todos, revision: payload.revision)
        case let .messageComplete(payload):
            draftingTool = nil
            complete(payload)
        case let .error(payload):
            draftingTool = nil
            fail(payload.message)
        case let .sessionInfo(info):
            if info.running == false, turnRunning { settle() } else if info.running == true { turnRunning = true }
        case let .sessionUsage(payload):
            usage = payload.usage
        case let .sessionTitle(payload):
            if !payload.title.isEmpty { title = payload.title }
        case let .btwComplete(payload):
            let question = payload.question.map { " \"\($0)\"" } ?? ""
            appendBackground("[btw\(question)]", report: payload.text)
        case let .backgroundComplete(payload):
            appendBackground(payload.taskId.isEmpty ? "background task finished" : "[bg \(payload.taskId)]", report: payload.text)
        case let .reviewSummary(payload):
            appendReview(payload.text)
        case let .unknown(type, payload):
            if let salvaged = Self.salvage(type, payload) { apply(salvaged, seq: seq) }
        default:
            break
        }
    }

    private mutating func startTurn() {
        sealStreams()
        settleRun()
        flushNextPrompts()
        turnRunning = true
        turnAnchored = true
        turnAnchor = items.last?.id
        turnStartAnchored = true
        turnStartAnchor = turnAnchor
    }

    /// Marks the turn begun when its first output arrives without a `message.start` (a turn already running when
    /// the chat attached): its rows follow the last prompt.
    private mutating func beginOutput() {
        turnRunning = true
        guard !turnAnchored else { return }
        turnAnchored = true
        turnAnchor = items.last(where: \.isUser)?.id
        if !turnStartAnchored {
            turnStartAnchored = true
            turnStartAnchor = turnAnchor
        }
    }

    private mutating func appendText(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = liveAssistantID, modifyAssistant(id, { $0.source += delta }) {
            return syncMedia(id)
        }
        // A reply's row is made with its first visible text, so a turn that opens with whitespace or a tool call
        // leaves no empty row.
        guard !delta.trimmed.isEmpty else { return }
        beginOutput()
        sealReasoning()
        settleRun()
        let id = nextID("text")
        items.append(.assistant(AssistantText(id: id, source: delta, streaming: true)))
        liveAssistantID = id
        syncMedia(id)
    }

    /// Commentary beside tool calls is sealed as its own row (already streamed, unless told otherwise).
    private mutating func sealInterim(_ text: String) {
        let text = text.trimmed
        if let id = liveAssistantID {
            liveAssistantID = nil
            if modifyAssistant(id, { item in
                if !text.isEmpty { item.source = text }
                item.streaming = false
                item.interim = true
            }) { return syncMedia(id) }
        }
        guard !text.isEmpty else { return }
        // A second delivery of the commentary that sealed the reply already.
        let start = regionStart
        if items[start...].contains(where: { item in
            if case let .assistant(existing) = item { return Self.normalized(existing.source) == Self.normalized(text) }
            return false
        }) { return }
        beginOutput()
        sealReasoning()
        settleRun()
        let id = nextID("text")
        items.append(.assistant(AssistantText(id: id, source: text, interim: true)))
        syncMedia(id)
    }

    private mutating func appendReasoning(_ delta: String) {
        guard !delta.isEmpty else { return }
        if let id = liveReasoningID, modifyReasoning(id, { $0.text += delta }) { return }
        guard !delta.trimmed.isEmpty else { return }
        beginOutput()
        sealAssistant()
        settleRun()
        let id = nextID("reasoning")
        items.append(.reasoning(Reasoning(id: id, text: delta, streaming: true, startedAt: now())))
        liveReasoningID = id
    }

    /// A finished reasoning block (providers that don't stream it) replaces the live one, or is added.
    private mutating func replaceReasoning(_ text: String) {
        guard !text.trimmed.isEmpty else { return }
        if let id = liveReasoningID {
            let now = now()
            liveReasoningID = nil
            if modifyReasoning(id, { item in
                item.text = text
                item.streaming = false
                item.duration = item.startedAt.map { now.timeIntervalSince($0) }
            }) { return }
        }
        // The reply below it is written already: the block came too late to stand above it.
        if let id = liveAssistantID, assistant(id)?.source.trimmed.isEmpty == false { return }
        let start = regionStart
        if items[start...].contains(where: { item in
            if case let .reasoning(existing) = item { return Self.normalized(existing.text) == Self.normalized(text) }
            return false
        }) { return }
        beginOutput()
        sealAssistant()
        settleRun()
        items.append(.reasoning(Reasoning(id: nextID("reasoning"), text: text)))
    }

    private mutating func startTool(callID: String, name: String, args: [String: JSONValue], context: String?) {
        beginOutput()
        sealStreams()
        if ToolCall.hiddenTools.contains(name) {
            hiddenCalls[callID] = ToolCall(id: callID, callID: callID, name: name, args: args, context: context, startedAt: now())
            return
        }
        // A repeated start, or one for a call a seal closed early: the call is still running.
        if let location = openCall(callID, from: 0) {
            return modifyCall(location) { call in
                call.args.merge(args) { _, new in new }
                if let context { call.context = context }
                call.done = false
            }
        }
        insert(ToolCall(id: uniqueCallID(callID), callID: callID, name: name, args: args, context: context, startedAt: now()), live: true)
    }

    private mutating func completeTool(_ payload: ToolCompletePayload) {
        beginOutput()
        sealStreams()
        if let todos = payload.todos { setTodos(todos, revision: payload.revision ?? todoRevision) }
        let now = now()
        func fill(_ call: inout ToolCall) {
            if let args = payload.args, !args.isEmpty { call.args.merge(args) { _, new in new } }
            call.result = payload.result ?? payload.resultText.map(JSONValue.string) ?? call.result
            call.resultText = payload.resultText ?? call.resultText
            call.summary = payload.summary ?? call.summary
            call.inlineDiff = payload.inlineDiff ?? call.inlineDiff
            call.duration = payload.durationS ?? call.duration
            call.completedAt = now
            call.done = true
        }
        if var call = hiddenCalls.removeValue(forKey: payload.toolId)
            ?? (ToolCall.hiddenTools.contains(payload.name) ? ToolCall(id: payload.toolId, callID: payload.toolId, name: payload.name) : nil) {
            fill(&call)
            guard call.failed else { return }
            call.id = uniqueCallID(call.callID)
            return insert(call, live: true)
        }
        if let location = openCall(payload.toolId, from: 0) {
            return modifyCall(location, fill)
        }
        var call = ToolCall(id: uniqueCallID(payload.toolId), callID: payload.toolId, name: payload.name)
        fill(&call)
        insert(call, live: true)
    }

    /// The reply is over: settles its rows, shows its failure and sums up its edits.
    private mutating func complete(_ payload: MessageCompletePayload) {
        let text = (payload.text.map { Self.text($0) } ?? payload.rendered ?? "").trimmed
        let failed = payload.status == .error
        let keepText = !failed || (payload.partial == true && !text.isEmpty)
        sealReasoning()
        if let id = liveAssistantID, !keepText || (text.isEmpty && assistant(id)?.source.trimmed.isEmpty != false) {
            // A failure's text is the error, not output to keep.
            remove(id: id)
            remove(id: "\(id)-media")
            liveAssistantID = nil
        }
        let start = regionStart
        if keepText, !text.isEmpty { settleReply(text, from: start) }
        sealAssistant()
        if let reasoning = payload.reasoning, !reasoning.trimmed.isEmpty,
           !items[min(start, items.count)...].contains(where: { if case .reasoning = $0 { return true }; return false }) {
            let at = items[min(start, items.count)...].lastIndex { if case .assistant = $0 { return true }; return false } ?? items.count
            items.insert(.reasoning(Reasoning(id: nextID("reasoning"), text: reasoning)), at: at)
        }
        let interrupted = payload.status == .interrupted
        sealOpenCalls(from: 0, interrupted: interrupted)
        if interrupted {
            items.append(.system(SystemNote(id: nextID("stopped"), kind: .stopped, text: "Response stopped", timestamp: now())))
        }
        if failed {
            let message = payload.error?.trimmed.nonEmpty ?? text.nonEmpty ?? "Hermes reported an error"
            appendError(Self.turnError(message: message, surface: payload.errorSurface, id: nextID("error")))
        }
        if let warning = payload.warning?.trimmed, !warning.isEmpty {
            items.append(.system(SystemNote(id: nextID("warning"), kind: .warning, text: warning, timestamp: now())))
        }
        appendChangedFiles(from: start, id: nextID("files"))
        endTurn()
    }

    /// The final text is the reply after the turn's last tool call: it settles the row streaming it (or the
    /// commentary that previewed it), or is added.
    private mutating func settleReply(_ text: String, from start: Int) {
        let region = items[min(start, items.count)...]
        let lastWork = region.lastIndex { item in
            switch item {
            case .toolRun, .subagent: return true
            default: return false
            }
        }
        let lastText = region.lastIndex { if case .assistant = $0 { return true }; return false }
        if let lastText, lastText > (lastWork ?? -1), case let .assistant(existing) = items[lastText] {
            _ = modifyAssistant(existing.id) { item in
                if Self.normalized(item.source) != Self.normalized(text) { item.source = text }
                item.streaming = false
                item.interim = false
            }
            return syncMedia(existing.id)
        }
        // The commentary before the tools already said it.
        if region.contains(where: { item in
            if case let .assistant(existing) = item { return existing.interim && Self.normalized(existing.source) == Self.normalized(text) }
            return false
        }) { return }
        settleRun()
        let id = nextID("text")
        items.append(.assistant(AssistantText(id: id, source: text)))
        syncMedia(id)
    }

    /// A failure outside a reply (agent init, model switch, resume) or a bare `error` frame ends the turn.
    private mutating func fail(_ message: String) {
        sealReasoning()
        if let id = liveAssistantID, assistant(id)?.source.trimmed.isEmpty != false { remove(id: id) }
        sealAssistant()
        sealOpenCalls(from: 0, interrupted: false)
        let message = message.trimmed.nonEmpty ?? "Hermes reported an error"
        appendError(Self.turnError(message: message, surface: nil, id: nextID("error")))
        endTurn()
    }

    /// Hermes reports the session idle: whatever is still open has ended, though the turn's terminal frame may
    /// still follow (and finds its rows).
    private mutating func settle() {
        sealStreams()
        sealOpenCalls(from: 0, interrupted: false)
        settleRun()
        turnRunning = false
        draftingTool = nil
        flushNextPrompts()
    }

    private mutating func endTurn() {
        settle()
        turnAnchored = false
        turnAnchor = nil
        turnStartAnchored = false
        turnStartAnchor = nil
    }

    /// The prompts held for the next turn join the transcript, after the turn that ran before them.
    private mutating func flushNextPrompts() {
        guard !nextPrompts.isEmpty else { return }
        items += nextPrompts.map(TranscriptItem.user)
        nextPrompts = []
    }

    /// A terminal frame repeating the failure a bare `error` frame showed already settles onto that card.
    private mutating func appendError(_ error: TurnError) {
        if case let .error(existing)? = items.last, existing.layer == nil || existing.message == error.message {
            items[items.count - 1] = .error(TurnError(
                id: existing.id, layer: error.layer ?? existing.layer, code: error.code ?? existing.code, message: error.message,
                retryable: error.retryable, provider: error.provider, providerLabel: error.providerLabel, model: error.model,
                authKind: error.authKind, resetsAt: error.resetsAt, recovery: error.recovery
            ))
            return
        }
        items.append(.error(error))
    }

    private mutating func appendBackground(_ label: String, report: String) {
        let report = report.trimmed
        guard !report.isEmpty else { return }
        items.append(.system(SystemNote(id: nextID("background"), kind: .background(report: report, process: false), text: label, timestamp: now())))
    }

    /// "💾 Self-improvement review: …" as the memory-write row it is.
    private mutating func appendReview(_ text: String) {
        var text = text.trimmed
        if text.hasPrefix("💾") { text = String(text.dropFirst()).trimmed }
        guard !text.isEmpty else { return }
        let parts = text.split(separator: ":", maxSplits: 1)
        let label = parts.first.map { String($0).trimmed } ?? text
        let detail = parts.count > 1 ? String(parts[1]).trimmed : ""
        items.append(.system(SystemNote(id: nextID("review"), kind: .review(label: label), text: detail, timestamp: now())))
    }

    // MARK: Subagents

    private enum SubagentPhase { case spawned, started, working, finished }

    private mutating func updateSubagent(_ payload: SubagentEventPayload, phase: SubagentPhase) {
        beginOutput()
        let (itemIndex, rowIndex) = subagentRow(for: payload)
        guard case var .subagent(delegation) = items[itemIndex] else { return }
        var row = delegation.rows[rowIndex]
        row.subagentID = payload.subagentId ?? row.subagentID
        row.childSessionID = payload.childSessionId ?? row.childSessionID
        row.model = payload.model ?? row.model
        row.taskIndex = payload.taskIndex
        if row.goal.isEmpty || row.goal == "Delegated task", !payload.goal.isEmpty { row.goal = payload.goal }
        switch phase {
        case .spawned:
            if !row.status.isTerminal, row.status != .running { row.status = .queued }
        case .started:
            if !row.status.isTerminal { row.status = .running }
        case .working:
            if !row.status.isTerminal { row.status = .running }
            let line = (payload.toolPreview ?? payload.text)?.trimmed.nonEmpty.map { text in
                payload.toolName.map { "\($0): \(text)" } ?? text
            } ?? payload.toolName
            if let line { row.addActivity(line) }
        case .finished:
            switch payload.status {
            case .failed?, .error?, .timeout?: row.status = .failed
            case .interrupted?: row.status = .interrupted
            case let .unknown(value)? where !["", "ok", "completed"].contains(value): row.status = .failed
            default: row.status = .completed
            }
            row.duration = payload.durationSeconds ?? row.duration
            if let summary = payload.summary?.trimmed.nonEmpty { row.addActivity(summary) }
        }
        delegation.rows[rowIndex] = row
        items[itemIndex] = .subagent(delegation)
    }

    /// The row an event is about: the one with its subagent id, else the dispatched goal it names, else the task
    /// at its index in a fan-out of the same size. A child nothing dispatched visibly gets a card of its own.
    private mutating func subagentRow(for payload: SubagentEventPayload) -> (Int, Int) {
        let goal = Self.normalized(payload.goal)
        let delegations = items.indices.reversed().compactMap { index -> (Int, Delegation)? in
            if case let .subagent(delegation) = items[index] { return (index, delegation) }
            return nil
        }
        if let id = payload.subagentId {
            for (index, delegation) in delegations {
                if let row = delegation.rows.firstIndex(where: { $0.subagentID == id }) { return (index, row) }
            }
        }
        if !goal.isEmpty {
            for (index, delegation) in delegations {
                if let row = delegation.rows.firstIndex(where: { $0.subagentID == nil && Self.normalized($0.goal) == goal }) {
                    return (index, row)
                }
            }
        }
        for (index, delegation) in delegations where delegation.rows.count == payload.taskCount
            && delegation.rows.indices.contains(payload.taskIndex) && delegation.rows[payload.taskIndex].subagentID == nil {
            return (index, payload.taskIndex)
        }
        let row = DelegateRow(id: nextID("child"), goal: payload.goal.isEmpty ? "Delegated task" : payload.goal,
                              status: .queued, taskIndex: payload.taskIndex)
        if case var .subagent(delegation)? = items.last, delegation.call == nil {
            delegation.rows.append(row)
            items[items.count - 1] = .subagent(delegation)
            return (items.count - 1, delegation.rows.count - 1)
        }
        sealStreams()
        settleRun()
        items.append(.subagent(Delegation(id: nextID("delegation"), call: nil, rows: [row])))
        return (items.count - 1, 0)
    }

    // MARK: Todos

    private mutating func setTodos(_ todos: [JSONValue], revision: Int) {
        guard revision >= todoRevision else { return }
        todoRevision = revision
        self.todos = todos.enumerated().compactMap { index, raw in
            let todo = Self.object(raw)
            guard let content = (todo["content"] ?? todo["text"] ?? todo["title"])?.stringValue else { return nil }
            return TodoItem(id: todo["id"].flatMap(Self.string) ?? "\(index)", content: content,
                            status: todo["status"]?.stringValue ?? "pending")
        }
    }

    // MARK: Tool calls

    /// Where a call sits: in a run, or as a delegation's call.
    private enum CallLocation {
        case run(item: Int, call: Int)
        case delegation(item: Int)
    }

    /// The newest call with `callID` still waiting for its result (ids repeat across turns, so a call that has one
    /// is an earlier turn's), from `start` on. With `name`, the newest unanswered call of that tool instead.
    private func openCall(_ callID: String, name: String? = nil, from start: Int) -> CallLocation? {
        for index in items.indices.reversed() where index >= start {
            switch items[index] {
            case let .toolRun(run):
                if let call = run.calls.lastIndex(where: { call in call.result == nil && (name.map { call.name == $0 } ?? (call.callID == callID)) }) {
                    return .run(item: index, call: call)
                }
            case let .subagent(delegation):
                if let call = delegation.call, call.result == nil, name.map({ $0 == call.name }) ?? (call.callID == callID) {
                    return .delegation(item: index)
                }
            default:
                continue
            }
        }
        return nil
    }

    private mutating func modifyCall(_ location: CallLocation, _ body: (inout ToolCall) -> Void) {
        switch location {
        case let .run(item, call):
            guard case var .toolRun(run) = items[item] else { return }
            body(&run.calls[call])
            items[item] = .toolRun(run)
        case let .delegation(item):
            guard case var .subagent(delegation) = items[item], var call = delegation.call else { return }
            body(&call)
            delegation.call = call
            delegation.rows = Self.mergeRows(Delegation.rows(from: call, idPrefix: delegation.id), into: delegation.rows)
            items[item] = .subagent(delegation)
        }
    }

    /// Adds a call: a delegation becomes its card, a call that stands alone its own run, any other joins the run
    /// before it.
    private mutating func insert(_ call: ToolCall, live: Bool = false, runID: String? = nil) {
        if call.name == "delegate_task" {
            // Children reported before their call (no tool progress) belong to it.
            if case var .subagent(delegation)? = items.last, delegation.call == nil {
                delegation.call = call
                delegation.rows = Self.mergeRows(Delegation.rows(from: call, idPrefix: delegation.id), into: delegation.rows)
                items[items.count - 1] = .subagent(delegation)
            } else {
                let id = runID ?? nextID("delegation")
                items.append(.subagent(Delegation(id: id, call: call, rows: Delegation.rows(from: call, idPrefix: id))))
            }
            liveRunID = nil
            return
        }
        if !call.standsAlone, case var .toolRun(run)? = items.last, !run.calls.contains(where: \.standsAlone) {
            run.calls.append(call)
            run.live = live
            items[items.count - 1] = .toolRun(run)
            liveRunID = live ? run.id : nil
            return
        }
        settleRun()
        let id = runID ?? nextID("run")
        items.append(.toolRun(ToolRun(id: id, calls: [call], live: live)))
        liveRunID = live ? id : nil
    }

    /// Ends every call from `start` on that is still open: the turn is over, so none is running.
    private mutating func sealOpenCalls(from start: Int, interrupted: Bool) {
        let now = now()
        for index in items.indices where index >= start {
            switch items[index] {
            case var .toolRun(run) where run.calls.contains(where: { !$0.done }) || run.live:
                for call in run.calls.indices where !run.calls[call].done {
                    run.calls[call].done = true
                    run.calls[call].interrupted = interrupted
                    run.calls[call].completedAt = run.calls[call].completedAt ?? now
                }
                run.live = false
                items[index] = .toolRun(run)
            case var .subagent(delegation):
                var changed = false
                if var call = delegation.call, !call.done {
                    call.done = true
                    call.interrupted = interrupted
                    delegation.call = call
                    changed = true
                }
                // Children outlive the turn that spawned them; with nothing watching they are parked, not running.
                for row in delegation.rows.indices where delegation.rows[row].status.isLive && delegation.rows[row].subagentID == nil {
                    delegation.rows[row].status = interrupted ? .interrupted : .dispatched
                    changed = true
                }
                if changed { items[index] = .subagent(delegation) }
            default:
                continue
            }
        }
    }

    private mutating func uniqueCallID(_ callID: String) -> String {
        let used = items.contains { item in
            switch item {
            case let .toolRun(run): return run.calls.contains { $0.id == callID }
            case let .subagent(delegation): return delegation.call?.id == callID
            default: return false
            }
        }
        return used ? "\(callID)#\(nextSerial())" : callID
    }

    // MARK: Changed files

    /// One row per file the turn edited (first-touched order), each edit's +/- summed. Only edits with a diff count.
    private mutating func appendChangedFiles(from start: Int, id: String) {
        guard start <= items.count else { return }
        var files: [ChangedFile] = []
        for item in items[start...] {
            guard case let .toolRun(run) = item else { continue }
            for call in run.calls where call.isFileEdit {
                guard let diff = call.diff, let path = call.editPath else { continue }
                let stats = ToolCall.diffStats(diff)
                if let index = files.firstIndex(where: { $0.path == path }) {
                    files[index].added += stats.added
                    files[index].removed += stats.removed
                    files[index].diffs.append(diff)
                } else {
                    files.append(ChangedFile(path: path, added: stats.added, removed: stats.removed, diffs: [diff]))
                }
            }
        }
        guard !files.isEmpty else { return }
        items.append(.changedFiles(ChangedFiles(id: id, files: files)))
    }

    // MARK: Streams

    private mutating func sealAssistant() {
        guard let id = liveAssistantID else { return }
        liveAssistantID = nil
        _ = modifyAssistant(id) { $0.streaming = false }
    }

    private mutating func sealReasoning() {
        guard let id = liveReasoningID else { return }
        liveReasoningID = nil
        let now = now()
        _ = modifyReasoning(id) { item in
            item.streaming = false
            item.duration = item.duration ?? item.startedAt.map { now.timeIntervalSince($0) }
        }
    }

    private mutating func sealStreams() {
        sealAssistant()
        sealReasoning()
    }

    /// Something came after the live run, so it is no longer the one the turn is working in.
    private mutating func settleRun() {
        guard let id = liveRunID else { return }
        liveRunID = nil
        guard let index = items.lastIndex(where: { $0.id == id }), case var .toolRun(run) = items[index] else { return }
        run.live = false
        items[index] = .toolRun(run)
    }

    /// Keeps the media row after a reply in step with its `MEDIA:` tags.
    private mutating func syncMedia(_ id: String) {
        let mediaID = "\(id)-media"
        let media = assistant(id)?.media ?? []
        if let index = items.lastIndex(where: { $0.id == mediaID }) {
            if media.isEmpty { items.remove(at: index) } else { items[index] = .media(MediaGroup(id: mediaID, media: media)) }
        } else if !media.isEmpty, let index = items.lastIndex(where: { $0.id == id }) {
            items.insert(.media(MediaGroup(id: mediaID, media: media)), at: index + 1)
        }
    }

    // MARK: Lookup

    /// Where the running turn began (corrections included in it).
    private var turnStartIndex: Int {
        if turnStartAnchored {
            guard let anchor = turnStartAnchor else { return 0 }
            if let index = items.lastIndex(where: { $0.id == anchor }) { return index + 1 }
        }
        return regionStart
    }

    /// Where the current turn's rows start.
    private var regionStart: Int {
        if turnAnchored {
            guard let anchor = turnAnchor else { return 0 }
            if let index = items.lastIndex(where: { $0.id == anchor }) { return index + 1 }
        }
        return (items.lastIndex(where: \.isUser) ?? -1) + 1
    }

    private func assistant(_ id: String) -> AssistantText? {
        guard let index = items.lastIndex(where: { $0.id == id }), case let .assistant(item) = items[index] else { return nil }
        return item
    }

    private mutating func modifyAssistant(_ id: String, _ body: (inout AssistantText) -> Void) -> Bool {
        guard let index = items.lastIndex(where: { $0.id == id }), case var .assistant(item) = items[index] else { return false }
        body(&item)
        items[index] = .assistant(item)
        return true
    }

    private mutating func modifyReasoning(_ id: String, _ body: (inout Reasoning) -> Void) -> Bool {
        guard let index = items.lastIndex(where: { $0.id == id }), case var .reasoning(item) = items[index] else { return false }
        body(&item)
        items[index] = .reasoning(item)
        return true
    }

    private mutating func nextSerial() -> Int {
        serial += 1
        return serial
    }

    private mutating func nextID(_ prefix: String) -> String {
        "\(prefix)-\(nextSerial())"
    }
}

// MARK: - Projection helpers

extension Transcript {
    /// Display kinds Hermes writes itself rather than any view sending them (`NOTICE_DISPLAY_KINDS`).
    static let noticeKinds: Set<String> = [
        "model_switch", "async_delegation_complete", "process_complete", "auto_continue", "personality_switch", "failed_turn",
    ]

    /// A stored prompt as shown: the context Hermes appended dropped, and reference lines (`@image:` anywhere, a
    /// leading run of `@file:` …) lifted into chips.
    static func userText(_ raw: String) -> (text: String, refs: [AttachmentRef]) {
        var text = raw.replacingOccurrences(
            of: "(^|\\n)\\[Triggering message id: `[^`\\n]*` — use as `message_id` for reply/react/pin via the discord tools\\.\\]\\n*",
            with: "$1", options: .regularExpression)
        var refs: [AttachmentRef] = []
        if let marker = text.range(of: "(?:^|\\n)--- Attached Context ---[ \\t]*\\n", options: .regularExpression) {
            let attached = String(text[marker.upperBound...])
            text = String(text[..<marker.lowerBound])
            let visible = text
            let pattern = AttachmentRef.pattern
            for match in pattern.matches(in: attached, range: NSRange(attached.startIndex..., in: attached)) {
                guard let range = Range(match.range, in: attached), let ref = AttachmentRef(String(attached[range])),
                      !visible.contains(ref.ref), !refs.contains(ref) else { continue }
                refs.append(ref)
            }
        }
        if let warnings = text.range(of: "(?:^|\\n)--- Context Warnings ---", options: .regularExpression) {
            text = String(text[..<warnings.lowerBound])
        }
        var lines = text.components(separatedBy: "\n")
        let images = lines.filter { $0.hasPrefix("@image:") }.compactMap(AttachmentRef.init)
        if !images.isEmpty {
            lines.removeAll { $0.hasPrefix("@image:") || $0 == "[screenshot]" }
        }
        var leading: [AttachmentRef] = []
        while let first = lines.first, let ref = AttachmentRef(first) {
            leading.append(ref)
            lines.removeFirst()
        }
        return (lines.joined(separator: "\n").trimmed, refs + leading + images)
    }

    /// "Voice call started" for the plugin's `[Voice call started]` (and the other call notices).
    static func callNotice(_ text: String) -> String? {
        guard text.hasPrefix("[Voice call "), let close = text.firstIndex(of: "]") else { return nil }
        return String(text[text.index(after: text.startIndex)..<close])
    }

    /// The result body of a background completion (`asyncResultBody`): its producer's boundaries, not the preamble.
    static func asyncResult(_ content: String) -> String? {
        var bodies = [content]
        if content.hasPrefix("[IMPORTANT: ") {
            bodies = content.components(separatedBy: "\n\n[IMPORTANT: ").enumerated().map { index, block in
                var block = index == 0 ? String(block.dropFirst("[IMPORTANT: ".count)) : block
                if block.hasSuffix("]") { block.removeLast() }
                return block
            }.filter { $0.range(of: "^\\d+ background processes completed\\.", options: .regularExpression) == nil }
        } else if content.hasPrefix("[ASYNC DELEGATION"), let marker = content.range(of: "(?m)^--- (?:RESULT|ERROR) ---\\r?\\n", options: .regularExpression) {
            bodies = [String(content[marker.upperBound...])]
        }
        let joined = bodies.map { body -> String in
            body.replacingOccurrences(of: "\\nFull live transcript \\(complete tool/assistant trace\\): [^\\n]*\\n*$", with: "",
                                      options: .regularExpression).trimmed
        }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return joined.isEmpty ? nil : joined
    }

    /// A failed turn's card, kept on its stored boundary row (`display_metadata.error_surface`).
    static func storedError(_ metadata: JSONValue?, id: String) -> TurnError? {
        let metadata = object(metadata)
        let raw = object(metadata["error_surface"])
        guard let layer = raw["layer"]?.stringValue, TurnError.Layer(rawValue: layer) != nil else { return nil }
        let known: Set<String> = ["layer", "code", "retryable", "provider", "model", "resets_at"]
        let surface = ErrorSurface(
            layer: layer, code: raw["code"]?.stringValue?.trimmed.nonEmpty ?? "unknown", retryable: raw["retryable"]?.boolValue ?? true,
            provider: raw["provider"]?.stringValue, model: raw["model"]?.stringValue, resetsAt: raw["resets_at"]?.doubleValue,
            extras: raw.filter { !known.contains($0.key) }
        )
        let message = metadata["error"]?.stringValue?.trimmed.nonEmpty ?? surface.code
        return turnError(message: message, surface: surface, id: id)
    }

    /// The error card for a failure: its layer and code from `surface`, else read from the message where the gateway
    /// sends none (a chat open elsewhere, a full disk).
    static func turnError(message: String, surface: ErrorSurface?, id: String) -> TurnError {
        var error = TurnError(id: id, message: message)
        if let surface, let layer = TurnError.Layer(rawValue: surface.layer) {
            error.layer = layer
            error.code = surface.code.isEmpty ? nil : surface.code
            error.retryable = surface.retryable
            error.provider = surface.provider
            error.model = surface.model
            error.providerLabel = surface.extras["provider_label"]?.stringValue
            error.authKind = surface.extras["auth_kind"]?.stringValue
            error.resetsAt = surface.resetsAt.map { Date(timeIntervalSince1970: $0) }
        } else if message.range(of: "already has a live owner", options: .caseInsensitive) != nil || message.contains("SESSION_NOT_OWNED") {
            error.layer = .gateway
            error.code = "SESSION_NOT_OWNED"
            error.retryable = false
        } else if message.range(of: "no space left on device|not enough space|database or disk is full|\\bENOSPC\\b|disk full|full disk",
                                options: [.regularExpression, .caseInsensitive]) != nil {
            error.layer = .disk
            error.code = "disk_full"
            error.retryable = false
        }
        error.recovery = recovery(for: error)
        return error
    }

    /// `errorRecoveryPlan`: Retry unless the failure is known to repeat (a rejected credential still offers it,
    /// fixing it changes the outcome), plus what each code needs.
    static func recovery(for error: TurnError) -> [ErrorRecovery] {
        let credential = error.layer == .auth && (error.authKind == "oauth" || error.authKind == "api_key")
        var plan: Set<ErrorRecovery> = []
        if error.layer == nil || error.retryable || credential { plan.insert(.retry) }
        if let layer = error.layer, [.auth, .billing, .endpoint, .provider].contains(layer) { plan.insert(.switchProvider) }
        switch error.code ?? "" {
        case "SESSION_NOT_OWNED": plan.remove(.retry); plan.insert(.startNewSession)
        case "content_policy_blocked": plan.remove(.retry); plan.insert(.editMessage)
        case "context_overflow", "payload_too_large": plan.remove(.retry); plan.formUnion([.compress, .startNewSession])
        case "disk_full": plan.insert(.retry)
        case "loop_error": plan.insert(.startNewSession)
        case "model_not_found": plan.remove(.retry); plan.insert(.chooseModel)
        default: break
        }
        return ErrorRecovery.allCases.filter(plan.contains)
    }

    /// Text of a stored `content` (a string, or parts) or any value: strings as they are, parts joined.
    static func text(_ value: JSONValue?, depth: Int = 0) -> String {
        guard let value, depth <= 2 else { return "" }
        switch value {
        case let .string(text): return text
        case .null: return ""
        case let .array(parts): return parts.map { text($0, depth: depth + 1) }.joined()
        case let .object(object):
            let nested = text(object["text"] ?? object["output_text"] ?? object["content"] ?? object["message"], depth: depth + 1)
            if !nested.isEmpty { return nested }
            return (try? value.jsonData()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        case let .int(number): return String(number)
        case let .double(number): return String(number)
        case let .bool(flag): return String(flag)
        }
    }

    /// An object, or a JSON string holding one; anything else is empty.
    static func object(_ value: JSONValue?) -> [String: JSONValue] {
        switch value {
        case let .object(object)?: return object
        case let .string(text)?:
            guard text.trimmed.hasPrefix("{"), let parsed = try? JSONValue(jsonData: Data(text.utf8)) else { return [:] }
            return parsed.objectValue ?? [:]
        default: return [:]
        }
    }

    /// A stored tool row's content: its JSON when it parses, else the text.
    static func storedResult(_ content: JSONValue?) -> JSONValue {
        guard let content else { return .string("") }
        if case .object = content { return content }
        if case .array = content { return content }
        let string = Self.text(content)
        if let parsed = try? JSONValue(jsonData: Data(string.utf8)) {
            switch parsed {
            case .object, .array: return parsed
            default: break
            }
        }
        return .string(string)
    }

    static func reasoningText(_ details: JSONValue?) -> String? {
        guard let details = details?.arrayValue else { return nil }
        let text = details.compactMap { detail -> String? in
            let detail = object(detail)
            return (detail["text"] ?? detail["summary"])?.stringValue
        }.joined(separator: "\n\n")
        return text.isEmpty ? nil : text
    }

    static func rowID(_ row: [String: JSONValue]) -> Int? {
        row["row_id"]?.intValue ?? row["id"]?.intValue
    }

    static func string(_ value: JSONValue) -> String? {
        switch value {
        case let .string(text): return text
        case let .int(number): return String(number)
        default: return nil
        }
    }

    /// Epoch seconds (or ms) as a date.
    static func date(_ value: JSONValue?) -> Date? {
        guard var seconds = value?.doubleValue else { return nil }
        while seconds > 1e11 { seconds /= 1000 }
        return Date(timeIntervalSince1970: seconds)
    }

    static func normalized(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The transcript events, rebuilt from a payload outside the contract (another Hermes version).
    static func salvage(_ type: String, _ payload: JSONValue?) -> GatewayEvent? {
        let payload = payload ?? [:]
        let text = payload["text"]?.stringValue
        switch type {
        case "message.delta":
            return text.map { .messageDelta(StreamDeltaPayload(text: $0)) }
        case "reasoning.delta", "reasoning.available":
            return text.map { type == "reasoning.delta" ? .reasoningDelta(StreamDeltaPayload(text: $0)) : .reasoningAvailable(StreamDeltaPayload(text: $0)) }
        case "message.interim":
            return text.map { .messageInterim(MessageInterimPayload(text: $0, alreadyStreamed: payload["already_streamed"]?.boolValue ?? false)) }
        case "message.complete":
            return .messageComplete(MessageCompletePayload(
                text: payload["text"], status: payload["status"]?.stringValue.map(TurnStatus.init(rawValue:)),
                rendered: payload["rendered"]?.stringValue, error: payload["error"]?.stringValue, partial: payload["partial"]?.boolValue
            ))
        case "tool.start", "tool.complete":
            guard let name = payload["name"]?.stringValue ?? payload["tool_name"]?.stringValue else { return nil }
            let id = payload["tool_id"].flatMap(string) ?? payload["tool_call_id"].flatMap(string) ?? ""
            let args = object(payload["args"])
            if type == "tool.start" {
                return .toolStart(ToolStartPayload(toolId: id, name: name, context: payload["context"]?.stringValue,
                                                   args: args, preview: payload["preview"]?.stringValue))
            }
            return .toolComplete(ToolCompletePayload(toolId: id, name: name, args: args, durationS: payload["duration_s"]?.doubleValue,
                                                     result: payload["result"], summary: payload["summary"]?.stringValue,
                                                     resultText: payload["result_text"]?.stringValue,
                                                     inlineDiff: payload["inline_diff"]?.stringValue))
        case "error":
            return .error(ErrorPayload(message: payload["message"]?.stringValue ?? ""))
        default:
            return nil
        }
    }

    /// Delegation rows as the call describes them, kept where live events know better.
    fileprivate static func mergeRows(_ described: [DelegateRow], into live: [DelegateRow]) -> [DelegateRow] {
        guard !live.isEmpty else { return described }
        var rows = live
        for (index, row) in described.enumerated() {
            if let match = rows.firstIndex(where: { normalized($0.goal) == normalized(row.goal) }) ?? (rows.indices.contains(index) ? index : nil) {
                var merged = rows[match]
                if merged.goal == "Delegated task" { merged.goal = row.goal }
                if !merged.status.isTerminal, row.status.isTerminal { merged.status = row.status }
                if merged.status.isLive, row.status == .dispatched, merged.subagentID == nil { merged.status = .dispatched }
                merged.duration = merged.duration ?? row.duration
                merged.model = merged.model ?? row.model
                for line in row.activity where merged.activity.last != line { merged.addActivity(line) }
                rows[match] = merged
            } else {
                rows.append(row)
            }
        }
        return rows
    }
}

extension Delegation {
    /// The rows a `delegate_task` call describes (`delegateRowsFromCall`): the goals it dispatched, and how the
    /// result says they went. Without a result yet they run; a background dispatch parks them.
    static func rows(from call: ToolCall, idPrefix: String) -> [DelegateRow] {
        let tasks = call.args["tasks"]?.arrayValue ?? []
        var goals = tasks.enumerated().map { index, task in
            Transcript.object(task)["goal"]?.stringValue?.trimmed.nonEmpty ?? "Task \(index + 1)"
        }
        if goals.isEmpty, let goal = call.args["goal"]?.stringValue?.trimmed.nonEmpty { goals = [goal] }
        let result = Transcript.object(call.result)
        let finished = (result["results"]?.arrayValue ?? []).map { Transcript.object($0) }
        let dispatched = result["status"]?.stringValue == "dispatched" ? (result["goals"]?.arrayValue ?? []).compactMap(\.stringValue) : []
        let titles = !goals.isEmpty ? goals : !dispatched.isEmpty ? dispatched : finished.map { _ in "Delegated task" }
        let idle: DelegateRow.Status = call.result == nil ? (call.done ? .dispatched : .running) : .dispatched
        return titles.enumerated().map { index, goal in
            let entry = finished.indices.contains(index) ? finished[index] : nil
            var row = DelegateRow(id: "\(idPrefix)-\(index)", goal: goal, status: idle, taskIndex: index)
            if let entry {
                let status = entry["status"]?.stringValue ?? ""
                row.status = ["", "ok", "completed"].contains(status) ? .completed : .failed
                row.duration = entry["duration_seconds"]?.doubleValue
                row.model = entry["model"]?.stringValue
                if let summary = entry["summary"]?.stringValue?.trimmed.nonEmpty { row.activity = [summary] }
            }
            return row
        }
    }
}

extension DelegateRow {
    mutating func addActivity(_ line: String) {
        guard activity.last != line else { return }
        activity.append(line)
        if activity.count > 6 { activity.removeFirst(activity.count - 6) }
    }
}

// MARK: - Tool call facts

extension ToolCall {
    static let fileEditTools: Set<String> = ["edit_file", "patch", "write_file"]
    /// Shown only when they fail: todo calls feed the status stack, a reaction lands on its bubble.
    static let hiddenTools: Set<String> = ["todo", "todo_list", "react_to_message"]
    /// Cards that are the point of the turn and never fold into a run's summary.
    static let cardTools: Set<String> = ["clarify", "image_generate", "manage_catalog", "manage_connections"]

    var isPending: Bool { !done }
    var isFileEdit: Bool { Self.fileEditTools.contains(name) }

    /// Hermes speaking on a call (`speak`, and the call tools' lines).
    var isSpeech: Bool {
        ["speak", "start_call", "end_call"].contains { name == $0 || name.hasSuffix("__\($0)") }
    }

    var spokenText: String? { args["text"]?.stringValue?.trimmed.nonEmpty }

    /// Drawn on its own rather than folded into a run's summary.
    var standsAlone: Bool { isFileEdit || isSpeech || Self.cardTools.contains(name) }

    /// The result as an object, under the gateway's display hints (`toolResultRecord`).
    var record: [String: JSONValue] {
        var record: [String: JSONValue] = [:]
        if let inlineDiff { record["inline_diff"] = .string(inlineDiff) }
        if let summary { record["summary"] = .string(summary) }
        if let duration { record["duration_s"] = .double(duration) }
        record.merge(Transcript.object(result)) { _, result in result }
        return record
    }

    /// The edit's diff, without terminal colors.
    var diff: String? {
        let record = record
        for key in ["inline_diff", "diff"] {
            if let diff = record[key]?.stringValue, !diff.trimmed.isEmpty {
                return diff.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
            }
        }
        return nil
    }

    var editPath: String? {
        Self.firstString(args, ["path", "file", "filepath"]) ?? Self.firstString(record, ["path", "file", "filepath", "resolved_path"])
    }

    var exitCode: Int? { record["exit_code"]?.intValue }

    /// Reported failure, by the result's own account (`toolCallFailed`): explicit success wins.
    var failed: Bool {
        let record = Transcript.object(result)
        if record["success"]?.boolValue == true || record["ok"]?.boolValue == true { return false }
        return record["success"]?.boolValue == false || record["ok"]?.boolValue == false || Self.errorText(result) != nil
    }

    static func diffStats(_ diff: String) -> (added: Int, removed: Int) {
        var added = 0, removed = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+"), !line.hasPrefix("+++") { added += 1 } else if line.hasPrefix("-"), !line.hasPrefix("---") { removed += 1 }
        }
        return (added, removed)
    }

    static func firstString(_ record: [String: JSONValue], _ keys: [String]) -> String? {
        for key in keys {
            if let value = record[key]?.stringValue?.trimmed, !value.isEmpty { return value }
        }
        return nil
    }

    private static let errorKeys = ["error", "errors", "failure", "exception"]
    private static let wrapperKeys = ["data", "result", "output", "response", "payload"]
    private static let messageKeys = ["message", "reason", "detail"]
    private static let nonErrorText: Set<String> = ["", "0", "false", "none", "null", "nil", "ok", "success", "n/a", "na"]

    /// The failure a result describes (`extractToolErrorMessage`): an error field, or the message of a result that
    /// declares failure. Output that merely mentions an error doesn't count.
    static func errorText(_ value: JSONValue?, depth: Int = 0, declared: Bool = false) -> String? {
        guard depth <= 5, let value = parsed(value) else { return nil }
        switch value {
        case let .array(items):
            return items.lazy.compactMap { errorText($0, depth: depth + 1, declared: declared) }.first
        case let .object(record):
            if record["success"]?.boolValue == true || record["ok"]?.boolValue == true { return nil }
            for key in errorKeys where meaningful(record[key]) {
                if let text = valueText(record[key]) { return text }
            }
            let signal = hasErrorSignal(record)
            if signal, let text = firstString(record, messageKeys) { return clipped(text) }
            let failed = declared || signal
            for key in failed ? errorKeys + wrapperKeys + ["details"] : errorKeys {
                if let nested = errorText(record[key], depth: depth + 1, declared: failed) { return nested }
            }
            return nil
        default:
            return nil
        }
    }

    private static func parsed(_ value: JSONValue?) -> JSONValue? {
        guard let value else { return nil }
        if case let .string(text) = value {
            let trimmed = text.trimmed
            guard trimmed.hasPrefix("{") || trimmed.hasPrefix("[") else { return value }
            return (try? JSONValue(jsonData: Data(trimmed.utf8))) ?? value
        }
        return value
    }

    private static func meaningful(_ value: JSONValue?) -> Bool {
        switch parsed(value) {
        case nil, .null?: return false
        case let .string(text)?: return !nonErrorText.contains(text.trimmed.lowercased())
        case let .bool(flag)?: return flag
        case let .int(number)?: return number != 0
        case let .double(number)?: return number != 0
        case let .array(items)?: return items.contains { meaningful($0) }
        case let .object(record)?: return !record.isEmpty
        }
    }

    private static func hasErrorSignal(_ record: [String: JSONValue]) -> Bool {
        let status = record["status"]?.stringValue?.trimmed ?? ""
        return record["success"]?.boolValue == false || record["ok"]?.boolValue == false
            || status.range(of: "^(error|failed|failure|fatal|exception)$", options: [.regularExpression, .caseInsensitive]) != nil
            || errorKeys.contains { meaningful(record[$0]) }
    }

    private static func valueText(_ value: JSONValue?) -> String? {
        switch parsed(value) {
        case let .string(text)?: return meaningful(.string(text)) ? clipped(text) : nil
        case let .array(items)?:
            let texts = items.compactMap { valueText($0) }.prefix(3)
            return texts.isEmpty ? nil : clipped(texts.joined(separator: "; "))
        case let .object(record)?: return firstString(record, messageKeys).map(clipped)
        default: return nil
        }
    }

    private static func clipped(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
        return lines.count > 700 ? String(lines.prefix(700)) + "…" : lines
    }
}

// MARK: - MEDIA tags

extension MediaRef {
    /// `text` without its `MEDIA:` tags, and the files they name. A tag on a line of its own is dropped with the line;
    /// one inside prose leaves the file's name in its place.
    static func split(_ text: String) -> (text: String, media: [MediaRef]) {
        guard text.contains("MEDIA:") else { return (text, []) }
        var media: [MediaRef] = []
        /// The file a tag names, and the prose punctuation that trailed a bare one.
        func add(_ raw: String) -> (ref: MediaRef, trailing: String)? {
            var path = raw.trimmed
            var trailing = ""
            if let first = path.first, "`\"'".contains(first), path.count >= 2, path.last == first {
                path = String(path.dropFirst().dropLast())
            } else {
                while let last = path.last, ".,;:!?".contains(last) { trailing.insert(path.removeLast(), at: trailing.startIndex) }
            }
            guard plausible(path) else { return nil }
            let ref = MediaRef(path: path)
            if !media.contains(ref) { media.append(ref) }
            return (ref, trailing)
        }
        var lines: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "`\"'"))
            if trimmed.hasPrefix("MEDIA:"), add(String(trimmed.dropFirst("MEDIA:".count))) != nil { continue }
            lines.append(line)
        }
        var result = lines.joined(separator: "\n")
        let inline = try! NSRegularExpression(pattern: "[`\"']?MEDIA:\\s*(`[^`\\n]+`|\"[^\"\\n]+\"|'[^'\\n]+'|[^\\s`\"]+)[`\"']?")
        for match in inline.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let value = Range(match.range(at: 1), in: result),
                  let found = add(String(result[value])) else { continue }
            result.replaceSubrange(whole, with: "`\(found.ref.name)`\(found.trailing)")
        }
        return (result.trimmingCharacters(in: .newlines), media)
    }

    /// A path or URL worth a chip, not a stray word after `MEDIA:`.
    private static func plausible(_ path: String) -> Bool {
        guard !path.isEmpty, !path.contains("MEDIA:") else { return false }
        if path.hasPrefix("/") || path.hasPrefix("~/") || path.hasPrefix("http://") || path.hasPrefix("https://") { return true }
        if path.range(of: "^[A-Za-z]:[/\\\\]", options: .regularExpression) != nil { return true }
        return !(path as NSString).pathExtension.isEmpty
    }
}

// MARK: - Small helpers

fileprivate extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
    var nonEmpty: String? { isEmpty ? nil : self }
}

fileprivate extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
