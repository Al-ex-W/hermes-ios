import SwiftUI

/// The connector dialog (`local-dialog.tsx` over `connector-dialog.tsx`) as a sheet: header with state and the
/// server's switch, the install lead for a catalog entry, the sign-in, the tools, the test result, usage, and
/// Advanced (the entry, Edit, Logs, Remove). The OAuth browser opens over it.
struct ConnectorDetailSheet: View {
    @ObservedObject var model: ConnectorsModel
    let cardKey: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            if let card = model.card(cardKey) {
                ConnectorDetailView(model: model, card: card) { dismiss() }
            } else {
                ContentUnavailableView("Not configured any more", systemImage: "powerplug",
                                       description: Text("This server left the host's configuration."))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    }
            }
        }
        .sheet(item: $model.browser) { page in
            SafariSheet(url: page.url).ignoresSafeArea()
        }
        .onDisappear {
            // The browser sheet lives here: a sign-in can't go on once the detail is gone.
            if let name = model.card(cardKey)?.serverName {
                model.stopAuth(name)
                model.dismissAuth(name)
            }
        }
    }
}

private struct ConnectorDetailView: View {
    @ObservedObject var model: ConnectorsModel
    let card: ConnectorCard
    let close: () -> Void
    @State private var installValues: [String: String] = [:]
    @State private var confirmingRemove = false

    private var server: MCPServerSummary? { model.server(card.serverName) }
    private var entry: MCPCatalogEntry? { card.installed ? nil : model.entry(card.entryName) }
    private var probe: MCPTestResult? { card.serverName.flatMap { model.probes[$0] } }
    private var probing: Bool { card.serverName.map(model.probing.contains) ?? false }
    private var busy: Bool { model.busy.contains(card.key) }
    /// A configured server Hermes owns (not a plugin's).
    private var owned: Bool { card.installed && card.plugin == nil }

