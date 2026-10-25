import SwiftUI

/// How full the session's context is (`session.usage` context_used / max / percent), as a small ring. Tapping it
/// opens the breakdown by category (`session.context_breakdown`).
struct ContextMeter: View {
    @ObservedObject var status: StatusStackModel
    @State private var showing = false

    var body: some View {
        if let usage = status.usage, let max = usage.contextMax, max > 0 {
            let percent = Self.percent(usage)
            Button { showing = true } label: {
                ZStack {
                    Circle().stroke(Theme.Hairline.secondary, lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: CGFloat(percent) / 100)
                        .stroke(Self.tint(percent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                .frame(width: 16, height: 16)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Context usage")
            .accessibilityValue("\(usage.contextEstimated == true ? "about " : "")\(percent)% full")
            .popover(isPresented: $showing) {
                ContextBreakdownView(status: status)
                    .presentationCompactAdaptation(.popover)
            }
        }
    }

    static func percent(_ usage: Usage) -> Int {
        if let percent = usage.contextPercent { return min(100, Swift.max(0, percent)) }
        guard let used = usage.contextUsed, let max = usage.contextMax, max > 0 else { return 0 }
        return min(100, Int((Double(used) / Double(max) * 100).rounded()))
    }

    static func tint(_ percent: Int) -> Color {
        percent >= 90 ? Theme.Semantic.red : percent >= 75 ? Theme.Semantic.orange : Theme.midground
    }
}

/// The desktop's context usage panel: tokens used of the window, percent full, compressions, and a bar and list
/// of the categories filling it.
struct ContextBreakdownView: View {
    @ObservedObject var status: StatusStackModel

    var body: some View {
        let usage = status.usage
        let used = status.breakdown?.contextUsed ?? usage?.contextUsed ?? 0
        let max = status.breakdown?.contextMax ?? usage?.contextMax ?? 0
        let estimated = status.breakdown?.contextEstimated ?? usage?.contextEstimated ?? false
        let categories = status.breakdown?.categories ?? []
        let sum = categories.reduce(0) { $0 + $1.tokens }
        let total = Swift.max(1, sum > 0 ? sum : used)
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            HStack(alignment: .firstTextBaseline) {
                Text("Context Usage").hermesText(.button).foregroundStyle(Theme.Text.primary)
                Spacer()
                Text("\(estimated ? "~" : "")\(Self.compact(used)) / \(Self.compact(max)) Tokens")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
            }
            HStack {
                Text("\(estimated ? "~" : "")\(usage.map(ContextMeter.percent) ?? 0)% Full")
                Spacer()
                if let compressions = usage?.compressions {
                    Label("\(compressions) compression\(compressions == 1 ? "" : "s")", systemImage: "square.stack")
                        .foregroundStyle(Theme.Text.tertiary)
                }
            }
            .hermesText(.meta)
            .foregroundStyle(Theme.Text.primary)
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(categories, id: \.id) { category in
                        Self.color(category.color)
                            .frame(width: Swift.max(1, proxy.size.width * CGFloat(category.tokens) / CGFloat(total)))
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 6)
            .background(Theme.Hairline.tertiary)
            .clipShape(Capsule())
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                ForEach(categories, id: \.id) { category in
                    HStack(spacing: Theme.Spacing.md) {
                        RoundedRectangle(cornerRadius: 2).fill(Self.color(category.color)).frame(width: 8, height: 8)
                        Text(Self.label(category)).foregroundStyle(Theme.Text.secondary).lineLimit(1)
                        Spacer()
                        Text("~\(Self.compact(category.tokens))").monospacedDigit().foregroundStyle(Theme.Text.primary)
                    }
                }
            }
            .hermesText(.meta)
            if categories.isEmpty {
                Text(status.loadingBreakdown ? "Loading breakdown…" : "No context data yet")
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .padding(Theme.Spacing.lg)
        .frame(width: 288)
        .task { await status.loadBreakdown() }
    }

    private static func label(_ category: ContextCategory) -> String {
        switch category.id {
        case "conversation": return "Conversation"
        case "mcp": return "MCP"
        case "memory": return "Memory"
        case "rules": return "Rules"
        case "skills": return "Skills"
        case "subagent_definitions": return "Subagent definitions"
        case "system_prompt": return "System prompt"
        case "tool_definitions": return "Tool definitions"
        default: return category.label
        }
    }

    /// `#rrggbb` from the breakdown; anything else is drawn in the brand stroke.
    static func color(_ value: String) -> Color {
        var hex = value.trimmingCharacters(in: .whitespaces)
        guard hex.hasPrefix("#") else { return Theme.midground }
        hex.removeFirst()
        if hex.count == 3 { hex = hex.map { "\($0)\($0)" }.joined() }
        guard hex.count == 6, let rgb = UInt32(hex, radix: 16) else { return Theme.midground }
        return Color(red: Double(rgb >> 16 & 0xff) / 255, green: Double(rgb >> 8 & 0xff) / 255, blue: Double(rgb & 0xff) / 255)
    }

    /// 1.2k, 128k, 1.1M.
    static func compact(_ value: Int) -> String {
        switch value {
        case ..<1000: return "\(value)"
        case ..<1_000_000:
            let thousands = Double(value) / 1000
            return thousands < 10 ? String(format: "%.1fk", thousands) : "\(Int(thousands.rounded()))k"
        default:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        }
    }
}
