import SwiftUI
import UIKit

/// A chat in the detail column. On iPhone the workspace panel (the desktop's right sidebar: Files and Review) for its
/// folder is a sheet over it; on iPad it is a column of the shell beside the split view (`WorkspaceSidePanel`).
struct ChatColumn: View {
    let chat: ChatModel
    let sidebar: SidebarModel
    let client: DashboardClient
    let connection: GatewayConnection
    /// The session's folder on the host; nil shows "No project open".
    let folder: String?
    @Binding var workspaceOpen: Bool
    @Environment(\.horizontalSizeClass) private var sizeClass
    /// Copies of the chat's turn state, so a streaming reply doesn't redraw the panel.
    @State private var busy = false
    @State private var runtimeID: String?

    var body: some View {
        let stack = NavigationStack { ChatScreen(chat: chat, sidebar: sidebar, workspaceOpen: $workspaceOpen) }
        if sizeClass == .compact {
            // A sheet is a presentation of its own, so the panel's navigation stays out of the chat's.
            stack
                .sheet(isPresented: $workspaceOpen) {
                    WorkspacePanel(context: .chat(chat, sidebar: sidebar, client: client, connection: connection,
                                                  folder: folder, busy: busy, runtimeID: runtimeID,
                                                  open: $workspaceOpen, compact: true))
                }
                .onReceive(chat.$busy.removeDuplicates()) { busy = $0 }
                .onReceive(chat.$runtimeID.removeDuplicates()) { runtimeID = $0 }
        } else {
            stack
        }
    }
}

/// The workspace panel beside the chat on iPad: a column of the shell next to the split view, in a hosting
/// controller of its own. Inside the split view's detail column the chat's navigation bar spans the whole column,
/// and a panel there (an inspector) had its title, toolbar and pushed pages merged into the chat's bar.
struct WorkspaceSidePanel: View {
    let chat: ChatModel
    let sidebar: SidebarModel
    let client: DashboardClient
    let connection: GatewayConnection
    /// The session's folder on the host; nil shows "No project open".
    let folder: String?
    @Binding var open: Bool
    /// Copies of the chat's turn state, so a streaming reply doesn't redraw the panel.
    @State private var busy = false
    @State private var runtimeID: String?

    /// About as wide as the desktop's right sidebar.
    static let width: CGFloat = 360

    var body: some View {
        WorkspaceHostedPanel(context: .chat(chat, sidebar: sidebar, client: client, connection: connection, folder: folder,
                                            busy: busy, runtimeID: runtimeID, open: $open, compact: false))
            .onReceive(chat.$busy.removeDuplicates()) { busy = $0 }
            .onReceive(chat.$runtimeID.removeDuplicates()) { runtimeID = $0 }
    }
}

/// `WorkspacePanel` in a hosting controller of its own, so its NavigationStack, titles and toolbars stay inside the
/// panel, as they do in a sheet.
private struct WorkspaceHostedPanel: UIViewControllerRepresentable {
    let context: WorkspaceContext

    func makeUIViewController(context: Context) -> UIHostingController<WorkspacePanel> {
        let controller = UIHostingController(rootView: WorkspacePanel(context: self.context))
        controller.view.backgroundColor = UIColor(Theme.background)
        return controller
    }

    func updateUIViewController(_ controller: UIHostingController<WorkspacePanel>, context: Context) {
        controller.rootView = WorkspacePanel(context: self.context)
    }
}

extension WorkspaceContext {
    /// The panel's context for a chat: its folder and turn state, and the hand-offs into its composer and sidebar.
    @MainActor
    static func chat(_ chat: ChatModel, sidebar: SidebarModel, client: DashboardClient, connection: GatewayConnection,
                     folder: String?, busy: Bool, runtimeID: String?, open: Binding<Bool>, compact: Bool) -> WorkspaceContext {
        let profile = chat.profile
        return WorkspaceContext(
            client: client, gateway: connection.client, profile: profile, cwd: folder, sessionID: chat.storedID,
            runtimeSessionID: runtimeID, turnBusy: busy,
            insertIntoComposer: { [weak chat] text in chat?.composer.insert(text) },
            submitToChat: { [weak chat] text in
                guard let chat else { return }
                Task { _ = await chat.composer.sender.send(text) }
            },
            startSession: { [weak sidebar] folder in
                // The open state outlives the chat, so on iPhone the sheet would come back over the new chat.
                if compact { open.wrappedValue = false }
                sidebar?.newSession(in: folder, profile: profile)
            },
            // Beside the chat the header button closes it; as a sheet it needs its own.
            close: compact ? { open.wrappedValue = false } : nil
        )
    }
}
