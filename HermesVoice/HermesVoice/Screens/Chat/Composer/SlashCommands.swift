import Foundation

/// A slash command the app fulfils itself.
enum SlashAction: Equatable {
    /// `/new`: a fresh chat.
    case newChat
    /// `/branch`: the conversation continues in a new chat.
    case branch
    /// `/model`: the model menu.
    case chooseModel
    /// `/resume`: the session list.
    case chooseSession
    /// `/journey` (`/learning`, `/memory-graph`): the memory graph.
    case openMemoryGraph
}

/// What a slash command asks of the chat it runs in (`ChatModel` provides it).
@MainActor
protocol SlashCommandHost: AnyObject {
    /// The live session the command runs against, attaching first.
    func slashSessionID() async throws -> String
    /// Shows a command's output in the transcript, as a system row.
    func showSlashOutput(_ text: String)
    /// Sends a prompt a command produced (a skill's body, a `/goal` kickoff), or queues it while a turn runs.
    /// `display` is what the user bubble shows instead of an expanded skill body.
    func sendSlashPrompt(_ text: String, display: String?) async -> Bool
    /// Loads text into the composer (`/undo`).
    func prefillComposer(_ text: String)
    func performSlashAction(_ action: SlashAction) async
    /// Hermes rewrote the stored transcript (`/compress`, `/retry`, `/undo`): show the new one.
    func transcriptChanged() async
}

/// `/name arg…` split the way Hermes splits it: the lower-cased name without the slash, and the argument with its
/// outer whitespace trimmed (its interior, newlines included, kept).
struct SlashCommand: Equatable {
    var name: String
    var arg: String

    init(name: String, arg: String) {
        self.name = name
        self.arg = arg
    }

    init(_ text: String) {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }
        guard let first = body.first, !first.isWhitespace else {
            name = ""
            arg = ""
            return
        }
        let end = body.firstIndex(where: \.isWhitespace) ?? body.endIndex
        name = body[..<end].lowercased()
        arg = body[end...].trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Runs a slash command as the desktop does (`use-prompt-actions/slash.ts`): the commands it owns run locally or
/// through their own RPC (`/stop`, `/title`, `/reasoning`, `/yolo`, `/compress`, `/btw`, `/bg`, `/save`,
/// `/status`, `/help`), the app's own become a `SlashAction`, and every other one runs on Hermes through
/// `slash.exec`, falling back to `command.dispatch` for skill, send, alias and prefill directives.
@MainActor
struct SlashCommandRunner {
    let client: GatewayClient
    let profile: String?
    let host: SlashCommandHost
    /// The last `commands.catalog`, for aliases and the commands this app can't offer.
    var catalog: CommandsCatalogResult?

    /// Desktop-local commands with no counterpart here.
    nonisolated static let unavailable: Set<String> = [
        "wake", "pet", "hatch", "generate-pet", "skin", "browser", "handoff", "profile", "voice",
    ]
    /// The commands run here rather than through `slash.exec`.
    nonisolated static let local: Set<String> = [
        "new", "reset", "clear", "branch", "fork", "model", "resume", "sessions", "switch", "stop", "title", "reasoning",
        "yolo", "help", "commands", "compress", "compact", "btw", "bg", "background", "save", "status", "journey",
        "learning", "memory-graph",
    ]
    /// The commands that rewind Hermes' stored transcript before their directive comes back.
    nonisolated static let rewinding: Set<String> = ["retry", "undo"]
    /// The longest a `/compress` summary may take.
    static let compressTimeout: TimeInterval = 300

    /// Runs `text`; false when the chat couldn't be attached, so nothing ran.
    func run(_ text: String) async -> Bool {
        let command = SlashCommand(text)
        let sessionID: String
        do {
            sessionID = try await host.slashSessionID()
        } catch {
            return false
        }
        guard !command.name.isEmpty else {
            // A degenerate `/ words` keeps the words.
            let rest = text.trimmingCharacters(in: .whitespacesAndNewlines).drop { $0 == "/" }
            if !rest.trimmingCharacters(in: .whitespaces).isEmpty { host.prefillComposer(text) }
            host.showSlashOutput("Type a command name after the slash.")
            return true
        }
        await run(command, sessionID: sessionID)
        return true
    }

