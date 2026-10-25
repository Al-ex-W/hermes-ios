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
                .task { await delegate.model.restore() }
        }
    }
}

/// Owns the app model from launch: a VoIP push can start the app in the background, with no window, and PushKit
/// must be registered before `didFinishLaunching` returns for that push to be delivered.
final class AppDelegate: NSObject, UIApplicationDelegate {
    @MainActor private(set) lazy var model = AppModel()

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        MainActor.assumeIsolated { model.startPush() }
        return true
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calls: CallController
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            if model.signedIn {
                NavigationStack { SessionListView() }
            } else {
                NavigationStack { LoginView() }
            }
        }
        .tint(.indigo)
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.didBecomeActive() }
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
