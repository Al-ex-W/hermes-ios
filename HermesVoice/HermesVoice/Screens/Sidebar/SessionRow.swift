import SwiftUI

/// A sidebar session row (`session-row.tsx`): status dot, title, and its age on the right.
struct SessionRow: View {
    let session: SessionInfo
    let status: SessionStatus
    /// The owning profile, when the list spans several.
    var profile: String?
    /// The matched text of a search hit.
    var snippet: String?

    var body: some View {
        SidebarRowLayout(status: status) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(session.displayTitle)
                    .hermesText(.rowTitle)
                    .foregroundStyle(status.hasLiveTurn ? Theme.foreground : Theme.Text.primary)
                    .lineLimit(1)
                if let snippet {
                    Text(snippet)
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                }
            }
        } trailing: {
            if let profile {
                Text(profile)
                    .hermesText(.meta)
                    .foregroundStyle(Theme.Text.quaternary)
                    .lineLimit(1)
            }
            if session.pinned, snippet == nil {
                Image(systemName: Theme.Icon.pin)
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.Text.quaternary)
                    .accessibilityLabel("Pinned")
            }
            Text(SessionGroups.age(session.lastActive))
                .hermesText(.meta)
                .monospacedDigit()
                .foregroundStyle(Theme.Text.tertiary)
        }
    }
}

/// The row of a new chat that isn't in the list yet.
struct DraftSessionRow: View {
    @ObservedObject var chat: ChatModel
    let status: SessionStatus

    var body: some View {
        SidebarRowLayout(status: status) {
            Text(chat.hasContent ? chat.title : "New session")
                .hermesText(.rowTitle)
                .foregroundStyle(Theme.Text.primary)
                .lineLimit(1)
        } trailing: {
            EmptyView()
        }
    }
}

/// Dot, content and trailing meta, at the sidebar's row height.
struct SidebarRowLayout<Content: View, Trailing: View>: View {
    let status: SessionStatus
    @ViewBuilder var content: Content
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            SessionStatusDot(status: status)
            content
            Spacer(minLength: Theme.Spacing.xs)
            HStack(spacing: Theme.Spacing.sm) { trailing }
        }
        .padding(.vertical, Theme.Spacing.sm)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One status per session (`session-status-dot.tsx`): color and fill tell the states apart, none of them moves.
/// Amber needs input, accent is running, emerald finished unread, hollow grey is a draft, faint grey idle.
struct SessionStatusDot: View {
    let status: SessionStatus

    var body: some View {
        dot
            .frame(width: 8, height: 8)
            .accessibilityHidden(status.accessibilityLabel == nil)
            .accessibilityLabel(status.accessibilityLabel ?? "")
    }

    @ViewBuilder private var dot: some View {
        switch status {
        case .needsInput: Circle().fill(Theme.Semantic.attention).frame(width: 6, height: 6)
        case .working: Circle().fill(Theme.midground).frame(width: 6, height: 6)
        case .unread: Circle().fill(Theme.Semantic.success).frame(width: 6, height: 6)
        case .draft: Circle().strokeBorder(Theme.Text.quaternary, lineWidth: 1).frame(width: 6, height: 6)
        case .idle: Circle().fill(Theme.Text.quaternary).frame(width: 4, height: 4)
        }
    }
}

/// A sidebar navigation row (`SIDEBAR_NAV`).
struct SidebarNavRow: View {
    let title: String
    let icon: String

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: Theme.IconSize.sm))
                .frame(width: Theme.IconSize.md)
            Text(title).hermesText(.body)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Theme.Text.secondary)
        .padding(.vertical, Theme.Spacing.xs)
        .contentShape(Rectangle())
    }
}
