import OrbitKit
import SwiftUI
#if os(iOS)
import UIKit
import AVFAudio
#endif

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore

    var body: some View {
        Group {
            if model.isPaired {
                OrbitHomeView()
            } else {
                PairingView()
            }
        }
        .overlay(alignment: .top) {
            if let b = model.banner {
                Text(b).font(.callout).lineLimit(3).padding(.horizontal, 18).padding(.vertical, 12)
                    .orbitGlass(in: RoundedRectangle(cornerRadius: 20)).padding(.horizontal, 20).padding(.top, 68)
                    .onTapGesture { model.banner = nil }
                    .task { try? await Task.sleep(nanoseconds: 5_000_000_000); model.banner = nil }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { model.start() }
    }
}

enum OrbitSection: String, CaseIterable, Identifiable {
    case chat = "Orbit", activity = "Activity", memory = "Memory", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .chat: return "bubble.left"
        case .activity: return "bolt"
        case .memory: return "brain.head.profile"
        case .settings: return "gearshape"
        }
    }
    var selectedIcon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .activity: return "bolt.fill"
        case .memory: return "brain.head.profile.fill"
        case .settings: return "gearshape.fill"
        }
    }
}

/// The drawer can open from the iPhone's left edge without stealing chat scrolling.
struct OrbitHomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var section: OrbitSection = .chat
    @StateObject private var settingsNavigation = OrbitSettingsNavigation()
    @State private var sidebarOpen = false
    @State private var sidebarOpenedByHover = false
    @FocusState private var composerFocused: Bool
    @State private var restoreComposerFocus = false
    @GestureState private var swipe: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let headerHeight: CGFloat = 68
            #else
            let headerHeight: CGFloat = 94
            #endif
            let drawerWidth = min(320, geometry.size.width - 36)
            let reveal = min(max((sidebarOpen ? drawerWidth : 0) + swipe, 0), drawerWidth)
            ZStack(alignment: .leading) {
                OrbitPalette.surface.ignoresSafeArea()
                Group {
                    if section == .chat {
                    ZStack(alignment: .top) {
                        sectionContent
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .safeAreaInset(edge: .top, spacing: 0) {
                                Color.clear.frame(height: headerHeight).allowsHitTesting(false)
                            }
                            .ignoresSafeArea(.container, edges: .top)
                        header
                            .background(alignment: .top) {
                                ZStack {
                                    Rectangle().fill(.ultraThinMaterial)
                                        .opacity(0.22)
                                        .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                                    LinearGradient(stops: [
                                        .init(color: .black.opacity(0.42), location: 0),
                                        .init(color: .black.opacity(0.18), location: 0.55),
                                        .init(color: .clear, location: 1)
                                    ], startPoint: .top, endPoint: .bottom)
                                }
                                    .frame(height: geometry.safeAreaInsets.top + headerHeight + 24)
                                    .offset(y: -geometry.safeAreaInsets.top)
                                    .allowsHitTesting(false)
                            }
                    }
                    } else {
                        VStack(spacing: 0) {
                            header
                            sectionContent.frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background { OrbitBackdrop() }
                .overlay {
                    if reveal > 0 {
                        Color.black.opacity(0.12 * reveal / drawerWidth)
                            .contentShape(Rectangle())
                            .onTapGesture { setSidebar(false) }
                            .gesture(closeGesture)
                            .accessibilityLabel("Close sidebar").accessibilityAddTraits(.isButton)
                    }
                }
                .offset(x: reveal)
                .accessibilityHidden(sidebarOpen)

                #if os(iOS)
                if !sidebarOpen {
                    Color.clear
                        .frame(width: 22)
                        .contentShape(Rectangle())
                        .gesture(openGesture)
                        .accessibilityHidden(true)
                }
                #endif

                drawer
                    .frame(width: drawerWidth)
                    .frame(maxHeight: .infinity)
                    .background(OrbitPalette.sidebar.ignoresSafeArea())
                    .overlay(alignment: .trailing) {
                        Rectangle().fill(Color.primary.opacity(0.08)).frame(width: 1)
                    }
                    .offset(x: reveal - drawerWidth)
                    .gesture(closeGesture)
                    .accessibilityHidden(!sidebarOpen)
                    .accessibilityAction(.escape) { setSidebar(false) }
                    .zIndex(1)
            }
            #if os(iOS)
            // Keep horizontal drawer clipping, while allowing the feed and header blur
            // to extend through the status bar to the physical top edge.
            .mask(Rectangle()
                .padding(.top, -geometry.safeAreaInsets.top)
                .padding(.bottom, -geometry.safeAreaInsets.bottom))
            #else
            .clipped()
            #endif
            #if os(macOS)
            .background {
                MacSidebarHover(sidebarOpen: sidebarOpen, dismissOnExit: sidebarOpenedByHover, sidebarWidth: drawerWidth,
                                onOpen: { setSidebar(true, fromHover: true) },
                                onClose: { if sidebarOpenedByHover { setSidebar(false) } })
            }
            #endif
        }
        .task { await model.openMainConversation() }
        .onChange(of: swipe) { old, current in
            #if os(iOS)
            if !sidebarOpen, old <= 0, current > 0 { dismissKeyboardForSidebar() }
            #endif
        }
        .onChange(of: section) { _, destination in
            if destination != .chat { restoreComposerFocus = false }
        }
        .task(id: sidebarOpen || swipe > 0) {
            #if os(iOS)
            // Also restores focus after a cancelled edge swipe. Wait until the drawer settles.
            guard !sidebarOpen, swipe == 0, restoreComposerFocus, section == .chat else { return }
            do { try await Task.sleep(nanoseconds: 340_000_000) } catch { return }
            guard !Task.isCancelled, !sidebarOpen, section == .chat else { return }
            composerFocused = true
            restoreComposerFocus = false
            #endif
        }
        #if os(macOS)
        .onExitCommand { setSidebar(false) }
        #endif
    }

    private var header: some View {
        OrbitGlassGroup {
            Text(section == .settings ? settingsNavigation.title : section.rawValue)
                .lineLimit(1).minimumScaleFactor(0.7)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity).frame(minHeight: 46)
                .padding(.horizontal, 58)
                .overlay(alignment: .leading) {
                    if section == .settings, !settingsNavigation.path.isEmpty {
                        OrbitCircleButton(symbol: "chevron.left", label: "Back") { settingsNavigation.back() }
                    } else {
                        OrbitMenuButton { setSidebar(true) }
                    }
                }
                .padding(.horizontal, 20)
                #if os(macOS)
                .padding(.top, 36)
                #else
                .padding(.top, 10)
                #endif
                .padding(.bottom, 12)
        }
    }

    @ViewBuilder private var sectionContent: some View {
        switch section {
        case .chat: PersistentChatView(composerFocused: $composerFocused)
        case .activity: WorkView(onCompose: compose, onReviewApproval: { section = .chat })
        case .memory: MemoryView(onTrack: { compose("Help me keep track of ") })
        case .settings: SettingsView(navigation: settingsNavigation, showsHeader: false)
        }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            drawerBrand
                .padding(.horizontal, 8)
                .padding(.bottom, OrbitTheme.isMac ? 18 : 26)
            VStack(spacing: 2) {
                ForEach(OrbitSection.allCases.filter { $0 != .settings }) { destination in
                    drawerRow(destination)
                }
            }
            Spacer(minLength: 20)
            drawerStatus.padding(.horizontal, 8).padding(.bottom, 12)
            Rectangle().fill(OrbitTheme.hairline).frame(height: 0.5).padding(.horizontal, 8).padding(.bottom, 8)
            drawerRow(.settings)
        }
        .padding(.horizontal, OrbitTheme.isMac ? 10 : 14)
        .padding(.vertical, OrbitTheme.isMac ? 12 : 16)
        #if os(macOS)
        .padding(.top, 34)
        #endif
    }

    private var drawerBrand: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(.white.opacity(0.9), lineWidth: OrbitTheme.isMac ? 1.6 : 2)
                    .frame(width: OrbitTheme.isMac ? 15 : 19, height: OrbitTheme.isMac ? 15 : 19)
                Circle().fill(.white).frame(width: OrbitTheme.isMac ? 5 : 6, height: OrbitTheme.isMac ? 5 : 6)
                    .offset(x: OrbitTheme.isMac ? 10 : 12.5, y: OrbitTheme.isMac ? -6 : -8)
            }
            .frame(width: OrbitTheme.isMac ? 34 : 42, height: OrbitTheme.isMac ? 34 : 42)
            .background(
                LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.95), Color(red: 0.55, green: 0.3, blue: 0.85)], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 12, style: .continuous)
            )
            VStack(alignment: .leading, spacing: 1) {
                Text("Orbit").font(.system(size: OrbitTheme.isMac ? 16 : 20, weight: .bold, design: .rounded))
                Text(assistantStatus).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var assistantStatus: String {
        guard let info = model.modelInfo else { return "Personal assistant" }
        return info.chatgptAccounts.contains { $0.status == "active" } ? "Luna & Sol ready" : "Connect ChatGPT in Settings"
    }

    private var drawerStatus: some View {
        let devices = store.devices.values.filter { $0.revokedAt == nil }.count
        let failing = store.lastSyncError != nil
        return HStack(spacing: 8) {
            Circle().fill(failing ? Color.orange : Color.green).frame(width: 7, height: 7)
            Text(failing ? "Sync issue" : store.lastSyncAt.map { "Synced \($0.formatted(.relative(presentation: .named)))" } ?? "Connecting…")
                .lineLimit(1)
            Spacer(minLength: 4)
            Label("\(devices)", systemImage: "laptopcomputer.and.iphone").labelStyle(.titleAndIcon)
                .accessibilityLabel("\(devices) devices")
        }
        .font(OrbitTheme.footnote).foregroundStyle(.secondary)
    }

    private func drawerBadge(_ destination: OrbitSection) -> (Int, Color)? {
        switch destination {
        case .chat:
            let n = store.pendingApprovals.count
            return n > 0 ? (n, .orange) : nil
        case .activity:
            let n = store.recentTasks.filter { $0.status == "queued" || $0.status == "leased" }.count
            return n > 0 ? (n, Color.white.opacity(0.55)) : nil
        default: return nil
        }
    }

    private func drawerRow(_ destination: OrbitSection) -> some View {
        let selected = section == destination
        return Button {
            section = destination
            setSidebar(false)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: selected ? destination.selectedIcon : destination.icon)
                    .font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: selected ? .semibold : .regular))
                    .frame(width: OrbitTheme.isMac ? 20 : 26)
                    .foregroundStyle(selected ? .primary : .secondary)
                Text(destination.rawValue)
                    .font(.system(size: OrbitTheme.isMac ? 13.5 : 17, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : Color.white.opacity(0.78))
                Spacer()
                if let (count, tint) = drawerBadge(destination) {
                    Text("\(count)").font(.system(size: OrbitTheme.isMac ? 10.5 : 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(tint == .orange ? Color.black : Color.white)
                        .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 20)
                        .background(tint == .orange ? Color.orange : Color.white.opacity(0.14), in: Capsule())
                        .accessibilityLabel(destination == .chat ? "\(count) approvals waiting" : "\(count) tasks running")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: OrbitTheme.isMac ? 34 : 48)
            .background(selected ? OrbitTheme.selection : .clear, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 13, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 13, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private var openGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($swipe) { value, state, _ in
                guard value.translation.width > abs(value.translation.height) else { return }
                state = max(value.translation.width, 0)
            }
            .onEnded { value in
                if value.translation.width > 65 && value.translation.width > abs(value.translation.height) { setSidebar(true) }
            }
    }

    private var closeGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($swipe) { value, state, _ in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                state = min(value.translation.width, 0)
            }
            .onEnded { value in
                if value.translation.width < -65 && abs(value.translation.width) > abs(value.translation.height) { setSidebar(false) }
            }
    }

    private func compose(_ text: String) {
        if !text.isEmpty {
            let existing = model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
            model.chatDraft = existing.isEmpty ? text : existing + "\n\n" + text
        }
        section = .chat
    }

    private func dismissKeyboardForSidebar() {
        #if os(iOS)
        restoreComposerFocus = restoreComposerFocus || (section == .chat && composerFocused)
        composerFocused = false
        // Covers a focused Settings field as well as the chat composer, using the public responder API.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        #endif
    }

    private func setSidebar(_ open: Bool, fromHover: Bool = false) {
        sidebarOpenedByHover = open && fromHover
        if open { dismissKeyboardForSidebar() }
        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.86)) { sidebarOpen = open }
    }
}

