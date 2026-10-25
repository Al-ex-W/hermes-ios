import SwiftUI

/// A run of tool calls (`ToolRun` / `ToolGroupSlot`). One call is its row; several are one summary line ("Explored
/// 3 files, ran 2 commands") that opens to the rows, and while the run is live the line shows the call in progress
/// under it.
struct ToolRunView: View {
    let run: ToolRun
    @State private var expanded: Bool?

    var body: some View {
        if run.calls.count == 1, let call = run.calls.first {
            ToolRow(call: call)
        } else {
            let open = expanded ?? false
            VStack(alignment: .leading, spacing: Theme.Spacing.toolRow) {
                ScaffoldRow(open: open, onToggle: { expanded = !open }) {
                    Text(ToolRunSummary.summarize(run.calls, live: run.live))
                } trailing: {
                    if run.live, let start = run.calls.first?.startedAt { TranscriptElapsed(start: start) }
                }
                if open {
                    ForEach(run.calls) { ToolRow(call: $0) }
                } else if run.live, let current = run.calls.last(where: \.isPending) ?? run.calls.last {
                    ToolRow(call: current)
                        .id(current.id)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                        .padding(.leading, Theme.Spacing.lg)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: run.calls.last?.id)
        }
    }
}

/// One tool call (`ToolEntry`): status glyph, title and meta on one line; tapped, its command and exit code, output,
/// diff, search hits and raw payload. Spoken lines keep the green speaker style.
struct ToolRow: View {
    let call: ToolCall
    @State private var userOpen: Bool?

    var body: some View {
        if call.isSpeech {
            SpeechRow(call: call)
        } else if call.drawsNothing {
            EmptyView()
        } else {
            let status = call.status
            let open = userOpen ?? (call.diff != nil && call.done)
            let expandable = hasBody(status)
            VStack(alignment: .leading, spacing: 0) {
                ScaffoldRow(open: open, onToggle: expandable ? { userOpen = !open } : nil) {
                    header(status)
                } trailing: {
                    if call.isPending, let start = call.startedAt { TranscriptElapsed(start: start) }
                }
                .padding(.horizontal, open ? Theme.Spacing.md : 0)
                .padding(.vertical, open ? Theme.Spacing.xs : 0)
                if open {
                    Rectangle().fill(Theme.Hairline.tertiary).frame(height: Theme.hairlineWidth)
                    ToolDetail(call: call, status: status).padding(Theme.Spacing.sm)
                }
            }
            .overlay {
                if open {
                    RoundedRectangle(cornerRadius: Theme.Radius.control * 2)
                        .strokeBorder(Theme.Hairline.tertiary, lineWidth: Theme.hairlineWidth)
                }
            }
        }
    }

    @ViewBuilder
    private func header(_ status: ToolStatus) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            switch status {
            case .running: ScaffoldSpinner()
            case .error: ScaffoldGlyph(symbol: Theme.Icon.error, color: Theme.Semantic.red)
            case .warning: ScaffoldGlyph(symbol: Theme.Icon.error, color: Theme.Semantic.attention)
            default: ScaffoldGlyph(symbol: call.symbol)
            }
            Text(call.title)
                .foregroundStyle(status == .error ? Theme.Semantic.red : status == .warning ? Theme.Semantic.attention : Theme.Text.scaffold)
                .truncationMode(.tail)
            if let server = call.server, call.done {
                Text(server).hermesText(.meta).foregroundStyle(Theme.Text.scaffoldMeta)
            }
            if call.done, let counts = call.diffCounts {
                HStack(spacing: Theme.Spacing.xs) {
                    if counts.added > 0 { Text("+\(counts.added)").foregroundStyle(Theme.Semantic.diffAddForeground) }
                    if counts.removed > 0 { Text("−\(counts.removed)").foregroundStyle(Theme.Semantic.diffRemoveForeground) }
                }
                .font(.system(size: 10, design: .monospaced))
            } else if call.done, !call.isFileEdit, let duration = call.durationLabel {
                Text(duration).hermesText(.meta).foregroundStyle(Theme.Text.scaffoldMeta).monospacedDigit()
            }
        }
    }

    private func hasBody(_ status: ToolStatus) -> Bool {
        call.diff != nil || call.output != nil || call.stdout != nil || call.stderr != nil || !call.searchHits.isEmpty
            || (call.name == "terminal" && (call.command != nil || call.exitCode != nil)) || status == .error
            || !call.args.isEmpty || call.result != nil
    }
}

