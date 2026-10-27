import SwiftUI
import UIKit

@main
struct HermesVoiceApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(delegate.model)
                .environmentObject(delegate.model.calls)
                .environmentObject(delegate.model.push)
                .environmentObject(delegate.model.notifications)
                .task { await delegate.model.restore() }
        }
    }
}

/// Owns the app model from launch: a VoIP push or a notification action can start the app in the background, with
/// no window, and PushKit and the notification delegate must be set before `didFinishLaunching` returns for them to
/// be delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private(set) lazy var model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { model.startPush() }
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        MainActor.assumeIsolated { model.push.didRegisterForAlerts(deviceToken: deviceToken) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        MainActor.assumeIsolated { model.push.didFailToRegisterForAlerts(error) }
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
        .hermesAppearance()
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active: model.didBecomeActive()
            case .background: model.didEnterBackground()
            default: break
            }
        }
        #if DEBUG
        .onOpenURL { url in model.push.deliverDebugPush(url) }
        #endif
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
    /// The subagents of every chat on this connection, heard from sign-in on, so the tree and the sidebar's Agents
    /// count are current before the tree opens.
    @StateObject private var agents: AgentsStore
    @EnvironmentObject private var model: AppModel
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.scenePhase) private var scenePhase
    @State private var compactColumn = NavigationSplitViewColumn.sidebar
    /// Whether the sidebar is on screen; nil until it first shows.
    @State private var sidebarShown: Bool?
    private let client: DashboardClient
    private let connection: GatewayConnection

    init(model: AppModel, client: DashboardClient, connection: GatewayConnection) {
        self.client = client
        self.connection = connection
        _sidebar = StateObject(wrappedValue: SidebarModel(app: model, client: client, connection: connection))
        _agents = StateObject(wrappedValue: AgentsStore(connection: connection))
    }

    var body: some View {
        NavigationSplitView(preferredCompactColumn: $compactColumn) {
            SidebarView(sidebar: sidebar, agents: agents)
                .navigationSplitViewColumnWidth(min: 260, ideal: 300, max: 380)
                .onAppear {
                    let returning = sidebarShown == false
                    sidebarShown = true
                    if returning { backToList() }
                }
                .onDisappear { sidebarShown = false }
        } detail: {
            DetailColumn(sidebar: sidebar, client: client, connection: connection)
        }
        .environmentObject(agents)
        .onChange(of: sidebar.selection) { _, selection in
            if selection != nil {
                compactColumn = .detail
            } else if sizeClass == .compact {
                compactColumn = .sidebar
            }
        }
        .onChange(of: compactColumn) { _, _ in backToList() }
        .onAppear {
            let column = $compactColumn, model = sidebar
            model.revealDetail = { [weak model] in
                guard model?.compact == true, column.wrappedValue != .detail else { return false }
                column.wrappedValue = .detail
                return true
            }
        }
        .onChange(of: sizeClass, initial: true) { _, size in sidebar.compact = size == .compact }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                Task { await sidebar.refresh() }
                Task { await sidebar.refreshKanban() }
            }
        }
        // A tapped notification opens its session (also one that launched the app).
        .onReceive(model.notifications.$openRequest.compactMap { $0 }.receive(on: DispatchQueue.main)) { target in
            model.notifications.openRequest = nil
            sidebar.open(sessionID: target.id, profile: target.profile)
        }
    }

    /// Back to the list on iPhone: nothing is open, so the same row can open again. Only once the list shows again:
    /// SwiftUI also reports the sidebar column when a page pushed inside a screen pops back to that screen.
    private func backToList() {
        if sizeClass == .compact, compactColumn == .sidebar, sidebarShown == true { sidebar.selection = nil }
    }
}

/// What the sidebar opened: a chat, one of the desktop's screens, or nothing yet.
private struct DetailColumn: View {
    @ObservedObject var sidebar: SidebarModel
    let client: DashboardClient
    let connection: GatewayConnection
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var agents: AgentsStore
    /// The workspace panel (the desktop's right sidebar) beside the chat. It stays open from chat to chat, as the
    /// desktop's does.
    @State private var workspaceOpen = false

    var body: some View {
        // One branch for every chat, so a draft that becomes its listed session keeps its screen.
        if let chat = openChat {
            ChatColumn(chat: chat, sidebar: sidebar, client: client, connection: connection, folder: folder(of: chat),
                       workspaceOpen: $workspaceOpen)
                .id(chat.id)
                .onAppear {
                    sidebar.show(chat)
                    agents.focus(chat)
                    model.notifications.showing(chat)
                }
                .onDisappear { model.notifications.hid(chat) }
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
                // Each screen starts on the sidebar's profile and is rebuilt when that changes. Artifacts spans
                // every profile, and Kanban boards and the subagent tree belong to no profile, so they stay.
                NavigationStack { screen(destination) }
                    .id("\(destination.title)|\(destination.followsProfile ? scope : "")")
            }
        }
    }

    @ViewBuilder private func screen(_ destination: SidebarDestination) -> some View {
        switch destination {
        case .capabilities:
            CapabilitiesView(profile: scope == SidebarOptions.allProfiles ? nil : scope)
        case .messaging:
            MessagingScreen(context: MessagingContext(client: client, profileScope: scope))
        case .artifacts:
            // The desktop indexes every profile's sessions here, whatever the sidebar shows.
            ArtifactsScreen(client: client, profile: SidebarOptions.allProfiles, openSession: openSession)
        case .scheduledJobs:
            ScheduledJobsScreen(client: client, profileScope: scope, openSession: openSession)
        case .kanban:
            KanbanScreen(context: KanbanContext(client: client))
        case .commandCenter:
            CommandCenterScreen(client: client, profileScope: scope, sessionActions: sessionActions,
                                sessionImport: SessionImportScreen.Context(client: client, connection: connection,
                                                                           profileScope: scope, openSession: openSession),
                                openSession: openSession)
        case .agents:
            AgentsScreen(context: .init(store: agents, openSession: openSession))
        case .webhooks:
            WebhooksScreen(context: MessagingContext(client: client, profileScope: scope))
        case .memoryGraph:
            StarmapScreen(context: .init(client: client, profileScope: scope))
        case .draft, .session:
            // Chats show above; these never reach here.
            nothingOpen
        }
    }

    /// The sidebar's profile, or `SidebarOptions.allProfiles`.
    private var scope: String { sidebar.options.profileScope }

    /// The chat's folder on the host: its session row's, or the folder a new chat starts in.
    private func folder(of chat: ChatModel) -> String? {
        if let id = chat.storedID, let cwd = sidebar.row(id)?.cwd, !cwd.isEmpty { return cwd }
        return chat.isNewChat ? chat.workingFolder : nil
    }

    /// A session a screen links to opens in this column, as a tapped sidebar row would.
    private var openSession: (String, String?) -> Void {
        { [sidebar] id, profile in sidebar.open(sessionID: id, profile: profile) }
    }

    /// The Command Center's session rows act through the sidebar, so its lists stay in step.
    private var sessionActions: CommandCenterSessionActions {
        CommandCenterSessionActions(setPinned: { [sidebar] in try await sidebar.trySetPinned($0, $1) },
                                    export: { [sidebar] in try await sidebar.tryExport($0) },
                                    delete: { [sidebar] in try await sidebar.tryDelete($0) })
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
