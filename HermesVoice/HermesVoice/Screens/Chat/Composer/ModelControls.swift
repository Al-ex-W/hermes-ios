import SwiftUI

/// The composer's model pill (the desktop's `model-pill.tsx`): the session's model, opening a searchable list of
/// the providers' models from `model.options`. A quiet spinner stands in until the model is known.
struct ModelPill: View {
    @ObservedObject var composer: ComposerModel
    var disabled = false
    @State private var picking = false

    var body: some View {
        Button { picking = true } label: {
            HStack(spacing: Theme.Spacing.xs) {
                if let model = composer.model {
                    Text(ComposerModel.modelLabel(model.model, fast: false)).lineLimit(1).truncationMode(.middle)
                } else {
                    ProgressView().controlSize(.mini).opacity(0.5)
                }
                if composer.pendingModel != nil {
                    Circle().fill(Theme.midground).frame(width: 4, height: 4).accessibilityHidden(true)
                }
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.5)
            }
            .hermesText(.button)
            .fontWeight(.regular)
            .foregroundStyle(Theme.Text.tertiary)
            .padding(.horizontal, Theme.Spacing.md)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(composer.model.map { "Model · \($0.provider): \($0.model)" } ?? "Switch model")
        .sheet(isPresented: $picking) {
            ModelPickerSheet(composer: composer)
                .presentationDetents([.medium, .large])
        }
        .onChange(of: composer.modelMenuRequested) {
            if composer.modelMenuRequested {
                composer.modelMenuRequested = false
                picking = true
            }
        }
        .alert("Switch model?", isPresented: Binding(get: { composer.modelConfirmation != nil },
                                                     set: { if !$0 { composer.modelConfirmation = nil } })) {
            Button("Switch") {
                if let pick = composer.modelConfirmation?.pick { Task { await composer.confirmSelect(pick) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(composer.modelConfirmation?.message ?? "")
        }
    }
}

/// Every configured provider's models, current first, with search.
struct ModelPickerSheet: View {
    @ObservedObject var composer: ComposerModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var providers: [ModelOptionProvider] {
        let all = composer.options?.providers ?? []
        let current = composer.model?.provider
        return all.filter { $0.slug == current } + all.filter { $0.slug != current }
    }

    private func models(_ provider: ModelOptionProvider) -> [String] {
        let models = provider.models ?? []
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return models }
        if provider.name.lowercased().contains(needle) || provider.slug.lowercased().contains(needle) { return models }
        return models.filter { $0.lowercased().contains(needle) }
    }

    var body: some View {
        NavigationStack {
            List {
                if composer.options == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }
                        .listRowBackground(Color.clear)
                }
                ForEach(providers, id: \.slug) { provider in
                    let models = models(provider)
                    if !models.isEmpty {
                        Section {
                            ForEach(models, id: \.self) { model in row(provider, model) }
                        } header: {
                            Text(provider.name)
                        } footer: {
                            if let warning = provider.warning, !warning.isEmpty { Text(warning) }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search models")
            .navigationTitle("Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .task { await composer.refreshModel() }
        }
    }

    private func row(_ provider: ModelOptionProvider, _ model: String) -> some View {
        let pick = ModelPick(provider: provider.slug, model: model)
        let current = composer.model == pick
        let unavailable = provider.unavailableModels?.contains(model) == true
        return Button {
            dismiss()
            Task { await composer.select(pick) }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 1) {
                    Text(model).hermesText(.body).foregroundStyle(unavailable ? Theme.Text.quaternary : Theme.Text.primary)
                    if let caps = provider.capabilities?[model], caps.reasoning || caps.fast {
                        Text([caps.reasoning ? "Reasoning" : nil, caps.fast ? "Fast" : nil].compactMap { $0 }.joined(separator: " · "))
                            .hermesText(.meta)
                            .foregroundStyle(Theme.Text.tertiary)
                    }
                }
                Spacer()
                if current { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
            }
        }
        .disabled(unavailable)
    }
}

/// The effort pill (the desktop's `reasoning-pill.tsx`): Thinking, Fast and the reasoning level of the session's
/// model. Hidden when the model has neither.
struct EffortPill: View {
    @ObservedObject var composer: ComposerModel
    var disabled = false

    var body: some View {
        let fast = composer.fastControl
        if composer.supportsReasoning || fast != .none {
            Menu {
                if composer.canDisableReasoning {
                    Toggle("Thinking", isOn: Binding(
                        get: { composer.effort?.lowercased() != "none" },
                        set: { on in Task { await composer.setEffort(on ? Self.resolved(composer.effort) : "none") } }
                    ))
                }
                if fast != .none {
                    Toggle("Fast", isOn: Binding(get: { fast.isOn }, set: { on in Task { await composer.setFast(on) } }))
                }
                if composer.supportsReasoning {
                    Picker("Effort", selection: Binding(
                        get: { Self.resolved(composer.effort) },
                        set: { level in Task { await composer.setEffort(level) } }
                    )) {
                        ForEach(ComposerModel.efforts, id: \.self) { level in
                            Text(Self.title(level)).tag(level)
                        }
                    }
                    .pickerStyle(.inline)
                }
            } label: {
                HStack(spacing: Theme.Spacing.xs) {
                    if composer.supportsReasoning {
                        if composer.effort == nil {
                            ProgressView().controlSize(.mini).opacity(0.5)
                        } else {
                            Text(ComposerModel.effortLabel(composer.effort))
                        }
                    }
                    if fast.isOn { Image(systemName: "bolt.fill").font(.system(size: 9)) }
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).opacity(0.5)
                }
                .hermesText(.button)
                .fontWeight(.regular)
                .foregroundStyle(Theme.Text.tertiary)
                .padding(.horizontal, Theme.Spacing.sm)
                .frame(height: 32)
                .contentShape(Rectangle())
            }
            .disabled(disabled)
            .accessibilityLabel("Effort: \(Self.title(Self.resolved(composer.effort)))\(fast.isOn ? ", Fast" : "")")
        }
    }

    /// The level a scale shows: unset inherits medium, "none" (thinking off) shows medium as the level it returns to.
    static func resolved(_ effort: String?) -> String {
        let value = (effort ?? "").lowercased()
        return ComposerModel.efforts.contains(value) ? value : ComposerModel.defaultEffort
    }

    static func title(_ level: String) -> String {
        switch level {
        case "minimal": return "Minimal"
        case "low": return "Low"
        case "medium": return "Medium"
        case "high": return "High"
        case "xhigh": return "Extra high"
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return level.capitalized
        }
    }
}