struct PersistentChatView: View {
    @FocusState.Binding var composerFocused: Bool
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore

    var body: some View {
        Group {
            if let id = model.mainConversationId {
                ChatView(composerFocused: $composerFocused, conversationId: id)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "circle.circle").font(.system(size: 44, weight: .light))
                    Text("Your conversation with Orbit").font(.title3.weight(.medium))
                    if model.openingConversation {
                        ProgressView("Connecting…")
                    } else {
                        Text("Connect to your server to continue.").foregroundStyle(.secondary)
                        Button("Try again") { Task { await model.openMainConversation() } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = ""
    @State private var code = ""
    @State private var admin = ""
    @State private var name = DeviceName.current
    @State private var busy = false

    @State private var firstDevice = false

    var body: some View {
        ZStack {
            OrbitBackdrop()
            OrbitScreen {
                VStack(spacing: 14) {
                    ZStack {
                        Circle().stroke(.white.opacity(0.92), lineWidth: 3).frame(width: 34, height: 34)
                        Circle().fill(.white).frame(width: 10, height: 10).offset(x: 21, y: -14)
                    }
                    .frame(width: 84, height: 84)
                    .background(LinearGradient(colors: [Color(red: 0.32, green: 0.36, blue: 0.95), Color(red: 0.55, green: 0.3, blue: 0.85)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing),
                                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .shadow(color: Color(red: 0.45, green: 0.35, blue: 0.95).opacity(0.45), radius: 28, y: 10)
                    Text("Meet Orbit").font(.system(size: OrbitTheme.isMac ? 28 : 34, weight: .bold, design: .rounded))
                    Text("Your day, a little lighter.").font(OrbitTheme.isMac ? .system(size: 14) : .system(size: 17)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, OrbitTheme.isMac ? 40 : 48).padding(.bottom, 4)

                OrbitGroup(header: "Server") {
                    OrbitFieldRow(label: "Orbit URL", prompt: "https://orbit.workers.dev", text: $server)
                    OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                    OrbitFieldRow(label: "Device name", prompt: "My iPhone", text: $name)
                }
                OrbitGroup(header: "Pair this device",
                             footer: firstDevice ? "The admin token is used once to pair and is never stored." : "Open Orbit on a paired device → Settings → Devices → Pair a new device.") {
                    if firstDevice {
                        OrbitFieldRow(label: "Admin token", prompt: "Paste the admin token", text: $admin, secure: true)
                    } else {
                        OrbitFieldRow(label: "Pairing code", prompt: "10-character code", text: $code)
                    }
                }
                VStack(spacing: 12) {
                    Button {
                        busy = true
                        Task { await model.pair(server: server, code: firstDevice ? "" : code, adminToken: firstDevice ? admin : "", name: name); busy = false }
                    } label: {
                        HStack(spacing: 8) {
                            if busy { ProgressView().controlSize(.small).tint(.black) }
                            Text(busy ? "Connecting…" : "Connect")
                        }
                    }
                    .buttonStyle(.orbitPrimary)
                    .disabled(busy || server.isEmpty || (firstDevice ? admin.isEmpty : code.isEmpty))
                    Button(firstDevice ? "I have a pairing code" : "Setting up your first device?") {
                        withAnimation(.easeOut(duration: 0.2)) { firstDevice.toggle() }
                    }
                    .buttonStyle(.plain).font(OrbitTheme.footnote.weight(.medium)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 520)
        }
        .onAppear { server = model.serverURL }
    }
}

// MARK: - Conversations & chat

struct ChatView: View {
    @FocusState.Binding var composerFocused: Bool
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    let conversationId: String
    @State private var selectedModel = "Auto"
    @State private var showingModelPicker = false
    #if os(iOS)
    @State private var dictation = OrbitDictation()
    @State private var dictationPrefix = ""
    @Environment(\.scenePhase) private var dictationPhase
    #endif

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if store.chat(conversationId).isEmpty, !model.sending.contains(conversationId) {
                            OrbitChatWelcome { prompt in
                                model.chatDraft = prompt
                                composerFocused = true
                            }
                        }
                        ForEach(store.chat(conversationId)) { m in MessageBubble(message: m).id(m.id) }
                        if model.sending.contains(conversationId) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let live = model.streaming[conversationId], !live.isEmpty {
                                    MessageBubble(message: Message(id: "streaming", conversationId: conversationId, role: "assistant", content: live, meta: nil, createdAt: 0))
                                } else {
                                    ProgressView().padding(.leading, 12)
                                }
                                if let status = model.turnStatus[conversationId] {
                                    Text(status).font(.caption).foregroundStyle(.secondary).padding(.leading, 12)
                                }
                            }
                            .id("typing")
                        }
                        ForEach(store.pendingApprovals) { approval in
                            ChatApprovalCard(approval: approval).id("approval-" + approval.id)
                        }
                        if model.failedSend[conversationId] != nil {
                            Button("Couldn't send — tap to retry") { Task { await model.retry(in: conversationId) } }.font(.callout).padding(.leading, 12)
                        }
                    }
                    .frame(maxWidth: 760)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 24).padding(.vertical, 20)
                }
                .defaultScrollAnchor(.bottom)
                .keepsBottomOnResize()
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: composerFocused) { _, focused in
                    // Opening the keyboard or growing the composer shouldn't strand the user mid-history.
                    if focused { withAnimation { proxy.scrollTo(store.chat(conversationId).last?.id, anchor: .bottom) } }
                }
                .onChange(of: store.chat(conversationId).count) { _, _ in
                    // A pending approval card sits below the newest message; keep it in view.
                    if let id = store.pendingApprovals.first?.id {
                        withAnimation { proxy.scrollTo("approval-" + id, anchor: .bottom) }
                    } else {
                        withAnimation { proxy.scrollTo(store.chat(conversationId).last?.id, anchor: .bottom) }
                    }
                }
                // Also fires when an approval's details load and the card grows, so it stays fully visible.
                .onChange(of: store.pendingApprovals.map { "\($0.id):\($0.params == nil ? 0 : 1)" }) { _, keys in
                    guard let id = store.pendingApprovals.first?.id, !keys.isEmpty else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        withAnimation { proxy.scrollTo("approval-" + id, anchor: .bottom) }
                    }
                }
                .onChange(of: model.streaming[conversationId]?.count ?? 0) { _, _ in
                    proxy.scrollTo("typing", anchor: .bottom)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                TextField("Ask Orbit anything…", text: $model.chatDraft, axis: .vertical)
                    #if os(macOS)
                    .lineLimit(1...6).font(.system(size: 14)).frame(minHeight: 28, alignment: .topLeading)
                    #else
                    .lineLimit(1...5).font(.body).frame(minHeight: 28, alignment: .topLeading)
                    #endif
                    .textFieldStyle(.plain).foregroundStyle(.white.opacity(0.95))
                    .focused($composerFocused)
                    #if os(iOS)
                    .disabled(dictation.isBusy)
                    #endif
                    .onSubmit(sendDraft)
                    .padding(.horizontal, 6).padding(.top, 4)
                HStack(spacing: 10) {
                    Button {
                        #if os(iOS)
                        composerFocused = false
                        #endif
                        showingModelPicker.toggle()
                    } label: {
                        HStack(spacing: 7) {
                            Image(systemName: selectedModel == "Sol" ? "brain" : "sparkles")
                            Text(selectedModel)
                            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
                        }
                        .font(.system(size: 14, weight: .medium))
                        #if os(iOS)
                        .frame(width: 100, height: 44)
                        #else
                        .frame(width: 100, height: 34)
                        #endif
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .orbitGlass(in: Capsule(), interactive: true)
                    .accessibilityLabel("Choose model: \(selectedModel)")
                    .popover(isPresented: $showingModelPicker, arrowEdge: .bottom) {
                        VStack(spacing: 3) {
                            ForEach(["Auto", "Luna", "Sol"], id: \.self) { option in
                                Button {
                                    selectedModel = option
                                    showingModelPicker = false
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: option == "Auto" ? "sparkles" : option == "Luna" ? "bolt" : "brain")
                                            .font(.system(size: 14)).frame(width: 20).foregroundStyle(.secondary)
                                        Text(option).font(.system(size: 14, weight: .medium))
                                        Spacer()
                                        if selectedModel == option {
                                            Image(systemName: "checkmark").font(.system(size: 12, weight: .semibold))
                                        }
                                    }
                                    .padding(.horizontal, 12)
                                    #if os(iOS)
                                    .frame(height: 44)
                                    #else
                                    .frame(height: 36)
                                    #endif
                                    .contentShape(Capsule())
                                    .background(selectedModel == option ? Color.white.opacity(0.09) : .clear, in: Capsule())
                                }.buttonStyle(.plain)
                            }
                        }
                        .padding(7).frame(width: 188)
                        .fixedSize(horizontal: false, vertical: true)
                        .preferredColorScheme(.dark)
                        #if os(iOS)
                        .presentationCompactAdaptation(.popover)
                        #endif
                    }
                    Spacer(minLength: 0)
                    #if os(iOS)
                    Button {
                        if dictation.isRecording { dictation.finish() }
                        else { startDictation() }
                    } label: {
                        Group {
                            if dictation.isStarting || dictation.isFinishing {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic")
                                    .font(.system(size: 19, weight: .medium))
                            }
                        }.frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(dictation.isRecording ? Color.red : .white.opacity(0.75))
                    .accessibilityLabel(dictation.isRecording ? "Stop dictation" : "Dictate message")
                    .disabled(model.sending.contains(conversationId) || dictation.isStarting || dictation.isFinishing)
                    #endif
                    if model.sending.contains(conversationId) {
                        ProgressView().controlSize(.small).frame(width: 40, height: 40)
                            .accessibilityLabel("Orbit is replying")
                    } else {
                        Button(action: sendDraft) {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.black).frame(width: 40, height: 40)
                                .background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send message")
                        .disabled(model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .opacity(model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.35 : 1)
                        .keyboardShortcut(.return, modifiers: .command)
                    }
                }.foregroundStyle(.white.opacity(0.75))
            }
            #if os(iOS)
            .padding(10)
            #else
            .padding(14)
            #endif
            .background(Color(red: 0.12, green: 0.125, blue: 0.14).opacity(0.65), in: RoundedRectangle(cornerRadius: 26))
            .orbitGlass(in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26).strokeBorder(composerFocused ? Color.purple.opacity(0.35) : .clear))
            .frame(maxWidth: 760)
            .padding(.horizontal, 20).padding(.bottom, 12).padding(.top, 8)
        }
        .task(id: store.pendingApprovals.map(\.id)) { await model.loadApprovalDetails() }
        #if os(iOS)
        .alert("Dictation", isPresented: Binding(get: { dictation.error != nil }, set: { if !$0 { dictation.error = nil } })) {
            if dictation.needsSettings {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Button("OK", role: .cancel) { dictation.error = nil }
        } message: { Text(dictation.error ?? "") }
        .onChange(of: dictation.transcript) { _, text in model.chatDraft = dictatedMessage(text) }
        .onChange(of: dictation.completedText) { _, text in
            guard let text, dictationPhase == .active else { return }
            model.chatDraft = dictatedMessage(text)
            sendDraft()
        }
        .onChange(of: dictationPhase) { _, phase in
            if phase == .background || (phase != .active && (dictation.isRecording || dictation.isFinishing)) { dictation.cancel() }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: DispatchQueue.main)) { _ in dictation.cancel() }
        .onDisappear { dictation.cancel() }
        #endif
    }

