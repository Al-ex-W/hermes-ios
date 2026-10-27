import SwiftUI
import UIKit

// Small pieces the Scheduled jobs, Command Center and Artifacts screens share.

/// A state pill (the desktop's `PanelPill` tones: good, warn, bad, muted).
struct OpsPill: View {
    enum Tone { case good, warn, bad, muted }

    let text: String
    var tone: Tone = .muted

    init(_ text: String, tone: Tone = .muted) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .hermesText(.meta)
            .fontWeight(.medium)
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .foregroundStyle(color)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.row))
            .fixedSize()
    }

    private var color: Color {
        switch tone {
        case .good: return Theme.primary
        case .warn: return Theme.Semantic.attention
        case .bad: return Theme.destructive
        case .muted: return Theme.Text.tertiary
        }
    }
}

/// A status dot.
struct OpsDot: View {
    let color: Color
    var size: CGFloat = 7

    var body: some View {
        Circle().fill(color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The page loader the desktop shows instead of "Loading…": a centred spinner row.
struct OpsLoaderRow: View {
    var body: some View {
        HStack { Spacer(); ProgressView(); Spacer() }
            .padding(.vertical, Theme.Spacing.md)
            .listRowBackground(Color.clear)
            .accessibilityLabel("Loading")
    }
}

/// Monospaced text to read and select (a prompt, a log tail).
struct OpsTextBlock: View {
    let text: String
    var style: Theme.TextStyle = .code
    var color: Color = Theme.Text.secondary

    var body: some View {
        Text(text)
            .hermesText(style)
            .foregroundStyle(color)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Spacing.md)
            .background(Theme.Fill.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.bubble))
            .hermesOutline()
    }
}

/// A transient confirmation of something done (the desktop's success toasts).
struct OpsNotice: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String?
}

/// A question asked before something destructive or disruptive runs.
struct OpsConfirmation: Identifiable {
    let id = UUID()
    var title: String
    var message: String
    var confirmLabel: String
    var destructive = true
    var action: () async -> Void
}

extension View {
    /// Shows `notice` at the bottom for a moment.
    func opsToast(_ notice: Binding<OpsNotice?>) -> some View {
        modifier(OpsToastModifier(notice: notice))
    }

    /// Asks `confirmation` and runs its action on yes.
    func opsConfirm(_ confirmation: Binding<OpsConfirmation?>) -> some View {
        alert(confirmation.wrappedValue?.title ?? "",
              isPresented: Binding(get: { confirmation.wrappedValue != nil }, set: { if !$0 { confirmation.wrappedValue = nil } }),
              presenting: confirmation.wrappedValue) { pending in
            Button(pending.confirmLabel, role: pending.destructive ? .destructive : nil) {
                Task { await pending.action() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(pending.message)
        }
    }

    /// The share sheet for a downloaded file; the temporary copy is deleted when the sheet closes.
    func opsShareSheet(_ file: Binding<SharedFile?>) -> some View {
        sheet(item: file, onDismiss: nil) { shared in
            ShareSheet(items: [shared.url])
                .ignoresSafeArea()
                .onDisappear { DashboardClient.removeTemporaryFile(shared.url) }
        }
    }
}

private struct OpsToastModifier: ViewModifier {
    @Binding var notice: OpsNotice?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let notice {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(notice.title).hermesText(.rowTitle).foregroundStyle(Theme.Text.primary)
                    if let message = notice.message, !message.isEmpty {
                        Text(message).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(2)
                    }
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.vertical, Theme.Spacing.lg)
                .frame(maxWidth: 420, alignment: .leading)
                .hermesFloating(radius: Theme.Radius.widget)
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.bottom, Theme.Spacing.xl)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
                .task(id: notice.id) {
                    try? await Task.sleep(for: .seconds(2.5))
                    withAnimation { self.notice = nil }
                }
                .onTapGesture { withAnimation { self.notice = nil } }
            }
        }
        .animation(.easeOut(duration: 0.2), value: notice)
    }
}

/// A button that copies `text` and says so for a moment.
struct OpsCopyButton: View {
    let text: String
    var label = "Copy"
    @State private var copied = false

    var body: some View {
        Button {
            UIPasteboard.general.string = text
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : label, systemImage: copied ? "checkmark" : Theme.Icon.copy)
        }
    }
}

extension OpsActionStatus {
    /// The pill for an action's outcome.
    var pill: OpsPill {
        switch outcome {
        case .running: return OpsPill("running", tone: .good)
        case .done: return OpsPill("done", tone: .muted)
        case .failed: return OpsPill("failed", tone: .bad)
        }
    }
}
