import SwiftUI

/// A chat in the detail column with the workspace panel (the desktop's right sidebar: Files and Review) for its
/// folder: an inspector beside the chat on iPad, a sheet over it on iPhone.
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
        NavigationStack { ChatScreen(chat: chat, sidebar: sidebar, workspaceOpen: $workspaceOpen) }
            .inspector(isPresented: $workspaceOpen) {
                WorkspacePanel(context: context)
                    .inspectorColumnWidth(min: 320, ideal: 380, max: 560)
                    .presentationDetents([.large])
            }
            .onReceive(chat.$busy.removeDuplicates()) { busy = $0 }
            .onReceive(chat.$runtimeID.removeDuplicates()) { runtimeID = $0 }
    }

    private var context: WorkspaceContext {
        let chat = chat, sidebar = sidebar, profile = chat.profile
        return WorkspaceContext(
            client: client, gateway: connection.client, profile: chat.profile, cwd: folder, sessionID: chat.storedID,
            runtimeSessionID: runtimeID, turnBusy: busy,
            insertIntoComposer: { [weak chat] text in chat?.composer.insert(text) },
            submitToChat: { [weak chat] text in
                guard let chat else { return }
                Task { _ = await chat.composer.sender.send(text) }
            },
            startSession: { [weak sidebar] folder in sidebar?.newSession(in: folder, profile: profile) },
            // Beside the chat the header button closes it; as a sheet it needs its own.
            close: sizeClass == .compact ? { workspaceOpen = false } : nil
        )
    }
}
