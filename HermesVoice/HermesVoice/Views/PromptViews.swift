import SwiftUI

/// What Hermes is waiting on in this chat (approvals, questions, passwords), above the composer.
struct PromptStack: View {
    @ObservedObject var center: PromptCenter
    let sessionIDs: Set<String>

    var body: some View {
        let prompts = center.prompts(for: sessionIDs)
        let approvals = prompts.filter { if case .approval = $0.kind { return true }; return false }
        if !prompts.isEmpty {
            VStack(spacing: Theme.Spacing.md) {
                ForEach(prompts) { prompt in
                    Group {
                        switch prompt.kind {
                        case let .approval(approval):
                            ApprovalCard(prompt: prompt, approval: approval, center: center,
                                         position: (approvals.firstIndex { $0.id == prompt.id } ?? 0) + 1, total: approvals.count)
                        case let .clarify(params):
                            ClarifyCard(prompt: prompt, params: params, center: center)
                        case let .value(request):
                            ValueCard(prompt: prompt, request: request, center: center)
                        }
                    }
                    .disabled(prompt.answering)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.22), value: prompts.map(\.id))
            .padding(.vertical, Theme.Spacing.md)
        }
    }
}

// MARK: - Approval

/// A command waiting for a decision (`ApprovalCard`): the command, then Reject, a menu with Allow this session and
/// Always allow… (confirmed first, since it is permanent), and Run.
struct ApprovalCard: View {
    let prompt: PromptCenter.Prompt
    let approval: PromptCenter.Approval
    let center: PromptCenter
    var position = 1
    var total = 1
    @State private var submitting: ApprovalChoice?
    @State private var confirmAlways = false

    /// A plugin rule's synthetic target (`<tool> (plugin approval rule)`) says nothing; the description does.
    private var showsDescription: Bool {
        let command = approval.command.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty || command.range(of: "^<[^>]+> \\(", options: .regularExpression) != nil
    }

    private var details: String {
        (showsDescription ? approval.description : approval.command).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: Theme.Icon.terminal).font(.system(size: 12))
                Text(showsDescription ? "Command details" : "Command")
                if !showsDescription, !approval.description.isEmpty {
                    Text("· \(approval.description)").foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                }
                Spacer()
                if total > 1 {
                    Text("\(position) / \(total)").monospacedDigit().foregroundStyle(Theme.Text.tertiary)
                }
            }
            .hermesText(.caption)
            .foregroundStyle(Theme.Text.secondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.md)
            if !details.isEmpty {
                ScrollView(.vertical) {
                    Text(details)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.Text.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.md)
            }
            PromptFailure(prompt: prompt).padding(.horizontal, Theme.Spacing.md)
            HStack(spacing: Theme.Spacing.sm) {
                Spacer()
                Button {
                    respond(.deny)
                } label: {
                    label("Reject", for: .deny)
                }
                .buttonStyle(PromptButtonStyle(kind: .text))
                if hasMoreOptions {
                    Menu {
                        if approval.choices.contains(.session) {
                            Button("Allow this session") { respond(.session) }
                        }
                        if approval.choices.contains(.always) {
                            Button("Always allow…") { confirmAlways = true }
                        }
                        Button("Reject", role: .destructive) { respond(.deny) }
                    } label: {
                        HStack(spacing: Theme.Spacing.xs) {
                            label("Always allow…", for: .session)
                            Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .menuStyle(.button)
                    .buttonStyle(PromptButtonStyle(kind: .secondary))
                    .accessibilityLabel("More approval options")
                }
                Button {
                    respond(.once)
                } label: {
                    label("Run", for: .once)
                }
                .buttonStyle(PromptButtonStyle(kind: .primary))
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.bottom, Theme.Spacing.sm)
            .padding(.top, Theme.Spacing.xs)
            .disabled(submitting != nil)
        }
        .background(Theme.background, in: RoundedRectangle(cornerRadius: Theme.Radius.widget))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.Radius.widget).strokeBorder(Theme.Hairline.secondary, lineWidth: Theme.hairlineWidth)
        }
        .alert("Always allow this command?", isPresented: $confirmAlways) {
            Button("Cancel", role: .cancel) {}
            Button("Always allow", role: .destructive) { respond(.always) }
        } message: {
            Text("This adds the “\(approval.description)” pattern to your permanent allowlist (~/.hermes/config.yaml). Hermes won’t ask again for commands like this — in this session or any future one.\n\n\(approval.command)")
        }
        .onChange(of: prompt.answering) { if !prompt.answering { submitting = nil } }
    }

    private var hasMoreOptions: Bool { approval.choices.contains(.session) || approval.choices.contains(.always) }

    @ViewBuilder
    private func label(_ title: String, for choice: ApprovalChoice) -> some View {
        if submitting == choice || (choice == .session && submitting == .always) {
            ProgressView().controlSize(.mini)
        } else {
            Text(title)
        }
    }

    private func respond(_ choice: ApprovalChoice) {
        guard submitting == nil else { return }
        submitting = choice
        Task { await center.approve(prompt.id, choice) }
    }
}

