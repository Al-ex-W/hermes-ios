import SwiftUI

/// What Hermes is waiting on in this chat (approvals, questions, passwords), above the composer.
struct PromptStack: View {
    @ObservedObject var center: PromptCenter
    let sessionIDs: Set<String>

    var body: some View {
        let prompts = center.prompts(for: sessionIDs)
        if !prompts.isEmpty {
            VStack(spacing: 8) {
                ForEach(prompts) { prompt in
                    Group {
                        switch prompt.kind {
                        case let .approval(approval):
                            ApprovalCard(prompt: prompt, approval: approval, center: center)
                        case let .clarify(params):
                            ClarifyCard(prompt: prompt, params: params, center: center)
                        case let .value(request):
                            ValueCard(prompt: prompt, request: request, center: center)
                        }
                    }
                    .disabled(prompt.answering)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.top, 8)
        }
    }
}

/// A dangerous command waiting for a decision: Run, Allow session, Always or Reject.
struct ApprovalCard: View {
    let prompt: PromptCenter.Prompt
    let approval: PromptCenter.Approval
    let center: PromptCenter

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(approval.description, systemImage: "exclamationmark.shield")
                .font(.subheadline.weight(.semibold))
            if !approval.command.isEmpty {
                Text(approval.command)
                    .font(.caption.monospaced())
                    .lineLimit(6)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 6))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(approval.choices, id: \.rawValue) { choice in
                    Button {
                        Task { await center.approve(prompt.id, choice) }
                    } label: {
                        Text(Self.label(choice)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .tint(Self.tint(choice))
                }
            }
            PromptFailure(prompt: prompt)
        }
    }

    static func tint(_ choice: ApprovalChoice) -> Color {
        switch choice {
        case .once: return .accentColor
        case .deny: return .red
        default: return .secondary
        }
    }

    static func label(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: return "Run"
        case .session: return "Allow session"
        case .always: return "Always"
        case .deny: return "Reject"
        case let .unknown(value): return value
        }
    }
}

/// The clarify tool's questions: a choice (or several) or a typed answer each; unanswered ones are skipped.
struct ClarifyCard: View {
    let prompt: PromptCenter.Prompt
    let params: ClarifyRequestParams
    let center: PromptCenter
    @State private var picked: [String: [String]] = [:]
    @State private var typed: [String: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Hermes asks", systemImage: "questionmark.bubble")
                .font(.subheadline.weight(.semibold))
            ForEach(params.questions, id: \.qid) { question in
                VStack(alignment: .leading, spacing: 6) {
                    Text(question.question).font(.callout)
                    if let choices = question.choices, !choices.isEmpty {
                        ForEach(choices, id: \.self) { choice in
                            Button {
                                pick(choice, in: question)
                            } label: {
                                Label(choice, systemImage: symbol(choice, in: question))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else {
                        TextField("Answer", text: Binding(
                            get: { typed[question.qid] ?? "" },
                            set: { typed[question.qid] = $0 }
                        ), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                    }
                }
            }
            HStack {
                Button("Skip all") {
                    Task { await center.answerClarify(prompt.id, answers: nil) }
                }
                Spacer()
                Button("Send") {
                    Task { await center.answerClarify(prompt.id, answers: answers) }
                }
                .buttonStyle(.borderedProminent)
            }
            PromptFailure(prompt: prompt)
        }
        .onAppear(perform: prefill)
    }

    private func pick(_ choice: String, in question: ClarifyQuestion) {
        var current = picked[question.qid] ?? []
        if question.multiSelect == true {
            if let index = current.firstIndex(of: choice) { current.remove(at: index) } else { current.append(choice) }
        } else {
            current = current == [choice] ? [] : [choice]
        }
        picked[question.qid] = current
    }

    private func symbol(_ choice: String, in question: ClarifyQuestion) -> String {
        let on = picked[question.qid]?.contains(choice) == true
        if question.multiSelect == true { return on ? "checkmark.square.fill" : "square" }
        return on ? "largecircle.fill.circle" : "circle"
    }

    /// Per question: the choice, a multi-select as a JSON array in the offered order, the typed text, or nil (skipped).
    private var answers: [String: String?] {
        var result: [String: String?] = [:]
        for question in params.questions {
            if let choices = question.choices, !choices.isEmpty {
                let chosen = choices.filter { picked[question.qid]?.contains($0) == true }
                if chosen.isEmpty {
                    result[question.qid] = .some(nil)
                } else if question.multiSelect == true {
                    let data = (try? JSONSerialization.data(withJSONObject: chosen)) ?? Data()
                    result[question.qid] = .some(String(decoding: data, as: UTF8.self))
                } else {
                    result[question.qid] = .some(chosen[0])
                }
            } else {
                let text = (typed[question.qid] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                result[question.qid] = .some(text.isEmpty ? nil : text)
            }
        }
        return result
    }

    /// Answers locked already (from another client, or before a reconnect).
    private func prefill() {
        for question in params.questions {
            guard let locked = params.answers?[question.qid] ?? nil else { continue }
            if let choices = question.choices, !choices.isEmpty {
                let list = (try? JSONSerialization.jsonObject(with: Data(locked.utf8))) as? [String]
                picked[question.qid] = list ?? [locked]
            } else {
                typed[question.qid] = locked
            }
        }
    }
}

/// A password, secret, code or login Hermes needs; entered in a sheet.
struct ValueCard: View {
    let prompt: PromptCenter.Prompt
    let request: PromptCenter.ValueRequest
    let center: PromptCenter
    @State private var entering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(request.title, systemImage: request.field == .code ? "number" : "key.fill")
                .font(.subheadline.weight(.semibold))
            if let message = request.message, !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(4)
            }
            HStack {
                Button("Decline") {
                    Task { await center.answerValue(prompt.id, "") }
                }
                Spacer()
                Button("Enter…") { entering = true }
                    .buttonStyle(.borderedProminent)
            }
            PromptFailure(prompt: prompt)
        }
        .sheet(isPresented: $entering) {
            ValueSheet(request: request) { value in
                Task { await center.answerValue(prompt.id, value) }
            }
        }
    }
}

struct ValueSheet: View {
    let request: PromptCenter.ValueRequest
    let submit: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var identifier = ""
    @State private var value = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    switch request.field {
                    case .secret:
                        SecureField("Value", text: $value)
                    case .code:
                        TextField("Code", text: $value)
                            .keyboardType(.numberPad)
                            .textContentType(.oneTimeCode)
                    case .login:
                        TextField("Username or email", text: $identifier)
                            .textContentType(.username)
                            .textInputAutocapitalization(.never)
                        SecureField("Password", text: $value)
                            .textContentType(.password)
                    }
                } footer: {
                    if let message = request.message { Text(message) }
                }
            }
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") {
                        submit(answer)
                        dismiss()
                    }
                    .disabled(value.isEmpty)
                }
            }
        }
    }

    /// A login is answered as JSON `{identifier, password}`.
    private var answer: String {
        guard request.field == .login else { return value }
        let data = (try? JSONSerialization.data(withJSONObject: ["identifier": identifier, "password": value])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

private struct PromptFailure: View {
    let prompt: PromptCenter.Prompt

    var body: some View {
        if let failure = prompt.failure {
            Text(failure).font(.caption).foregroundStyle(.red)
        }
    }
}
