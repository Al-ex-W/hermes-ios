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
        .alert("Call", isPresented: Binding(get: { calls.lastError != nil }, set: { if !$0 { calls.lastError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(calls.lastError ?? "")
        }
    }
}
