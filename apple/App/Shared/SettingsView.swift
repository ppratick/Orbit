import OrbitKit
import SwiftUI
import UniformTypeIdentifiers
#if os(iOS)
import UIKit
#endif

enum SettingsDestination: String, Hashable {
    case assistant = "Assistant", connections = "Connected apps", devices = "Devices", data = "Data & privacy"
    case icloud = "iCloud Mail", github = "GitHub", canvas = "Canvas", mac = "Mac access"
}

@MainActor final class OrbitSettingsNavigation: ObservableObject {
    @Published var path: [SettingsDestination] = []
    var title: String { path.last?.rawValue ?? "Settings" }
    func push(_ destination: SettingsDestination) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { path.append(destination) }
    }
    func back() {
        guard !path.isEmpty else { return }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) { _ = path.removeLast() }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @Environment(\.openURL) private var openURL
    @ObservedObject var navigation = OrbitSettingsNavigation()
    var showsHeader = true
    @State private var pairing: APIClient.PairingCode?
    @State private var creatingCode = false
    @State private var icloudUser = ""
    @State private var icloudPassword = ""
    @State private var token = ""
    @State private var canvasURL = ""
    @State private var exportDoc: MarkdownDoc?
    @State private var signingIn = false
    @State private var signIn: ChatGPTSignIn?
    @State private var confirmUnpair = false
    @State private var syncing = false
    @State private var deviceToRemove: DeviceInfo?
    @State private var showAddAccounts = false
    @State private var expandedErrors: Set<String> = []
    @State private var copied = false

    private var connectedAccounts: [Account] {
        store.accounts.values.filter { $0.provider != "chatgpt" && $0.status != "disabled" }
            .sorted { ($0.provider, $0.label) < ($1.provider, $1.label) }
    }
    private var chatGPTAccount: Account? {
        model.modelInfo?.chatgptAccounts.first { $0.status != "disabled" }
    }
    private var chatGPTConnected: Bool { chatGPTAccount?.status == "active" }
    private var devices: [DeviceInfo] {
        store.devices.values.filter { $0.revokedAt == nil }.sorted { ($0.lastSeenAt?.date ?? .distantPast) > ($1.lastSeenAt?.date ?? .distantPast) }
    }
    private var serverHost: String { URL(string: model.serverURL)?.host ?? model.serverURL }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                Text(navigation.title)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                    .lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .padding(.horizontal, 58)
                    .overlay(alignment: .leading) {
                        if !navigation.path.isEmpty {
                            OrbitCircleButton(symbol: "chevron.left", label: "Back") { navigation.back() }
                        }
                    }.padding(16)
            }
            ZStack {
                if let destination = navigation.path.last {
                    OrbitScreen { destinationContent(destination) }
                        .id(destination)
                        .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                                removal: .move(edge: .trailing).combined(with: .opacity)))
                } else {
                    settingsOverview
                        .transition(.move(edge: .leading).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .background { OrbitBackdrop() }
        .fileExporter(isPresented: Binding(get: { exportDoc != nil }, set: { if !$0 { exportDoc = nil } }),
                      document: exportDoc, contentType: .plainText,
                      defaultFilename: "orbit-export-\(Date().formatted(.iso8601.year().month().day())).md") { _ in exportDoc = nil }
        .confirmationDialog("Unpair this device?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.unpair() }
        } message: {
            Text("This device stops syncing and forgets its access. Your conversation and memory stay on your server.")
        }
        .confirmationDialog("Remove paired device?", isPresented: Binding(get: { deviceToRemove != nil }, set: { if !$0 { deviceToRemove = nil } }), titleVisibility: .visible) {
            Button("Remove device", role: .destructive) {
                guard let device = deviceToRemove else { return }
                deviceToRemove = nil
                Task { await model.removeDevice(device) }
            }
        } message: {
            Text("\(deviceToRemove?.name ?? "This device") will stop syncing and running tasks. You can pair it again later.")
        }
        .task { await model.refreshModelInfo() }
    }

    // MARK: Overview

    private var settingsOverview: some View {
        OrbitScreen {
            profileCard
            OrbitGroup {
                link(.assistant, symbol: "sparkle", tint: OrbitProvider.tint("chatgpt"),
                     subtitle: chatGPTConnected ? "ChatGPT connected · Luna & Sol" : "Connect ChatGPT to start")
            }
            OrbitGroup(header: "Connections") {
                link(.connections, symbol: "square.stack.3d.up.fill", tint: Color(red: 0.3, green: 0.5, blue: 0.98),
                     subtitle: connectedAccounts.isEmpty ? "Mail, Drive, Canvas, GitHub" : "\(connectedAccounts.count) connected")
                OrbitRowDivider()
                link(.devices, symbol: "laptopcomputer.and.iphone", tint: Color(red: 0.45, green: 0.45, blue: 0.5),
                     subtitle: "\(devices.count) paired")
            }
            OrbitGroup(header: "General",
                         footer: serverHost.isEmpty ? nil : "Connected to \(serverHost)") {
                link(.data, symbol: "lock.fill", tint: Color(red: 0.2, green: 0.62, blue: 0.5), subtitle: "Sync, export and this device")
                #if os(macOS)
                OrbitRowDivider()
                link(.mac, symbol: "folder.fill", tint: Color(red: 0.25, green: 0.6, blue: 0.95), subtitle: "Files and scripts")
                #endif
            }
        }
    }

    private var profileCard: some View {
        HStack(spacing: 14) {
            ZStack {
                Circle().stroke(.white.opacity(0.92), lineWidth: 2.2).frame(width: 24, height: 24)
                Circle().fill(.white).frame(width: 7, height: 7).offset(x: 15, y: -10)
            }
            .frame(width: OrbitTheme.isMac ? 48 : 58, height: OrbitTheme.isMac ? 48 : 58)
            .background(LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.95), Color(red: 0.55, green: 0.3, blue: 0.85)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 12 : 16, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text("Your Orbit").font(.system(size: OrbitTheme.isMac ? 16 : 19, weight: .semibold))
                if let label = chatGPTAccount?.label, chatGPTConnected {
                    Text(label).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Personal assistant").font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            OrbitBadge(text: chatGPTConnected ? "Ready" : "Setup needed", tint: chatGPTConnected ? .green : .orange)
        }
        .padding(OrbitTheme.isMac ? 14 : 16)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }

    private func link(_ destination: SettingsDestination, symbol: String, tint: Color, subtitle: String) -> some View {
        Button { navigation.push(destination) } label: {
            OrbitRow(symbol: symbol, tint: tint, title: destination.rawValue, subtitle: subtitle, accessory: .chevron)
        }.buttonStyle(OrbitRowButtonStyle())
    }

    @ViewBuilder private func destinationContent(_ destination: SettingsDestination) -> some View {
        switch destination {
        case .assistant: assistantSettings
        case .connections: connectionSettings
        case .devices: deviceSettings
        case .data: dataSettings
        case .icloud: iCloudSettings
        case .github, .canvas: tokenSettings(destination)
        case .mac:
            #if os(macOS)
            macSettings
            #else
            EmptyView()
            #endif
        }
    }

    // MARK: Assistant

    @ViewBuilder private var assistantSettings: some View {
        OrbitHero(symbol: "sparkle", tint: OrbitProvider.tint("chatgpt"), title: "Assistant",
                  detail: "Orbit thinks with your ChatGPT plan. Luna handles everyday requests; Sol takes on harder, multi-step work.")
        OrbitGroup(header: "ChatGPT account") {
            OrbitRow(symbol: "person.crop.circle.fill", tint: OrbitProvider.tint("chatgpt"),
                     title: chatGPTConnected ? (chatGPTAccount?.label ?? "Connected") : "Not connected",
                     subtitle: chatGPTConnected ? "Signed in" : "Sign in to let Orbit reply") {
                OrbitBadge(text: chatGPTConnected ? "Active" : "Off", tint: chatGPTConnected ? .green : .secondary)
            }
            if let error = chatGPTAccount?.lastError { errorRow(id: "chatgpt", error) }
            OrbitRowDivider(inset: 0)
            VStack(spacing: 8) {
                Button(action: connectChatGPT) {
                    HStack(spacing: 8) {
                        if signingIn { ProgressView().controlSize(.small).tint(.black) }
                        Text(signingIn ? "Waiting for ChatGPT…" : chatGPTConnected ? "Reconnect ChatGPT" : "Continue with ChatGPT")
                    }
                }
                .buttonStyle(.orbitPrimary).disabled(signingIn)
                if chatGPTAccount != nil {
                    Button("Sign out", role: .destructive) {
                        Task {
                            await model.perform { api in
                                let revoked = try await api.chatgptSignOut()
                                await MainActor.run { model.banner = revoked ? "Signed out" : "Signed out locally. Check ChatGPT settings to revoke access." }
                            }
                            await model.refreshModelInfo()
                        }
                    }
                    .buttonStyle(.orbitDestructive)
                }
            }
            .padding(OrbitTheme.rowHorizontal)
        }
        OrbitGroup(header: "Models") {
            modelRow("Luna", detail: fullModelName(model.modelInfo?.basicModel) ?? "Everyday tasks", symbol: "moon.fill", tint: Color(red: 0.4, green: 0.45, blue: 0.95), verified: model.modelInfo?.verified?.basic)
            OrbitRowDivider()
            modelRow("Sol", detail: fullModelName(model.modelInfo?.advancedModel) ?? "Deeper reasoning", symbol: "sun.max.fill", tint: Color(red: 0.98, green: 0.62, blue: 0.2), verified: model.modelInfo?.verified?.advanced)
            if let error = model.modelInfo?.verifyError { errorRow(id: "verify", error) }
        }
    }

    private func fullModelName(_ slug: String?) -> String? {
        guard let slug else { return nil }
        return model.modelInfo?.catalog?.first { $0.slug == slug }?.displayName ?? slug
    }

    private func modelRow(_ title: String, detail: String, symbol: String, tint: Color, verified: Bool?) -> some View {
        OrbitRow(symbol: symbol, tint: tint, title: title, subtitle: detail) {
            if let verified {
                Image(systemName: verified ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                    .font(.system(size: OrbitTheme.isMac ? 14 : 18))
                    .foregroundStyle(verified ? .green : .orange)
                    .accessibilityLabel(verified ? "Available" : "Unavailable")
            }
        }
    }

    // MARK: Connections

    @ViewBuilder private var connectionSettings: some View {
        ForEach(["google", "icloud_mail", "github", "canvas"], id: \.self) { provider in
            let accounts = connectedAccounts.filter { $0.provider == provider }
            if !accounts.isEmpty {
                OrbitGroup(header: provider == "google" ? "Gmail & Drive" : OrbitProvider.name(provider)) {
                    ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                        if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal) }
                        accountRow(account)
                    }
                }
            }
        }
        DisclosureGroup(isExpanded: $showAddAccounts) {
            OrbitGroup() {
            Button {
                Task {
                    guard let api = model.api else { return }
                    do { if let url = URL(string: try await api.googleLink(label: "").url) { openURL(url) } }
                    catch { model.banner = error.localizedDescription }
                }
            } label: {
                OrbitRow(symbol: OrbitProvider.symbol("google"), tint: OrbitProvider.tint("google"), title: "Google", subtitle: "Gmail and Drive", accessory: .external)
            }.buttonStyle(OrbitRowButtonStyle())
            OrbitRowDivider()
            providerLink(.icloud, provider: "icloud", subtitle: "Mail over IMAP")
            OrbitRowDivider()
            providerLink(.github, provider: "github", subtitle: "Issues, pull requests and code")
            OrbitRowDivider()
            providerLink(.canvas, provider: "canvas", subtitle: "Courses and deadlines")
            }
            .padding(.top, 12)
        } label: {
            Label("Add an account", systemImage: "plus.circle")
                .font(OrbitTheme.body).foregroundStyle(.primary)
        }
        .tint(.secondary)
    }

    private func providerLink(_ destination: SettingsDestination, provider: String, subtitle: String) -> some View {
        Button { navigation.push(destination) } label: {
            OrbitRow(symbol: OrbitProvider.symbol(provider), tint: OrbitProvider.tint(provider), title: destination.rawValue, subtitle: subtitle, accessory: .chevron)
        }.buttonStyle(OrbitRowButtonStyle())
    }

    private func accountRow(_ account: Account) -> some View {
        VStack(spacing: 0) {
            OrbitRow(title: account.label.isEmpty ? OrbitProvider.name(account.provider) : account.label,
                     subtitle: account.lastError == nil ? "Connected" : "Needs attention") {
                if account.lastError != nil { OrbitBadge(text: "Issue", tint: .orange) }
                Menu {
                    Button("Disconnect", role: .destructive) { Task { await model.perform { try await $0.disconnect(accountId: account.id) } } }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Options for \(account.label)")
            }
            if let error = account.lastError { errorRow(id: account.id, error) }
        }
    }

    // MARK: Integration forms

    @ViewBuilder private var iCloudSettings: some View {
        OrbitHero(symbol: OrbitProvider.symbol("icloud"), tint: OrbitProvider.tint("icloud"), title: "iCloud Mail",
                  detail: "Lets Orbit search and read your iCloud inbox. Your Apple ID password is never used.")
        OrbitGroup(header: "Account",
                     footer: "Create an app-specific password at account.apple.com → Sign-In and Security. You can revoke it there any time.") {
            OrbitFieldRow(label: "Email", prompt: "you@icloud.com", text: $icloudUser)
                #if os(iOS)
                .textContentType(.username).keyboardType(.emailAddress)
                #endif
            OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
            OrbitFieldRow(label: "App-specific password", prompt: "xxxx-xxxx-xxxx-xxxx", text: $icloudPassword, secure: true)
        }
        VStack(spacing: 10) {
            Button("Connect iCloud Mail") {
                let user = icloudUser, password = icloudPassword
                icloudPassword = ""
                Task { await model.perform { try await $0.connectICloud(username: user, appPassword: password) } }
            }
            .buttonStyle(.orbitPrimary).disabled(icloudUser.isEmpty || icloudPassword.isEmpty)
            Link(destination: URL(string: "https://account.apple.com")!) {
                Label("Get an app-specific password", systemImage: "arrow.up.right")
                    .font(OrbitTheme.footnote.weight(.medium))
            }
        }
        .onDisappear { icloudPassword = "" }
    }

    @ViewBuilder private func tokenSettings(_ destination: SettingsDestination) -> some View {
        let provider = destination == .github ? "github" : "canvas"
        OrbitHero(symbol: OrbitProvider.symbol(provider), tint: OrbitProvider.tint(provider), title: destination.rawValue,
                  detail: destination == .github
                    ? "Read issues, pull requests and repositories you choose. Comments and merges wait for approval."
                    : "See your courses, assignments and due dates. Submissions wait for approval.")
        OrbitGroup(header: "Access",
                     footer: destination == .github
                        ? "GitHub → Settings → Developer settings → Fine-grained tokens. Grant read access to the repositories Orbit should see."
                        : "Canvas → Account → Settings → New Access Token. Use your school’s Canvas address, like canvas.school.edu.") {
            if destination == .canvas {
                OrbitFieldRow(label: "School URL", prompt: "https://canvas.school.edu", text: $canvasURL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    #endif
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
            }
            OrbitFieldRow(label: "Access token", prompt: "Paste your token", text: $token, secure: true)
        }
        Button("Connect \(destination.rawValue)") {
            let value = token, base = destination == .canvas ? canvasURL : nil
            token = ""
            Task { await model.perform { try await $0.connectToken(provider: destination.rawValue.lowercased(), token: value, baseURL: base) } }
        }
        .buttonStyle(.orbitPrimary).disabled(token.isEmpty || (destination == .canvas && canvasURL.isEmpty))
        .onAppear { token = "" }
        .onDisappear { token = "" }
    }

    // MARK: Devices

    @ViewBuilder private var deviceSettings: some View {
        OrbitGroup(header: "Paired devices",
                     footer: "Calendar, Reminders and Mac actions run on these devices. Edits always run on the device that has the item.") {
            if devices.isEmpty {
                OrbitRow(title: "No devices yet", subtitle: "Pair your Mac or iPhone to sync")
            }
            ForEach(Array(devices.enumerated()), id: \.element.id) { index, device in
                if index > 0 { OrbitRowDivider() }
                OrbitRow(symbol: device.kind == "mac" ? "laptopcomputer" : "iphone", tint: Color(white: 0.4),
                         title: device.name,
                         subtitle: device.lastSeenAt.map { "Active \($0.date.formatted(.relative(presentation: .named)))" } ?? "Paired, not seen yet") {
                    if let seen = device.lastSeenAt?.date, Date().timeIntervalSince(seen) < 5 * 60 {
                        OrbitBadge(text: "Online", tint: .green)
                    }
                    Menu {
                        Button("Remove device", role: .destructive) { deviceToRemove = device }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 30, height: 30)
                            .contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .accessibilityLabel("Options for \(device.name)")
                }
            }
        }
        if let pairing {
            pairingCard(pairing)
        }
        Button {
            creatingCode = true
            Task {
                pairing = try? await model.api?.createPairingCode()
                creatingCode = false
                copied = false
            }
        } label: {
            HStack(spacing: 8) {
                if creatingCode { ProgressView().controlSize(.small).tint(.black) }
                Text(pairing == nil ? "Pair a new device" : "Get a new code")
            }
        }
        .buttonStyle(pairing == nil ? OrbitButtonStyle(kind: .primary) : OrbitButtonStyle(kind: .secondary))
        .disabled(creatingCode)
    }

    private func pairingCard(_ pairing: APIClient.PairingCode) -> some View {
        VStack(spacing: OrbitTheme.isMac ? 10 : 14) {
            Text("PAIRING CODE").font(OrbitTheme.sectionHeader).tracking(1).foregroundStyle(.secondary)
            Text(pairing.code.map(String.init).joined(separator: " "))
                .font(.system(size: OrbitTheme.isMac ? 26 : 32, weight: .semibold, design: .monospaced))
                .textSelection(.enabled).minimumScaleFactor(0.6).lineLimit(1)
                .accessibilityLabel("Pairing code \(pairing.code)")
            Text("Enter this on your other device. Expires at \(pairing.expiresAt.date.formatted(date: .omitted, time: .shortened)).")
                .font(OrbitTheme.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button {
                copy(pairing.code)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy code", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(OrbitButtonStyle(kind: .secondary, fullWidth: false))
        }
        .padding(OrbitTheme.isMac ? 18 : 22)
        .frame(maxWidth: .infinity)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous)
            .stroke(Color.white.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
    }

    private func copy(_ text: String) {
        #if os(iOS)
        UIPasteboard.general.string = text
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        #endif
    }

    // MARK: Data & privacy

    @ViewBuilder private var dataSettings: some View {
        OrbitGroup(header: "Sync") {
            OrbitRow(symbol: "arrow.triangle.2.circlepath", tint: store.lastSyncError == nil ? Color(red: 0.2, green: 0.72, blue: 0.42) : .orange,
                     title: "Last sync",
                     accessory: .value(store.lastSyncAt?.formatted(date: .omitted, time: .shortened) ?? "Not yet"))
            if let error = store.lastSyncError { errorRow(id: "sync", error) }
            OrbitRowDivider()
            OrbitRow(symbol: "server.rack", tint: Color(white: 0.4), title: "Server", subtitle: serverHost)
                .textSelection(.enabled)
            OrbitRowDivider(inset: 0)
            Button {
                syncing = true
                Task { await model.tick(); syncing = false }
            } label: {
                OrbitRow(title: syncing ? "Syncing…" : "Sync now", titleColor: .accentColor) {
                    if syncing { ProgressView().controlSize(.small) }
                }
            }
            .buttonStyle(OrbitRowButtonStyle()).disabled(syncing)
        }
        OrbitGroup(header: "Your data", footer: "Exports your memory, tracked items and conversation as a Markdown file.") {
            Button {
                Task {
                    guard let api = model.api else { return }
                    do { exportDoc = MarkdownDoc(data: try await api.exportMarkdown()) }
                    catch { model.banner = error.localizedDescription }
                }
            } label: {
                OrbitRow(symbol: "square.and.arrow.up", tint: Color(red: 0.3, green: 0.5, blue: 0.98), title: "Export memory & history", accessory: .chevron)
            }.buttonStyle(OrbitRowButtonStyle())
        }
        OrbitGroup(header: "This device") {
            Button { confirmUnpair = true } label: {
                OrbitRow(symbol: "xmark", tint: Color(red: 0.95, green: 0.33, blue: 0.3), title: "Unpair this device",
                         titleColor: Color(red: 1, green: 0.45, blue: 0.42))
            }.buttonStyle(OrbitRowButtonStyle())
        }
    }

    // MARK: Mac

    #if os(macOS)
    @ViewBuilder private var macSettings: some View {
        let scripts = MacExecutor.allowListedScripts()
        OrbitHero(symbol: "folder.fill", tint: Color(red: 0.25, green: 0.6, blue: 0.95), title: "Mac access",
                  detail: "Orbit can search and read files, and run scripts you place in your Orbit folder.")
        OrbitGroup(header: "Folder") {
            Button { NSWorkspace.shared.open(MacExecutor.orbitDir) } label: {
                OrbitRow(symbol: "folder", tint: Color(red: 0.25, green: 0.6, blue: 0.95), title: "Open Orbit folder", subtitle: MacExecutor.orbitDir.path, accessory: .external)
            }.buttonStyle(OrbitRowButtonStyle())
            OrbitRowDivider()
            Button { Task { await model.registerCapabilities() } } label: {
                OrbitRow(symbol: "arrow.clockwise", tint: Color(white: 0.4), title: "Refresh access", subtitle: "Re-share what this Mac can do")
            }.buttonStyle(OrbitRowButtonStyle())
        }
        OrbitGroup(header: "Allowed scripts", footer: "Add executable scripts to ~/Orbit/Scripts. Only these run without asking.") {
            if scripts.isEmpty {
                OrbitRow(symbol: "terminal", tint: Color(white: 0.3), title: "No scripts added")
            }
            ForEach(Array(scripts.enumerated()), id: \.offset) { index, script in
                if index > 0 { OrbitRowDivider() }
                OrbitRow(symbol: "terminal.fill", tint: Color(white: 0.3), title: script)
            }
        }
    }
    #endif

    // MARK: Helpers

    private func errorRow(id: String, _ error: String) -> some View {
        let open = expandedErrors.contains(id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.easeOut(duration: 0.2)) {
                    if open { expandedErrors.remove(id) } else { expandedErrors.insert(id) }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text("Connection details")
                    Spacer()
                    Image(systemName: "chevron.down").rotationEffect(.degrees(open ? 180 : 0))
                }
                .font(OrbitTheme.footnote.weight(.medium)).foregroundStyle(.orange)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                Text(error).font(OrbitTheme.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.leading, OrbitTheme.tileSize + 12)
        .padding(.bottom, OrbitTheme.rowVertical)
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
