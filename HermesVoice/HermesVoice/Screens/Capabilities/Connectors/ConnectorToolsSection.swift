import SwiftUI

/// A server's tools (`tools-panel.tsx` `LocalToolsPanel` over `tools-list.tsx`): a status line while they can't be
/// read, else the summary ("All tools" with one switch) or the full list with a switch per tool, and a footer to
/// save or discard the edit. Saving writes the server's `tools.include` / `tools.exclude`.
struct ConnectorToolsSection: View {
    @ObservedObject var model: ConnectorsModel
    let card: ConnectorCard
    let server: MCPServerSummary
    let probe: MCPTestResult?
    let probing: Bool

    @State private var editor = ConnectorToolsEditor()
    @State private var showAll = false
    @State private var query = ""
    @State private var saving = false
    @State private var expanded: Set<String> = []

    private var discovered: [MCPProbedTool] { probe?.ok == true ? probe?.tools ?? [] : [] }
    private var names: [String] { discovered.map(\.name) }
    private var savedDisabled: [String] { ConnectorToolsEditor.savedDisabled(server.tools, discovered: names) }
    /// Not connected, or a plugin's server: the switches can't be written.
    private var frozen: Bool { card.state != .connected || card.plugin != nil }

    var body: some View {
        Group {
            if !server.enabled {
                status(title: "\(card.name) is off.", body: "Turn it on with the switch above to read the tools it brings.",
                       systemImage: "powerplug")
            } else if card.reason == .serverNeedsAuth {
                status(title: "Sign in to \(card.name) to read its tools.", body: "The sign-in stays on the Hermes host.",
                       systemImage: "key")
            } else if probing || probe == nil {
                Section {
                    HStack(spacing: Theme.Spacing.md) {
                        ProgressView()
                        Text("Reading the tool list").foregroundStyle(Theme.Text.tertiary)
                    }
                } header: {
                    FormNote("Tools")
                }
                .hermesFormRows()
            } else if probe?.ok != true {
                Section {
                    HStack {
                        Text("Tool list unavailable.").foregroundStyle(Theme.Text.tertiary)
                        Spacer()
                        Button("Retry") { Task { await model.probe(server.name) } }
                            .buttonStyle(.borderless)
                    }
                } header: {
                    FormNote("Tools")
                }
                .hermesFormRows()
            } else {
                ready
            }
        }
        .task(id: savedKey) { editor.reset(saved: savedDisabled) }
    }

    /// The saved set's identity: a reload or another device's save starts the edit over.
    private var savedKey: String {
        server.name + "\u{0}" + savedDisabled.sorted().joined(separator: "\u{0}")
    }

    private func status(title: String, body: String, systemImage: String) -> some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).foregroundStyle(Theme.Text.primary)
                    Text(body).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(Theme.Text.tertiary)
            }
        } header: {
            FormNote("Tools")
        }
        .hermesFormRows()
    }

    // MARK: Ready

    @ViewBuilder private var ready: some View {
        let summary = editor.summary(names)
        Section {
            if names.isEmpty {
                FormNote("This server offers no tools.")
            } else if !showAll {
                HStack(spacing: Theme.Spacing.md) {
                    Text("All tools").foregroundStyle(Theme.Text.primary)
                    Text("\(summary.total)").monospacedDigit().foregroundStyle(Theme.Text.secondary)
                    Spacer()
                    if !frozen {
                        Text(summary.label)
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Text.tertiary)
                        Toggle("Turn every tool on or off", isOn: Binding(get: { summary.switchOn },
                                                                          set: { editor.setAll($0, tools: names) }))
                            .labelsHidden()
                    }
                }
                Button("Show all \(ConnectorFact.tools(names.count))") { showAll = true }
            } else {
                TextField("Search \(ConnectorFact.tools(names.count))", text: $query)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                let visible = filtered
                if visible.isEmpty {
                    FormNote("No tool matches these filters.")
                }
                ForEach(visible, id: \.name) { tool in
                    toolRow(tool)
                }
                Button("Show summary") {
                    showAll = false
                    query = ""
                }
            }
        } header: {
            HStack {
                FormNote(frozen && card.plugin == nil ? "What Hermes could do with \(card.name) once you connect"
                                                      : "What Hermes may do with \(card.name)")
                Spacer()
                FormNote(ConnectorFact.tools(names.count))
            }
        } footer: {
            if card.plugin != nil {
                FormNote("The plugin decides which of its tools Hermes gets.")
            }
        }
        .hermesFormRows()

        if editor.dirty && !frozen {
            Section {
                Text(editor.footer)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                HStack {
                    Button("Discard") { editor.discard() }
                        .buttonStyle(.borderless)
                        .disabled(saving)
                    Spacer()
                    Button {
                        Task { await save() }
                    } label: {
                        HStack(spacing: Theme.Spacing.sm) {
                            if saving { ProgressView() }
                            Text(saving ? "Saving..." : "Save changes")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(saving)
                }
            }
            .hermesFormRows()
        }
    }

    private var filtered: [MCPProbedTool] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return discovered }
        return discovered.filter {
            $0.name.lowercased().contains(needle) || ConnectorToolText.displayName($0.name).lowercased().contains(needle)
        }
    }

    private func toolRow(_ tool: MCPProbedTool) -> some View {
        let title = ConnectorToolText.displayName(tool.name)
        let open = expanded.contains(tool.name)
        let describes = !tool.description.isEmpty
            && Self.plainWords(tool.description) != Self.plainWords(title)
        return HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Button {
                guard describes else { return }
                if open { expanded.remove(tool.name) } else { expanded.insert(tool.name) }
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(title).foregroundStyle(Theme.Text.primary)
                    Text(tool.name).hermesText(.meta).monospaced().foregroundStyle(Theme.Text.tertiary)
                    if describes {
                        Text(tool.description)
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                            .lineLimit(open ? nil : 2)
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(describes ? (open ? "Hide what \(title) does" : "Show what \(title) does") : "")
            Toggle(editor.isOn(tool.name) ? "Turn \(title) off" : "Turn \(title) on",
                   isOn: Binding(get: { editor.isOn(tool.name) }, set: { _ in editor.toggle(tool.name) }))
                .labelsHidden()
                .disabled(frozen)
        }
    }

    /// `describesNothingNew`: a description that only repeats the name isn't worth a line.
    private static func plainWords(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if await model.saveTools(server.name, disabled: editor.disabled, discovered: names) {
            editor.markSaved()
        }
    }
}
