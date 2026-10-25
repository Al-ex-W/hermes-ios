import SwiftUI

struct ChatView: View {
    @ObservedObject var chat: ChatModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calls: CallController
    @State private var draft = ""

    private var callHere: VoiceCall? {
        guard let call = calls.active, call.chat === chat else { return nil }
        return call
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(chat.messages) { message in
                        MessageRow(message: message).id(message.id)
                    }
                    if chat.busy {
                        ProgressView().padding(.leading, 4).id("busy")
                    }
                }
                .padding()
            }
            .defaultScrollAnchor(.bottom)
            .onChange(of: chat.messages.last?.text) {
                if let last = chat.messages.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 8) {
                if let call = callHere { CallPanel(call: call) }
                if let prompts = model.prompts { PromptStack(center: prompts, sessionIDs: chat.sessionIDs) }
                composer
            }
            .padding(.horizontal)
            .padding(.bottom, 8)
            .background(.bar)
        }
        .navigationTitle(chat.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if callHere == nil {
                    Button {
                        Task { await model.startCall(in: chat) }
                    } label: {
                        Image(systemName: "phone.fill")
                    }
                    .disabled(calls.active != nil || calls.starting)
                    .accessibilityLabel("Start voice call")
                }
            }
        }
        .onAppear { chat.setInUse("view", true) }
        .onDisappear { chat.setInUse("view", false) }
        .task { await chat.open() }
        .alert("Hermes", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(chat.error ?? "")
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Message Hermes", text: $draft, axis: .vertical)
                .lineLimit(1...5)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
            if chat.busy && draft.isEmpty {
                Button { Task { await chat.interrupt() } } label: {
                    Image(systemName: "stop.circle.fill").font(.title)
                }
            } else {
                Button {
                    let text = draft
                    draft = ""
                    Task { await chat.send(text) }
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.title)
                }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.top, 8)
    }
}

struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        switch message.role {
        case .user:
            if let notice = callNotice {
                // The call announcements are instructions for Hermes; the chat only marks where the call began and ended.
                Label(notice, systemImage: "phone.fill")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 2)
            } else {
                HStack {
                    Spacer(minLength: 40)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        if spoken != nil { Image(systemName: "mic.fill").font(.caption).foregroundStyle(.green) }
                        Text(spoken ?? message.text).textSelection(.enabled)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(spoken != nil ? Color.green.opacity(0.18) : Color.indigo.opacity(0.18), in: RoundedRectangle(cornerRadius: 16))
                }
            }
        case .assistant:
            Text(LocalizedStringKey(message.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool, .system:
            Text(message.text)
                .font(.caption)
                .foregroundStyle(message.text.hasPrefix("🔊") ? Color.green : Color.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// "Voice call started", "Voice call not answered"… for the notices the Hermes Voice plugin posts.
    private var callNotice: String? { VoiceTranscript.notice(message.text) }  // Hook (M6): plugin notice formats

    /// What the user said on a call, without the markers and hint Hermes sees.
    private var spoken: String? { VoiceTranscript.spoken(message.text) }  // Hook (M6): plugin turn formats
}
