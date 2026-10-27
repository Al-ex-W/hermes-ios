import SwiftUI

extension SidebarDestination {
    /// The navigation rows below New session, in the desktop's order.
    static let screens: [SidebarDestination] = [.capabilities, .messaging, .artifacts, .scheduledJobs]

    var title: String {
        switch self {
        case .draft: return "New session"
        case .session: return "Session"
        case .capabilities: return "Capabilities"
        case .messaging: return "Messaging"
        case .artifacts: return "Artifacts"
        case .scheduledJobs: return "Scheduled jobs"
        case .commandCenter: return "Command Center"
        }
    }

    var icon: String {
        switch self {
        case .draft, .session: return Theme.Icon.newSession
        case .capabilities: return Theme.Icon.capabilities
        case .messaging: return Theme.Icon.messaging
        case .artifacts: return Theme.Icon.artifacts
        case .scheduledJobs: return Theme.Icon.scheduledJobs
        case .commandCenter: return Theme.Icon.commandCenter
        }
    }

    /// The milestone that brings a screen this app doesn't have yet; nil once it's here.
    var milestone: String? {
        switch self {
        case .messaging: return "M5"
        case .draft, .session, .capabilities, .artifacts, .scheduledJobs, .commandCenter: return nil
        }
    }
}

/// A desktop screen this app doesn't have yet.
struct PlaceholderScreen: View {
    let destination: SidebarDestination

    var body: some View {
        ContentUnavailableView {
            Label(destination.title, systemImage: destination.icon)
        } description: {
            Text(destination.milestone.map { "Coming in \($0)." } ?? "Not available yet.")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle(destination.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
