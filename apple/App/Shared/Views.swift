import OrbitKit
import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
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
    case chat = "Orbit", scheduled = "Scheduled", memory = "Memory", settings = "Settings"
    var id: Self { self }
    var icon: String {
        switch self {
        case .chat: return "bubble.left"
        case .scheduled: return "calendar.badge.clock"
        case .memory: return "brain.head.profile"
        case .settings: return "gearshape"
        }
    }
    var selectedIcon: String {
        switch self {
        case .chat: return "bubble.left.fill"
        case .scheduled: return "calendar.badge.clock"
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
    @State private var hoveredDestination: OrbitSection?
    @FocusState private var composerFocused: Bool
    @State private var restoreComposerFocus = false
    @State private var showActivity = false
    @State private var customizingPat = false
    @GestureState private var backSwipe: CGFloat = 0
    @GestureState private var swipe: CGFloat = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            #if os(iOS)
            let headerHeight: CGFloat = 110
            #else
            let headerHeight: CGFloat = 134
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
                                // The page follows the finger during a back swipe.
                                .offset(x: swipeGoesBack ? backSwipe * 0.85 : 0)
                                .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.86), value: backSwipe)
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
        // Presented from the root so header re-renders (glass morphing) never dismiss it.
        .sheet(isPresented: $showActivity) {
            ActivitySheet { model.chatJumpRequest += 1 }
                .environmentObject(model).environmentObject(store)
        }
        .sheet(isPresented: $customizingPat) {
            PatCustomizeSheet(initialName: PatHeader.name(store), initialColor: PatHeader.color(store)) { customizingPat = false }
                .environmentObject(model).environmentObject(store)
        }
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
            Group {
                if section == .chat {
                    PatHeader { customizingPat = true }
                } else {
                    Text(section == .settings ? settingsNavigation.title : section.rawValue)
                        .lineLimit(1).minimumScaleFactor(0.7)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                }
            }
                .frame(maxWidth: .infinity).frame(minHeight: 46)
                .padding(.horizontal, 58)
                .overlay(alignment: .leading) {
                    if section == .settings, !settingsNavigation.path.isEmpty {
                        OrbitCircleButton(symbol: "chevron.left", label: "Back") { settingsNavigation.back() }
                    } else {
                        OrbitMenuButton { setSidebar(true) }
                    }
                }
                .overlay(alignment: .trailing) {
                    if section == .chat { activityButton }
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
        case .scheduled: ScheduledView(onCompose: compose)
        case .memory: MemoryView(onTrack: { compose("Help me keep track of ") }, onAboutYou: {
            settingsNavigation.path = [.aboutYou]
            section = .settings
        })
        case .settings: SettingsView(navigation: settingsNavigation, showsHeader: false)
        }
    }

    private var drawer: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Orbit")
                    .font(.system(size: OrbitTheme.isMac ? 24 : 30, weight: .semibold, design: .rounded))
                    .tracking(-0.7)
                Spacer()
                Button { setSidebar(false) } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .background(.white.opacity(0.045), in: Circle())
                        .contentShape(Circle())
                }
                .buttonStyle(.plain).accessibilityLabel("Close sidebar")
            }
            .padding(.horizontal, 12)
            .padding(.bottom, OrbitTheme.isMac ? 28 : 32)
            VStack(spacing: 6) {
                ForEach(OrbitSection.allCases.filter { $0 != .settings }) { destination in
                    drawerRow(destination)
                }
            }
            Spacer(minLength: 24)
            drawerRow(.settings)
            drawerStatus.padding(.horizontal, 14).padding(.top, 18).padding(.bottom, 4)
        }
        .padding(.horizontal, OrbitTheme.isMac ? 14 : 16)
        .padding(.vertical, OrbitTheme.isMac ? 18 : 22)
        #if os(macOS)
        .padding(.top, 34)
        #endif
    }

    private var drawerStatus: some View {
        let failing = store.lastSyncError != nil
        let connected = store.lastSyncAt != nil
        return HStack(spacing: 7) {
            Circle().fill(failing ? Color.orange.opacity(0.8) : connected ? Color.green.opacity(0.7) : Color.secondary)
                .frame(width: 5, height: 5)
            Text(failing ? "Sync needs attention" : connected ? "Up to date" : "Connecting…")
        }
        .font(.system(size: OrbitTheme.isMac ? 11 : 12))
        .foregroundStyle(.tertiary)
    }

    private func drawerBadge(_ destination: OrbitSection) -> (Int, Color)? {
        switch destination {
        case .chat:
            let n = store.pendingApprovals.count
            return n > 0 ? (n, .orange) : nil
        case .settings:
            let n = store.pendingProfileSuggestions.count
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
                Text(destination == .chat ? "Chat" : destination.rawValue)
                    .font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? .primary : Color.white.opacity(0.78))
                Spacer()
                if let (count, tint) = drawerBadge(destination) {
                    Text("\(count)").font(.system(size: OrbitTheme.isMac ? 10.5 : 12, weight: .bold)).monospacedDigit()
                        .foregroundStyle(tint == .orange ? Color.black : Color.white)
                        .padding(.horizontal, 7).frame(minWidth: 20, minHeight: 20)
                        .background(tint == .orange ? Color.orange : Color.white.opacity(0.14), in: Capsule())
                        .accessibilityLabel(destination == .chat ? "\(count) approvals waiting" : "\(count) suggestions to review")
                }
            }
            .padding(.horizontal, 12)
            .frame(minHeight: OrbitTheme.isMac ? 40 : 50)
            .background(selected ? Color.white.opacity(0.085) : hoveredDestination == destination ? Color.white.opacity(0.035) : .clear,
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Color.white.opacity(0.055) : .clear, lineWidth: 0.5))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .onHover { hoveredDestination = $0 ? destination : nil }
    }

    /// Task status and history live one tap away from the chat instead of in a separate destination.
    private var activityButton: some View {
        let running = store.recentTasks.filter { $0.status == "queued" || $0.status == "leased" }.count
        return Button { showActivity = true } label: {
            Image(systemName: running > 0 ? "bolt.fill" : "bolt")
                .font(.system(size: 17, weight: .medium))
                .symbolEffect(.pulse, options: .repeating, isActive: running > 0)
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .orbitGlass(in: Circle(), interactive: true)
        .overlay(alignment: .topTrailing) {
            if running > 0 {
                Text("\(running)").font(.system(size: 11, weight: .bold)).monospacedDigit()
                    .foregroundStyle(.black).padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
                    .background(.white, in: Capsule())
                    .offset(x: 3, y: -3)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityLabel(running > 0 ? "Activity, \(running) running" : "Activity")
        .accessibilityIdentifier("orbit.activity.open")
        .help("Activity")
    }

    /// Inside a Settings sub-page, the left-edge swipe means "back", like a navigation stack.
    private var swipeGoesBack: Bool { section == .settings && !settingsNavigation.path.isEmpty }

    private var openGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .updating($swipe) { value, state, _ in
                guard !swipeGoesBack, value.translation.width > abs(value.translation.height) else { return }
                state = max(value.translation.width, 0)
            }
            .updating($backSwipe) { value, state, _ in
                guard swipeGoesBack, value.translation.width > abs(value.translation.height) else { return }
                state = max(value.translation.width, 0)
            }
            .onEnded { value in
                guard value.translation.width > 65 && value.translation.width > abs(value.translation.height) else { return }
                if swipeGoesBack { settingsNavigation.back() } else { setSidebar(true) }
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
    @State private var showingFilePicker = false
    @State private var showingPhotos = false
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var dropTargeted = false
    private var canSend: Bool { (!model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !model.pendingAttachments.isEmpty) && !model.preparingAttachments }
    @State private var selectedModel = "Auto"
    @State private var showingModelPicker = false
    /// Follow the newest content until the reader deliberately scrolls up; resume at the bottom.
    @State private var following = true
    @State private var newBelow = false
    @State private var scrollRequest = 0
    @State private var scroll = ChatScroll()
    #if os(iOS)
    @State private var dictation = OrbitDictation()
    @State private var dictationPrefix = ""
    @Environment(\.scenePhase) private var dictationPhase
    #endif

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    // A plain stack: a lazy one misestimates its height when the chat reappears and
                    // can leave the bottom-anchored view blank. History is bounded, so this stays cheap.
                    VStack(alignment: .leading, spacing: 20) {
                        if store.chat(conversationId).isEmpty, !model.sending.contains(conversationId) {
                            OrbitChatWelcome { prompt in
                                model.chatDraft = prompt
                                composerFocused = true
                            }
                        }
                        ForEach(store.chat(conversationId)) { m in MessageBubble(message: m).id(m.id) }
                        // The live reply stays visible while a follow-up is being typed, so the
                        // conversation doesn't shrink and jump under the reader.
                        if model.sending.contains(conversationId) {
                            VStack(alignment: .leading, spacing: 4) {
                                if let live = model.streaming[conversationId], !live.isEmpty {
                                    MessageBubble(message: Message(id: "streaming", conversationId: conversationId, role: "assistant", content: live, meta: nil, createdAt: 0))
                                } else {
                                    OrbitThinking(status: model.turnStatus[conversationId] ?? "Thinking")
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
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(ChatScroll.space)) } action: { frame in
                        trackScroll(frame, proxy: proxy)
                    }
                    Color.clear.frame(height: 1).id(ChatScroll.bottom)
                }
                .coordinateSpace(name: ChatScroll.space)
                .defaultScrollAnchor(.bottom)
                .keepsBottomOnResize()
                .scrollDismissesKeyboard(.interactively)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    scroll.viewport = height
                    // Keyboard, window or composer size changed: stay on the latest message if following.
                    if following, scroll.lastHeight != nil, scroll.distance(scroll.contentMaxY) > ChatScroll.threshold { pinToBottom(proxy) }
                }
                .overlay(alignment: .bottom) {
                    if newBelow {
                        newMessagesPill { jumpToLatest(proxy) }
                            .padding(.bottom, 10)
                            .transition(.move(edge: .bottom).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .bottom)))
                    }
                }
                .animation(.spring(response: 0.32, dampingFraction: 0.86), value: newBelow)
                .onChange(of: composerFocused) { _, focused in
                    // Starting to type means "take me to the conversation".
                    if focused { jumpToLatest(proxy) }
                }
                .onChange(of: model.chatDraft.isEmpty) { wasEmpty, isEmpty in
                    if wasEmpty, !isEmpty, !following || scroll.lastDistance > ChatScroll.threshold { jumpToLatest(proxy) }
                }
                .onChange(of: scrollRequest) { _, _ in jumpToLatest(proxy) }
                .onChange(of: model.chatJumpRequest) { _, _ in jumpToLatest(proxy) }
                // Content arriving below while the reader is scrolled up: offer a way down instead of yanking them.
                .onChange(of: store.chat(conversationId).count) { old, new in if new > old { noteNewContent() } }
                .onChange(of: model.streaming[conversationId]?.isEmpty ?? true) { _, empty in if !empty { noteNewContent() } }
                .onChange(of: store.pendingApprovals.map(\.id)) { old, new in if !Set(new).isSubset(of: Set(old)) { noteNewContent() } }
            }
            VStack(alignment: .leading, spacing: 8) {
                if !model.pendingAttachments.isEmpty { AttachmentDraftStrip() }
                if model.preparingAttachments { Label("Adding attachments…", systemImage: "paperclip").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 6) }
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
                    Menu {
                        Button { showingPhotos = true } label: { Label("Photos", systemImage: "photo") }
                        Button { showingFilePicker = true } label: { Label("Choose files", systemImage: "doc") }
                    } label: {
                        Image(systemName: "plus").font(.system(size: 19, weight: .medium)).frame(width: 34, height: 40)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("Add photos or files")
                    .disabled(model.preparingAttachments || model.pendingAttachments.count >= 6)
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
                    .disabled(dictation.isStarting || dictation.isFinishing)
                    #endif
                    if model.sending.contains(conversationId), model.chatDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, model.pendingAttachments.isEmpty {
                        OrbitThinkingDots().frame(width: 40, height: 40)
                            .accessibilityLabel("Orbit is replying")
                    } else {
                        Button(action: sendDraft) {
                            Image(systemName: "arrow.up").font(.system(size: 17, weight: .semibold))
                                .foregroundStyle(.black).frame(width: 40, height: 40)
                                .background(.white, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Send message")
                        .disabled(!canSend)
                        .opacity(canSend ? 1 : 0.35)
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
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 24).strokeBorder(.blue.opacity(0.8), style: StrokeStyle(lineWidth: 2, dash: [7]))
                    .padding(12).allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL.identifier, UTType.image.identifier], isTargeted: $dropTargeted) { model.importProviders($0) }
        #if os(macOS)
        .onPasteCommand(of: [.image, .fileURL]) { _ = model.importProviders($0) }
        #endif
        .fileImporter(isPresented: $showingFilePicker, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls): model.importAttachments(urls)
            case .failure(let error): model.banner = error.localizedDescription
            }
        }
        .photosPicker(isPresented: $showingPhotos, selection: $photoItems, maxSelectionCount: max(1, 6 - model.pendingAttachments.count), matching: .images)
        .onChange(of: photoItems) { _, items in
            guard !items.isEmpty else { return }
            Task {
                model.preparingAttachments = true
                defer { model.preparingAttachments = false; photoItems = [] }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw AttachmentIssue.invalidPhoto }
                        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                        let draft = try await Task.detached { try AttachmentDraft.prepare(name: "Photo.\(ext)", data: data) }.value
                        model.addAttachment(draft)
                    } catch { model.banner = error.localizedDescription }
                }
            }
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
        guard !dictation.isBusy else { return }
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
        guard canSend else { return }
        let files = model.pendingAttachments
        model.pendingAttachments = []
        let hasOverride = draft.lowercased().hasPrefix("/luna ") || draft.lowercased().hasPrefix("/sol ")
        let prefix = selectedModel == "Auto" || hasOverride ? "" : "/\(selectedModel.lowercased()) "
        model.chatDraft = ""
        scrollRequest += 1
        Task { await model.send(prefix + draft, in: conversationId, attachments: files) }
    }

    // MARK: Scrolling

    private func trackScroll(_ frame: CGRect, proxy: ScrollViewProxy) {
        let distance = scroll.distance(frame.maxY)
        // Content only moves down on screen when the reader scrolls up: growth happens below,
        // and our own scrolling moves it up. Shrinking at the bottom clamps to distance ≈ 0.
        if let last = scroll.lastMinY, frame.minY > last + 0.5, distance > ChatScroll.threshold, following {
            following = false
        }
        if distance <= ChatScroll.threshold {
            if !following { following = true }
            if newBelow { newBelow = false }
        } else if following, let height = scroll.lastHeight, frame.height != height {
            pinToBottom(proxy) // streaming text, a new message or an approval card grew the content
        }
        scroll.lastMinY = frame.minY
        scroll.lastHeight = frame.height
        scroll.contentMaxY = frame.maxY
        scroll.lastDistance = distance
    }

    private func pinToBottom(_ proxy: ScrollViewProxy) {
        guard !scroll.pinPending else { return }
        scroll.pinPending = true
        DispatchQueue.main.async {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { proxy.scrollTo(ChatScroll.bottom, anchor: .bottom) }
            scroll.pinPending = false
        }
    }

    private func jumpToLatest(_ proxy: ScrollViewProxy) {
        following = true
        newBelow = false
        withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) { proxy.scrollTo(ChatScroll.bottom, anchor: .bottom) }
    }

    private func noteNewContent() {
        if !following, scroll.lastDistance > ChatScroll.threshold, !newBelow { newBelow = true }
    }

    private func newMessagesPill(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text("New messages")
                Image(systemName: "arrow.down").font(.system(size: OrbitTheme.isMac ? 11 : 12, weight: .bold))
            }
            .font(.system(size: OrbitTheme.isMac ? 12.5 : 14, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .padding(.horizontal, OrbitTheme.isMac ? 14 : 16)
            .frame(height: OrbitTheme.isMac ? 30 : 38)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .background(Color(red: 0.12, green: 0.125, blue: 0.14).opacity(0.65), in: Capsule())
        .orbitGlass(in: Capsule(), interactive: true)
        .accessibilityLabel("New messages. Jump to latest")
        .accessibilityIdentifier("orbit.chat.newMessages")
    }
}