// MARK: - Clarify

/// The clarify tool's questions, all at once (`ClarifyToolPending`): letter-badged choices (one, or several), an
/// "Other" answer typed beside them, or a typed answer alone. Answers stay editable until Confirm and continue;
/// Skip cancels every question.
struct ClarifyCard: View {
    let prompt: PromptCenter.Prompt
    let params: ClarifyRequestParams
    let center: PromptCenter
    @State private var picked: [String: [String]] = [:]
    @State private var typed: [String: String] = [:]
    @State private var submitting = false

    static let recommended = "(Recommended)"

    var body: some View {
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                HStack(alignment: .top) {
                    Text("\(answeredCount) of \(params.questions.count) answered")
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.tertiary)
                    Spacer()
                    Image(systemName: "questionmark.bubble").font(.system(size: 13)).foregroundStyle(Theme.Text.tertiary)
                }
                ForEach(params.questions, id: \.qid) { question in
                    questionBlock(question)
                }
                PromptFailure(prompt: prompt)
            }
            .hermesText(.conversation)
            .foregroundStyle(Theme.Text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hermesCard()
            HStack(spacing: Theme.Spacing.xs) {
                Button("Skip") {
                    submitting = true
                    Task { await center.answerClarify(prompt.id, answers: nil) }
                }
                .buttonStyle(PromptButtonStyle(kind: .text))
                Button {
                    submitting = true
                    Task { await center.answerClarify(prompt.id, answers: answers) }
                } label: {
                    if submitting { ProgressView().controlSize(.mini) } else { Text("Confirm and continue") }
                }
                .buttonStyle(PromptButtonStyle(kind: .primary))
                .disabled(answeredCount == 0)
            }
            .disabled(submitting)
        }
        .onAppear(perform: prefill)
        .onChange(of: prompt.answering) { if !prompt.answering { submitting = false } }
    }

    @ViewBuilder
    private func questionBlock(_ question: ClarifyQuestion) -> some View {
        let choices = question.choices ?? []
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                Text(question.question).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if !choices.isEmpty {
                    Text(question.multiSelect == true ? "Select all that apply" : "Pick one")
                        .hermesText(.meta)
                        .foregroundStyle(Theme.Text.tertiary)
                        .padding(.horizontal, Theme.Spacing.xs)
                        .padding(.vertical, 1)
                        .background(Theme.Fill.controlHover, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
                }
            }
            if choices.isEmpty {
                field(question, placeholder: "Type your answer…")
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(choices.enumerated()), id: \.offset) { index, choice in
                        let selected = picked[question.qid]?.contains(choice) == true
                        Button { pick(choice, in: question) } label: {
                            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                                KeyBadge(letter: Self.letter(index), selected: selected)
                                choiceLabel(choice)
                                    .foregroundStyle(selected ? Theme.Text.primary : Theme.Text.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, Theme.Spacing.sm)
                            .padding(.vertical, Theme.Spacing.xs)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ChoiceRowStyle())
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                        KeyBadge(letter: Self.letter(choices.count),
                                 selected: !(typed[question.qid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        field(question, placeholder: "Other (type your answer)")
                    }
                    .padding(.horizontal, Theme.Spacing.sm)
                    .padding(.vertical, Theme.Spacing.xs)
                }
            }
        }
    }

    private func choiceLabel(_ choice: String) -> Text {
        let bare = Self.bare(choice)
        guard bare != choice else { return Text(choice) }
        return Text(bare) + Text(" \(Self.recommended)").foregroundStyle(Theme.Text.tertiary)
    }

    private func field(_ question: ClarifyQuestion, placeholder: String) -> some View {
        TextField(placeholder, text: Binding(
            get: { typed[question.qid] ?? "" },
            set: { value in
                typed[question.qid] = value
                // A typed answer replaces a single choice; beside a multi-select it is one more.
                if question.multiSelect != true, !value.isEmpty { picked[question.qid] = [] }
            }
        ), axis: .vertical)
        .lineLimit(1...6)
        .textFieldStyle(.plain)
        .foregroundStyle(Theme.Text.primary)
    }

    private func pick(_ choice: String, in question: ClarifyQuestion) {
        var current = picked[question.qid] ?? []
        if question.multiSelect == true {
            if let index = current.firstIndex(of: choice) { current.remove(at: index) } else { current.append(choice) }
        } else {
            current = current == [choice] ? [] : [choice]
            typed[question.qid] = ""
        }
        picked[question.qid] = current
    }

    private var answeredCount: Int {
        params.questions.filter { answer(for: $0) != nil }.count
    }

    /// A multi-select's choices (plus the typed one) as a JSON array in offered order; one choice, or the typed text.
    private func answer(for question: ClarifyQuestion) -> String? {
        let draft = (typed[question.qid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let chosen = (question.choices ?? []).filter { picked[question.qid]?.contains($0) == true }.map(Self.bare)
        if question.multiSelect == true {
            let combined = chosen + (draft.isEmpty ? [] : [draft])
            guard !combined.isEmpty, let data = try? JSONSerialization.data(withJSONObject: combined) else { return nil }
            return String(decoding: data, as: UTF8.self)
        }
        if let first = chosen.first { return first }
        return draft.isEmpty ? nil : draft
    }

    /// Per question its answer, or nil to skip it.
    private var answers: [String: String?] {
        var result: [String: String?] = [:]
        for question in params.questions { result[question.qid] = .some(answer(for: question)) }
        return result
    }

    /// Answers locked already (from another client, or before a reconnect).
    private func prefill() {
        for question in params.questions {
            guard let locked = params.answers?[question.qid] ?? nil, picked[question.qid] == nil, typed[question.qid] == nil else { continue }
            let choices = question.choices ?? []
            var values = [locked]
            if question.multiSelect == true, let list = (try? JSONSerialization.jsonObject(with: Data(locked.utf8))) as? [String] {
                values = list
            }
            let matched = choices.filter { values.contains(Self.bare($0)) }
            if matched.isEmpty {
                typed[question.qid] = locked
            } else {
                picked[question.qid] = matched
                let extra = values.filter { value in !matched.contains { Self.bare($0) == value } }
                if !extra.isEmpty { typed[question.qid] = extra.joined(separator: ", ") }
            }
        }
    }

    /// A choice without its "(Recommended)" tag, as the answer carries it.
    static func bare(_ choice: String) -> String {
        guard choice.hasSuffix(recommended) else { return choice }
        return String(choice.dropLast(recommended.count)).trimmingCharacters(in: .whitespaces)
    }

    static func letter(_ index: Int) -> String {
        String(UnicodeScalar(UInt8(65 + min(index, 25))))
    }
}

/// A choice's letter key: filled with the brand color once picked.
private struct KeyBadge: View {
    let letter: String
    let selected: Bool

    var body: some View {
        Text(letter)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(selected ? Theme.primaryForeground : Theme.Text.tertiary)
            .frame(width: 18, height: 18)
            .background(selected ? Theme.primary : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.control)
                    .strokeBorder(selected ? Theme.primary : Theme.Hairline.primary, lineWidth: Theme.hairlineWidth)
            }
    }
}

