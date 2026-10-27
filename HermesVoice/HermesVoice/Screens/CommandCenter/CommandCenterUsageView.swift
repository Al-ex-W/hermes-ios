import Charts
import SwiftUI

/// The Usage section (`UsagePanel`): sessions, API calls, tokens and cost over 7, 30 or 90 days, daily tokens, and
/// the top models and skills.
struct CommandCenterUsageView: View {
    let client: DashboardClient
    let profile: String?

    static let periods = [7, 30, 90]

    @State private var period = 30
    @State private var usage: UsageAnalytics?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        content
            .hermesForm()
            .navigationTitle("Usage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.sidebar, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Period", selection: $period) {
                        ForEach(Self.periods, id: \.self) { Text("\($0)d").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 200)
                }
            }
            .task(id: period) { await load() }
    }

    @ViewBuilder private var content: some View {
        if let usage, let totals = usage.totals {
            List {
                if let error {
                    Label(error, systemImage: Theme.Icon.error)
                        .hermesText(.caption)
                        .foregroundStyle(Theme.destructive)
                        .hermesFormRows()
                }
                Section {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .topLeading)], alignment: .leading,
                              spacing: Theme.Spacing.xl) {
                        UsageStat(label: "Sessions", value: CompactNumber.format(totals.sessions))
                        UsageStat(label: "API calls", value: CompactNumber.format(totals.apiCalls))
                        UsageStat(label: "Tokens in/out",
                                  value: "\(CompactNumber.format(totals.input)) / \(CompactNumber.format(totals.output))")
                        UsageStat(label: "Est. cost", value: Cost.format(totals.estimatedCost),
                                  hint: totals.actualCost > 0 ? "actual \(Cost.format(totals.actualCost))" : nil)
                    }
                    .padding(.vertical, Theme.Spacing.sm)
                }
                .hermesFormRows()

                Section {
                    if usage.daily.isEmpty {
                        Text("No daily activity.").foregroundStyle(Theme.Text.tertiary)
                    } else {
                        DailyTokensChart(days: usage.daily)
                            .padding(.vertical, Theme.Spacing.sm)
                    }
                } header: {
                    FormNote("Daily tokens")
                }
                .hermesFormRows()

                Section {
                    if usage.byModel.isEmpty {
                        Text("No model usage yet.").foregroundStyle(Theme.Text.tertiary)
                    }
                    ForEach(usage.byModel.prefix(6)) { model in
                        UsageRow(label: model.model, value: CompactNumber.format(model.tokens),
                                 detail: model.estimatedCost > 0 ? Cost.format(model.estimatedCost) : nil)
                    }
                } header: {
                    FormNote("Top models")
                }
                .hermesFormRows()

                Section {
                    if usage.topSkills.isEmpty {
                        Text("No skill activity yet.").foregroundStyle(Theme.Text.tertiary)
                    }
                    ForEach(usage.topSkills.prefix(6)) { skill in
                        UsageRow(label: skill.skill, value: "\(CompactNumber.format(skill.totalCount)) actions")
                    }
                } header: {
                    FormNote("Top skills")
                }
                .hermesFormRows()
            }
            .refreshable { await load() }
        } else if loading {
            List { OpsLoaderRow() }
        } else {
            ContentUnavailableView {
                Label(error == nil ? "No usage" : "Couldn't load usage", systemImage: "chart.bar")
            } description: {
                Text(error ?? "No usage in the last \(period) days.")
            } actions: {
                Button("Retry") { Task { await load() } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
        }
    }

    private func load() async {
        let requested = period
        loading = true
        defer { if requested == period { loading = false } }
        do {
            let next = try await client.usageAnalytics(days: requested, profile: profile)
            guard requested == period, !Task.isCancelled else { return }
            usage = next
            error = nil
        } catch {
            guard requested == period, !error.isCancellation else { return }
            self.error = error.dashboardMessage
        }
    }
}

private struct UsageStat: View {
    let label: String
    let value: String
    var hint: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium))
                .tracking(1.2)
                .foregroundStyle(Theme.Text.tertiary)
            Text(value)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let hint {
                Text(hint).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

private struct UsageRow: View {
    let label: String
    let value: String
    var detail: String?

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Text(label)
                .font(Theme.TextStyle.code.font)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Theme.Spacing.md)
            if let detail {
                Text(detail).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
            }
            Text(value).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).monospacedDigit()
        }
        .accessibilityElement(children: .combine)
    }
}

/// Input and output tokens per day, stacked (the desktop's bar strip).
private struct DailyTokensChart: View {
    let days: [UsageAnalytics.Day]

    private struct Bar: Identifiable {
        var day: String
        var kind: String
        var tokens: Int
        var id: String { "\(day)-\(kind)" }
    }

    private var bars: [Bar] {
        days.flatMap { [Bar(day: $0.day, kind: "input", tokens: $0.inputTokens), Bar(day: $0.day, kind: "output", tokens: $0.outputTokens)] }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Chart(bars) { bar in
                BarMark(x: .value("Day", bar.day), y: .value("Tokens", bar.tokens))
                    .foregroundStyle(by: .value("Kind", bar.kind))
            }
            .chartForegroundStyleScale(["input": Theme.primary.opacity(0.55), "output": Theme.Semantic.success.opacity(0.65)])
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Theme.Hairline.tertiary)
                    AxisValueLabel {
                        if let tokens = value.as(Int.self) {
                            Text(CompactNumber.format(tokens)).hermesText(.meta).foregroundStyle(Theme.Text.quaternary)
                        }
                    }
                }
            }
            .chartLegend(position: .top, alignment: .trailing)
            .frame(height: 140)
            .accessibilityLabel("Daily tokens")
            HStack {
                Text(days.first?.day ?? "")
                Spacer()
                Text(days.last?.day ?? "")
            }
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.tertiary)
        }
    }
}