/// Scroll bookkeeping that changes every frame; kept out of view state so it doesn't re-render.
final class ChatScroll {
    static let space = "orbit.chat.scroll"
    static let bottom = "orbit.chat.bottom"
    static let threshold: CGFloat = 24
    var viewport: CGFloat = 0
    var contentMaxY: CGFloat = 0
    var lastMinY: CGFloat?
    var lastHeight: CGFloat?
    var lastDistance: CGFloat = 0
    var pinPending = false
    /// How far the end of the content sits below the visible area (the 1-pt end marker included).
    func distance(_ maxY: CGFloat) -> CGFloat { maxY + 1 - viewport }
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

struct OrbitThinkingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3) { index in
                Circle().fill(Color.white.opacity(animate ? 0.75 : 0.25)).frame(width: 5, height: 5)
                    .offset(y: animate && !reduceMotion ? -2 : 0)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.65).repeatForever(autoreverses: true).delay(Double(index) * 0.16), value: animate)
            }
        }
        .onAppear { animate = true }.accessibilityHidden(true)
    }
}

struct OrbitThinking: View {
    var status: String
    var body: some View {
        HStack(spacing: 10) {
            OrbitThinkingDots()
            Text(status).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 15).padding(.vertical, 11)
        .background(.white.opacity(0.045), in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.05), lineWidth: 0.5))
        .accessibilityElement(children: .ignore).accessibilityLabel(status)
    }
}

