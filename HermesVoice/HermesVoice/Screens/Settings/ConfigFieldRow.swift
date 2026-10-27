import SwiftUI

/// A settings row (`ListRow`): title, optional description and status line, and a control beside the title or,
/// for editors too big for that (`wide`), under the description.
struct SettingsRow<Control: View>: View {
    let title: String
    var description: String?
    var error: String?
    var saving = false
    var wide = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            if wide {
                titleLine
                descriptionText
                control.padding(.top, Theme.Spacing.xs)
            } else {
                // Centered: a switch has no text baseline, and aligning on one sets it below the title.
                HStack(alignment: .center, spacing: Theme.Spacing.lg) {
                    titleLine
                    Spacer(minLength: Theme.Spacing.md)
                    control
                }
                descriptionText
            }
            if let error {
                Text(error)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.destructive)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Theme.Spacing.xxs)
    }

    private var titleLine: some View {
        HStack(spacing: Theme.Spacing.sm) {
            Text(title)
                .hermesText(.body)
                .foregroundStyle(Theme.Text.primary)
            if saving { ProgressView().controlSize(.mini) }
        }
    }

    @ViewBuilder private var descriptionText: some View {
        if let description, !description.isEmpty {
            Text(description)
                .hermesText(.caption)
                .foregroundStyle(Theme.Text.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One schema-driven config field (`ConfigField`), saved through the settings store when it changes: switches
/// and menus at once, typed values when the field is submitted or loses focus.
struct ConfigFieldRow: View {
    @EnvironmentObject private var store: SettingsStore
    let key: String
    /// Extra copy under the description (the detected context window, say).
    var note: String?

    var body: some View {
        let field = store.field(key)
        let value = store.value(key)
        let title = SettingsCatalog.label(for: key)
        let restart = field?.restartRequired == true ? "Applies after Hermes restarts." : nil
        let description = [SettingsCatalog.description(for: key, schema: field), note, restart].compactMap { $0 }.joined(separator: " ")
        let error = store.errors[key]
        let saving = store.saving.contains(key)
        switch store.control(key) {
        case .toggle?:
            SettingsRow(title: title, description: description, error: error, saving: saving) {
                Toggle(title, isOn: Binding(get: { value?.truthy ?? false }, set: { store.set(key, .bool($0)) }))
                    .labelsHidden()
            }
        case let .picker(options)?:
            SettingsRow(title: title, description: description, error: error, saving: saving) {
                Picker(title, selection: Binding(get: { value?.displayText ?? "" }, set: { store.set(key, .string($0)) })) {
                    ForEach(options, id: \.self) { option in
                        Text(SettingsCatalog.optionLabel(option, key: key, field: field)).tag(option)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        case let .searchablePicker(options, clearable)?:
            SettingsRow(title: title, description: description, error: error, saving: saving) {
                NavigationLink {
                    SearchableOptionList(title: title, options: options, clearLabel: clearable ? "System default" : nil,
                                         selection: value?.displayText ?? "") { store.set(key, .string($0)) }
                } label: {
                    Text(value?.displayText.nilIfEmpty ?? (clearable ? "System default" : "Not set"))
                        .foregroundStyle(Theme.Text.tertiary)
                        .lineLimit(1)
                }
                .fixedSize()
            }
        case let .number(bounds)?:
            SettingsRow(title: title, description: [description, bounds.summary].compactMap { $0?.nilIfEmpty }.joined(separator: " "),
                        error: error, saving: saving) {
                NumberFieldEditor(value: value, bounds: bounds) { store.set(key, $0) }
            }
        case let .text(multiline)?:
            SettingsRow(title: title, description: description, error: error, saving: saving, wide: multiline) {
                DraftTextField(text: value?.displayText ?? "", multiline: multiline) { store.set(key, .string($0)) }
            }
        case .secret?:
            SettingsRow(title: title, description: description, error: error, saving: saving) {
                DraftTextField(text: value?.displayText ?? "", secure: true) { store.set(key, .string($0)) }
            }
        case .list?:
            SettingsRow(title: title, description: description, error: error, saving: saving, wide: true) {
                DraftTextField(text: ListDraft.text(value), placeholder: "Comma-separated") {
                    store.set(key, .array(ListDraft.parse($0).map(JSONValue.string)))
                }
            }
        case .json?:
            SettingsRow(title: title, description: description, error: error, saving: saving, wide: true) {
                JSONFieldEditor(value: value ?? .object([:])) { store.set(key, $0) }
            }
        case .fallbackModels?:
            SettingsRow(title: title, description: description, error: error, saving: saving, wide: true) {
                FallbackModelsEditor(value: value) { store.set(key, $0) }
            }
        case .delegationRoute?:
            DelegationRouteRow(error: error, saving: saving)
        case nil:
            EmptyView()
        }
    }
}

/// The list editor's text form (`parseListFieldDraft`): comma-separated, trimmed, empty entries dropped.
enum ListDraft {
    static func parse(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    static func text(_ value: JSONValue?) -> String {
        if let items = value?.arrayValue { return items.map(\.displayText).joined(separator: ", ") }
        return value?.displayText ?? ""
    }
}

/// A text field that edits a draft and hands it over on submit or when it loses focus, if it changed.
/// An outside change to `text` (a rollback, a reload) replaces the draft while the field isn't being edited.
struct DraftTextField: View {
    let text: String
    var placeholder = "Not set"
    var multiline = false
    var secure = false
    let commit: (String) -> Void

    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if secure {
                SecureField(placeholder, text: $draft)
            } else if multiline {
                TextField(placeholder, text: $draft, axis: .vertical)
                    .lineLimit(3...10)
            } else {
                TextField(placeholder, text: $draft)
                    .multilineTextAlignment(.trailing)
            }
        }
        .hermesText(.body)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .focused($focused)
        .submitLabel(.done)
        .onSubmit(send)
        .onAppear { draft = text }
        .onChange(of: text) { _, new in if !focused { draft = new } }
        .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
    }

    private func send() {
        guard draft != text else { return }
        commit(draft)
    }
}

/// A number field: typed text is checked against the field's limits and saved once it parses; otherwise the
/// reason shows under it and nothing is sent.
struct NumberFieldEditor: View {
    let value: JSONValue?
    let bounds: NumberBounds
    let commit: (JSONValue) -> Void

    @State private var draft = ""
    @State private var problem: String?
    @FocusState private var focused: Bool

    private var shown: String { value?.displayText ?? "" }

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
            TextField("Not set", text: $draft)
                .keyboardType(bounds.integral ? .numberPad : .decimalPad)
                .multilineTextAlignment(.trailing)
                .hermesText(.body)
                .frame(maxWidth: 140)
                .focused($focused)
                .onSubmit(send)
            if let problem {
                Text(problem).hermesText(.meta).foregroundStyle(Theme.destructive)
            }
        }
        .onAppear { draft = shown }
        .onChange(of: shown) { _, new in if !focused { draft = new } }
        .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
        .toolbar {
            if focused {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focused = false }
                }
            }
        }
    }

    private func send() {
        guard draft != shown else { problem = nil; return }
        switch bounds.parse(draft) {
        case let .success(number):
            problem = nil
            if number != value { commit(number) }
        case let .failure(reason):
            problem = reason.localizedDescription
        }
    }
}

/// An object field as pretty-printed JSON; saved when it parses to an object or list, kept local otherwise.
struct JSONFieldEditor: View {
    let value: JSONValue
    let commit: (JSONValue) -> Void

    @State private var draft = ""
    @State private var invalid = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            TextEditor(text: $draft)
                .font(Theme.TextStyle.code.font)
                .frame(minHeight: 110)
                .scrollContentBackground(.hidden)
                .background(Theme.Fill.quinary, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focused)
            HStack {
                if invalid { Text("Not valid JSON. Fix it to save.").hermesText(.caption).foregroundStyle(Theme.destructive) }
                Spacer()
                if focused { Button("Save") { focused = false }.hermesText(.button) }
            }
        }
        .onAppear { draft = value.displayText }
        .onChange(of: value) { _, new in if !focused { draft = new.displayText } }
        .onChange(of: focused) { _, isFocused in if !isFocused { send() } }
    }

    private func send() {
        guard let data = draft.data(using: .utf8), let parsed = try? JSONValue(jsonData: data),
              parsed.objectValue != nil || parsed.arrayValue != nil else {
            invalid = true
            return
        }
        invalid = false
        if parsed != value { commit(parsed) }
    }
}

/// A long closed list (timezones) to search and pick from (`SearchableSelect`).
struct SearchableOptionList: View {
    let title: String
    let options: [String]
    var clearLabel: String?
    let selection: String
    let choose: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var shown: [String] {
        let needle = SettingsSearch.normalize(query)
        guard !needle.isEmpty else { return options }
        return options.filter { SettingsSearch.normalize($0).contains(needle) }
    }

    var body: some View {
        List {
            if let clearLabel, query.isEmpty {
                row(clearLabel, value: "")
            }
            ForEach(shown, id: \.self) { option in row(option, value: option) }
        }
        .overlay {
            if shown.isEmpty && !query.isEmpty { ContentUnavailableView.search(text: query) }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always))
        .hermesForm()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ label: String, value: String) -> some View {
        Button {
            if value != selection { choose(value) }
            dismiss()
        } label: {
            HStack {
                Text(label).foregroundStyle(Theme.Text.primary)
                Spacer()
                if value == selection { Image(systemName: "checkmark").foregroundStyle(Theme.primary) }
            }
        }
        .hermesFormRows()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
