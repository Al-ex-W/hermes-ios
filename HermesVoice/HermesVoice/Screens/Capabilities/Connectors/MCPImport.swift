import Foundation

/// Paste-anything import for the add-server form (`lib/mcp-import.ts`): an mcp.json snippet, a bare
/// `npx`/`uvx`/`bunx`/`docker`/`node` command, a `claude mcp add` or `hermes mcp add` line, a plain server URL, or a
/// Cursor install link, read into named server entries. Pure; nil when nothing in the text reads as a server.
enum MCPImport {
    struct Entry: Equatable {
        var name: String
        var config: [String: JSONValue]
    }

    static func parse(_ text: String) -> [Entry]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let entries = cursorDeeplink(trimmed) { return entries }
        if let entries = json(trimmed) { return entries }
        // Fold shell line continuations; each remaining line is read on its own.
        let folded = trimmed.replacingOccurrences(of: #"\\\r?\n"#, with: " ", options: .regularExpression)
        var results: [Entry] = []
        for line in folded.components(separatedBy: "\n") {
            let clean = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !clean.isEmpty, let entries = parseLine(clean) { results += entries }
        }
        return results.isEmpty ? nil : results
    }

    /// `draftFromEntry`: a parsed entry as the form's fields; the typed bearer token survives a paste.
    static func draft(_ entry: Entry, previous: MCPServerDraft) -> MCPServerDraft {
        let config = normalized(entry.config)
        var draft = MCPServerDraft()
        draft.name = entry.name.isEmpty ? previous.name : entry.name
        if let url = config["url"]?.stringValue, !url.isEmpty {
            draft.transport = .http
            draft.url = url
            draft.auth = config["auth"]?.stringValue == "oauth" ? .oauth : .none
            draft.bearer = previous.bearer
            draft.headers = (config["headers"]?.objectValue ?? [:]).sorted { $0.key < $1.key }
                .map { MCPServerDraft.Pair($0.key, $0.value.stringValue ?? "") }
            return draft
        }
        draft.transport = .stdio
        draft.command = config["command"]?.stringValue ?? ""
        draft.args = (config["args"]?.arrayValue ?? []).map { MCPServerDraft.Value($0.stringValue ?? "") }
        draft.cwd = config["cwd"]?.stringValue ?? ""
        for (key, value) in (config["env"]?.objectValue ?? [:]).sorted(by: { $0.key < $1.key }) {
            if value.stringValue == MCPServerDraft.reference(key) {
                draft.passthrough.append(MCPServerDraft.Value(key))
            } else {
                draft.env.append(MCPServerDraft.Pair(key, value.stringValue ?? ""))
            }
        }
        return draft
    }

    // MARK: Shapes

    static func isServerShape(_ config: [String: JSONValue]) -> Bool {
        config["command"]?.stringValue != nil || config["url"]?.stringValue != nil
    }

    /// Cursor and Claude write `type`; Hermes reads `transport`.
    static func normalized(_ config: [String: JSONValue]) -> [String: JSONValue] {
        guard let type = config["type"], type.stringValue != nil, config["transport"] == nil else { return config }
        var next = config
        next["type"] = nil
        next["transport"] = type
        return next
    }