struct MessageBubble: View {
    let message: Message
    @State private var showingDetails = false
    var isUser: Bool { message.role == "user" }
    private var details: AnswerDetails? { AnswerDetails(message: message) }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: isUser ? .trailing : .leading, spacing: 5) {
            if let title = message.meta?["schedule"]?["title"]?.string {
                Label("Scheduled · \(title)", systemImage: "calendar.badge.clock")
                    .font(.system(size: OrbitTheme.isMac ? 11 : 12, weight: .medium))
                    .foregroundStyle(ScheduledView.tint.opacity(0.9))
                    .padding(.leading, 12)
            }
            ForEach(message.attachments) { attachment in AttachmentCard(attachment: attachment) }
            // Rendered as plain text (never Markdown), with links detected — like a text message.
            if !message.content.isEmpty {
            Text(PlainText.attributed(message.content))
                #if os(macOS)
                .textSelection(.enabled)
                #endif
                .font(.body)
                .lineSpacing(5)
                .foregroundStyle(.white)
                .tint(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(isUser ? OrbitPalette.userBubble : OrbitPalette.assistantBubble,
                            in: RoundedRectangle(cornerRadius: 22))
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 22))
                #endif
                .overlay(alignment: .topTrailing) {
                    if isUser, let emoji = message.meta?["reaction"]?["emoji"]?.string {
                        Text(emoji)
                            .font(.system(size: OrbitTheme.isMac ? 15 : 18))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(OrbitPalette.assistantBubble, in: Capsule())
                            .overlay(Capsule().stroke(Color.black, lineWidth: 2))
                            .offset(x: 6, y: -14)
                            .accessibilityLabel("Orbit reacted \(emoji)")
                    }
                }
                .padding(.top, isUser && message.meta?["reaction"]?["emoji"]?.string != nil ? 10 : 0)
                // Hold (or right-click on Mac) for actions; answer details live here, out of the way.
                .contextMenu {
                    Button { copy() } label: { Label("Copy", systemImage: "doc.on.doc") }
                    if details != nil {
                        Button {
                            // Let the menu finish closing before the card appears.
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { showingDetails = true }
                        } label: { Label("Answer details", systemImage: "info.circle") }
                    }
                }
                .popover(isPresented: $showingDetails, arrowEdge: .bottom) {
                    if let details {
                        AnswerDetailsCard(details: details)
                            .preferredColorScheme(.dark)
                            #if os(iOS)
                            .presentationCompactAdaptation(.popover)
                            #endif
                    }
                }
            }
            }
            if !isUser { Spacer(minLength: 40) }
        }
    }

    private func copy() {
        #if os(iOS)
        UIPasteboard.general.string = message.content
        #else
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.content, forType: .string)
        #endif
    }
}