/// What an opened tool row shows.
private struct ToolDetail: View {
    let call: ToolCall
    let status: ToolStatus
    @State private var showPayload = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            if call.name == "terminal" {
                TerminalCommand(command: call.command, exitCode: call.exitCode)
            }
            if let diff = call.diff {
                DiffView(diff: diff)
            } else if status == .error, let error = call.errorDescription {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(error)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Semantic.red)
                        .textSelection(.enabled)
                    if let output = call.output, output != error { OutputBlock(text: output) }
                }
            } else if !call.searchHits.isEmpty {
                SearchHits(hits: call.searchHits)
            } else if call.stdout != nil || call.stderr != nil {
                if let stdout = call.stdout { OutputBlock(text: stdout, label: call.stderr != nil ? "stdout" : nil) }
                if let stderr = call.stderr { OutputBlock(text: stderr, label: "stderr", dimmed: true) }
            } else if let output = call.output {
                OutputBlock(text: output)
            }
            if !call.args.isEmpty || call.result != nil {
                Button {
                    showPayload.toggle()
                } label: {
                    HStack(spacing: Theme.Spacing.xs) {
                        Image(systemName: Theme.Icon.disclosure)
                            .font(.system(size: 8, weight: .semibold))
                            .rotationEffect(.degrees(showPayload ? 90 : 0))
                        Text("TOOL PAYLOAD").font(.system(size: 9.5, weight: .medium)).tracking(0.8)
                    }
                    .foregroundStyle(Theme.Text.tertiary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if showPayload { OutputBlock(text: call.payloadText, small: true) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Raw output: monospaced, scrollable within a few lines, with copy.
private struct OutputBlock: View {
    let text: String
    var label: String?
    var dimmed = false
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack {
                if let label {
                    Text(label.uppercased()).font(.system(size: 9.5, weight: .medium)).tracking(0.8).foregroundStyle(Theme.Text.tertiary)
                }
                Spacer()
                TranscriptCopyButton(text: text, label: "Copy output")
            }
            ScrollView(.vertical) {
                Text(ToolCall.clamp(text.trimmingCharacters(in: .newlines)))
                    .font(.system(size: small ? 10 : 11, design: .monospaced))
                    .foregroundStyle(dimmed ? Theme.Text.tertiary : Theme.Text.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// `$ command` with its exit code, green for 0 and amber otherwise.
private struct TerminalCommand: View {
    let command: String?
    let exitCode: Int?

    var body: some View {
        if command != nil || exitCode != nil {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                if let command {
                    (Text("$ ").foregroundStyle(Theme.primary) + Text(command).foregroundStyle(Theme.Text.secondary))
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let exitCode {
                    Text("exit \(exitCode)")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(exitCode == 0 ? Theme.Semantic.green : Theme.Semantic.attention)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Theme.Fill.tertiary, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
                }
            }
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.sm)
            .background(Theme.Fill.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .hermesOutline(radius: Theme.Radius.control)
        }
    }
}

/// A unified diff, lines tinted by what they add or remove.
struct DiffView: View {
    let diff: String

    var body: some View {
        let lines = Array(diff.split(separator: "\n", omittingEmptySubsequences: false).prefix(400))
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(Self.foreground(line))
                        .padding(.horizontal, Theme.Spacing.sm)
                        .frame(minHeight: 16, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Self.background(line))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxHeight: 320)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private static func foreground(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return Theme.Text.tertiary }
        if line.hasPrefix("+") { return Theme.Semantic.diffAddForeground }
        if line.hasPrefix("-") { return Theme.Semantic.diffRemoveForeground }
        if line.hasPrefix("@@") { return Theme.Semantic.cyan }
        return Theme.Text.secondary
    }

    private static func background(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .clear }
        if line.hasPrefix("+") { return Theme.Semantic.diffAddBackground }
        if line.hasPrefix("-") { return Theme.Semantic.diffRemoveBackground }
        return .clear
    }
}

private struct SearchHits: View {
    let hits: [ToolSearchHit]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            ForEach(Array(hits.enumerated()), id: \.offset) { _, hit in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    if let url = hit.url.flatMap(URL.init(string:)) {
                        Link(hit.title, destination: url).hermesText(.tool).foregroundStyle(Theme.Text.secondary)
                    } else {
                        Text(hit.title).hermesText(.tool).foregroundStyle(Theme.Text.secondary)
                    }
                    if let snippet = hit.snippet {
                        Text(snippet).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(3)
                    }
                }
            }
        }
    }
}

/// What Hermes said out loud on a call: the speaker glyph and the words, in green.
struct SpeechRow: View {
    let call: ToolCall

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
            Image(systemName: call.isPending ? "speaker.wave.2" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .symbolEffect(.variableColor.iterative, isActive: call.isPending)
            Text(call.spokenText ?? (call.isPending ? "speaking…" : "spoke"))
                .hermesText(.tool)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(call.status == .error ? Theme.Semantic.red : Theme.Semantic.green)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