    #if os(iOS)
    private func dictatedMessage(_ text: String) -> String {
        String([dictationPrefix, text].filter { !$0.isEmpty }.joined(separator: " ").prefix(4000))
    }
    private func startDictation() {
        guard !model.sending.contains(conversationId), !dictation.isBusy else { return }
        dictationPrefix = model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        composerFocused = false
        Task { await dictation.start() }
    }
    #endif

    private func sendDraft() {
        #if os(iOS)
        guard !dictation.isStarting else { return }
        if dictation.isRecording || dictation.isFinishing {
            dictation.finish(send: true)
            return
        }
        #endif
        let draft = model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty, !model.sending.contains(conversationId) else { return }
        let hasOverride = draft.lowercased().hasPrefix("/luna ") || draft.lowercased().hasPrefix("/sol ")
        let prefix = selectedModel == "Auto" || hasOverride ? "" : "/\(selectedModel.lowercased()) "
        model.chatDraft = ""
        Task { await model.send(prefix + draft, in: conversationId) }
    }
}

private extension View {
    /// Keep the newest message pinned when the visible area shrinks (keyboard, multi-line composer).
    @ViewBuilder func keepsBottomOnResize() -> some View {
        if #available(iOS 18.0, macOS 15.0, *) {
            self.defaultScrollAnchor(.bottom, for: .sizeChanges)
        } else {
            self
        }
    }
}

