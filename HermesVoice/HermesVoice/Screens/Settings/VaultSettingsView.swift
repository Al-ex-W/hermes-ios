import SwiftUI

/// Settings > Passwords & Logins (`vault-settings.tsx`): credentials the browser fills on their origin without
/// the model seeing them (`vault.list|add|remove`), and the password managers they can come from
/// (`vault.sources|source_set|unlock|lock`). A secret typed here goes to the host in one `vault.add` and is
/// cleared from the form; the list only ever shows metadata.
struct VaultSettingsView: View {
    @EnvironmentObject private var context: SettingsContext
    let subpage: String?

    @State private var items: [VaultItem] = []
    @State private var sources: [VaultSource] = []
    @State private var loaded = false
    @State private var failure: String?
    @State private var adding = false
    @State private var removing: VaultItem?
    @State private var unlocking: VaultSource?
    @State private var password = ""
    @State private var busy = false

    private var showsSources: Bool { subpage == "sources" }

    var body: some View {
        Form {
            if context.gateway == nil {
                Section { FormNote("Not connected to Hermes.") }
            } else if showsSources {
                sourcesSection
            } else {
                credentialsSection
            }
        }
        .hermesForm()
        .overlay { if !loaded && context.gateway != nil { ProgressView() } }
        .refreshable { await reload() }
        .task { await reload() }
        .toolbar {
            if !showsSources {
                ToolbarItem(placement: .primaryAction) {
                    Button { adding = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("Add credential")
                        .disabled(context.gateway == nil)
                }
            }
        }
        .sheet(isPresented: $adding) {
            NavigationStack { VaultAddForm { await reload() } }
                .environmentObject(context)
        }
        .confirmationDialog("Delete \(removing?.label ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { item in
            Button("Delete", role: .destructive) { Task { await remove(item) } }
        } message: { _ in
            Text("The browser can no longer fill it.")
        }
        .alert("Unlock \(unlocking?.displayName ?? "")", isPresented: Binding(get: { unlocking != nil }, set: { if !$0 { unlocking = nil; password = "" } }),
               presenting: unlocking) { source in
            SecureField("Master password", text: $password)
            Button("Cancel", role: .cancel) { password = "" }
            Button("Unlock") { Task { await unlock(source) } }
        }
    }

    private var credentialsSection: some View {
        Section {
            if loaded && items.isEmpty {
                Text("No saved credentials yet.").foregroundStyle(Theme.Text.tertiary)
            }
            ForEach(items, id: \.id) { item in
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack {
                        Text(item.label).foregroundStyle(Theme.Text.primary)
                        Spacer()
                        Text(Self.kindLabel(item.kind)).hermesText(.meta).foregroundStyle(Theme.Text.tertiary)
                    }
                    let facts = [item.identifier, item.origin.map(Self.host), item.hasOtp == true ? "2FA code" : nil]
                        .compactMap { $0?.nilIfEmpty }
                    if !facts.isEmpty {
                        Text(facts.joined(separator: " · ")).hermesText(.caption).foregroundStyle(Theme.Text.tertiary).lineLimit(1)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { removing = item }
                }
            }
        } header: {
            FormNote("Saved credentials")
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("The browser fills these on the site they were saved for. The model never sees the secret.") }
        }
        .hermesFormRows()
        .id("vault.credentials")
    }

