import SwiftUI
import UIKit

/// One chat (the desktop's `app/chat`): the transcript, and under it the call panel, the prompts Hermes waits on,
/// the status stack and the composer; the session menu and the call button sit in the header.
struct ChatScreen: View {
    @ObservedObject var chat: ChatModel
    let sidebar: SidebarModel
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var calls: CallController
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var preview: MediaPreview?
    @State private var mediaNote: String?

    private var callHere: VoiceCall? {
        guard let call = calls.active, call.chat === chat else { return nil }
        return call
    }

    var body: some View {
        TranscriptScroll(chat: chat)
            .safeAreaInset(edge: .bottom, spacing: 0) { dock }
            .background(Theme.background)
            .navigationTitle(chat.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Theme.background, for: .navigationBar)
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if callHere == nil {
                        Button {
                            Task { await model.startCall(in: chat) }
                        } label: {
                            Image(systemName: "phone")
                        }
                        .disabled(calls.active != nil || calls.starting)
                        .accessibilityLabel("Start voice call")
                    }
                    ChatSessionMenu(chat: chat, sidebar: sidebar, open: open)
                }
            }
            .environment(\.transcriptActions, actions)
            .onAppear {
                chat.setInUse("view", true)
                let compact = sizeClass == .compact
                let shell = sidebar, app = model
                chat.navigate = { [weak shell, weak app] route in
                    guard let shell, let app else { return }
                    Self.open(route, sidebar: shell, app: app, compact: compact)
                }
            }
            .onDisappear { chat.setInUse("view", false) }
            .task { await chat.open() }
            // The stack reads the session's registries once the chat has one, and again after a resume.
            .onChange(of: chat.runtimeID) { Task { await chat.status.refresh() } }
            .alert("Hermes", isPresented: Binding(get: { chat.error != nil }, set: { if !$0 { chat.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(chat.error ?? "")
            }
            .alert("Hermes", isPresented: Binding(get: { mediaNote != nil }, set: { if !$0 { mediaNote = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(mediaNote ?? "")
            }
            .sheet(item: $preview) { MediaPreviewSheet(preview: $0) }
    }

    /// What sits on the composer: the call, open prompts, the status stack, then the composer itself.
    private var dock: some View {
        VStack(spacing: 0) {
            if let call = callHere {
                CallPanel(call: call).padding(.bottom, Theme.Spacing.md)
            }
            if let prompts = model.prompts {
                PromptStack(center: prompts, sessionIDs: chat.sessionIDs)
            }
            StatusStackView(status: chat.status, composer: chat.composer, busy: chat.busy)
            ComposerView(composer: chat.composer, busy: chat.busy, status: chat.status, newChat: chat.isNewChat && !chat.hasContent)
        }
        .padding(.horizontal, Theme.Spacing.lg)
        .padding(.bottom, Theme.Spacing.md)
        .background(Theme.background)
    }

    private var actions: TranscriptActions {
        TranscriptActions(
            recover: { recovery, _ in recover(recovery) },
            openMedia: { ref in openMedia(ref) }
        )
    }

    private func recover(_ recovery: ErrorRecovery) {
        switch recovery {
        case .retry:
            Task { _ = await chat.runSlash("/retry") }
        case .compress:
            Task { _ = await chat.runSlash("/compress") }
        case .chooseModel, .switchProvider:
            chat.composer.modelMenuRequested = true
        case .editMessage:
            let last = chat.transcript.items.last { $0.isUser }
            if case let .user(message)? = last { chat.composer.prefill(message.text) }
        case .startNewSession:
            sidebar.newSession()
        }
    }

    private func openMedia(_ ref: MediaRef) {
        guard ref.kind == .image else {
            mediaNote = "\(ref.name) can't be opened here. Press and hold it to copy its path."
            return
        }
        Task {
            do {
                let data = try await chat.media(ref)
                guard let image = UIImage(data: data) else { throw DashboardError.rpc("\(ref.name) isn't an image this phone can show.") }
                preview = MediaPreview(name: ref.name, image: image)
            } catch {
                if !error.isCancellation { mediaNote = error.localizedDescription }
            }
        }
    }

    private func open(_ route: ChatModel.Route) {
        Self.open(route, sidebar: sidebar, app: model, compact: sizeClass == .compact)
    }

    private static func open(_ route: ChatModel.Route, sidebar: SidebarModel, app: AppModel, compact: Bool) {
        switch route {
        case .newChat:
            sidebar.newSession()
        case .sessions:
            // Beside the sidebar there is nothing to open.
            if compact { sidebar.selection = nil }
        case let .session(summary):
            if let chat = app.chat(for: summary) { sidebar.open(chat) }
        }
    }
}

/// The header's session menu, once the chat holds something. Its changes show in the sidebar at once.
private struct ChatSessionMenu: View {
    @ObservedObject var chat: ChatModel
    @ObservedObject var sidebar: SidebarModel
    let open: (ChatModel.Route) -> Void

    var body: some View {
        if let target {
            SessionMenu(target: target, actions: chat.sessionActions) { event in
                switch event {
                case let .renamed(title):
                    chat.renamed(title)
                case let .branched(storedID, _, title):
                    open(.session(SessionSummary(id: storedID, title: title.isEmpty ? chat.title : title,
                                                 lastActive: nil, profile: chat.profile)))
                default:
                    break
                }
                Task { await sidebar.applied(event, to: target.storedID) }
            }
        }
    }

    private var target: SessionMenuTarget? {
        guard let id = chat.storedID, chat.hasContent else { return nil }
        let row = sidebar.row(id)
        return SessionMenuTarget(storedID: id, runtimeID: chat.runtimeID, title: chat.title, profile: chat.profile,
                                 pinned: row?.pinned ?? false, unread: row?.unread ?? false,
                                 archived: row?.archived ?? false, cwd: row?.cwd)
    }
}

// MARK: - Transcript

/// The transcript, kept on its newest row while the reader is there, with earlier history a tap away.
private struct TranscriptScroll: View {
    @ObservedObject var chat: ChatModel
    /// The reader is at the end, so new rows keep it there. Only the reader's own scrolling changes it: rows
    /// growing under the end move the content's bottom but not its top.
    @State private var following = true
    @State private var contentTop: CGFloat?
    /// Where the visible part of the scroll view ends on screen (above the composer).
    @State private var visibleBottom: CGFloat = .infinity

    private static let bottom = "transcript-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if chat.hasOlderHistory { olderHistory(proxy) }
                    if chat.transcript.items.isEmpty, chat.isNewChat, !chat.busy {
                        emptyState
                    }
                    TranscriptList(items: chat.transcript.items)
                    activity
                    Color.clear.frame(height: 1).id(Self.bottom)
                }
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: ContentFrameKey.self, value: geometry.frame(in: .global))
                    }
                }
                .padding(.horizontal, Theme.Spacing.page)
                .padding(.top, Theme.Spacing.lg)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .defaultScrollAnchor(.bottom)
            .scrollDismissesKeyboard(.interactively)
            .background {
                GeometryReader { geometry in
                    let bottom = geometry.frame(in: .global).maxY - geometry.safeAreaInsets.bottom
                    Color.clear
                        .onAppear { visibleBottom = bottom }
                        .onChange(of: bottom) { _, value in visibleBottom = value }
                }
            }
            .onPreferenceChange(ContentFrameKey.self) { frame in
                let scrolled = contentTop.map { abs($0 - frame.minY) > 0.5 } ?? true
                contentTop = frame.minY
                let atEnd = frame.maxY <= visibleBottom + 64
                if scrolled || atEnd { following = atEnd }
            }
            // The dock above the composer grew or shrank (a prompt card, the status stack, the keyboard).
            .onChange(of: visibleBottom) {
                if following { proxy.scrollTo(Self.bottom, anchor: .bottom) }
            }
            .onChange(of: chat.transcript.items.last) { old, new in
                // Follow the reply while the reader is at the end; a prompt just sent always brings it back there.
                let sent = new?.isUser == true && new?.id != old?.id
                guard following || sent else { return }
                proxy.scrollTo(Self.bottom, anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !following, !chat.transcript.items.isEmpty {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(Self.bottom, anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: Theme.IconSize.sm, weight: .semibold))
                            .foregroundStyle(Theme.Text.secondary)
                            .frame(width: 32, height: 32)
                            .hermesFloating(radius: 16)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, Theme.Spacing.md)
                    .accessibilityLabel("Scroll to the latest message")
                    .transition(.opacity)
                }
            }
        }
    }

    private func olderHistory(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if chat.loadingOlder {
                ProgressView().controlSize(.small)
            } else {
                Button("Show earlier messages") {
                    let first = chat.transcript.items.first { $0.isDrawn }?.id
                    Task {
                        await chat.loadOlder()
                        // Keep the row that was on top where it was.
                        if let first { proxy.scrollTo(first, anchor: .top) }
                    }
                }
                .hermesText(.button)
                .buttonStyle(.plain)
                .foregroundStyle(Theme.Text.tertiary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 32)
        .padding(.bottom, Theme.Spacing.xl)
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: Theme.IconSize.xl, weight: .light))
                .foregroundStyle(Theme.Text.quaternary)
            Text("Start a conversation")
                .hermesText(.rowTitle)
                .foregroundStyle(Theme.Text.secondary)
            Text(chat.profile.map { "A new session in the \($0) profile." } ?? "A new session on this Hermes.")
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 120)
    }

    /// While a turn runs and nothing of it shows yet: the tool being prepared, or that Hermes is thinking.
    @ViewBuilder private var activity: some View {
        if chat.busy, let label = activityLabel {
            HStack(spacing: Theme.Spacing.sm) {
                ScaffoldSpinner()
                Text(label)
                    .hermesText(.tool)
                    .foregroundStyle(Theme.Text.scaffold)
            }
            .padding(.leading, Theme.Spacing.messageIndent)
            .padding(.top, chat.transcript.items.isEmpty ? 0 : Theme.Spacing.turnBlock)
            .transition(.opacity)
        }
    }

    private var activityLabel: String? {
        if let tool = chat.transcript.draftingTool {
            return "\(ToolCall.titles[tool]?.pending ?? "Preparing \(ToolCall.displayName(tool))")…"
        }
        switch chat.transcript.items.last {
        case .user?, .system?, nil: return "Thinking…"
        default: return nil
        }
    }
}

private struct ContentFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

// MARK: - Media

private struct MediaPreview: Identifiable {
    let id = UUID()
    let name: String
    let image: UIImage
}

/// An image Hermes delivered, full screen, to zoom with a pinch and share.
private struct MediaPreviewSheet: View {
    let preview: MediaPreview
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1

    var body: some View {
        NavigationStack {
            Image(uiImage: preview.image)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale)
                .gesture(MagnifyGesture().onChanged { scale = max(1, $0.magnification) }.onEnded { _ in
                    withAnimation(.easeOut(duration: 0.2)) { scale = 1 }
                })
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.background)
                .navigationTitle(preview.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        ShareLink(item: Image(uiImage: preview.image), preview: SharePreview(preview.name, image: Image(uiImage: preview.image)))
                    }
                }
        }
    }
}
