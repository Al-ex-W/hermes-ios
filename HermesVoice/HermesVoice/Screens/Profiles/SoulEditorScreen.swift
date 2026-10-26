import SwiftUI
import UIKit

/// A profile's SOUL.md (`GET` / `PUT /api/profiles/:name/soul`), loaded once and saved whole.
@MainActor
final class SoulEditorModel: ObservableObject {
    @Published var text = ""
    @Published private(set) var original = ""
    /// False until the file is first written.
    @Published private(set) var exists = true
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var saving = false
    @Published private(set) var loadError: String?
    @Published var failure: String?
    let client: DashboardClient
    let profile: String

    init(client: DashboardClient, profile: String) {
        self.client = client
        self.profile = profile
    }

    /// Edits not saved yet.
    var dirty: Bool { loaded && text != original }

    /// Loads the file the first time only, so coming back to the screen never replaces edits.
    func loadOnce() async {
        guard !loaded, !loading else { return }
        loading = true
        defer { loading = false }
        do {
            apply(try await client.profileSoul(profile))
            loadError = nil
        } catch {
            guard !error.isCancellation else { return }
            loadError = error.dashboardMessage
        }
    }

    func apply(_ soul: ProfileSoul) {
        text = soul.content
        original = soul.content
        exists = soul.exists
        loaded = true
    }

    /// Saves what is in the editor now; edits typed while it saves stay unsaved.
    @discardableResult
    func save() async -> Bool {
        guard loaded, !saving else { return false }
        let content = text
        saving = true
        defer { saving = false }
        do {
            try await client.saveProfileSoul(profile, content: content)
            original = content
            exists = true
            return true
        } catch {
            failure = "Couldn't save SOUL.md. \(error.dashboardMessage)"
            return false
        }
    }
}

/// The SOUL.md editor: monospaced, plain text, with a guard against leaving unsaved edits behind.
struct SoulEditorScreen: View {
    @StateObject private var model: SoulEditorModel
    @State private var confirmingDiscard = false
    @Environment(\.dismiss) private var dismiss

    init(client: DashboardClient, profile: String) {
        _model = StateObject(wrappedValue: SoulEditorModel(client: client, profile: profile))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError, !model.loaded {
                ContentUnavailableView {
                    Label("Couldn't load SOUL.md", systemImage: Theme.Icon.error)
                } description: {
                    Text(error)
                } actions: {
                    Button("Try again") { Task { await model.loadOnce() } }
                }
            } else if !model.loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                if !model.exists {
                    Text("No SOUL.md file exists for this profile yet. Write instructions below and save to create one. Personality presets in config.yaml are managed separately.")
                        .hermesText(.caption)
                        .foregroundStyle(Theme.Text.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Theme.Spacing.page)
                        .padding(.vertical, Theme.Spacing.md)
                        .hermesHairline()
                }
                SoulTextEditor(text: $model.text, placeholder: "Empty SOUL.md — start writing the persona…")
                    .padding(.horizontal, Theme.Spacing.lg)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .navigationTitle("SOUL.md")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Theme.sidebar, for: .navigationBar)
        .navigationBarBackButtonHidden(model.dirty)
        .interactiveDismissDisabled(model.dirty)
        .toolbar {
            if model.dirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        confirmingDiscard = true
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            Image(systemName: "chevron.left").fontWeight(.semibold)
                            Text("Back")
                        }
                    }
                    .accessibilityLabel("Back")
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("SOUL.md").font(.headline)
                        Text("Unsaved changes").hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                if model.saving {
                    ProgressView()
                } else {
                    Button("Save") { Task { await model.save() } }
                        .disabled(!model.dirty)
                }
            }
        }
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Save") {
                Task { if await model.save() { dismiss() } }
            }
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        } message: {
            Text("Your edits to \(model.profile)'s SOUL.md haven't been saved.")
        }
        .failureAlert($model.failure)
        .task { await model.loadOnce() }
    }
}

/// A plain-text `UITextView` for prompts and config text: monospaced, no autocorrect, spell check, smart quotes
/// or smart dashes, so what is typed is what Hermes reads.
struct CodeTextView: UIViewRepresentable {
    @Binding var text: String

    static let pointSize: CGFloat = 13
    static let inset = UIEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
    /// The editor's font for SwiftUI overlays such as the placeholder.
    static var font: Font { .system(size: pointSize, design: .monospaced) }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView()
        view.font = UIFontMetrics(forTextStyle: .body)
            .scaledFont(for: .monospacedSystemFont(ofSize: Self.pointSize, weight: .regular))
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textColor = UIColor(Theme.Text.primary)
        view.tintColor = UIColor(Theme.primary)
        view.autocorrectionType = .no
        view.autocapitalizationType = .none
        view.spellCheckingType = .no
        view.smartQuotesType = .no
        view.smartDashesType = .no
        view.smartInsertDeleteType = .no
        view.textContainerInset = Self.inset
        view.keyboardDismissMode = .interactive
        view.alwaysBounceVertical = true
        view.text = text
        view.delegate = context.coordinator
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        context.coordinator.text = $text
        if view.text != text { view.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var text: Binding<String>

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ view: UITextView) {
            text.wrappedValue = view.text
        }
    }
}