struct MessageBubble: View {
    let message: Message
    var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            // Rendered as plain text (never Markdown), with links detected — like a text message.
            Text(PlainText.attributed(message.content))
                .textSelection(.enabled)
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isUser ? OrbitPalette.userBubble : OrbitPalette.assistantBubble,
                            in: RoundedRectangle(cornerRadius: 22))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Approvals

struct ChatApprovalCard: View {
    @EnvironmentObject var model: AppModel
    let approval: Approval
    @State private var deciding: Bool?   // nil idle; true approving; false denying

    /// "Changing an existing reminder: Mark reminder … complete" → reason + action.
    private var parts: (reason: String, action: String) {
        let s = approval.summary
        if let r = s.range(of: ": ") { return (String(s[..<r.lowerBound]), String(s[r.upperBound...])) }
        return ("Needs your approval", s)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 12 : 16) {
            HStack(spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold)).foregroundStyle(.black)
                    .frame(width: OrbitTheme.isMac ? 22 : 26, height: OrbitTheme.isMac ? 22 : 26)
                    .background(Color.orange, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text("Approval needed").font(.system(size: OrbitTheme.isMac ? 12 : 13.5, weight: .semibold)).foregroundStyle(.orange)
                    Text(parts.reason.orbitTypographic).font(OrbitTheme.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("Expires \(approval.expiresAt.date, style: .relative)")
                    .font(.system(size: OrbitTheme.isMac ? 10.5 : 12)).foregroundStyle(.tertiary).lineLimit(1)
            }
            Text(parts.action.orbitTypographic)
                .font(.system(size: OrbitTheme.isMac ? 15 : 18, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            if case .object(let params)? = approval.params {
                let rows = Self.rows(params)
                if !rows.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            if index > 0 { Rectangle().fill(OrbitTheme.hairline).frame(height: 0.5) }
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(row.label).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
                                    .frame(width: OrbitTheme.isMac ? 96 : 104, alignment: .leading)
                                Text(row.value).font(OrbitTheme.isMac ? .system(size: 12.5) : .system(size: 15))
                                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(.vertical, OrbitTheme.isMac ? 7 : 10)
                        }
                    }
                    .padding(.horizontal, OrbitTheme.isMac ? 12 : 14)
                    .background(OrbitTheme.raisedHigh.opacity(0.6), in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 14, style: .continuous))
                }
                HStack(spacing: 10) {
                    Button { decide(false) } label: {
                        if deciding == false { ProgressView().controlSize(.small) } else { Text("Deny") }
                    }.buttonStyle(.orbitSecondary)
                    Button { decide(true) } label: {
                        if deciding == true { ProgressView().controlSize(.small).tint(.black) } else { Text("Approve") }
                    }.buttonStyle(.orbitPrimary)
                }
                .disabled(deciding != nil)
            } else {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Loading details…").font(OrbitTheme.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry") { Task { await model.loadApprovalDetails() } }
                        .buttonStyle(OrbitButtonStyle(kind: .secondary, fullWidth: false))
                }
            }
        }
        .padding(OrbitTheme.isMac ? 16 : 18)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 16 : 24, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 16 : 24, style: .continuous)
                .stroke(LinearGradient(colors: [Color.orange.opacity(0.55), Color.orange.opacity(0.12)], startPoint: .top, endPoint: .bottom), lineWidth: 1)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Approval needed: \(parts.action)")
    }

    /// The parameters a person needs to judge the action: internal ids are hidden, edits are listed
    /// field by field ("New due"), and timestamps are shown in local time.
    static func rows(_ params: [String: JSONValue]) -> [(label: String, value: String)] {
        func label(_ k: String) -> String { k.replacingOccurrences(of: "_", with: " ").capitalized }
        func value(_ v: JSONValue) -> String {
            if let s = v.string, s.count >= 20, let d = ISO.parse(s) { return d.formatted(date: .abbreviated, time: .shortened) }
            return v.display
        }
        // What, when, where — then everything else alphabetically.
        let order = ["title", "subject", "to", "start", "end", "due", "all_day", "location", "calendar", "list", "notes", "body", "changes"]
        func rank(_ k: String) -> Int { order.firstIndex(of: k) ?? order.count }
        var out: [(label: String, value: String)] = []
        for key in params.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) where key != "device_id" && !key.hasSuffix("_id") {
            guard let v = params[key] else { continue }
            if key == "changes", case .object(let changes) = v {
                for ck in changes.keys.sorted(by: { (rank($0), $0) < (rank($1), $1) }) { if let cv = changes[ck] { out.append(("New " + label(ck).lowercased(), value(cv))) } }
            } else {
                out.append((key == "title" && params["changes"] != nil ? "Current title" : label(key), value(v)))
            }
        }
        return out
    }

    private func decide(_ approve: Bool) {
        deciding = approve
        Task {
            await model.decide(approval.id, approve: approve)
            deciding = nil
        }
    }
}