    private func run(_ command: SlashCommand, sessionID: String) async {
        let name = canonical(command.name)
        if let reason = unavailableMessage(name) {
            host.showSlashOutput(reason)
            return
        }
        switch name {
        case "new", "reset", "clear":
            await host.performSlashAction(.newChat)
        case "branch", "fork":
            await host.performSlashAction(.branch)
        case "model":
            await host.performSlashAction(.chooseModel)
        case "resume", "sessions", "switch":
            await host.performSlashAction(.chooseSession)
        case "journey", "learning", "memory-graph":
            // The desktop opens its memory graph instead of printing the timeline; arguments are ignored.
            await host.performSlashAction(.openMemoryGraph)
        case "stop":
            await stop(sessionID)
        case "title" where !command.arg.isEmpty:
            await rename(command.arg, sessionID)
        case "reasoning":
            await reasoning(command, sessionID)
        case "yolo":
            await output(command) {
                let result = try await client.configSet(.init(profile: profile, key: "yolo", value: "toggle", sessionId: sessionID))
                return Self.text(result.value) == "1" ? "YOLO on — dangerous commands run without asking." : "YOLO off — dangerous commands ask first."
            }
        case "help", "commands":
            await output(command) {
                Self.render(try await client.commandsCatalog(.init(sessionId: sessionID, profile: profile)))
            }
        case "compress", "compact":
            await compress(command, sessionID)
        case "btw":
            await sideTask(command, sessionID, usage: "Usage: /btw <question> — answered from a snapshot of this conversation without interrupting it.") { text in
                let task = try await Self.lenient { try await client.promptBtw(.init(sessionId: sessionID, profile: profile, text: text)) }?.taskId
                return "btw\(task.map { " \($0)" } ?? "") — answering from a conversation snapshot"
            }
        case "bg", "background":
            await sideTask(command, sessionID, usage: "Usage: /background <prompt> — the task runs in a separate session and the result appears here when done.") { text in
                let task = try await Self.lenient { try await client.promptBackground(.init(sessionId: sessionID, profile: profile, text: text)) }?.taskId
                return "Background task\(task.map { " \($0)" } ?? "") started — you can continue chatting; the result will appear here when done."
            }
        case "save":
            await output(command, fallback: true) {
                try await client.sessionSave(.init(sessionId: sessionID, profile: profile)).file.map { "Saved transcript to \($0)" } ?? "/save: no output"
            }
        case "status":
            await output(command, fallback: true) {
                try await client.sessionStatus(.init(sessionId: sessionID, profile: profile)).output
            }
        default:
            await exec(command, sessionID)
        }
    }

    // MARK: Local commands

    /// `/stop` ends the turn, then every background process (`process.stop` is registry-wide).
    private func stop(_ sessionID: String) async {
        var lines: [String] = []
        do {
            _ = try await Self.lenient { try await client.sessionInterrupt(.init(sessionId: sessionID, profile: profile)) }
            lines.append("Stopped the active turn.")
        } catch {
            lines.append("Could not stop the active turn: \(error.localizedDescription)")
        }
        do {
            let killed = try await Self.lenient { try await client.processStop(.init()) }?.killed
            if let killed {
                lines.append(killed > 0 ? "Stopped \(killed) background process\(killed == 1 ? "" : "es")." : "No background processes to stop.")
            }
        } catch {
            lines.append("Could not stop background processes: \(error.localizedDescription)")
        }
        host.showSlashOutput(lines.joined(separator: "\n"))
    }

    private func rename(_ title: String, _ sessionID: String) async {
        do {
            let result = try await Self.lenient { try await client.sessionTitle(.init(sessionId: sessionID, profile: profile, title: title)) }
            let final = (result?.title ?? title).trimmingCharacters(in: .whitespacesAndNewlines)
            let pending = result?.pending == true ? " (queued while session initializes)" : ""
            host.showSlashOutput(final.isEmpty ? "Session title cleared." : "Session title set: \(final)\(pending)")
        } catch {
            host.showSlashOutput("error: \(error.localizedDescription)")
        }
    }

