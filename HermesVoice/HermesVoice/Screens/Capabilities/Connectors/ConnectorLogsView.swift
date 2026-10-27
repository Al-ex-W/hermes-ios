import SwiftUI

/// A server's log tail (`mcp-logs.tsx` `McpLogPane`): its sections of the host's `mcp.log` (stdio output) or the
/// agent log searched for its name, polled every 2 s while open.
struct ConnectorLogsView: View {
    let api: MCPAPI
    let server: String

    @State private var source: MCPLogSource = .stdio
    @State private var lines: [String]?
    @State private var error: String?
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            Picker("Log", selection: $source) {
                Text("stdio").tag(MCPLogSource.stdio)
                Text("agent").tag(MCPLogSource.agent)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.vertical, Theme.Spacing.md)
            .hermesHairline()

            content
        }
        .background(Theme.background)
        .navigationTitle("Logs")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query, prompt: "Search")
        .task(id: source) { await poll() }
    }

    @ViewBuilder private var content: some View {
        if let lines {
            let shown = filtered(lines)
            if shown.isEmpty {
                ContentUnavailableView(query.isEmpty ? "No output yet." : "No matching lines", systemImage: Theme.Icon.terminal,
                                       description: error.map { Text($0) })
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(shown.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .hermesText(.tool)
                                    .monospaced()
                                    .foregroundStyle(Theme.Text.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                        .textSelection(.enabled)
                        .padding(Theme.Spacing.lg)
                    }
                    .onAppear { proxy.scrollTo(shown.count - 1, anchor: .bottom) }
                }
            }
        } else if let error {
            ContentUnavailableView("Couldn't read the log", systemImage: Theme.Icon.error, description: Text(error))
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filtered(_ lines: [String]) -> [String] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return needle.isEmpty ? lines : lines.filter { $0.lowercased().contains(needle) }
    }

    private func poll() async {
        lines = nil
        error = nil
        while !Task.isCancelled {
            do {
                lines = try await api.logs(source, server: server)
                error = nil
            } catch {
                guard !error.isCancellation else { return }
                self.error = error.dashboardMessage
            }
            try? await Task.sleep(for: .seconds(2))
        }
    }
}