    private var sourcesSection: some View {
        Section {
            if loaded && sources.isEmpty {
                Text("No password managers found on the host.").foregroundStyle(Theme.Text.tertiary)
            }
            ForEach(sources, id: \.name) { source in
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    Toggle(isOn: Binding(get: { source.enabled }, set: { on in Task { await setEnabled(source, on) } })) {
                        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                            Text(source.displayName).foregroundStyle(Theme.Text.primary)
                            Text(Self.state(source)).hermesText(.caption).foregroundStyle(Theme.Text.tertiary)
                        }
                    }
                    .disabled(busy || !source.installed)
                    if source.enabled && source.needsUnlock {
                        Button(source.unlocked ? "Lock" : "Unlock") {
                            if source.unlocked { Task { await lock(source) } } else { unlocking = source }
                        }
                        .hermesText(.button)
                        .disabled(busy)
                    }
                }
            }
        } header: {
            FormNote("Password managers")
        } footer: {
            if let failure { FormNote(failure, color: Theme.destructive) }
            else { FormNote("Credentials can also come from a password manager on the host.") }
        }
        .hermesFormRows()
        .id("vault.sources")
    }

    static func kindLabel(_ kind: String) -> String {
        switch kind {
        case "login": return "Login"
        case "payment": return "Card"
        case "address": return "Address"
        default: return SettingsText.prettyName(kind)
        }
    }

    static func host(_ origin: String) -> String {
        URL(string: origin)?.host ?? origin
    }

    static func state(_ source: VaultSource) -> String {
        if !source.installed { return "Not installed on the host" }
        if !source.enabled { return "Off" }
        if source.needsUnlock { return source.unlocked ? "Unlocked" : "Locked" }
        return "On"
    }

    private func reload() async {
        guard let gateway = context.gateway else { return }
        do {
            if showsSources {
                sources = try await gateway.vaultSources().sources ?? []
            } else {
                items = try await gateway.vaultList().items ?? []
            }
            failure = nil
        } catch {
            if !error.isCancellation { failure = error.localizedDescription }
        }
        loaded = true
    }

    private func run(_ action: (GatewayClient) async throws -> Void) async {
        guard let gateway = context.gateway else { return }
        busy = true
        defer { busy = false }
        do {
            try await action(gateway)
            failure = nil
        } catch {
            failure = error.localizedDescription
        }
        await reload()
    }

    private func remove(_ item: VaultItem) async {
        await run { _ = try await $0.vaultRemove(.init(id: item.id)) }
    }

    private func setEnabled(_ source: VaultSource, _ enabled: Bool) async {
        await run { _ = try await $0.vaultSourceSet(.init(name: source.name, enabled: enabled)) }
    }

    private func unlock(_ source: VaultSource) async {
        let secret = password
        password = ""
        await run { _ = try await $0.vaultUnlock(.init(name: source.name, password: secret)) }
    }

    private func lock(_ source: VaultSource) async {
        await run { _ = try await $0.vaultLock(.init(name: source.name)) }
    }
}

/// The add form (`buildSecret`): what each kind stores, checked like the desktop (an http(s) origin, and an
/// identifier and password for a login).
struct VaultAddForm: View {
    @EnvironmentObject private var context: SettingsContext
    @Environment(\.dismiss) private var dismiss
    let saved: () async -> Void

    struct Draft: Equatable {
        var kind = "login"
        var label = ""
        var origin = ""
        var identifierType = "email"
        var identifier = ""
        var password = ""
        var otpSecret = ""
        var cardNumber = ""
        var cardName = ""
        var expMonth = ""
        var expYear = ""
        var cvc = ""
        var postal = ""
        var line1 = ""
        var line2 = ""
        var city = ""
        var state = ""
        var country = ""

        /// Why it can't be saved yet, or nil.
        var problem: String? {
            if label.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a name." }
            if !Self.isValidOrigin(origin.trimmingCharacters(in: .whitespaces)) {
                return "Enter the site's address, starting with https://."
            }
            if kind == "login", identifier.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty {
                return "A login needs an identifier and a password."
            }
            return nil
        }

        static func isValidOrigin(_ value: String) -> Bool {
            guard let url = URL(string: value), let scheme = url.scheme?.lowercased() else { return false }
            return (scheme == "https" || scheme == "http") && !(url.host ?? "").isEmpty
        }

