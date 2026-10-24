import SwiftUI

struct SessionListView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calls: CallController
    @State private var showSettings = false
    @State private var newChat: ChatModel?

    var body: some View {
        List(model.sessions) { session in
            NavigationLink(value: session) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title).lineLimit(1)
                    if let date = session.lastActive {
                        Text(date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                ContentUnavailableView("No chats yet", systemImage: "bubble.left.and.bubble.right", description: Text("Start one with the compose button."))
            }
        }
        // Runs on first show and each time a chat is popped back to the list.
        .task { await model.refresh() }
        .refreshable { await model.refresh() }
        .navigationTitle("Chats")
        .navigationDestination(for: SessionSummary.self) { session in
            if let chat = model.chat(for: session) { ChatView(chat: chat) }
        }
        .navigationDestination(item: $newChat) { chat in
            ChatView(chat: chat)
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { newChat = model.chat(for: nil) } label: { Image(systemName: "square.and.pencil") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let call = calls.active {
                ActiveCallBanner(call: call) { newChat = call.chat }
            }
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView() }
        }
        .alert("Hermes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? "")
        }
    }
}

extension ChatModel: Hashable {
    nonisolated static func == (lhs: ChatModel, rhs: ChatModel) -> Bool { lhs === rhs }
    nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// Shown outside the chat that owns the call; tapping it opens that chat.
struct ActiveCallBanner: View {
    @ObservedObject var call: VoiceCall
    let open: () -> Void
    @EnvironmentObject private var calls: CallController

    var body: some View {
        HStack {
            Button(action: open) {
                HStack {
                    Image(systemName: "phone.fill")
                    Text("On a call · \(call.chat.title)").lineLimit(1)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Opens the chat with the call")
            Button(role: .destructive) { calls.end() } label: { Image(systemName: "phone.down.fill") }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.green.gradient, in: Capsule())
        .padding(.horizontal, 16)
    }
}
