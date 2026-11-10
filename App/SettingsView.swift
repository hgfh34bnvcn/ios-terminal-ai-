import SwiftUI
import TermCore
import TermSSH

enum SettingsRoute: Hashable {
    case connection(UUID?)
    case host(UUID?)
    case instructions
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var path: [SettingsRoute] = []

    var body: some View {
        NavigationStack(path: $path) {
            Form {
                connections
                environments
                agent
                appearance
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(for: SettingsRoute.self) { route in
                switch route {
                case .connection(let id): ConnectionEditor(profileID: id)
                case .host(let id): HostEditor(hostID: id)
                case .instructions: InstructionsEditor()
                }
            }
        }
        .tint(model.palette.accent)
        .onAppear {
            if model.demo == .connection, path.isEmpty, let first = model.profiles.first {
                path = [.connection(first.id)]
            }
        }
    }

    private var connections: some View {
        Section {
            ForEach(model.profiles) { profile in
                NavigationLink(value: SettingsRoute.connection(profile.id)) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if profile.id == model.activeProfile?.id {
                            Image(systemName: "checkmark").foregroundStyle(.tint)
                        }
                    }
                }
            }
            NavigationLink(value: SettingsRoute.connection(nil)) {
                Label("Add connection", systemImage: "plus")
            }
        } header: {
            Text("Connections")
        } footer: {
            Text("The gateways requests are sent to. The one in use is ticked; switch on a connection's page or from the session list.")
        }
    }

    private var environments: some View {
        Section {
            LabeledContent(model.deviceName, value: "Files only")
            ForEach(model.hosts) { host in
                NavigationLink(value: SettingsRoute.host(host.id)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.name)
                        Text(host.address).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            NavigationLink(value: SettingsRoute.host(nil)) {
                Label("Add SSH host", systemImage: "plus")
            }
        } header: {
            Text("Environments")
        } footer: {
            Text("Where sessions work. On an SSH host the agent can run commands; on this device it can only read and write files, which appear in Files › On My iPhone › TermAI.")
        }
    }

    private var agent: some View {
        Section {
            Picker("New sessions start in", selection: binding(\.defaultMode)) {
                ForEach(PermissionMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            NavigationLink(value: SettingsRoute.instructions) {
                LabeledContent("Instructions", value: model.settings.instructions.trimmed.isEmpty ? "None" : "On")
            }
        } header: {
            Text("Agent")
        } footer: {
            Text("\(model.settings.defaultMode.title): \(model.settings.defaultMode.detail.lowercased()). Instructions are added to every session; a CLAUDE.md or AGENTS.md in the working folder is read as well.")
        }
    }

    private var appearance: some View {
        Section("Appearance") {
            Picker("Theme", selection: binding(\.themeID)) {
                ForEach(Theme.all) { theme in
                    Text(theme.name).tag(theme.id)
                }
            }
            Stepper("Text size: \(Int(model.settings.fontSize))", value: binding(\.fontSize), in: 11...22, step: 1)
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<AppSettings, Value>) -> Binding<Value> {
        Binding(
            get: { model.settings[keyPath: keyPath] },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }
}

// MARK: Connection

/// One gateway: where it is, how to authenticate, and which models it offers.
private struct ConnectionEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID?

    @State private var draft = Profile(name: "", baseURL: "")
    @State private var apiKey = ""
    @State private var headers: [HeaderField] = []
    @State private var loaded = false
    @State private var revealKey = false
    @State private var testing = false
    @State private var testResult: String?
    @State private var testFailed = false
    @State private var addingModel = false

    private var problem: String? {
        if draft.name.trimmed.isEmpty { return "Connection needs a name" }
        guard let url = URL(string: draft.baseURL.trimmed), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", url.host != nil else {
            return "Connection needs Gateway base URL"
        }
        return nil
    }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $draft.name)
                    .autocorrectionDisabled()
                Picker("API format", selection: $draft.format) {
                    ForEach(APIFormat.allCases) { format in
                        Text(format.title).tag(format)
                    }
                }
            } header: {
                Text("Connection")
            } footer: {
                Text(draft.format == .anthropic
                     ? "Requests go to /v1/messages under the base URL, the format Claude Code and Claude Desktop gateways use."
                     : "Requests go to /chat/completions under the base URL. Include /v1 in the base URL if your provider has it.")
            }

            Section {
                TextField(draft.format == .anthropic ? "https://llm-gateway.example.com" : "https://api.example.com/v1",
                          text: $draft.baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                HStack {
                    Group {
                        if revealKey {
                            TextField("Gateway API key", text: $apiKey)
                        } else {
                            SecureField("Gateway API key", text: $apiKey)
                        }
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    Button {
                        revealKey.toggle()
                    } label: {
                        Image(systemName: revealKey ? "eye.slash" : "eye")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(revealKey ? "Hide key" : "Show key")
                }
                Picker("Gateway auth scheme", selection: $draft.authScheme) {
                    Text("bearer").tag(AuthScheme.bearer)
                    Text("x-api-key").tag(AuthScheme.xAPIKey)
                }
            } header: {
                Text("Gateway credentials")
            } footer: {
                Text("The auth scheme is how the key is sent: Authorization: Bearer, or the x-api-key header. The key is kept in the Keychain on this device.")
            }

            Section {
                ForEach($headers) { $header in
                    HStack {
                        TextField("Name", text: $header.name)
                        Divider()
                        TextField("Value", text: $header.value)
                    }
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.callout, design: .monospaced))
                }
                .onDelete { headers.remove(atOffsets: $0) }
                Button {
                    headers.append(HeaderField())
                } label: {
                    Label("Add header", systemImage: "plus")
                }
            } header: {
                Text("Custom inference headers")
            } footer: {
                Text("Extra headers sent with every request, for routing or tenant selection.")
            }

            models

            if draft.format == .anthropic {
                Section {
                    LabeledContent("Max output tokens") {
                        TextField("16000", value: $draft.maxOutputTokens, format: .number.grouping(.never))
                            .keyboardType(.numberPad)
                            .multilineTextAlignment(.trailing)
                    }
                    Toggle("Prompt caching", isOn: $draft.promptCaching)
                } header: {
                    Text("Advanced")
                } footer: {
                    Text("Caching marks the conversation so far as reusable, which makes each tool round cheaper and faster.")
                }
            }

            Section {
                Button {
                    test()
                } label: {
                    HStack {
                        Text("Test connection")
                        Spacer()
                        if testing { ProgressView() }
                    }
                }
                .disabled(testing || problem != nil)
                if let testResult {
                    Text(testResult)
                        .font(.footnote)
                        .foregroundStyle(testFailed ? Color.red : Color.secondary)
                }
            }

            if let id = profileID {
                Section {
                    if model.activeProfile?.id != id {
                        Button("Use this connection") {
                            model.activateProfile(id)
                        }
                    }
                    Button("Delete connection", role: .destructive) {
                        model.deleteProfile(id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(profileID == nil ? "New connection" : draft.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveProfile(draft, apiKey: apiKey, headers: headers)
                    dismiss()
                }
                .disabled(problem != nil)
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let problem {
                Text(problem)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .sheet(isPresented: $addingModel) {
            AddModelSheet(discovered: draft.discovered.filter { !draft.models.contains($0.id) }) { id in
                if !draft.models.contains(id) { draft.models.append(id) }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let profile = model.profiles.first(where: { $0.id == profileID }) {
                draft = profile
                apiKey = model.apiKey(for: profile)
                headers = model.headers(for: profile)
            }
        }
    }

    private var models: some View {
        Section {
            Toggle("Model discovery", isOn: $draft.modelDiscovery)
            ForEach(draft.models, id: \.self) { id in
                HStack {
                    Text(id)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if id == draft.models.first {
                        Text("default").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .swipeActions(edge: .leading) {
                    Button("Make default") {
                        draft.models.removeAll { $0 == id }
                        draft.models.insert(id, at: 0)
                    }
                    .tint(.orange)
                }
            }
            .onDelete { draft.models.remove(atOffsets: $0) }
            Button {
                addingModel = true
            } label: {
                Label("Add model", systemImage: "plus")
            }
            Picker("Default model effort", selection: $draft.defaultEffort) {
                ForEach(Effort.allCases) { effort in
                    Text(effort.title).tag(effort)
                }
            }
            Toggle("Always start with the default model", isOn: $draft.alwaysStartWithDefault)
        } header: {
            Text("Models")
        } footer: {
            Text(draft.modelDiscovery
                 ? "Discovery fills the model picker from the gateway's model list when the app starts (\(draft.discovered.count) found so far). Models listed here come first, and the first one is the default. With \"Always start\" off, new sessions keep your last model and effort."
                 : "Only the models listed here are offered, and the first one is the default. With \"Always start\" off, new sessions keep your last model and effort.")
        }
    }

    private func test() {
        testing = true
        testResult = nil
        let profile = draft, key = apiKey, extra = headers
        Task {
            do {
                let found = try await model.fetchModels(for: profile, apiKey: key, headers: extra)
                draft.discovered = found
                testFailed = false
                testResult = found.isEmpty
                    ? "Connected, but the gateway listed no models. Add model IDs by hand."
                    : "Connected. \(found.count) models available."
            } catch {
                testFailed = true
                testResult = ErrorText.describe(error)
            }
            testing = false
        }
    }
}

private struct AddModelSheet: View {
    let discovered: [ModelInfo]
    let add: (String) -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var custom = ""
    @State private var search = ""

    private var matches: [ModelInfo] {
        let query = search.trimmed.lowercased()
        guard !query.isEmpty else { return discovered }
        return discovered.filter { $0.id.lowercased().contains(query) || ($0.displayName ?? "").lowercased().contains(query) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("Model ID", text: $custom)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.callout, design: .monospaced))
                        Button("Add") {
                            add(custom.trimmed)
                            dismiss()
                        }
                        .buttonStyle(.borderless)
                        .disabled(custom.trimmed.isEmpty)
                    }
                } footer: {
                    Text("The exact ID your gateway expects.")
                }
                if !discovered.isEmpty {
                    Section("From the gateway") {
                        ForEach(matches) { info in
                            Button {
                                add(info.id)
                                dismiss()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(info.displayName ?? info.id).foregroundStyle(Color.primary)
                                    if info.displayName != nil {
                                        Text(info.id).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Filter models")
            .navigationTitle("Add model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .tint(model.palette.accent)
    }
}

// MARK: SSH host

private struct HostEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let hostID: UUID?

    @State private var host = SSHHost(name: "", host: "", username: "")
    @State private var secret = ""
    @State private var passphrase = ""
    @State private var loaded = false

    private var canSave: Bool {
        ![host.name, host.host, host.username].contains { $0.trimmed.isEmpty } && (1...65_535).contains(host.port)
    }

    var body: some View {
        Form {
            Section("Server") {
                TextField("Name, e.g. web1", text: $host.name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Hostname or IP", text: $host.host)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                LabeledContent("Port") {
                    TextField("22", value: $host.port, format: .number.grouping(.never))
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Username", text: $host.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Section {
                // Switching method clears the secret; done in the setter so loading a saved host does not trigger it.
                Picker("Method", selection: Binding(
                    get: { host.auth },
                    set: { method in
                        guard method != host.auth else { return }
                        host.auth = method
                        secret = ""
                        passphrase = ""
                    })) {
                    Text("Password").tag(SSHHost.Auth.password)
                    Text("Private key").tag(SSHHost.Auth.privateKey)
                }
                .pickerStyle(.segmented)
                if host.auth == .password {
                    SecureField("Password", text: $secret)
                } else {
                    TextEditor(text: $secret)
                        .font(.system(.caption2, design: .monospaced))
                        .frame(minHeight: 120)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Passphrase (if the key has one)", text: $passphrase)
                }
            } header: {
                Text("Authentication")
            } footer: {
                Text(host.auth == .password
                     ? "Kept in the Keychain on this device."
                     : "Paste an Ed25519 or RSA private key in OpenSSH format (-----BEGIN OPENSSH PRIVATE KEY-----). Kept in the Keychain on this device.")
            }

            if let key = host.trustedHostKey {
                Section {
                    Text(SSHKeys.fingerprint(ofOpenSSHKey: key))
                        .font(.system(.caption, design: .monospaced))
                    Button("Forget host key", role: .destructive) {
                        host.trustedHostKey = nil
                    }
                } header: {
                    Text("Trusted host key")
                } footer: {
                    Text("Recorded on the first connection. Later connections are refused if the server presents a different key.")
                }
            }

            if let id = hostID {
                Section {
                    Button("Delete host", role: .destructive) {
                        model.deleteHost(id)
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle(hostID == nil ? "New SSH host" : host.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    model.saveHost(host, secret: secret, passphrase: passphrase)
                    dismiss()
                }
                .disabled(!canSave)
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let saved = model.hosts.first(where: { $0.id == hostID }) {
                host = saved
                secret = model.hostSecret(for: saved)
                passphrase = model.hostPassphrase(for: saved)
            }
        }
    }
}

private struct InstructionsEditor: View {
    @Environment(AppModel.self) private var model
    @State private var text = ""
    @State private var loaded = false

    var body: some View {
        TextEditor(text: $text)
            .font(.system(.body, design: .monospaced))
            .padding(8)
            .navigationTitle("Instructions")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !loaded else { return }
                loaded = true
                text = model.settings.instructions
            }
            .onChange(of: text) {
                model.update { $0.instructions = text }
            }
    }
}

// MARK: Working folder

/// Picks the folder a session works in by browsing the environment or typing a path.
struct FolderPicker: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var listing: FolderListing?
    @State private var typed = ""
    @State private var loading = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField(model.hasShell ? "~/project" : "/notes", text: $typed)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.system(.callout, design: .monospaced))
                            .onSubmit { load(typed) }
                        Button("Go") { load(typed) }
                            .buttonStyle(.borderless)
                    }
                } header: {
                    Text("Path on \(model.environmentLabel)")
                } footer: {
                    if let problem {
                        Text(problem).foregroundStyle(Color.red)
                    }
                }

                if !model.recentFolders.isEmpty {
                    Section("Recent") {
                        ForEach(model.recentFolders, id: \.self) { folder in
                            Button {
                                choose(folder)
                            } label: {
                                row(folder, symbol: "clock")
                            }
                        }
                    }
                }

                Section {
                    if loading {
                        HStack {
                            ProgressView()
                            Text("Loading…").foregroundStyle(.secondary)
                        }
                    }
                    if let listing {
                        if let parent = listing.parent {
                            Button {
                                load(parent)
                            } label: {
                                row("..", symbol: "arrow.up")
                            }
                        }
                        ForEach(listing.directories, id: \.self) { name in
                            Button {
                                load(listing.path == "/" ? "/" + name : listing.path + "/" + name)
                            } label: {
                                row(name, symbol: "folder")
                            }
                        }
                        if listing.directories.isEmpty {
                            Text("No folders here").foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text(listing?.display ?? "Folders")
                }
            }
            .navigationTitle("Working folder")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use folder") {
                        choose(typed.trimmed.isEmpty ? (listing?.display ?? "") : typed)
                    }
                }
            }
            .onAppear {
                if listing == nil, !loading { load(model.session.folder) }
            }
        }
        .tint(model.palette.accent)
    }

    private func row(_ title: String, symbol: String) -> some View {
        Label {
            Text(title).foregroundStyle(Color.primary)
        } icon: {
            Image(systemName: symbol)
        }
    }

    private func load(_ path: String) {
        loading = true
        problem = nil
        Task {
            do {
                let result = try await model.browse(path)
                listing = result
                typed = result.display
            } catch {
                problem = ErrorText.describe(error)
            }
            loading = false
        }
    }

    private func choose(_ path: String) {
        model.setFolder(path)
        dismiss()
    }
}