// MARK: - Activity

/// Groups items into "Today", "Yesterday", then dated sections, newest first.
func orbitDayGroups<T>(_ items: [T], date: (T) -> Date) -> [(title: String, items: [T])] {
    let cal = Calendar.current
    var order: [Date] = []
    var buckets: [Date: [T]] = [:]
    for item in items {
        let day = cal.startOfDay(for: date(item))
        if buckets[day] == nil { order.append(day) }
        buckets[day, default: []].append(item)
    }
    return order.map { day in
        let title = cal.isDateInToday(day) ? "Today" : cal.isDateInYesterday(day) ? "Yesterday"
            : day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        return (title, buckets[day] ?? [])
    }
}

struct WorkView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onCompose: (String) -> Void
    var onReviewApproval: () -> Void
    @State private var tab = 0
    @State private var expandedError: String?

    private var activeTasks: [OrbitTask] {
        store.recentTasks.filter { ["queued", "leased", "awaiting_approval"].contains($0.status) }
    }
    private var finishedTasks: [OrbitTask] {
        store.recentTasks.filter { !["queued", "leased", "awaiting_approval"].contains($0.status) }
    }
    private var doneToday: Int {
        finishedTasks.filter { $0.status == "succeeded" && Calendar.current.isDateInToday($0.updatedAt.date) }.count
    }
    private var unread: Int { store.sortedNotifications.filter { $0.readAt == nil }.count }

    var body: some View {
        OrbitScreen(spacing: OrbitTheme.isMac ? 18 : 22) {
            HStack(spacing: 10) {
                OrbitStatTile(value: activeTasks.filter { $0.status != "awaiting_approval" }.count, label: "Running")
                OrbitStatTile(value: activeTasks.filter { $0.status == "awaiting_approval" }.count, label: "Needs you", tint: .orange)
                OrbitStatTile(value: doneToday, label: "Done today", tint: .green)
            }
            OrbitSegmented(titles: ["Active", "Done", "Updates", "History"], selection: $tab, badges: [2: unread])
            Group {
                switch tab {
                case 0: activeList
                case 1: finishedList
                case 2: notificationList
                default: historyList
                }
            }
            .padding(.top, 4)
            .transaction { $0.animation = nil } // swap lists instantly; only the segment indicator slides
        }
        .refreshable { await model.tick() }
    }

    // Active

    @ViewBuilder private var activeList: some View {
        let waiting = activeTasks.filter { $0.status == "awaiting_approval" }
        let running = activeTasks.filter { $0.status != "awaiting_approval" }
        if activeTasks.isEmpty {
            OrbitEmptyState(symbol: "bolt", title: "Nothing running", detail: "When Orbit works on something for you, it shows up here.")
            OrbitGroup(header: "Try asking Orbit") {
                suggestion("Check my email", detail: "Find what needs your attention", icon: "envelope.fill", tint: .blue,
                           prompt: "Check my connected email accounts and tell me what needs my attention.")
                OrbitRowDivider()
                suggestion("Daily briefing", detail: "Schedule, deadlines and next steps", icon: "sun.max.fill", tint: .orange,
                           prompt: "Give me a briefing of my schedule, upcoming deadlines, and anything waiting on me.")
            }
        } else {
            if !waiting.isEmpty {
                OrbitGroup(header: "Needs you") { taskRows(waiting) }
            }
            if !running.isEmpty {
                OrbitGroup(header: "In progress") { taskRows(running) }
            }
        }
    }

    @ViewBuilder private var finishedList: some View {
        if finishedTasks.isEmpty {
            OrbitEmptyState(symbol: "checkmark", title: "Nothing finished yet", detail: "Completed tasks will appear here.")
        } else {
            ForEach(orbitDayGroups(Array(finishedTasks.prefix(100)), date: { $0.updatedAt.date }), id: \.title) { group in
                OrbitGroup(header: group.title) { taskRows(group.items) }
            }
        }
    }

    @ViewBuilder private func taskRows(_ tasks: [OrbitTask]) -> some View {
        ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
            if index > 0 { OrbitRowDivider() }
            taskRow(task)
        }
    }

    private func taskRow(_ task: OrbitTask) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                OrbitIconTile(symbol: taskIcon(task.status), tint: taskColor(task.status))
                VStack(alignment: .leading, spacing: 3) {
                    Text(task.summary.orbitTypographic).font(OrbitTheme.rowTitle).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Text(taskLabel(task.status)).foregroundStyle(task.status == "failed" || task.status == "awaiting_approval" ? .orange : .secondary)
                        Text("·").foregroundStyle(.tertiary)
                        Text(orbitTaskTime(task)).foregroundStyle(.secondary)
                    }
                    .font(OrbitTheme.rowSubtitle)
                }
                Spacer(minLength: 8)
                if task.status == "awaiting_approval" {
                    Button("Review", action: onReviewApproval)
                        .buttonStyle(OrbitButtonStyle(kind: .secondary, fullWidth: false))
                        .controlSize(.small)
                }
                if task.status == "queued" || task.status == "awaiting_approval" {
                    Menu {
                        Button("Cancel task", role: .destructive) { Task { await model.perform { try await $0.cancel(taskId: task.id) } } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize()
                    .accessibilityLabel("More for this task")
                }
                if task.status == "failed", task.error != nil {
                    Button {
                        withAnimation(.easeOut(duration: 0.2)) { expandedError = expandedError == task.id ? nil : task.id }
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(expandedError == task.id ? 180 : 0))
                            .frame(width: 32, height: 32).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("What happened")
                }
            }
            if task.status == "failed", let error = task.error, expandedError == task.id {
                Text(error).font(OrbitTheme.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(OrbitTheme.raisedHigh.opacity(0.6), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.top, 10).padding(.leading, OrbitTheme.tileSize + 12)
            }
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical)
        .frame(minHeight: OrbitTheme.rowMinHeight)
    }

    private func suggestion(_ title: String, detail: String, icon: String, tint: Color, prompt: String) -> some View {
        Button { onCompose(prompt) } label: {
            OrbitRow(symbol: icon, tint: tint, title: title, subtitle: detail, accessory: .external)
        }.buttonStyle(OrbitRowButtonStyle())
    }

    // Updates & history

    @ViewBuilder private var notificationList: some View {
        if store.sortedNotifications.isEmpty {
            OrbitEmptyState(symbol: "bell", title: "You’re up to date", detail: "Useful updates from Orbit will appear here.")
        } else {
            ForEach(orbitDayGroups(Array(store.sortedNotifications.prefix(150)), date: { $0.createdAt.date }), id: \.title) { group in
                OrbitGroup(header: group.title) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, notification in
                        if index > 0 { OrbitRowDivider() }
                        notificationRow(notification)
                    }
                }
            }
        }
    }

    private func notificationRow(_ notification: OrbitNotification) -> some View {
        HStack(alignment: .top, spacing: 12) {
            OrbitIconTile(symbol: notificationIcon(notification.category), tint: notificationTint(notification.category))
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(notification.title).font(OrbitTheme.rowTitle)
                    if notification.readAt == nil {
                        Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Unread")
                    }
                    Spacer(minLength: 6)
                    Text(notification.createdAt.date.formatted(date: .omitted, time: .shortened))
                        .font(OrbitTheme.footnote).foregroundStyle(.tertiary)
                }
                Text(notification.body.orbitTypographic).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
                    .lineLimit(6).textSelection(.enabled)
            }
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical)
        .onAppear {
            if notification.readAt == nil { Task { await model.perform { try await $0.markRead(notificationId: notification.id) } } }
        }
    }

    @ViewBuilder private var historyList: some View {
        if store.sortedActivity.isEmpty {
            OrbitEmptyState(symbol: "clock", title: "A fresh start", detail: "Everything Orbit does is logged here.")
        } else {
            ForEach(orbitDayGroups(Array(store.sortedActivity.prefix(200)), date: { $0.createdAt.date }), id: \.title) { group in
                OrbitGroup(header: group.title) {
                    ForEach(Array(group.items.enumerated()), id: \.element.id) { index, activity in
                        if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal + 22) }
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Image(systemName: historyIcon(activity.type))
                                .font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold))
                                .foregroundStyle(historyTint(activity.type)).frame(width: 12)
                            Text(activity.summary.orbitTypographic).font(OrbitTheme.isMac ? .system(size: 12.5) : .system(size: 15))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            Text(activity.createdAt.date.formatted(date: .omitted, time: .shortened))
                                .font(OrbitTheme.footnote).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, OrbitTheme.rowHorizontal)
                        .padding(.vertical, OrbitTheme.isMac ? 8 : 11)
                    }
                }
            }
        }
    }

    /// Running work shows how long ago it moved; finished work (already grouped by day) shows the time.
    private func orbitTaskTime(_ task: OrbitTask) -> String {
        let date = task.updatedAt.date
        if ["queued", "leased", "awaiting_approval"].contains(task.status) {
            return Date().timeIntervalSince(date) < 60 ? "just now" : date.formatted(.relative(presentation: .named))
        }
        return date.formatted(date: .omitted, time: .shortened)
    }

    // Visual vocabulary

    private func taskLabel(_ status: String) -> String {
        switch status {
        case "queued": return "Up next"
        case "leased": return "Working"
        case "awaiting_approval": return "Needs you"
        case "succeeded": return "Completed"
        case "failed": return "Needs attention"
        case "denied": return "Declined"
        case "cancelled": return "Cancelled"
        default: return status.capitalized
        }
    }
    private func taskIcon(_ status: String) -> String {
        switch status {
        case "succeeded": return "checkmark"
        case "failed": return "exclamationmark"
        case "awaiting_approval": return "hand.raised.fill"
        case "leased": return "arrow.triangle.2.circlepath"
        case "cancelled", "denied": return "minus"
        default: return "clock.fill"
        }
    }
    private func taskColor(_ status: String) -> Color {
        switch status {
        case "succeeded": return Color(red: 0.2, green: 0.72, blue: 0.42)
        case "failed": return Color(red: 0.95, green: 0.38, blue: 0.3)
        case "awaiting_approval": return .orange
        case "leased": return Color(red: 0.3, green: 0.5, blue: 0.98)
        default: return Color(white: 0.35)
        }
    }
    private func notificationIcon(_ category: String) -> String {
        switch category {
        case "approval": return "hand.raised.fill"
        case "task_done": return "checkmark"
        case "task_failed": return "exclamationmark"
        case "briefing": return "sun.max.fill"
        case "responsibility", "reminder": return "bookmark.fill"
        default: return "bell.fill"
        }
    }
    private func notificationTint(_ category: String) -> Color {
        switch category {
        case "approval": return .orange
        case "task_done": return Color(red: 0.2, green: 0.72, blue: 0.42)
        case "task_failed": return Color(red: 0.95, green: 0.38, blue: 0.3)
        case "briefing": return Color(red: 0.98, green: 0.62, blue: 0.2)
        case "responsibility", "reminder": return Color(red: 0.55, green: 0.4, blue: 0.95)
        default: return Color(white: 0.35)
        }
    }
    private func historyIcon(_ type: String) -> String {
        if type.contains("failed") || type.contains("denied") { return "xmark" }
        if type.contains("approv") { return "hand.raised.fill" }
        if type.contains("succeeded") { return "checkmark" }
        return "circle.fill"
    }
    private func historyTint(_ type: String) -> Color {
        if type.contains("failed") || type.contains("denied") { return Color(red: 0.95, green: 0.38, blue: 0.3) }
        if type.contains("approv") { return .orange }
        if type.contains("succeeded") { return .green }
        return Color(white: 0.4)
    }
}

