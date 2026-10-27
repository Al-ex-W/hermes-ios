import SwiftUI

extension SidebarDestination {
    /// The navigation rows below New session, in the desktop's order (`SIDEBAR_NAV`). Kanban, a plugin's
    /// contributed row, follows them while the host serves it.
    static let screens: [SidebarDestination] = [.capabilities, .messaging, .artifacts, .scheduledJobs]

    var title: String {
        switch self {
        case .draft: return "New session"
        case .session: return "Session"
        case .capabilities: return "Capabilities"
        case .messaging: return "Messaging"
        case .artifacts: return "Artifacts"
        case .scheduledJobs: return "Scheduled jobs"
        case .kanban: return KanbanScreen.title
        case .commandCenter: return "Command Center"
        case .agents: return "Agents"
        case .webhooks: return "Webhooks"
        case .memoryGraph: return "Memory Graph"
        }
    }

    var icon: String {
        switch self {
        case .draft, .session: return Theme.Icon.newSession
        case .capabilities: return Theme.Icon.capabilities
        case .messaging: return Theme.Icon.messaging
        case .artifacts: return Theme.Icon.artifacts
        case .scheduledJobs: return Theme.Icon.scheduledJobs
        case .kanban: return Theme.Icon.kanban
        case .commandCenter: return Theme.Icon.commandCenter
        case .agents: return Theme.Icon.agents
        case .webhooks: return Theme.Icon.webhooks
        case .memoryGraph: return Theme.Icon.memoryGraph
        }
    }

    /// The screen shows the sidebar's profile, so it is rebuilt when that changes. Artifacts spans every profile;
    /// Kanban boards and the subagent tree belong to none.
    var followsProfile: Bool {
        switch self {
        case .artifacts, .kanban, .agents: return false
        case .draft, .session, .capabilities, .messaging, .scheduledJobs, .commandCenter, .webhooks, .memoryGraph:
            return true
        }
    }
}