private struct ChoiceRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? Theme.Fill.controlHover : Color.clear, in: RoundedRectangle(cornerRadius: Theme.Radius.row))
    }
}

// MARK: - Passwords, secrets, codes

/// A password, secret, code or login Hermes needs: what it is for and why, answered in a masked sheet.
struct ValueCard: View {
    let prompt: PromptCenter.Prompt
    let request: PromptCenter.ValueRequest
    let center: PromptCenter
    @State private var entering = false

    var body: some View {
        let copy = ValueCopy(request)
        VStack(alignment: .trailing, spacing: Theme.Spacing.sm) {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                HStack(alignment: .top) {
                    Text(copy.title).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Image(systemName: request.field == .code ? "number" : "key").font(.system(size: 13)).foregroundStyle(Theme.Text.tertiary)
                }
                Text(copy.description)
                    .hermesText(.caption)
                    .foregroundStyle(Theme.Text.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail = copy.detail {
                    Text(detail)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.Text.primary)
                        .lineLimit(6)
                        .textSelection(.enabled)
                }
                PromptFailure(prompt: prompt)
            }
            .hermesText(.conversation)
            .foregroundStyle(Theme.Text.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hermesCard()
            HStack(spacing: Theme.Spacing.xs) {
                Button(copy.decline) {
                    Task { await center.answerValue(prompt.id, "") }
                }
                .buttonStyle(PromptButtonStyle(kind: .text))
                Button("\(copy.confirm)…") { entering = true }
                    .buttonStyle(PromptButtonStyle(kind: .primary))
            }
        }
        .sheet(isPresented: $entering) {
            ValueSheet(request: request) { value in
                Task { await center.answerValue(prompt.id, value) }
            }
        }
    }
}