struct AnswerDetailsCard: View {
    let details: AnswerDetails

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Answer details").font(.system(size: OrbitTheme.isMac ? 13 : 15, weight: .semibold))
            row("AI model calls") {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(details.calls.map { $0 == 0 ? "None" : "\($0)" } ?? "Unavailable")
                        .foregroundStyle(details.calls == nil ? Color.secondary : Color.primary)
                        .monospacedDigit()
                    if !details.breakdown.isEmpty {
                        Text(details.breakdownText).font(OrbitTheme.footnote).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            Divider().opacity(0.4)
            row("Models") {
                VStack(alignment: .trailing, spacing: 2) {
                    if details.models.isEmpty {
                        Text(details.postedByDevice ? "None" : "Unavailable").foregroundStyle(.secondary)
                    }
                    ForEach(details.models, id: \.model) { use in
                        HStack(spacing: 4) {
                            Text(AppModel.modelLabel(use.model))
                            if use.calls > 1 { Text("×\(use.calls)").foregroundStyle(.secondary).monospacedDigit() }
                        }
                        Text(use.model).font(OrbitTheme.footnote).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                }
            }
            Divider().opacity(0.4)
            row("Finished") {
                Text(details.finishedAt.formatted(date: Calendar.current.isDateInToday(details.finishedAt) ? .omitted : .abbreviated,
                                                  time: .shortened))
            }
            if details.postedByDevice {
                note("Posted by your device when the task finished, without an AI model.")
            } else if details.calls == nil {
                note("Call counts weren’t recorded for replies before this feature.")
            }
        }
        .font(.system(size: OrbitTheme.isMac ? 12.5 : 14))
        .padding(OrbitTheme.isMac ? 14 : 16)
        .frame(width: OrbitTheme.isMac ? 270 : 290, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row<V: View>(_ label: String, @ViewBuilder value: () -> V) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            value()
        }
        .accessibilityElement(children: .combine)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(OrbitTheme.footnote).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
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

/// Compact task status and history, opened from the chat header.
struct ActivitySheet: View {
    var onReviewApproval: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Activity").font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: .semibold))
                .frame(maxWidth: .infinity)
                .overlay(alignment: .trailing) {
                    Button("Done") { dismiss() }.buttonStyle(.plain).fontWeight(.semibold)
                        .font(OrbitTheme.body)
                        .keyboardShortcut(.cancelAction)
                }
                .padding(.horizontal, OrbitTheme.isMac ? 20 : 22)
                .padding(.top, OrbitTheme.isMac ? 16 : 20)
                .padding(.bottom, OrbitTheme.isMac ? 6 : 8)
            WorkView(onReviewApproval: {
                dismiss()
                onReviewApproval()
            })
        }
        .background(Color(white: 0.06).ignoresSafeArea())
        #if os(macOS)
        .frame(minWidth: 480, idealWidth: 540, minHeight: 520, idealHeight: 640)
        #endif
        .presentationDetents([.large]) // opens fully expanded
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

struct WorkView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onReviewApproval: () -> Void
    @State private var tab = 0
    @State private var expandedError: String?

    private var activeTasks: [OrbitTask] {
        store.recentTasks.filter { ["queued", "leased", "awaiting_approval"].contains($0.status) }
    }
    private var finishedTasks: [OrbitTask] {
        store.recentTasks.filter { !["queued", "leased", "awaiting_approval"].contains($0.status) }
    }
    private var unread: Int { store.sortedNotifications.filter { $0.readAt == nil }.count }

    var body: some View {
        OrbitScreen(spacing: OrbitTheme.isMac ? 18 : 22) {
            OrbitSegmented(titles: ["Active", "Done", "Updates", "History"], selection: $tab,
                           badges: [0: activeTasks.count, 2: unread])
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
    var onAboutYou: () -> Void
    @State private var tab = 0          // 0 preferences, 1 tracking
    @State private var query = ""
    @State private var newText = ""
    @State private var showAdd = false
    @State private var editingTracked: Responsibility?
    @State private var trackedTitle = ""
    @State private var trackedNotes = ""
    @State private var editing: Memory?
    @State private var editText = ""
    @FocusState private var searchFocused: Bool

    private func memories(_ kind: String) -> [Memory] {
        store.liveMemories.filter { $0.kind == kind && (query.isEmpty || $0.content.localizedCaseInsensitiveContains(query)) }
    }
    private var filteredMemories: [Memory] { memories("preference") }
    private var tracked: [Responsibility] {
        store.openResponsibilities.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        OrbitScreen(spacing: OrbitTheme.isMac ? 16 : 20) {
            OrbitSegmented(titles: ["Preferences", "Tracking"], selection: $tab)
            searchField
            Group {
                if tab == 1 { trackingList } else { memoryList }
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
            MemoryEditor(title: "New preference", text: $newText) {
                let content = newText
                newText = ""; showAdd = false
                Task { await model.perform { try await $0.addMemory(kind: "preference", content: content) } }
            } cancel: { showAdd = false }
        }
        .sheet(item: $editing) { memory in
            MemoryEditor(title: "Edit preference", text: $editText) {
                let content = editText
                editing = nil
                Task { await model.perform { try await $0.updateMemory(id: memory.id, content: content) } }
            } cancel: { editing = nil }
        }
        .sheet(item: $editingTracked) { item in
            VStack(spacing: 20) {
                HStack {
                    Button("Cancel") { editingTracked = nil }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Text("Edit tracked item").font(.headline)
                    Spacer()
                    Button("Save") {
                        let title = trackedTitle, notes = trackedNotes
                        editingTracked = nil
                        Task { await model.perform { try await $0.updateTrackedItem(id: item.id, title: title, notes: notes) } }
                    }.buttonStyle(.plain).disabled(trackedTitle.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                TextField("Title", text: $trackedTitle).textFieldStyle(.roundedBorder)
                TextField("Notes", text: $trackedNotes, axis: .vertical).lineLimit(4...10).textFieldStyle(.roundedBorder)
                Spacer(minLength: 0)
            }
            .padding(24).frame(minWidth: OrbitTheme.isMac ? 400 : nil, minHeight: OrbitTheme.isMac ? 280 : nil)
            .presentationDetents([.medium, .large]).preferredColorScheme(.dark)
        }
        .refreshable { await model.tick() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: OrbitTheme.isMac ? 12 : 15, weight: .medium)).foregroundStyle(.secondary)
            TextField(tab == 1 ? "Search tracked items" : "Search preferences", text: $query)
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
            if tab == 1 { onTrack() } else { showAdd = true }
        } label: {
            Label(tab == 1 ? "Track something" : "Add preference", systemImage: "plus")
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
            OrbitEmptyState(symbol: query.isEmpty ? "slider.horizontal.3" : "magnifyingglass",
                            title: query.isEmpty ? "No preferences yet" : "No matches",
                            detail: query.isEmpty ? "Tell Orbit how you like things done, and it will remember." : "Try a different search.")
        } else {
            OrbitGroup() {
                ForEach(Array(filteredMemories.enumerated()), id: \.element.id) { index, memory in
                    if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal) }
                    memoryRow(memory)
                }
            }
        }
        if query.isEmpty {
            Button(action: onAboutYou) {
                HStack(spacing: 5) {
                    Text("Name, school and people are in")
                    Text("About you").fontWeight(.semibold).foregroundStyle(.primary)
                    Image(systemName: "chevron.right").font(.system(size: OrbitTheme.isMac ? 9 : 11, weight: .semibold))
                }
                .font(OrbitTheme.footnote).foregroundStyle(.secondary)
                .lineLimit(1).minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.top, 2)
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
            OrbitGroup() {
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
                if responsibility.source != "user" {
                    Text("Added by Orbit").font(OrbitTheme.footnote).foregroundStyle(.tertiary)
                }
                if let why = responsibility.data?["why"]?.string, !why.isEmpty {
                    Text(why).font(OrbitTheme.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if let action = responsibility.data?["next_action"]?.string, !action.isEmpty {
                    Text(action).font(OrbitTheme.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
                if responsibility.data?["paused"]?.bool == true {
                    Text("Paused").font(OrbitTheme.footnote).foregroundStyle(.secondary)
                }
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
        Button {
            trackedTitle = responsibility.title; trackedNotes = responsibility.notes; editingTracked = responsibility
        } label: { Label("Edit", systemImage: "pencil") }
        let paused = responsibility.data?["paused"]?.bool == true
        Button {
            Task { await model.perform { try await $0.setResponsibilityPaused(id: responsibility.id, paused: !paused) } }
        } label: { Label(paused ? "Resume checks" : "Pause checks", systemImage: paused ? "play" : "pause") }
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
            TextField("e.g. Keep replies short and casual", text: $text, axis: .vertical)
                .lineLimit(4...10).textFieldStyle(.plain).font(OrbitTheme.body).focused($focused)
                .padding(14)
                .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
            Text("Preferences tell Orbit how you like things done. You can edit or delete them any time.")
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
