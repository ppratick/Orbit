import OrbitKit
import SwiftUI
import UniformTypeIdentifiers

enum SettingsDestination: String, Hashable {
    case assistant = "Assistant", connections = "Connected apps", devices = "Devices", data = "Data & privacy"
    case icloud = "iCloud Mail", github = "GitHub", slack = "Slack", canvas = "Canvas", mac = "Mac access"
}

@MainActor final class OrbitSettingsNavigation: ObservableObject {
    @Published var path: [SettingsDestination] = []
    var title: String { path.last?.rawValue ?? "Settings" }
    func back() { if !path.isEmpty { path.removeLast() } }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @Environment(\.openURL) private var openURL
    @ObservedObject var navigation = OrbitSettingsNavigation()
    var showsHeader = true
    @State private var pairing: APIClient.PairingCode?
    @State private var icloudUser = ""
    @State private var icloudPassword = ""
    @State private var token = ""
    @State private var canvasURL = ""
    @State private var exportDoc: MarkdownDoc?
    @State private var signingIn = false
    @State private var signIn: ChatGPTSignIn?
    @State private var confirmUnpair = false

    private var connectedAccounts: [Account] {
        store.accounts.values.filter { $0.provider != "chatgpt" && $0.status != "disabled" }
            .sorted { ($0.provider, $0.label) < ($1.provider, $1.label) }
    }
    private var chatGPTAccount: Account? {
        model.modelInfo?.chatgptAccounts.first { $0.status != "disabled" }
    }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                Text(navigation.title)
                    .font(.system(size: 24, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 58)
                    .overlay(alignment: .leading) {
                        if !navigation.path.isEmpty {
                            OrbitCircleButton(symbol: "chevron.left", label: "Back") { navigation.back() }
                        }
                    }.padding(20)
            }
            if let destination = navigation.path.last {
                OrbitPage { destinationContent(destination) }
                    .id(destination)
            } else { settingsOverview }
        }
        .background { OrbitBackdrop() }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .plainText,
                      defaultFilename: "orbit-export-\(Date().formatted(.iso8601.year().month().day())).md") { _ in exportDoc = nil }
        .confirmationDialog("Unpair this device?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        }
        .task { await model.refreshModelInfo() }
    }

    private var settingsOverview: some View {
            OrbitPage {
                OrbitCard {
                    HStack(spacing: 16) {
                        Image(systemName: "circle.circle").font(.system(size: 34, weight: .light))
                            .frame(width: 58, height: 58)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Your Orbit").font(.title3.weight(.semibold))
                            Text(chatGPTAccount?.status == "active" ? "Connected to ChatGPT" : "Personal assistant")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                OrbitCard {
                    destinationRow(.assistant, icon: "sparkle", subtitle: "Luna & Sol")
                    Divider()
                    destinationRow(.connections, icon: "square.stack.3d.up", subtitle: "\(connectedAccounts.count) connected")
                    Divider()
                    destinationRow(.devices, icon: "laptopcomputer.and.iphone", subtitle: "Mac & iPhone")
                }
                OrbitCard {
                    destinationRow(.data, icon: "lock", subtitle: "Sync, export & server")
                    #if os(macOS)
                    Divider()
                    destinationRow(.mac, icon: "folder", subtitle: "Files & scripts")
                    #endif
                }
            }
    }

    private func destinationRow(_ destination: SettingsDestination, icon: String, subtitle: String) -> some View {
        Button { navigation.path.append(destination) } label: {
            destinationLabel(destination, icon: icon, subtitle: subtitle)
        }.buttonStyle(.plain)
    }

    private func destinationLabel(_ destination: SettingsDestination, icon: String, subtitle: String) -> some View {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 19)).frame(width: 30)
                VStack(alignment: .leading, spacing: 4) {
                    Text(destination.rawValue).font(.body.weight(.medium))
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
    }

    @ViewBuilder private func destinationContent(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .assistant: assistantSettings
        case .connections: connectionSettings
        case .devices: deviceSettings
        case .data: dataSettings
        case .icloud: iCloudSettings
        case .github, .slack, .canvas: tokenSettings(destination)
        case .mac:
            #if os(macOS)
            macSettings
            #endif
        }
    }

    private var assistantSettings: some View {
        Group {
            OrbitCard {
                Label("ChatGPT", systemImage: "person.crop.circle").font(.headline)
                Text(chatGPTAccount?.status == "active" ? chatGPTAccount?.label ?? "Connected" : "Not connected")
                    .font(.subheadline).foregroundStyle(.secondary)
                Button(signingIn ? "Connecting…" : "Continue with ChatGPT", action: connectChatGPT)
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(signingIn)
                if let error = chatGPTAccount?.lastError { errorDetails(error) }
                if chatGPTAccount != nil {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await model.perform { api in
                                let revoked = try await api.chatgptSignOut()
                                await MainActor.run { model.banner = revoked ? "Signed out" : "Signed out locally. Check ChatGPT settings to revoke access." }
                            }
                            await model.refreshModelInfo()
                        }
                    }.font(.callout)
                }
            }
            OrbitCard {
                Label("Automatic routing", systemImage: "arrow.triangle.branch").font(.headline)
                modelRow("Luna", detail: "Everyday tasks", verified: model.modelInfo?.verified?.basic)
                Divider()
                modelRow("Sol", detail: "Deeper work", verified: model.modelInfo?.verified?.advanced)
                Button("Check availability") { Task { await model.refreshModelInfo(verify: true) } }
                    .buttonStyle(.bordered).controlSize(.large)
                if let error = model.modelInfo?.verifyError { errorDetails(error) }
                DisclosureGroup("Plan details") {
                    Text("Uses your ChatGPT allowance.").font(.caption).foregroundStyle(.secondary)
                    if let info = model.modelInfo {
                        Text("\(info.basicModel)\n\(info.advancedModel)").font(.caption.monospaced()).textSelection(.enabled)
                    }
                }.font(.callout)
            }
        }
    }

    private func modelRow(_ title: String, detail: String, verified: Bool?) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let verified { Image(systemName: verified ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(verified ? .green : .orange) }
        }
    }

    private var connectionSettings: some View {
        Group {
            if !connectedAccounts.isEmpty {
                OrbitCard {
                    Text("Connected").font(.headline)
                    ForEach(connectedAccounts) { account in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(account.label).font(.body.weight(.medium))
                                Text(account.provider.capitalized).font(.caption).foregroundStyle(.secondary)
                                if let error = account.lastError { errorDetails(error) }
                            }
                            Spacer()
                            Menu {
                                Button("Disconnect", role: .destructive) { Task { await model.perform { try await $0.disconnect(accountId: account.id) } } }
                            } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .fixedSize()
                        }
                    }
                }
            }
            OrbitCard {
                Text("Add an account").font(.headline)
                Button {
                    Task {
                        guard let api = model.api else { return }
                        do { if let url = URL(string: try await api.googleLink(label: "").url) { openURL(url) } }
                        catch { model.banner = error.localizedDescription }
                    }
                } label: {
                    HStack {
                        Image(systemName: "envelope").frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Google").fontWeight(.medium)
                            Text("Gmail & Drive").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "plus").foregroundStyle(.secondary)
                    }.padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                Divider()
                destinationRow(.icloud, icon: "icloud", subtitle: "Mail")
                Divider()
                destinationRow(.github, icon: "chevron.left.forwardslash.chevron.right", subtitle: "Repositories")
                Divider()
                destinationRow(.slack, icon: "number", subtitle: "Workspace")
                Divider()
                destinationRow(.canvas, icon: "graduationcap", subtitle: "Courses")
            }
        }
    }

    private var iCloudSettings: some View {
        OrbitCard {
            TextField("Email", text: $icloudUser).textContentType(.username).autocorrectionDisabled()
            Divider()
            SecureField("App-specific password", text: $icloudPassword)
            Button("Connect") {
                let user = icloudUser, password = icloudPassword
                icloudPassword = ""
                Task { await model.perform { try await $0.connectICloud(username: user, appPassword: password) } }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(icloudUser.isEmpty || icloudPassword.isEmpty)
            Link("Get an app-specific password", destination: URL(string: "https://account.apple.com")!).font(.caption)
        }.textFieldStyle(.plain)
        .onDisappear { icloudPassword = "" }
    }

    private func tokenSettings(_ provider: SettingsDestination) -> some View {
        OrbitCard {
            if provider == .canvas {
                TextField("School URL", text: $canvasURL).autocorrectionDisabled()
                Divider()
            }
            SecureField("Access token", text: $token)
            Button("Connect") {
                let value = token, base = provider == .canvas ? canvasURL : nil
                token = ""
                Task { await model.perform { try await $0.connectToken(provider: provider.rawValue.lowercased(), token: value, baseURL: base) } }
            }.buttonStyle(.borderedProminent).controlSize(.large).disabled(token.isEmpty || (provider == .canvas && canvasURL.isEmpty))
            DisclosureGroup("Where to find your token") {
                Text(provider == .github ? "GitHub Settings → Developer settings → Fine-grained tokens." :
                     provider == .slack ? "Use a user token from your Slack app." : "Canvas Account → Settings → New Access Token.")
                    .font(.caption).foregroundStyle(.secondary)
            }.font(.callout)
        }
        .textFieldStyle(.plain)
        .onAppear { token = "" }
        .onDisappear { token = "" }
    }

    private var deviceSettings: some View {
        Group {
            OrbitCard {
                ForEach(store.devices.values.filter { $0.revokedAt == nil }.sorted { $0.name < $1.name }) { device in
                    HStack(spacing: 14) {
                        Image(systemName: device.kind == "mac" ? "laptopcomputer" : "iphone").font(.title3).frame(width: 30)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(device.name).font(.body.weight(.medium))
                            Text(device.lastSeenAt.map { $0.date.formatted(.relative(presentation: .named)) } ?? "Paired")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Pair a device") { Task { pairing = try? await model.api?.createPairingCode() } }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            }
            if let pairing {
                OrbitCard {
                    Text(pairing.code).font(.system(.largeTitle, design: .monospaced)).textSelection(.enabled)
                    Text("Expires \(pairing.expiresAt.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var dataSettings: some View {
        Group {
            OrbitCard {
                LabeledContent("Last sync", value: store.lastSyncAt?.formatted(date: .omitted, time: .shortened) ?? "Not yet")
                if let error = store.lastSyncError { errorDetails(error) }
                Button("Sync now") { Task { await model.tick() } }.buttonStyle(.bordered)
                DisclosureGroup("Server") { Text(model.serverURL).font(.caption.monospaced()).textSelection(.enabled) }
            }
            OrbitCard {
                Button("Export memory & history") {
                    Task {
                        guard let api = model.api else { return }
                        do { exportDoc = MarkdownDoc(data: try await api.exportMarkdown()) }
                        catch { model.banner = error.localizedDescription }
                    }
                }
                Divider()
                Button("Unpair this device", role: .destructive) { confirmUnpair = true }
            }
        }
    }

    #if os(macOS)
    private var macSettings: some View {
        OrbitCard {
            Button("Open Orbit folder") { NSWorkspace.shared.open(MacExecutor.orbitDir) }.buttonStyle(.bordered).controlSize(.large)
            Button("Refresh access") { Task { await model.registerCapabilities() } }
            DisclosureGroup("Scripts") {
                Text("Add executable scripts to ~/Orbit/Scripts.").font(.caption).foregroundStyle(.secondary)
                Text(MacExecutor.allowListedScripts().joined(separator: ", ").isEmpty ? "No scripts added" : MacExecutor.allowListedScripts().joined(separator: ", "))
                    .font(.caption.monospaced())
            }
        }
    }
    #endif

    private func errorDetails(_ error: String) -> some View {
        DisclosureGroup("Connection details") { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            .font(.caption).foregroundStyle(.orange)
    }

    private func connectChatGPT() {
        signingIn = true
        Task {
            let session = ChatGPTSignIn()
            signIn = session
            if let api = model.api {
                do {
                    let email = try await session.signIn(api: api)
                    model.banner = email.map { "Connected as \($0)" } ?? "ChatGPT connected"
                } catch { model.banner = "Sign-in failed: \(error.localizedDescription)" }
            }
            await model.refreshModelInfo(verify: true)
            signingIn = false
            signIn = nil
        }
    }
}

struct MarkdownDoc: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
