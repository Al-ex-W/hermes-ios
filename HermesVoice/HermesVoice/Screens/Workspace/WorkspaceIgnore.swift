import Foundation

/// Always hidden in the file tree and the review list (`lib/excluded-paths.ts`): VCS internals, dependency, build and
/// cache folders, OS noise.
enum WorkspaceExclusions {
    static let always: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "bower_components", ".venv", "venv", "env", "__pycache__", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", ".tox", ".gradle", ".idea", "dist", "build", "out", "target", "vendor", "Pods",
        ".next", ".nuxt", ".svelte-kit", ".output", ".turbo", ".parcel-cache", ".cache", ".terraform", ".expo", ".angular",
        "coverage", ".DS_Store", "Thumbs.db",
    ]

    /// The floor while a project shows its gitignored files: what the host strips anyway, so `out`, `vendor`,
    /// `coverage` and the like can be revealed.
    static let showIgnored: Set<String> = [
        ".git", ".hg", ".svn", "node_modules", "bower_components", ".venv", "venv", "__pycache__", ".mypy_cache",
        ".pytest_cache", ".ruff_cache", ".tox", ".gradle", ".idea", "dist", "build", "target", "Pods", ".next", ".nuxt",
        ".svelte-kit", ".output", ".turbo", ".parcel-cache", ".cache", ".terraform", ".expo", ".angular", ".DS_Store",
        "Thumbs.db",
    ]

    /// True when any segment of a relative path is always excluded (`node_modules/.bin/x`, a bare `.DS_Store`).
    static func isExcludedPath(_ relativePath: String) -> Bool {
        relativePath.split(whereSeparator: { $0 == "/" || $0 == "\\" }).contains { always.contains(String($0)) }
    }
}

/// One `.gitignore` file's rules (the `ignore` package the desktop's tree uses): comments, negation, folder-only
/// patterns, anchoring, `*`, `?`, `[…]` and `**`, matched case-insensitively. Paths are relative to `base`, the
/// folder the file sits in; a folder is tested with a trailing `/`.
struct GitignoreRules {
    struct Rule {
        let pattern: String
        let negated: Bool
        let regex: NSRegularExpression
    }

    let base: String
    let rules: [Rule]

    init(base: String, text: String) {
        self.base = base
        rules = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).compactMap { Self.rule(String($0)) }
    }

    /// Whether `relativePath` is ignored; the last matching rule decides, and `!` re-includes.
    func ignores(_ relativePath: String, isDirectory: Bool) -> Bool {
        let path = relativePath.replacingOccurrences(of: "\\", with: "/")
        guard !path.isEmpty else { return false }
        let subject = isDirectory && !path.hasSuffix("/") ? path + "/" : path
        let range = NSRange(subject.startIndex..., in: subject)
        var ignored = false
        for rule in rules where rule.negated == ignored {
            if rule.regex.firstMatch(in: subject, range: range) != nil { ignored = !rule.negated }
        }
        return ignored
    }

    static func rule(_ line: String) -> Rule? {
        var text = line
        // Trailing spaces go unless escaped with a backslash.
        while text.hasSuffix(" "), !text.hasSuffix("\\ ") { text.removeLast() }
        guard !text.isEmpty, !text.hasPrefix("#") else { return nil }
        var negated = false
        if text.hasPrefix("!") {
            negated = true
            text.removeFirst()
        }
        var directoryOnly = false
        if text.hasSuffix("/"), !text.hasSuffix("\\/") {
            directoryOnly = true
            while text.hasSuffix("/") { text.removeLast() }
        }
        guard !text.isEmpty else { return nil }
        // A separator at the start or in the middle anchors the pattern to the .gitignore's folder.
        let anchored = text.contains("/")
        while text.hasPrefix("/") { text.removeFirst() }
        guard !text.isEmpty, let source = regexSource(text, anchored: anchored, directoryOnly: directoryOnly),
              let regex = try? NSRegularExpression(pattern: source, options: [.caseInsensitive]) else { return nil }
        return Rule(pattern: line, negated: negated, regex: regex)
    }

    static func regexSource(_ pattern: String, anchored: Bool, directoryOnly: Bool) -> String? {
        let segments = pattern.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var body = ""
        var needsSlash = false
        var trailingStars = false
        for (index, segment) in segments.enumerated() {
            if segment == "**" {
                if index == segments.count - 1 {
                    // `dir/**`: everything inside, not the folder itself; a bare `**`: everything.
                    body += needsSlash ? "/.+" : ".*"
                    trailingStars = true
                } else {
                    // `**/` and `/**/`: zero or more folders.
                    body += needsSlash ? "/(?:.*/)?" : "(?:.*/)?"
                }
                needsSlash = false
            } else {
                if needsSlash { body += "/" }
                body += glob(segment)
                needsSlash = true
            }
        }
        let prefix = anchored ? "^" : "^(?:.*/)?"
        let suffix = trailingStars ? "$" : directoryOnly ? "/.*$" : "(?:/.*)?$"
        return prefix + body + suffix
    }

    /// One path segment's glob as a regex: `*` and `?` stop at `/`, `[…]` is a class, `\` escapes.
    static func glob(_ segment: String) -> String {
        let characters = Array(segment)
        var out = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case "*":
                while index + 1 < characters.count, characters[index + 1] == "*" { index += 1 }
                out += "[^/]*"
            case "?":
                out += "[^/]"
            case "\\":
                if index + 1 < characters.count {
                    index += 1
                    out += NSRegularExpression.escapedPattern(for: String(characters[index]))
                } else {
                    out += "\\\\"
                }
            case "[":
                if let (classSource, end) = characterClass(characters, from: index) {
                    out += classSource
                    index = end
                } else {
                    out += "\\["
                }
            default:
                out += NSRegularExpression.escapedPattern(for: String(character))
            }
            index += 1
        }
        return out
    }

    /// `[…]` starting at `start`: the regex class and the index of its `]`, or nil when it never closes.
    private static func characterClass(_ characters: [Character], from start: Int) -> (String, Int)? {
        var index = start + 1
        var negated = false
        if index < characters.count, characters[index] == "!" || characters[index] == "^" {
            negated = true
            index += 1
        }
        var members = ""
        var first = true
        while index < characters.count {
            let character = characters[index]
            if character == "]", !first {
                guard !members.isEmpty else { return nil }
                return ("[" + (negated ? "^" : "") + members + "]", index)
            }
            if character == "\\", index + 1 < characters.count {
                index += 1
                members += escapedMember(characters[index])
            } else if character == "-", !first, index + 1 < characters.count, characters[index + 1] != "]" {
                members += "-"
            } else if character == "/" {
                return nil
            } else {
                members += escapedMember(character)
            }
            first = false
            index += 1
        }
        return nil
    }

    private static func escapedMember(_ character: Character) -> String {
        character.isLetter || character.isNumber ? String(character) : "\\" + String(character)
    }
}
