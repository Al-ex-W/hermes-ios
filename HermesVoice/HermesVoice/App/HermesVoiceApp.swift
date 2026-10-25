import SwiftUI

@main
struct HermesVoiceApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.calls)
                .task { await model.restore() }
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calls: CallController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.signedIn, let client = model.client, let connection = model.connection {
                // A new sign-in gets a new shell (and sidebar) for its client.
                AppShell(model: model, client: client, connection: connection)
                    .id(ObjectIdentifier(client))
            } else {
                NavigationStack { LoginView() }
            }
        }
        .tint(Theme.primary)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.didBecomeActive() }
        }
        .alert("Call", isPresented: Binding(get: { calls.lastError != nil }, set: { if !$0 { calls.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calls.lastError ?? "")
        }
    }
}

/// The signed-in app: the session sidebar beside the screen it opens on iPad, stacked on iPhone.
struct AppShell: View {
    @StateObject private var sidebar: SidebarModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var compactColumn = NavigationSplitViewColumn.sidebar

    init(model: AppModel, client: DashboardClient, connection: GatewayConnection) {
        _sidebar = StateObject(wrappedValue: SidebarModel(app: model, client: client, connection: connection))
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            SidebarView(sidebar: sidebar)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
        } detail: {
            DetailColumn(sidebar: sidebar)
        }
        .onChange(of: sidebar.selection) { _, selection in
            if selection != nil {
                compactColumn = .detail
            } else if sizeClass == .compact {
                compactColumn = .sidebar
            }
        }
        // Back to the list on iPhone: nothing is open, so the same row can open again.
        .onChange(of: compactColumn) { _, column in
            if column == .sidebar, sizeClass == .compact { sidebar.selection = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await sidebar.refresh() } }
        }
    }
}

/// What the sidebar opened: a chat, a screen still to come, or nothing yet.
private struct DetailColumn: View {
    @ObservedObject var sidebar: SidebarModel
    @EnvironmentObject private var model: AppModel

    var body: some View {
        // One branch for every chat, so a draft that becomes its listed session keeps its screen.
        if let chat = openChat {
            NavigationStack { ChatScreen(chat: chat, sidebar: sidebar) }
                .id(chat.id)
                .onAppear { sidebar.show(chat) }
        } else {
            switch sidebar.selection {
            case .session?:
                ContentUnavailableView("Session unavailable", systemImage: Theme.Icon.warning,
                                       description: Text("It may have been deleted."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.background)
            case .draft?, nil:
                nothingOpen
            case let destination?:
                NavigationStack { PlaceholderScreen(destination: destination) }
            }
        }
    }

    private var openChat: ChatModel? {
        switch sidebar.selection {
        case .draft?: return sidebar.draft
        case let .session(id)?: return sidebar.summary(for: id).flatMap { model.chat(for: $0) }
        default: return nil
        }
    }

    private var nothingOpen: some View {
        ContentUnavailableView("No session open", systemImage: "bubble.left.and.bubble.right",
                               description: Text("Pick a session in the sidebar, or start a new one."))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.background)
    }
}