    /// `/reasoning [level|show|hide|full|clamp] [--global|--session]` through `config.set key=reasoning`; bare, the
    /// current setting.
    private func reasoning(_ command: SlashCommand, _ sessionID: String) async {
        var scope: String?
        var values: [String] = []
        for part in command.arg.split(whereSeparator: \.isWhitespace).map(String.init) {
            switch part.lowercased() {
            case "--global", "-g", "global": scope = "global"
            case "--session", "-s", "session": scope = "session"
            default: values.append(part)
            }
        }
        await output(command, fallback: true) {
            guard !values.isEmpty else {
                let current = try await client.configGet(.init(profile: profile, key: "reasoning", sessionId: sessionID))
                return "reasoning: \(current.value ?? "medium") · display \(current.display ?? "hide")"
            }
            let value = values.joined(separator: " ")
            let result = try await client.configSet(.init(profile: profile, key: "reasoning", value: .string(value),
                                                          sessionId: sessionID, scope: scope))
            return "reasoning: \(Self.text(result.value) ?? value)"
        }
    }

    private func compress(_ command: SlashCommand, _ sessionID: String) async {
        host.showSlashOutput(command.arg.isEmpty ? "compressing context..." : "compressing context for: \(command.arg)")
        do {
            let result = try await client.sessionCompress(
                .init(sessionId: sessionID, profile: profile, focusTopic: command.arg.isEmpty ? nil : command.arg),
                timeout: Self.compressTimeout
            )
            if result.status == "pending" {
                host.showSlashOutput(result.message ?? "compression still running in the background")
                return
            }
            if let summary = result.summary, let headline = summary.headline, !headline.isEmpty {
                var lines = ["\(summary.noop == true ? "" : "✓ ")\(headline)"]
                if let line = summary.tokenLine { lines.append("  \(line)") }
                if let note = summary.note { lines.append("  \(note)") }
                host.showSlashOutput(lines.joined(separator: "\n"))
            } else if let removed = result.removed {
                host.showSlashOutput("✓ Compressed: \(removed) message\(removed == 1 ? "" : "s") summarized")
            }
            await host.transcriptChanged()
        } catch let error as GatewayRPCError where error.code == -32601 {
            await exec(command, sessionID)
        } catch {
            host.showSlashOutput("error: \(error.localizedDescription)")
        }
    }

    private func sideTask(_ command: SlashCommand, _ sessionID: String, usage: String,
                          _ start: (String) async throws -> String) async {
        guard !command.arg.isEmpty else {
            host.showSlashOutput(usage)
            return
        }
        do {
            host.showSlashOutput(try await start(command.arg))
        } catch let error as GatewayRPCError where error.code == -32601 {
            await exec(command, sessionID)
        } catch {
            host.showSlashOutput("error: \(error.localizedDescription)")
        }
    }

    /// Shows what `body` answers, or its error. `fallback`: an older Hermes without the method runs it through exec.
    private func output(_ command: SlashCommand, fallback: Bool = false, _ body: () async throws -> String) async {
        do {
            let text = try await body()
            host.showSlashOutput(text.isEmpty ? "/\(command.name): no output" : text)
        } catch let error as GatewayRPCError where fallback && error.code == -32601 {
            guard let sessionID = try? await host.slashSessionID() else { return }
            await exec(command, sessionID)
        } catch {
            host.showSlashOutput("error: \(error.localizedDescription)")
        }
    }

    // MARK: Hermes' commands