    var body: some View {
        Form {
            header
            if let plugin = card.plugin {
                Section {
                    FormNote("Provided by plugin \(plugin). Manage it on the Plugins tab.")
                }
                .hermesFormRows()
            }
            if let entry { install(entry) }
            if let name = card.serverName, let machine = model.auth[name], machine.phase != .idle, machine.phase != .cancelled {
                ConnectorAuthSection(model: model, name: name, machine: machine)
            }
            if card.installed, let server {
                ConnectorToolsSection(model: model, card: card, server: server, probe: probe, probing: probing)
                testSection(server)
                usage(server)
                advanced(server)
            } else {
                Section {
                    FormNote("Install it on the Hermes host to see the tools it brings.")
                } header: {
                    FormNote("Tools")
                }
                .hermesFormRows()
            }
        }
        .hermesForm()
        .navigationTitle(card.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: close)
            }
            if card.installed, let name = card.serverName {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Refresh tools", systemImage: Theme.Icon.retry) { Task { await model.probe(name) } }
                        if owned {
                            Divider()
                            Button("Remove", systemImage: Theme.Icon.delete, role: .destructive) { confirmingRemove = true }
                        }
                    } label: {
                        Label("More actions", systemImage: Theme.Icon.more)
                    }
                }
            }
        }
        .confirmationDialog("Remove \(card.name)?", isPresented: $confirmingRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                guard let name = card.serverName else { return }
                Task {
                    if await model.remove(name) { close() }
                }
            }
        } message: {
            Text(ConnectorCopy.removeBody)
        }
    }

    // MARK: Header

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: Theme.Spacing.lg) {
                ConnectorTile(name: card.name, size: 40)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ConnectorTitleLine(card: card)
                    Text(card.description ?? card.target ?? card.stateWord)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
                ConnectorStateBadge(card: card)
            }
            if card.hasSwitch, let name = card.serverName {
                Toggle(isOn: Binding(get: { card.serverEnabled }, set: { next in Task { await model.setEnabled(name, next) } })) {
                    Text("Hermes can use \(card.name)")
                }
                .disabled(busy)
            }
            if let reason = card.reason {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Text(reason.text)
                        .hermesText(.caption)
                        .foregroundStyle(ConnectorStyle.reasonTone(card.state))
                    if let error = probe?.error {
                        Text(error)
                            .hermesText(.tool)
                            .monospaced()
                            .foregroundStyle(Theme.Text.secondary)
                            .textSelection(.enabled)
                    }
                }
            }
            if card.verb == .authenticate, let name = card.serverName, model.auth[name]?.isRunning != true {
                Button("Authenticate") { model.authenticate(name) }
            }
        }
        .hermesFormRows()
    }

    // MARK: Install (catalog entry)

    @ViewBuilder
    private func install(_ entry: MCPCatalogEntry) -> some View {
        Section {
            if let command = entry.command {
                LabeledRow(title: "Command", value: ([command] + entry.args).joined(separator: " "), monospaced: true)
            }
            if let url = entry.url {
                LabeledRow(title: "URL", value: url, monospaced: true)
            }
            if let source = entry.installURL {
                LabeledRow(title: "Source", value: entry.installRef.map { "\(source) @ \($0)" } ?? source, monospaced: true)
            }
            if !entry.bootstrap.isEmpty {
                LabeledRow(title: "Setup steps", value: entry.bootstrap.joined(separator: "\n"), monospaced: true)
            }
            if !entry.transport.isEmpty {
                LabeledRow(title: "Transport", value: entry.transport)
            }
            LabeledRow(title: "Sign-in", value: Self.authLabel(entry.authType))
        } header: {
            FormNote("What it runs")
        } footer: {
            FormNote("Check what it runs before installing. Hermes installs it on the host, under this profile.")
        }
        .hermesFormRows()

        Section {
            if !entry.requiredEnv.isEmpty {
                ForEach(entry.requiredEnv, id: \.name) { field in
                    VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                        Text((field.prompt.isEmpty ? field.name : field.prompt) + (field.required ? " *" : ""))
                            .hermesText(.caption)
                            .foregroundStyle(Theme.Text.secondary)
                        SecretInput(title: field.name, text: Binding(get: { installValues[field.name] ?? "" },
                                                                    set: { installValues[field.name] = $0 }))
                    }
                }
            }
            Button {
                Task {
                    if await model.install(entry, env: installValues) { installValues = [:] }
                }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if busy { ProgressView() }
                    Text(busy ? "Installing…" : "Install")
                }
            }
            .disabled(busy || !entry.canInstall(with: installValues))
        } header: {
            if !entry.requiredEnv.isEmpty { FormNote("Fill in the required values before installing.") }
        } footer: {
            if !entry.requiredEnv.isEmpty {
                FormNote("The values go to the host's .env for this profile. The phone doesn't keep them.")
            }
        }
        .hermesFormRows()
    }

    private static func authLabel(_ type: String) -> String {
        switch type {
        case "api_key": return "API key"
        case "oauth": return "OAuth"
        case "none", "": return "None"
        default: return type
        }
    }

    // MARK: Test

    private func testSection(_ server: MCPServerSummary) -> some View {
        Section {
            Button {
                Task { await model.probe(server.name) }
            } label: {
                HStack(spacing: Theme.Spacing.sm) {
                    if probing { ProgressView() }
                    Text(probing ? "Testing…" : "Test connection")
                }
            }
            .disabled(probing || !server.enabled)
            if let probe, !probing {
                if probe.ok {
                    Label(ConnectorToolText.capabilities(tools: server.tools.enabledCount(probe.tools.map(\.name)),
                                                         prompts: probe.prompts, resources: probe.resources),
                          systemImage: "checkmark.circle")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Semantic.green)
                } else {
                    Label(probe.error ?? "The server didn't answer.", systemImage: Theme.Icon.error)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Semantic.red)
                        .textSelection(.enabled)
                }
            }
        } footer: {
            FormNote("Connects to the server from the host, lists its tools and disconnects.")
        }
        .hermesFormRows()
    }

    // MARK: Usage

    @ViewBuilder
    private func usage(_ server: MCPServerSummary) -> some View {
        let uses = model.calls30d.map { MCPCost.uses(server.name, calls: $0) }
        let tokens = probe.flatMap { $0.ok ? MCPCost.tokensPerCall($0.tools, filter: server.tools) : nil }
        let parts = [uses.map { "\(MCPCost.compact($0)) uses in 30 days" },
                     tokens.flatMap { $0 > 0 ? "\(MCPCost.compact($0)) tokens per call" : nil }].compactMap { $0 }
        if !parts.isEmpty {
            Section {
                Text(parts.joined(separator: " · "))
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            .hermesFormRows()
        }
    }

    // MARK: Advanced

    private func advanced(_ server: MCPServerSummary) -> some View {
        Section {
            DisclosureGroup {
                LabeledRow(title: "Transport", value: server.transport == .http ? "Streamable HTTP" : server.transport == .stdio ? "STDIO" : "Unknown")
                if let url = server.url {
                    LabeledRow(title: "URL", value: url, monospaced: true)
                }
                if let command = server.command {
                    LabeledRow(title: "Command", value: ([command] + server.args).joined(separator: " "), monospaced: true)
                }
                ForEach(server.env, id: \.key) { variable in
                    LabeledRow(title: variable.key, value: CredentialMask.display(variable.value) ?? "Not set", monospaced: true)
                }
                if let auth = server.auth {
                    LabeledRow(title: "Auth", value: auth == "oauth" ? "OAuth" : auth == "header" ? "Header (API key)" : auth)
                }
                if let include = server.tools.include {
                    LabeledRow(title: "Tools allowed", value: include.isEmpty ? "None" : include.joined(separator: ", "), monospaced: true)
                } else if let exclude = server.tools.exclude, !exclude.isEmpty {
                    LabeledRow(title: "Tools off", value: exclude.joined(separator: ", "), monospaced: true)
                }
                if owned {
                    NavigationLink {
                        MCPServerForm(model: model, mode: .edit(server.name)) { _ in }
                    } label: {
                        Label("Edit server", systemImage: Theme.Icon.rename)
                    }
                }
                NavigationLink {
                    ConnectorLogsView(api: model.api, server: server.name)
                } label: {
                    Label("Logs", systemImage: Theme.Icon.terminal)
                }
                if owned {
                    Button(role: .destructive) {
                        confirmingRemove = true
                    } label: {
                        Label("Remove", systemImage: Theme.Icon.delete)
                    }
                    .foregroundStyle(Theme.destructive)
                }
            } label: {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text("Advanced")
                    Text("the server entry and logs")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.quaternary)
                }
            }
        } footer: {
            FormNote("Values are masked the way the host shows them.")
        }
        .hermesFormRows()
    }
}