        /// The encrypted payload of `vault.add`.
        var secret: [String: JSONValue] {
            func trimmed(_ text: String) -> JSONValue { .string(text.trimmingCharacters(in: .whitespaces)) }
            switch kind {
            case "login":
                var secret: [String: JSONValue] = ["identifier_type": .string(identifierType), "identifier": trimmed(identifier),
                                                   "password": .string(password)]
                if !otpSecret.trimmingCharacters(in: .whitespaces).isEmpty { secret["otp_secret"] = trimmed(otpSecret) }
                return secret
            case "payment":
                return ["card_number": .string(cardNumber.filter { !$0.isWhitespace }), "cardholder_name": trimmed(cardName),
                        "exp_month": trimmed(expMonth), "exp_year": trimmed(expYear), "cvc": .string(cvc),
                        "billing_postal_code": trimmed(postal)]
            default:
                var secret: [String: JSONValue] = ["address_line1": trimmed(line1), "city": trimmed(city),
                                                   "postal_code": trimmed(postal), "country": trimmed(country)]
                if !line2.trimmingCharacters(in: .whitespaces).isEmpty { secret["address_line2"] = trimmed(line2) }
                if !state.trimmingCharacters(in: .whitespaces).isEmpty { secret["state"] = trimmed(state) }
                return secret
            }
        }
    }

    @State private var draft = Draft()
    @State private var saving = false
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                Picker("Kind", selection: $draft.kind) {
                    Text("Login").tag("login")
                    Text("Card").tag("payment")
                    Text("Address").tag("address")
                }
                TextField("Name", text: $draft.label)
                TextField(draft.kind == "login" ? "https://example.com" : "https://shop.example.com", text: $draft.origin)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            } footer: {
                FormNote("Filled only on this site.")
            }
            .hermesFormRows()
            switch draft.kind {
            case "login":
                Section {
                    Picker("Sign in with", selection: $draft.identifierType) {
                        Text("Email").tag("email")
                        Text("Phone").tag("phone")
                        Text("Username").tag("username")
                    }
                    TextField("Email, phone or username", text: $draft.identifier)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Password", text: $draft.password)
                    SecureField("2FA secret (optional)", text: $draft.otpSecret)
                }
                .hermesFormRows()
            case "payment":
                Section {
                    TextField("Card number", text: $draft.cardNumber).keyboardType(.numberPad)
                    TextField("Name on card", text: $draft.cardName)
                    HStack {
                        TextField("MM", text: $draft.expMonth).keyboardType(.numberPad)
                        TextField("YYYY", text: $draft.expYear).keyboardType(.numberPad)
                    }
                    SecureField("CVC", text: $draft.cvc).keyboardType(.numberPad)
                    TextField("Billing postal code", text: $draft.postal)
                }
                .hermesFormRows()
            default:
                Section {
                    TextField("Address line 1", text: $draft.line1)
                    TextField("Address line 2 (optional)", text: $draft.line2)
                    TextField("City", text: $draft.city)
                    TextField("State or region (optional)", text: $draft.state)
                    TextField("Postal code", text: $draft.postal)
                    TextField("Country", text: $draft.country)
                }
                .hermesFormRows()
            }
            if let failure {
                Section { FormNote(failure, color: Theme.destructive) }
            }
        }
        .hermesForm()
        .navigationTitle("Add credential")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") { Task { await save() } }.disabled(saving)
            }
        }
    }

    private func save() async {
        if let problem = draft.problem {
            failure = problem
            return
        }
        guard let gateway = context.gateway else { return }
        saving = true
        defer { saving = false }
        let origin = draft.origin.trimmingCharacters(in: .whitespaces)
        do {
            _ = try await gateway.vaultAdd(.init(kind: VaultKind(rawValue: draft.kind),
                                                 label: draft.label.trimmingCharacters(in: .whitespaces),
                                                 origin: origin, secret: draft.secret))
            draft = Draft()
            await saved()
            dismiss()
        } catch {
            failure = error.localizedDescription
        }
    }
}