    /// `slash.exec`; a directive (or a worker failure) goes through `command.dispatch`.
    private func exec(_ command: SlashCommand, _ sessionID: String) async {
        let line = command.arg.isEmpty ? command.name : "\(command.name) \(command.arg)"
        var execError: Error?
        do {
            let result: SlashExecResult
            do {
                result = try await client.slashExec(.init(sessionId: sessionID, command: line, profile: profile))
            } catch let error as GatewayDecodingError {
                result = SlashExecResult(output: error.raw["output"]?.stringValue, warning: error.raw["warning"]?.stringValue)
            }
            if let type = result.type, let dispatch = Dispatch(type: type, output: result.output, target: result.target,
                                                                message: result.message, notice: result.notice,
                                                                display: result.display) {
                await handle(dispatch, command, sessionID)
                return
            }
            let body = (result.output?.isEmpty == false ? result.output : nil) ?? "/\(command.name): no output"
            host.showSlashOutput(result.warning.map { "warning: \($0)\n\(body)" } ?? body)
            return
        } catch {
            execError = error
        }
        do {
            let result = try await client.commandDispatch(.init(name: command.name, arg: command.arg.isEmpty ? nil : command.arg,
                                                                sessionId: sessionID, profile: profile))
            guard let dispatch = Dispatch(type: result.type, output: result.output, target: result.target, message: result.message,
                                          notice: result.notice, display: result.display) else {
                host.showSlashOutput("error: invalid response: command.dispatch")
                return
            }
            await handle(dispatch, command, sessionID)
        } catch {
            // "not a quick/plugin/skill command" only says the fallback had nothing to add.
            if let execError, error.localizedDescription.range(of: #"not a quick/plugin/(bundle/)?skill command"#, options: [.regularExpression, .caseInsensitive]) != nil {
                host.showSlashOutput("error: /\(command.name) failed: \(execError.localizedDescription)")
            } else {
                host.showSlashOutput("error: \(error.localizedDescription)")
            }
        }
    }

    /// A `command.dispatch` answer (`apps/shared/src/slash.ts`).
    private enum Dispatch {
        case output(String?)
        case alias(String)
        /// `skill`: the message is a skill's expanded body, never shown.
        case send(message: String, notice: String?, display: String?, skill: Bool)
        case prefill(message: String, notice: String?)

        init?(type: DispatchType, output: String?, target: String?, message: String?, notice: String?, display: String?) {
            switch type {
            case .exec, .plugin: self = .output(output)
            case .alias:
                guard let target else { return nil }
                self = .alias(target)
            case .send, .skill:
                self = .send(message: message ?? "", notice: notice, display: display, skill: type == .skill)
            case .prefill:
                guard let message else { return nil }
                self = .prefill(message: message, notice: notice)
            case .unknown:
                return nil
            }
        }
    }

    private func handle(_ dispatch: Dispatch, _ command: SlashCommand, _ sessionID: String) async {
        if Self.rewinding.contains(canonical(command.name)) {
            switch dispatch {
            case .send, .prefill: await host.transcriptChanged()
            default: break
            }
        }
        switch dispatch {
        case let .output(text):
            host.showSlashOutput(text ?? "(no output)")
        case let .alias(target):
            await run(SlashCommand("/\(target) \(command.arg)"), sessionID: sessionID)
        case let .prefill(message, notice):
            if let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty { host.showSlashOutput(notice) }
            let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            if !message.isEmpty { host.prefillComposer(message) }
        case let .send(message, notice, display, skill):
            if let notice = notice?.trimmingCharacters(in: .whitespacesAndNewlines), !notice.isEmpty { host.showSlashOutput(notice) }
            let message = message.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !message.isEmpty else {
                host.showSlashOutput("/\(command.name): \(skill ? "skill payload missing message" : "empty message")")
                return
            }
            _ = await host.sendSlashPrompt(message, display: Self.shown(message, display: display, skill: skill, command: command))
        }
    }

    /// What the bubble of a directive's message shows (the desktop's `projected || skillInvocationText(message)`):
    /// the projection Hermes sent, else the invocation a skill scaffold names, else the message itself (nil). A
    /// skill body is never shown, so one without either shows the command typed.
    nonisolated static func shown(_ message: String, display: String?, skill: Bool, command: SlashCommand) -> String? {
        if let display = display?.trimmingCharacters(in: .whitespacesAndNewlines), !display.isEmpty { return display }
        if let invocation = skillInvocation(message) { return invocation }
        guard skill else { return nil }
        return command.arg.isEmpty ? "/\(command.name)" : "/\(command.name) \(command.arg)"
    }