/// The state badge (`STATE_BADGE`).
struct ConnectorStateBadge: View {
    let card: ConnectorCard

    var body: some View {
        Text(card.stateWord)
            .hermesText(.meta)
            .foregroundStyle(tone)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .background(tone.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.control))
    }

    private var tone: Color {
        switch card.state {
        case .connected: return Theme.Semantic.green
        case .broken: return Theme.Semantic.red
        case .connecting, .expired: return Theme.Semantic.orange
        case .available, .off, .unknown: return Theme.Text.tertiary
        }
    }
}

/// A title over a selectable value.
struct LabeledRow: View {
    let title: String
    let value: String
    var monospaced = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(title)
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.tertiary)
            Text(value)
                .hermesText(monospaced ? .tool : .body)
                .monospaced(monospaced)
                .foregroundStyle(Theme.Text.primary)
                .textSelection(.enabled)
        }
    }
}

// MARK: - Sign-in

/// One OAuth run (`completeMcpDesktopOAuth`): opening, waiting on the browser, done, or why it can't work.
private struct ConnectorAuthSection: View {
    @ObservedObject var model: ConnectorsModel
    let name: String
    let machine: MCPOAuthMachine

    var body: some View {
        Section {
            switch machine.phase {
            case .idle, .cancelled:
                EmptyView()
            case .starting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Opening sign-in…").foregroundStyle(Theme.Text.secondary)
                }
            case .waiting:
                HStack(spacing: Theme.Spacing.md) {
                    ProgressView()
                    Text("Waiting for your browser…").foregroundStyle(Theme.Text.secondary)
                }
                Button("Open the link again") { model.reopenAuth(name) }
                Button("Stop waiting", role: .cancel) { model.stopAuth(name) }
                    .foregroundStyle(Theme.Text.secondary)
            case let .approved(tools):
                Label("Authenticated · \(ConnectorFact.tools(tools.count))", systemImage: "checkmark.circle")
                    .foregroundStyle(Theme.Semantic.green)
                Button("Done") { model.dismissAuth(name) }
            case let .failed(message):
                Label(message, systemImage: Theme.Icon.error)
                    .foregroundStyle(Theme.Semantic.red)
                    .textSelection(.enabled)
                Button("Try again") { model.authenticate(name) }
            case let .unreachable(host):
                VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                    Label("The sign-in can't finish from this phone", systemImage: Theme.Icon.warning)
                        .foregroundStyle(Theme.Semantic.orange)
                    Text(unreachableNote(host))
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.secondary)
                        .textSelection(.enabled)
                }
                Button("Try again") { model.authenticate(name) }
            }
        } header: {
            FormNote("Sign-in")
        } footer: {
            if case let .waiting(_, url) = machine.phase {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    FormNote("Finish the sign-in in the browser. Hermes keeps the token on the host.")
                    if let redirect = MCPOAuthFlow.redirect(in: url),
                       let origin = MCPOAuthFlow.mismatchedOrigin(redirect, dashboard: model.dashboard) {
                        FormNote("The provider returns to \(origin), not the address this phone uses. If the last page "
                                 + "doesn't load, set dashboard.public_url on the host and try again.")
                    }
                }
            }
        }
        .hermesFormRows()
    }

    private func unreachableNote(_ host: String) -> String {
        var origin = "\(model.dashboard.scheme ?? "https")://\(model.dashboard.host ?? "")"
        if let port = model.dashboard.port { origin += ":\(port)" }
        let target = host.isEmpty ? "the host's own loopback address" : host
        return "The provider would send your browser back to \(target), which only the host itself can open. "
            + "Set dashboard.public_url in the host's config (or HERMES_DASHBOARD_PUBLIC_URL) to \(origin), restart the "
            + "dashboard, then try again. Or authenticate from a browser on the host."
    }
}