// MARK: - Memory & responsibilities

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onTrack: () -> Void
    @State private var tab = 0
    @State private var query = ""
    @State private var newText = ""
    @State private var newKind = 0      // 0 preference, 1 fact
    @State private var showAdd = false
    @State private var editing: Memory?
    @State private var editText = ""
    @FocusState private var searchFocused: Bool

    private func memories(_ kind: String) -> [Memory] {
        store.liveMemories.filter { $0.kind == kind && (query.isEmpty || $0.content.localizedCaseInsensitiveContains(query)) }
    }
    private var filteredMemories: [Memory] { memories(tab == 0 ? "preference" : "fact") }
    private var tracked: [Responsibility] {
        store.openResponsibilities.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        OrbitScreen(spacing: OrbitTheme.isMac ? 16 : 20) {
            OrbitSegmented(titles: ["Preferences", "About you", "Tracking"], selection: $tab)
            searchField
            Group {
                if tab == 2 { trackingList } else { memoryList }
            }
            .padding(.top, 4)
            .transaction { $0.animation = nil }
            Color.clear.frame(height: 60) // room above the floating button
        }
        .overlay(alignment: .bottom) {
            // Aligned to the content column, not the window corner, on wide windows.
            HStack { Spacer(); addButton }
                .frame(maxWidth: OrbitTheme.pageWidth)
                .padding(.horizontal, OrbitTheme.pagePadding)
        }
        .sheet(isPresented: $showAdd) {
            MemoryEditor(title: "New memory", text: $newText, kind: $newKind, showsKind: true) {
                let content = newText, kind = newKind == 0 ? "preference" : "fact"
                newText = ""; showAdd = false
                Task { await model.perform { try await $0.addMemory(kind: kind, content: content) } }
            } cancel: { showAdd = false }
        }
        .sheet(item: $editing) { memory in
            MemoryEditor(title: "Edit memory", text: $editText, kind: .constant(0), showsKind: false) {
                let content = editText
                editing = nil
                Task { await model.perform { try await $0.updateMemory(id: memory.id, content: content) } }
            } cancel: { editing = nil }
        }
        .refreshable { await model.tick() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: OrbitTheme.isMac ? 12 : 15, weight: .medium)).foregroundStyle(.secondary)
            TextField(tab == 2 ? "Search tracked items" : "Search memory", text: $query)
                .textFieldStyle(.plain).font(OrbitTheme.body).focused($searchFocused)
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary) }
                    .buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .frame(height: OrbitTheme.isMac ? 32 : 42)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 13, style: .continuous)
            .stroke(searchFocused ? Color.white.opacity(0.22) : OrbitTheme.hairline, lineWidth: searchFocused ? 1 : 0.5))
    }

    private var addButton: some View {
        Button {
            if tab == 2 { onTrack() } else { newKind = tab == 0 ? 0 : 1; showAdd = true }
        } label: {
            Label(tab == 2 ? "Track something" : "Add memory", systemImage: "plus")
                .font(.system(size: OrbitTheme.isMac ? 13 : 15, weight: .semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, OrbitTheme.isMac ? 14 : 18)
                .frame(height: OrbitTheme.isMac ? 34 : 48)
                .background(.white, in: Capsule())
                .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.bottom, OrbitTheme.isMac ? 18 : 12)
    }

    @ViewBuilder private var memoryList: some View {
        if filteredMemories.isEmpty {
            OrbitEmptyState(symbol: query.isEmpty ? (tab == 0 ? "slider.horizontal.3" : "person") : "magnifyingglass",
                            title: query.isEmpty ? (tab == 0 ? "No preferences yet" : "Nothing saved about you") : "No matches",
                            detail: query.isEmpty ? (tab == 0 ? "Tell Orbit how you like things done, and it will remember." : "Facts you share, like your school or routines, live here.") : "Try a different search.")
        } else {
            OrbitGroup(header: "\(filteredMemories.count) saved") {
                ForEach(Array(filteredMemories.enumerated()), id: \.element.id) { index, memory in
                    if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal) }
                    memoryRow(memory)
                }
            }
        }
    }

    private func memoryRow(_ memory: Memory) -> some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.content).font(OrbitTheme.body).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                Text("Updated \(memory.updatedAt.date.formatted(date: .abbreviated, time: .omitted))")
                    .font(OrbitTheme.footnote).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Menu {
                memoryActions(memory)
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .accessibilityLabel("Memory options")
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical)
        .contentShape(Rectangle())
        .contextMenu { memoryActions(memory) }
    }

    @ViewBuilder private func memoryActions(_ memory: Memory) -> some View {
        Button { editing = memory; editText = memory.content } label: { Label("Edit", systemImage: "pencil") }
        Button(role: .destructive) { Task { await model.perform { try await $0.deleteMemory(id: memory.id) } } } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder private var trackingList: some View {
        if tracked.isEmpty {
            OrbitEmptyState(symbol: query.isEmpty ? "bookmark" : "magnifyingglass", title: query.isEmpty ? "Keep it on your radar" : "No matches",
                            detail: query.isEmpty ? "Follow-ups, deadlines, deliveries and things you’re waiting on." : "Try a different search.")
        } else {
            OrbitGroup(header: "\(tracked.count) tracked") {
                ForEach(Array(tracked.enumerated()), id: \.element.id) { index, responsibility in
                    if index > 0 { OrbitRowDivider() }
                    trackingRow(responsibility)
                }
            }
        }
    }

    private func trackingRow(_ responsibility: Responsibility) -> some View {
        let overdue = (responsibility.dueAt?.date).map { $0 < Date() } ?? false
        return HStack(alignment: .center, spacing: 12) {
            OrbitIconTile(symbol: trackingIcon(responsibility.kind), tint: overdue ? Color(red: 0.95, green: 0.38, blue: 0.3) : Color(red: 0.55, green: 0.4, blue: 0.95))
            VStack(alignment: .leading, spacing: 4) {
                Text(responsibility.title).font(OrbitTheme.rowTitle).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let due = responsibility.dueAt {
                        OrbitBadge(text: (overdue ? "Overdue · " : "Due ") + due.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()),
                                   tint: overdue ? .orange : .secondary)
                    }
                    if let next = responsibility.nextCheckAt {
                        Text("Checks \(next.date, style: .relative)").font(OrbitTheme.footnote).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            Spacer(minLength: 8)
            Menu { trackingActions(responsibility) } label: {
                Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).fixedSize()
            .accessibilityLabel("Tracking options")
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical)
        .contentShape(Rectangle())
        .contextMenu { trackingActions(responsibility) }
    }

    @ViewBuilder private func trackingActions(_ responsibility: Responsibility) -> some View {
        Button { Task { await model.perform { try await $0.setResponsibilityStatus(id: responsibility.id, status: "done") } } } label: { Label("Mark done", systemImage: "checkmark") }
        Button(role: .destructive) { Task { await model.perform { try await $0.setResponsibilityStatus(id: responsibility.id, status: "cancelled") } } } label: { Label("Stop tracking", systemImage: "xmark") }
    }

    private func trackingIcon(_ kind: String) -> String {
        switch kind {
        case "delivery": return "shippingbox.fill"
        case "return", "refund": return "arrow.uturn.backward"
        case "renewal", "subscription": return "arrow.clockwise"
        case "deadline": return "calendar"
        case "reply", "follow_up": return "arrowshape.turn.up.left.fill"
        default: return "bookmark.fill"
        }
    }
}

/// Sheet for adding or editing a memory.
struct MemoryEditor: View {
    let title: String
    @Binding var text: String
    @Binding var kind: Int
    var showsKind: Bool
    var save: () -> Void
    var cancel: () -> Void
    @FocusState private var focused: Bool

    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 16 : 20) {
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.plain).foregroundStyle(.secondary)
                Spacer()
                Text(title).font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: .semibold))
                Spacer()
                Button("Save", action: save).buttonStyle(.plain).fontWeight(.semibold)
                    .foregroundStyle(empty ? Color.secondary : Color.white).disabled(empty)
                    .keyboardShortcut(.defaultAction)
            }
            .font(OrbitTheme.body)
            if showsKind {
                OrbitSegmented(titles: ["Preference", "About you"], selection: $kind)
            }
            TextField(kind == 0 || !showsKind ? "e.g. Keep replies short and casual" : "e.g. I study CS at CMU", text: $text, axis: .vertical)
                .lineLimit(4...10).textFieldStyle(.plain).font(OrbitTheme.body).focused($focused)
                .padding(14)
                .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
            Text("Orbit uses memories to personalize replies. You can edit or delete them any time.")
                .font(OrbitTheme.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(OrbitTheme.isMac ? 20 : 22)
        .frame(minWidth: 320, idealWidth: 440, minHeight: OrbitTheme.isMac ? 280 : nil)
        .background(Color(white: 0.06).ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear { focused = true }
    }
}