/// The masked entry for a value request: a secure field (or a one-time code, or a login's two fields).
struct ValueSheet: View {
    let request: PromptCenter.ValueRequest
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var value = ""
    @FocusState private var focused: Bool

    var body: some View {
        let copy = ValueCopy(request)
        NavigationStack {
            Form {
                Section {
                    switch request.field {
                    case .secret:
                        SecureField(copy.placeholder, text: $value)
                            .textContentType(.password)
                            .focused($focused)
                    case .code:
                        TextField("Code", text: $value)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                            .focused($focused)
                    case .login:
                        TextField("Email or username", text: $identifier, prompt: Text("you@example.com"))
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($focused)
                        SecureField("Password", text: $value)
                            .textContentType(.password)
                    }
                } header: {
                    Text(copy.description).textCase(nil)
                } footer: {
                    VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                        if let detail = copy.detail { Text(detail).font(.system(size: 12, design: .monospaced)) }
                        if let footnote = copy.footnote { Text(footnote) }
                    }
                }
            }
            .navigationTitle(copy.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(copy.confirm) {
                        submit(answer)
                        dismiss()
                    }
                    .disabled(value.isEmpty || (request.field == .login && identifier.isEmpty))
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    /// A login is answered as JSON `{identifier, password}`.
    private var answer: String {
        guard request.field == .login else { return value }
        let data = (try? JSONSerialization.data(withJSONObject: ["identifier": identifier, "password": value])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The desktop's words for each value request (`prompts.*`).
private struct ValueCopy {
    var title: String
    var description: String
    /// The command a password is for, or the secret's name.
    var detail: String?
    var placeholder = "Value"
    var decline = "Decline"
    var confirm = "Send"
    var footnote: String?

    init(_ request: PromptCenter.ValueRequest) {
        let message = request.message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let given = message?.isEmpty == false ? message : nil
        switch request.method {
        case "sudo":
            title = "Administrator password"
            description = "Review the command before entering your sudo password. Your password is sent to the agent running it and cached for this session."
            detail = given
            if given == nil { footnote = "This agent did not provide the command. Cancel if you cannot verify it in the conversation." }
            placeholder = "sudo password"
        case "display.install.sudo":
            title = "Administrator password"
            description = "Hermes needs your sudo password to install the Bot Screen packages (TigerVNC + Xfce) on the gateway host. It is sent only to that host."
            placeholder = "sudo password"
        case "secret":
            title = "Secret required"
            description = given ?? "Hermes needs a credential to continue."
            detail = request.title
            placeholder = "secret value"
        case "vault.unlock_prompt":
            let name = request.title.hasPrefix("Unlock ") ? String(request.title.dropFirst("Unlock ".count)) : "the password manager"
            title = request.title
            description = "The agent wants to sign into a site with a login saved in \(name). Enter your master password to unlock it for this session — it goes straight to \(name) and is never stored or shown to the agent."
            placeholder = "Master password"
            decline = "Keep locked"
            confirm = "Unlock"
        case "vault.save_login":
            let prefix = "Save a login for "
            let site = request.title.hasPrefix(prefix) ? String(request.title.dropFirst(prefix.count)) : "this site"
            title = "Save your \(site) login?"
            description = "Hermes reached a sign-in page\(given.map { " at \($0)" } ?? "") and has no login for it. Enter it once here; it is encrypted on the host and filled into the page without the model ever seeing the password."
            decline = "Don't save"
            confirm = "Save & sign in"
            footnote = "Manage saved logins in Settings → Passwords & Logins."
        case "vault.code":
            let prefix = "Code for "
            let site = request.title.hasPrefix(prefix) ? String(request.title.dropFirst(prefix.count)) : "the site"
            title = "Verification code for \(site)"
            description = "\(site) is asking for a one-time code (text message, email or authenticator app). Enter it here and Hermes types it into the page; the model never sees it."
            detail = given
            decline = "Skip"
            confirm = "Enter code"
            footnote = "Tip: save the authenticator key with this login in Settings → Passwords & Logins and Hermes enters codes for you."
        default:
            title = request.title
            description = given ?? "Hermes needs a value to continue."
        }
    }
}

// MARK: - Shared

/// The desktop's small buttons: filled primary, soft secondary, and a bare text button.
struct PromptButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, text }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        PromptButtonBody(kind: kind, configuration: configuration)
    }
}

private struct PromptButtonBody: View {
    let kind: PromptButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .hermesText(.button)
            .foregroundStyle(foreground)
            .padding(.horizontal, Theme.Spacing.md + 2)
            .frame(minHeight: 28)
            .background(background, in: RoundedRectangle(cornerRadius: Theme.Radius.control))
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(Rectangle())
    }

    private var foreground: Color {
        switch kind {
        case .primary: return Theme.primaryForeground
        case .secondary: return Theme.Text.primary
        case .text: return Theme.Text.secondary
        }
    }

    private var background: Color {
        let pressed = configuration.isPressed
        switch kind {
        case .primary: return pressed ? Theme.primary.opacity(0.85) : Theme.primary
        case .secondary: return pressed ? Theme.Fill.controlActive : Theme.Fill.quaternary
        case .text: return pressed ? Theme.Fill.controlHover : .clear
        }
    }
}

private struct PromptFailure: View {
    let prompt: PromptCenter.Prompt

    var body: some View {
        if let failure = prompt.failure {
            Text(failure).hermesText(.caption).foregroundStyle(Theme.Semantic.red)
        }
    }
}
