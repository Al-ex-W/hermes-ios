import SwiftUI

/// Starts one spawned host action at a time and tails it through `GET /api/actions/{name}/status` (the desktop's
/// `MaintenancePanel` tail and `runSystemAction`). A later launch replaces the tail of an earlier one.
@MainActor
final class OpsActionRunner: ObservableObject {
    /// The action being (or last) tailed, by its display label.
    @Published private(set) var label: String?
    @Published private(set) var status: OpsActionStatus?
    /// A poll is going.
    @Published private(set) var polling = false

    let client: DashboardClient
    private var tail: Task<Void, Never>?

    init(client: DashboardClient) {
        self.client = client
    }

    deinit { tail?.cancel() }

    /// Something launched here still runs (its buttons stay disabled).
    var isRunning: Bool { polling && (status?.running ?? true) }

    /// Starts the action and tails it. A refused start (`ok: false`, e.g. an update the host manages itself)
    /// throws its message. `limit` caps the polls; `tolerance` is how many failed status reads in a row are
    /// survived (an update restarts the dashboard under the poll). `finished` gets the last status.
    @discardableResult
    func run(_ label: String, limit: Int = 240, tolerance: Int = 5,
             start: () async throws -> OpsActionStart,
             finished: ((OpsActionStatus?) -> Void)? = nil) async throws -> OpsActionStart {
        let started = try await start()
        guard started.ok else { throw DashboardError.rpc(started.message ?? "\(label) didn't start.") }
        tail?.cancel()
        self.label = label
        status = OpsActionStatus(name: started.name, running: true, lines: ["Action started, waiting for status..."])
        polling = true
        let name = started.name
        tail = Task { [weak self] in
            var poll = OpsActionPoll(limit: limit, maxConsecutiveFailures: tolerance)
            var step = OpsActionPoll.Step.wait
            while step == .wait, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(OpsActionPoll.interval))
                guard let self, !Task.isCancelled else { return }
                do {
                    let status = try await self.client.opsActionStatus(name)
                    guard !Task.isCancelled else { return }
                    self.status = status
                    step = poll.record(status)
                } catch {
                    if error.isCancellation { return }
                    step = poll.recordFailure()
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.polling = false
            finished?(poll.latest)
        }
        return started
    }

    /// Stops tailing (the action keeps running on the host).
    func stop() {
        tail?.cancel()
        polling = false
    }
}

/// The tail of the running or last action: its name, outcome and log.
struct OpsActionLog: View {
    @ObservedObject var runner: OpsActionRunner
    @State private var expanded = true

    var body: some View {
        if let status = runner.status {
            Section {
                DisclosureGroup(isExpanded: $expanded) {
                    OpsTextBlock(text: status.lines.isEmpty ? "No output yet." : status.lines.joined(separator: "\n"),
                                 color: Theme.Text.tertiary)
                        .padding(.top, Theme.Spacing.sm)
                    if !status.lines.isEmpty {
                        OpsCopyButton(text: status.lines.joined(separator: "\n"), label: "Copy log")
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                    }
                } label: {
                    HStack(spacing: Theme.Spacing.sm) {
                        Text(runner.label ?? status.name).foregroundStyle(Theme.Text.primary)
                        if status.running { ProgressView().controlSize(.mini) }
                        Spacer()
                        status.pill
                    }
                }
            } header: {
                FormNote("Action log")
            }
            .hermesFormRows()
        }
    }
}