    private static func isURL(_ text: String) -> Bool {
        text.range(of: #"^https?://\S+$"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// "mcp.linear.app" → "linear": generic front labels dropped.
    static func name(fromURL raw: String) -> String {
        guard let host = URL(string: raw)?.host else { return "server" }
        var labels = host.split(separator: ".").map(String.init)
        while labels.count > 1, ["api", "mcp", "www"].contains(labels[0]) { labels.removeFirst() }
        return labels.first ?? "server"
    }

    /// "@modelcontextprotocol/server-filesystem@latest" → "filesystem".
    static func cleanupName(_ base: String) -> String {
        let stripped = base
            .replacingOccurrences(of: #"\.(cjs|js|mjs|py|ts)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"^(mcp-server-|server-|mcp-)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(-mcp-server|-mcp|-server)$"#, with: "", options: .regularExpression)
        return stripped.isEmpty ? base : stripped
    }

    private static func packageBasename(_ spec: String) -> String {
        var bare = spec.components(separatedBy: "==")[0]
        if let at = bare.lastIndex(of: "@"), at > bare.startIndex { bare = String(bare[..<at]) }
        return cleanupName(bare.split(separator: "/", omittingEmptySubsequences: false).last.map(String.init) ?? bare)
    }

    /// Whitespace-split with single and double quotes (backslash escapes inside double quotes); nil on an open quote.
    static func tokenize(_ line: String) -> [String]? {
        var tokens: [String] = []
        var current = ""
        var sawQuote = false
        var quote: Character?
        let characters = Array(line)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\", open == "\"", index + 1 < characters.count {
                    index += 1
                    current.append(characters[index])
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
                sawQuote = true
            } else if character.isWhitespace {
                if !current.isEmpty || sawQuote {
                    tokens.append(current)
                    current = ""
                    sawQuote = false
                }
            } else {
                current.append(character)
            }
            index += 1
        }
        if quote != nil { return nil }
        if !current.isEmpty || sawQuote { tokens.append(current) }
        return tokens
    }

    private static let stdioCommands: Set<String> = ["bunx", "docker", "node", "npx", "uvx"]
    private static let dockerValueFlags: Set<String> = [
        "--entrypoint", "--env", "--label", "--mount", "--name", "--network", "--platform", "--publish", "--pull",
        "--user", "--volume", "--workdir", "-e", "-l", "-p", "-u", "-v", "-w",
    ]

    static func inferCommandName(_ command: String, _ args: [String]) -> String {
        if command == "docker" {
            var index = args.first == "run" ? 1 : 0
            while index < args.count {
                let arg = args[index]
                if arg.hasPrefix("-") {
                    if dockerValueFlags.contains(arg) { index += 1 }
                    index += 1
                    continue
                }
                let last = arg.split(separator: "/").last.map(String.init) ?? arg
                return cleanupName(last.components(separatedBy: ":")[0])
            }
            return "docker"
        }
        if command == "node" {
            guard let script = args.first(where: { !$0.hasPrefix("-") }) else { return "node" }
            let last = script.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map(String.init) ?? script
            return cleanupName(last)
        }
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg.hasPrefix("-") {
                if arg == "--from" || arg == "--package" || arg == "-p" { index += 1 }
                index += 1
                continue
            }
            return packageBasename(arg)
        }
        return command
    }

    private static func strings(_ values: [String]) -> JSONValue { .array(values.map(JSONValue.string)) }

    private static func fromCommandLine(_ tokens: [String]) -> Entry? {
        guard let command = tokens.first, stdioCommands.contains(command) else { return nil }
        let args = Array(tokens.dropFirst())
        return Entry(name: inferCommandName(command, args), config: ["command": .string(command), "args": strings(args)])
    }

    /// `claude mcp add NAME [--transport http|sse] [-e K=V]… [--] CMD ARGS…` and `claude mcp add NAME URL`.
    private static func fromClaudeAdd(_ tokens: [String]) -> Entry? {
        var name: String?
        var transport: String?
        var rest: [String]?
        var env: [String: JSONValue] = [:]
        var headers: [String: JSONValue] = [:]
        var index = 3
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" { rest = Array(tokens[(index + 1)...]); break }
            if token == "--transport" || token == "-t" {
                index += 1
                transport = index < tokens.count ? tokens[index] : nil
            } else if token == "--env" || token == "-e" {
                index += 1
                let pair = index < tokens.count ? tokens[index] : ""
                if let eq = pair.firstIndex(of: "="), eq > pair.startIndex {
                    env[String(pair[..<eq])] = .string(String(pair[pair.index(after: eq)...]))
                }
            } else if token == "--header" || token == "-H" {
                index += 1
                let pair = index < tokens.count ? tokens[index] : ""
                if let colon = pair.firstIndex(of: ":"), colon > pair.startIndex {
                    headers[pair[..<colon].trimmingCharacters(in: .whitespaces)]
                        = .string(pair[pair.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
            } else if token == "--scope" || token == "-s" {
                index += 1
            } else if token.hasPrefix("-") {
                // An unknown flag.
            } else if name == nil {
                name = token
            } else {
                rest = Array(tokens[index...])
                break
            }
            index += 1
        }
        guard let name, let rest, let first = rest.first else { return nil }
        if rest.count == 1, isURL(first) {
            var config: [String: JSONValue] = ["url": .string(first)]
            if let transport { config["transport"] = .string(transport) }
            if !headers.isEmpty { config["headers"] = .object(headers) }
            return Entry(name: name, config: config)
        }
        var config: [String: JSONValue] = ["command": .string(first), "args": strings(Array(rest.dropFirst()))]
        if !env.isEmpty { config["env"] = .object(env) }
        return Entry(name: name, config: config)
    }

    /// `hermes mcp add NAME (--url URL | --command CMD [--args …]) [--auth MODE] [--env K=V …]`.
    private static func fromHermesAdd(_ tokens: [String]) -> Entry? {
        var name: String?, url: String?, command: String?, auth: String?
        var args: [String] = []
        var env: [String: JSONValue] = [:]
        var index = 3
        while index < tokens.count {
            let token = tokens[index]
            if token == "--args" {
                let rest = Array(tokens[(index + 1)...])
                args = rest.first == "--" ? Array(rest.dropFirst()) : rest
                break
            }
            if token == "--url" || token == "--command" || token == "--auth" {
                let value = index + 1 < tokens.count ? tokens[index + 1] : nil
                if token == "--url" { url = value } else if token == "--command" { command = value } else { auth = value }
                index += 1
            } else if token == "--env" {
                while index + 1 < tokens.count, !tokens[index + 1].hasPrefix("-") {
                    index += 1
                    let pair = tokens[index]
                    if let eq = pair.firstIndex(of: "="), eq > pair.startIndex {
                        env[String(pair[..<eq])] = .string(String(pair[pair.index(after: eq)...]))
                    }
                }
            } else if token == "--connect-timeout" || token == "--preset" {
                index += 1
            } else if !token.hasPrefix("-"), name == nil {
                name = token
            }
            index += 1
        }
        guard let name, url != nil || command != nil else { return nil }
        var config: [String: JSONValue] = url.map { ["url": .string($0)] } ?? ["command": .string(command ?? "")]
        if url == nil, !args.isEmpty { config["args"] = strings(args) }
        if let auth { config["auth"] = .string(auth) }
        if !env.isEmpty { config["env"] = .object(env) }
        return Entry(name: name, config: config)
    }

    private static func cursorDeeplink(_ text: String) -> [Entry]? {
        let prefix = "cursor://anysphere.cursor-deeplink/mcp/install?"
        guard text.lowercased().hasPrefix(prefix) else { return nil }
        let items = URLComponents(string: "x://y?" + text.dropFirst(prefix.count))?.queryItems ?? []
        guard let name = items.first(where: { $0.name == "name" })?.value, !name.isEmpty,
              let encoded = items.first(where: { $0.name == "config" })?.value,
              let data = Data(base64Encoded: padded(encoded.filter { !$0.isWhitespace })), let config = (try? JSONValue(jsonData: data))?.objectValue,
              isServerShape(config) else { return nil }
        return [Entry(name: name, config: normalized(config))]
    }

    /// `atob` takes base64 without its `=` padding; `Data` doesn't.
    private static func padded(_ base64: String) -> String {
        base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
    }

    private static func nameFromConfig(_ config: [String: JSONValue]) -> String {
        if let url = config["url"]?.stringValue { return name(fromURL: url) }
        if let command = config["command"]?.stringValue {
            return inferCommandName(command, config["args"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        }
        return "server"
    }

    /// `{"mcpServers": {…}}`, a bare name → config map, or one unnamed server (named from its command or URL).
    private static func json(_ text: String) -> [Entry]? {
        guard let data = text.data(using: .utf8), let object = (try? JSONValue(jsonData: data))?.objectValue else { return nil }
        if isServerShape(object) {
            let config = normalized(object)
            return [Entry(name: nameFromConfig(config), config: config)]
        }
        let map = (object["mcpServers"] ?? object["mcp_servers"])?.objectValue ?? object
        guard !map.isEmpty else { return nil }
        var out: [Entry] = []
        for (name, value) in map.sorted(by: { $0.key < $1.key }) {
            guard let config = value.objectValue, isServerShape(config) else { return nil }
            out.append(Entry(name: name, config: normalized(config)))
        }
        return out
    }

    private static func parseLine(_ line: String) -> [Entry]? {
        if isURL(line) { return [Entry(name: name(fromURL: line), config: ["url": .string(line)])] }
        guard let tokens = tokenize(line), !tokens.isEmpty else { return nil }
        if tokens.count >= 3, tokens[1] == "mcp", tokens[2] == "add" {
            if tokens[0] == "claude" { return fromClaudeAdd(tokens).map { [$0] } }
            if tokens[0] == "hermes" { return fromHermesAdd(tokens).map { [$0] } }
        }
        return fromCommandLine(tokens).map { [$0] }
    }
}