    /// The invocation a skill scaffold came from (`/work fix the leak`), or nil for ordinary prose
    /// (`shared/src/skill-scaffold.ts`, mirroring `agent/skill_commands.py`).
    nonisolated static func skillInvocation(_ text: String) -> String? {
        let prefix = "[IMPORTANT: The user has invoked the "
        guard text.hasPrefix(prefix + "\"") else { return nil }
        let afterQuote = text.dropFirst(prefix.count + 1)
        guard let close = afterQuote.firstIndex(of: "\"") else { return nil }
        let name = afterQuote[..<close].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        let label = name.hasPrefix("/") ? name : "/\(name)"
        func between(_ marker: String, _ end: String, fromEnd: Bool = false) -> String {
            guard let found = fromEnd ? text.range(of: marker, options: .backwards) : text.range(of: marker) else { return "" }
            let tail = text[found.upperBound...]
            let stop = tail.range(of: end)?.lowerBound ?? tail.endIndex
            return tail[..<stop].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let instruction: String
        if text.contains(" skill bundle,") {
            instruction = between("\nUser instruction: ", "\n\n[Loaded as part of the ")
        } else if text.contains("The full skill content is loaded below.]") {
            instruction = between("The user has provided the following instruction alongside the skill invocation: ",
                                  "\n\n[Runtime note:", fromEnd: true)
        } else {
            instruction = ""
        }
        guard !instruction.isEmpty else { return label }
        return "\(label) \(instruction.split(whereSeparator: \.isWhitespace).joined(separator: " "))"
    }

    // MARK: Catalog

    private func canonical(_ name: String) -> String {
        guard let canon = catalog?.canon else { return name }
        let key = "/\(name)"
        return (canon[key] ?? canon[key.lowercased()]).map { String($0.drop { $0 == "/" }) } ?? name
    }

    /// Why `name` can't run here, if it can't.
    private func unavailableMessage(_ name: String) -> String? {
        let command = "/\(name)"
        if name == "voice" { return "\(command) isn't available here. Use the call button to talk with Hermes." }
        if Self.unavailable.contains(name) { return "\(command) isn't available on iPhone." }
        // The commands handled here win over the catalog's disposition (`/clear` is `/new` here).
        if Self.local.contains(name) { return nil }
        switch catalog?.commands?[command]?.desktop {
        case "terminal"?: return "\(command) is only available in the terminal interface."
        case "messaging"?: return "\(command) is only used from messaging platforms."
        case "settings"?: return "\(command) is managed from Settings."
        case "advanced"?: return "\(command) isn't offered here. Use the matching control or the terminal interface instead."
        case "composer-voice"?: return "\(command) isn't available here. Use the call button to talk with Hermes."
        default: return nil
        }
    }

    /// `/help`: the catalog by section.
    static func render(_ catalog: CommandsCatalogResult) -> String {
        let sections = catalog.categories?.isEmpty == false
            ? catalog.categories!.map { ($0.name, $0.pairs ?? []) }
            : [("", catalog.pairs ?? [])]
        var lines: [String] = []
        for (name, pairs) in sections where !pairs.isEmpty {
            if !lines.isEmpty { lines.append("") }
            if !name.isEmpty { lines.append(name) }
            for pair in pairs {
                guard let command = pair.first else { continue }
                lines.append(pair.count > 1 && !pair[1].isEmpty ? "\(command) — \(pair[1])" : command)
            }
        }
        if let warning = catalog.warning, !warning.isEmpty { lines.append("warning: \(warning)") }
        return lines.isEmpty ? "No commands available." : lines.joined(separator: "\n")
    }

    private static func text(_ value: BoolOrString?) -> String? {
        switch value {
        case let .string(text)?: return text
        case let .bool(flag)?: return flag ? "1" : "0"
        case nil: return nil
        }
    }

    /// A call whose answer may be outside the contract: nil then, since it went through.
    private static func lenient<Result>(_ call: () async throws -> Result) async throws -> Result? {
        do {
            return try await call()
        } catch is GatewayDecodingError {
            return nil
        }
    }
}
