import OrbitKit
import SwiftUI
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @Environment(\.openURL) private var openURL
    @State private var pairing: APIClient.PairingCode?
    @State private var icloudUser = ""
    @State private var icloudPassword = ""
    @State private var tokenProvider = "github"
    @State private var token = ""
    @State private var canvasURL = ""
    @State private var exportDoc: MarkdownDoc?
    @State private var signingIn = false
    @State private var signIn: ChatGPTSignIn? // retained while the web session is open

    var body: some View {
        Form {
            Section(header: Text("AI model"), footer: Text("Orbit uses your ChatGPT plan through Sign in with ChatGPT: Luna for basic tasks, Sol for harder ones. Plan usage limits are shared with your other apps (ChatGPT Settings → Usage). There is no paid API fallback.")) {
                if let m = model.modelInfo {
                    LabeledContent("Basic", value: m.basicModel + (m.verified.map { $0.basic ? " ✓" : " — not in your catalog" } ?? ""))
                    LabeledContent("Advanced", value: m.advancedModel + (m.verified.map { $0.advanced ? " ✓" : " — not in your catalog" } ?? ""))
                    if let e = m.verifyError { Text(e).font(.caption).foregroundStyle(.red) }
                    if let a = m.chatgptAccounts.first(where: { $0.status != "disabled" }) {
                        LabeledContent("ChatGPT", value: a.status == "active" ? (a.identity.map { _ in a.label } ?? "signed in") : a.status.replacingOccurrences(of: "_", with: " "))
                        if let e = a.lastError { Text(e).font(.caption).foregroundStyle(.orange) }
                    } else {
                        Text("Not signed in").foregroundStyle(.secondary)
                    }
                }
                Button(signingIn ? "Waiting for sign-in in the browser…" : "Continue with ChatGPT") {
                    signingIn = true
                    Task {
                        let s = ChatGPTSignIn()
                        signIn = s
                        if let api = model.api {
                            do {
                                let email = try await s.signIn(api: api)
                                model.banner = "Signed in with ChatGPT\(email.map { " as \($0)" } ?? "")"
                            } catch { model.banner = "ChatGPT sign-in: \(error.localizedDescription)" }
                        }
                        await model.refreshModelInfo(verify: true)
                        signingIn = false
                        signIn = nil
                    }
                }.disabled(signingIn)
                Button("Verify model IDs with my account") { Task { await model.refreshModelInfo(verify: true) } }
                if model.modelInfo?.chatgptAccounts.contains(where: { $0.status == "active" || $0.status == "error" }) == true {
                    Button("Sign out of ChatGPT", role: .destructive) {
                        Task {
                            await model.perform { api in
                                let revoked = try await api.chatgptSignOut()
                                await MainActor.run { model.banner = revoked ? "Signed out of ChatGPT" : "Signed out locally; remote revocation wasn't confirmed — you can disconnect Orbit in ChatGPT Settings." }
                            }
                            await model.refreshModelInfo()
                        }
                    }
                }
            }

            Section(header: Text("Accounts"), footer: Text("Credentials are sent once to your Orbit server, encrypted there, and never shown to the AI model.")) {
                ForEach(store.accounts.values.sorted { $0.provider < $1.provider }) { a in
                    VStack(alignment: .leading) {
                        Text("\(a.provider) · \(a.label)")
                        if let e = a.lastError { Text(e).font(.caption).foregroundStyle(.red) }
                        else if let s = a.lastSyncAt { Text("checked \(s.date, style: .relative) ago").font(.caption).foregroundStyle(.secondary) }
                    }
                    .swipeActions { Button("Disconnect", role: .destructive) { Task { await model.perform { try await $0.disconnect(accountId: a.id) } } } }
                }
                Button("Connect a Google account (Gmail + Drive)") {
                    Task {
                        guard let api = model.api else { return }
                        do { if let u = URL(string: try await api.googleLink(label: "").url) { openURL(u) } } catch { model.banner = error.localizedDescription }
                    }
                }
            }

            Section(header: Text("iCloud Mail"), footer: Text("Use an app-specific password from appleid.apple.com (Sign-In and Security → App-Specific Passwords).")) {
                TextField("you@icloud.com", text: $icloudUser).autocorrectionDisabled()
                SecureField("App-specific password", text: $icloudPassword)
                Button("Connect iCloud Mail") {
                    let u = icloudUser, p = icloudPassword
                    icloudPassword = ""
                    Task { await model.perform { try await $0.connectICloud(username: u, appPassword: p) } }
                }.disabled(icloudUser.isEmpty || icloudPassword.isEmpty)
            }

            Section(header: Text("Token-based services"), footer: Text("GitHub: fine-grained personal access token. Slack: user token (xoxp-) from your own Slack app. Canvas: Account → Settings → New Access Token.")) {
                Picker("Service", selection: $tokenProvider) { Text("GitHub").tag("github"); Text("Slack").tag("slack"); Text("Canvas").tag("canvas") }
                if tokenProvider == "canvas" { TextField("https://school.instructure.com", text: $canvasURL).autocorrectionDisabled() }
                SecureField("Token", text: $token)
                Button("Connect") {
                    let p = tokenProvider, t = token, base = tokenProvider == "canvas" ? canvasURL : nil
                    token = ""
                    Task { await model.perform { try await $0.connectToken(provider: p, token: t, baseURL: base) } }
                }.disabled(token.isEmpty || (tokenProvider == "canvas" && canvasURL.isEmpty))
            }

            Section("Devices") {
                ForEach(store.devices.values.filter { $0.revokedAt == nil }.sorted { $0.name < $1.name }) { d in
                    LabeledContent(d.name, value: d.lastSeenAt.map { "\($0.date.formatted(.relative(presentation: .named)))" } ?? d.kind)
                }
                Button("Pair another device") { Task { pairing = try? await model.api?.createPairingCode() } }
                if let p = pairing {
                    Text(p.code).font(.title.monospaced()).textSelection(.enabled)
                    Text("Valid until \(p.expiresAt.date.formatted(date: .omitted, time: .shortened)), single use").font(.caption)
                }
            }

            Section("Data") {
                Button("Export memory & history as Markdown") {
                    Task {
                        guard let api = model.api else { return }
                        do { exportDoc = MarkdownDoc(data: try await api.exportMarkdown()) } catch { model.banner = error.localizedDescription }
                    }
                }
                if let s = store.lastSyncAt { LabeledContent("Last sync", value: s.formatted(date: .omitted, time: .standard)) }
                if let e = store.lastSyncError { Text(e).font(.caption).foregroundStyle(.red) }
                LabeledContent("Server", value: model.serverURL)
                Button("Unpair this device", role: .destructive) { model.unpair() }
            }

            #if os(macOS)
            Section(header: Text("Mac companion"), footer: Text("Put scripts Orbit may run without asking into ~/Orbit/Scripts (must be executable). Anything else needs approval.")) {
                LabeledContent("Allow-listed scripts", value: MacExecutor.allowListedScripts().joined(separator: ", ").isEmpty ? "none" : MacExecutor.allowListedScripts().joined(separator: ", "))
                Button("Open ~/Orbit") { NSWorkspace.shared.open(MacExecutor.orbitDir) }
                Button("Refresh capabilities") { Task { await model.registerCapabilities() } }
            }
            #endif
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }), document: exportDoc, contentType: .plainText,
                      defaultFilename: "orbit-export-\(Date().formatted(.iso8601.year().month().day())).md") { _ in exportDoc = nil }
        .task { await model.refreshModelInfo() }
    }
}

struct MarkdownDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
