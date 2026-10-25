import SwiftUI

/// A thinking block (`ThinkingDisclosure`): "Thinking" with a ticking timer while it streams, open as a short
/// scrolling preview; settled, "Thought for Xs" and closed until tapped.
struct ReasoningRow: View {
    let reasoning: Reasoning
    /// nil until the user taps: then their choice wins over the default.
    @State private var userOpen: Bool?
    /// A preview shown while streaming stays open when the block settles, so the row doesn't jump.
    @State private var sawLive = false

    private var open: Bool { userOpen ?? (reasoning.streaming || sawLive) }
    private var isPreview: Bool { userOpen == nil && (reasoning.streaming || sawLive) }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            ScaffoldRow(open: open, onToggle: { userOpen = !open }) {
                Text(label)
            } trailing: {
                if reasoning.streaming, let start = reasoning.startedAt { TranscriptElapsed(start: start) }
            }
            if open {
                ScrollViewReader { proxy in
                    ScrollView(.vertical) {
                        MarkdownView(markdown: reasoning.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                     style: .caption, color: Theme.Text.tertiary)
                            .padding(.bottom, Theme.Spacing.xs)
                        Color.clear.frame(height: 1).id("end")
                    }
                    .frame(maxHeight: isPreview ? 160 : 420)
                    .fixedSize(horizontal: false, vertical: true)
                    .onChange(of: reasoning.text) {
                        if reasoning.streaming { proxy.scrollTo("end", anchor: .bottom) }
                    }
                }
                .opacity(0.8)
            }
        }
        .onAppear { if reasoning.streaming { sawLive = true } }
        .onChange(of: reasoning.streaming) { if reasoning.streaming { sawLive = true } }
    }

    /// "Thinking" while it runs; settled, how long it took when that was watched ("Thought briefly" under a
    /// second), else just "Thought".
    private var label: String {
        if reasoning.streaming { return "Thinking" }
        guard let duration = reasoning.duration else { return "Thought" }
        return duration < 1 ? "Thought briefly" : "Thought for \(TranscriptElapsed.format(duration))"
    }
}
