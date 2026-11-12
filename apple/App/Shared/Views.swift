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
        case .activity: return "clock"
        case .memory: return "brain"
        case .settings: return "gearshape"
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
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "circle.circle").font(.title2.weight(.light))
                Text("Orbit").font(.title2.weight(.semibold))
                Spacer()
            }.padding(.horizontal, 12).padding(.bottom, 24)
            ForEach(OrbitSection.allCases.filter { $0 != .settings }) { destination in
                drawerRow(destination)
            }
            Spacer(minLength: 20)
            Divider().padding(.horizontal, 12)
            drawerRow(.settings)
        }.padding(16)
        #if os(macOS)
        .padding(.top, 36)
        #endif
    }

    private func drawerRow(_ destination: OrbitSection) -> some View {
        Button {
            section = destination
            setSidebar(false)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: destination.icon).font(.system(size: 18)).frame(width: 24)
                Text(destination.rawValue).font(.body.weight(section == destination ? .semibold : .regular))
                Spacer()
                if destination == .chat, !store.pendingApprovals.isEmpty {
                    Text("\(store.pendingApprovals.count)").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                        .accessibilityLabel("\(store.pendingApprovals.count) approvals in chat")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 16)
            .contentShape(RoundedRectangle(cornerRadius: 18))
            .background(section == destination ? Color.primary.opacity(0.07) : .clear,
                        in: RoundedRectangle(cornerRadius: 18))
        }.buttonStyle(.plain)
        .accessibilityAddTraits(section == destination ? [.isSelected] : [])
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

    var body: some View {
        ZStack {
            OrbitBackdrop()
            OrbitPage {
                VStack(alignment: .leading, spacing: 12) {
                    Image(systemName: "circle.circle").font(.system(size: 48, weight: .ultraLight))
                        .frame(width: 90, height: 90).orbitGlass(in: Circle()).padding(.bottom, 16)
                    Text("Meet Orbit.").font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    Text("Your day, a little lighter.").foregroundStyle(.secondary)
                }.padding(.vertical, 24)
                OrbitCard {
                    Text("Your server").font(.headline)
                    TextField("https://orbit.workers.dev", text: $server).autocorrectionDisabled()
                    Divider()
                    TextField("Device name", text: $name)
                }
                OrbitCard {
                    Text("Pair this device").font(.headline)
                    TextField("Pairing code", text: $code).autocorrectionDisabled()
                    Text("Get a code from Orbit on your other device.").font(.caption).foregroundStyle(.secondary)
                    DisclosureGroup("First device setup") {
                        SecureField("Admin token", text: $admin).padding(.top, 8)
                    }.font(.callout)
                }
                Button {
                    busy = true
                    Task { await model.pair(server: server, code: code, adminToken: admin, name: name); busy = false }
                } label: {
                    HStack {
                        Spacer()
                        if busy { ProgressView().controlSize(.small) }
                        Text(busy ? "Connecting…" : "Connect").fontWeight(.semibold)
                        Spacer()
                    }.padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(busy || server.isEmpty || (code.isEmpty && admin.isEmpty))
            }.frame(maxWidth: 540)
        }
        .textFieldStyle(.plain)
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
                    withAnimation { proxy.scrollTo(store.chat(conversationId).last?.id, anchor: .bottom) }
                }
                .onChange(of: store.pendingApprovals.map(\.id)) { _, ids in
                    if let id = ids.first { withAnimation { proxy.scrollTo("approval-" + id, anchor: .bottom) } }
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
    @State private var deciding = false

    var body: some View {
        OrbitSolidCard {
            Label("Needs your approval", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            Text(approval.summary).font(.headline)
            if case .object(let params)? = approval.params {
                ForEach(params.keys.sorted(), id: \.self) { key in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(key.replacingOccurrences(of: "_", with: " ").capitalized).font(.caption).foregroundStyle(.secondary)
                        Text(params[key]?.display ?? "").font(.callout).textSelection(.enabled)
                    }
                }
                HStack(spacing: 12) {
                    Button(deciding ? "Working…" : "Approve") { decide(true) }.buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { decide(false) }.buttonStyle(.bordered)
                    Spacer()
                }.controlSize(.large).disabled(deciding)
            } else {
                ProgressView("Loading action details…").font(.caption)
                Button("Retry") { Task { await model.loadApprovalDetails() } }.font(.caption)
            }
            Text("Expires \(approval.expiresAt.date, style: .relative)").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func decide(_ approve: Bool) {
        deciding = true
        Task {
            await model.decide(approval.id, approve: approve)
            deciding = false
        }
    }
}

// MARK: - Activity

struct WorkView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onCompose: (String) -> Void
    var onReviewApproval: () -> Void
    @State private var tab = 0

    private var activeTasks: [OrbitTask] {
        store.recentTasks.filter { ["queued", "leased", "awaiting_approval"].contains($0.status) }
    }
    private var finishedTasks: [OrbitTask] {
        store.recentTasks.filter { !["queued", "leased", "awaiting_approval"].contains($0.status) }
    }

    var body: some View {
        OrbitPage {
            OrbitPillTabs(titles: ["Active", "Done", "Updates", "History"], selection: $tab)
            switch tab {
            case 0: taskList(activeTasks, active: true)
            case 1: taskList(finishedTasks, active: false)
            case 2: notificationList
            default: historyList
            }
        }
        .refreshable { await model.tick() }
    }

    @ViewBuilder private func taskList(_ tasks: [OrbitTask], active: Bool) -> some View {
        if tasks.isEmpty {
            if active {
                Text("Try asking Orbit").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 16)
                suggestion("Email check", detail: "Find what needs your attention.", icon: "envelope",
                           prompt: "Check my connected email accounts and tell me what needs my attention.")
                suggestion("Daily briefing", detail: "Your schedule, deadlines, and next steps.", icon: "sun.max",
                           prompt: "Give me a briefing of my schedule, upcoming deadlines, and anything waiting on me.")
            } else {
                OrbitEmptyState(symbol: "checkmark.circle", title: "Nothing finished yet", detail: "Completed tasks will appear here.")
            }
        } else {
            Text("\(tasks.count) \(active ? "in progress" : "finished")")
                .font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.top, 8)
        }
        ForEach(tasks.prefix(100)) { task in
            OrbitSolidCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: taskIcon(task.status)).font(.title3).foregroundStyle(taskColor(task.status))
                        .frame(width: 28).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(task.summary).font(.body.weight(.medium))
                        HStack(spacing: 6) {
                            Text(taskLabel(task.status))
                            Text("·")
                            Text(task.updatedAt.date, style: .relative)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if task.status == "queued" || task.status == "awaiting_approval" {
                        Menu {
                            Button("Cancel task", role: .destructive) { Task { await model.perform { try await $0.cancel(taskId: task.id) } } }
                        } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                    }
                }
                if task.status == "awaiting_approval" {
                    Button("Review in chat", action: onReviewApproval).buttonStyle(.bordered).controlSize(.large)
                }
                if let error = task.error, task.status == "failed" {
                    DisclosureGroup("What happened") { Text(error).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
    }

    private func suggestion(_ title: String, detail: String, icon: String, prompt: String) -> some View {
        Button { onCompose(prompt) } label: {
            OrbitSolidCard {
                HStack(spacing: 18) {
                    Image(systemName: icon).font(.title2.weight(.light)).frame(width: 34)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(title).font(.body.weight(.medium))
                        Text(detail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
        }.buttonStyle(.plain)
    }

    @ViewBuilder private var notificationList: some View {
        if store.sortedNotifications.isEmpty {
            OrbitEmptyState(symbol: "bell", title: "You’re up to date", detail: "Useful updates will appear here.")
        }
        ForEach(store.sortedNotifications.prefix(150)) { notification in
            OrbitSolidCard {
                HStack(alignment: .top) {
                    Text(notification.title).font(.body.weight(.semibold))
                    Spacer()
                    if notification.readAt == nil { Circle().fill(Color.accentColor).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                }
                Text(notification.body).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                Text(notification.createdAt.date, style: .relative).font(.caption).foregroundStyle(.tertiary)
            }
            .onAppear {
                if notification.readAt == nil { Task { await model.perform { try await $0.markRead(notificationId: notification.id) } } }
            }
        }
    }

    @ViewBuilder private var historyList: some View {
        if store.sortedActivity.isEmpty {
            OrbitEmptyState(symbol: "clock", title: "A fresh start", detail: "Orbit’s actions will appear here.")
        }
        ForEach(store.sortedActivity.prefix(200)) { activity in
            OrbitSolidCard {
                HStack(alignment: .top, spacing: 14) {
                    Image(systemName: "clock").foregroundStyle(.secondary).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(activity.summary).font(.subheadline)
                        Text(activity.createdAt.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func taskLabel(_ status: String) -> String {
        switch status {
        case "queued": return "Up next"
        case "leased": return "Working"
        case "awaiting_approval": return "Needs you"
        case "succeeded": return "Completed"
        case "failed": return "Needs attention"
        case "denied": return "Declined"
        default: return status.capitalized
        }
    }
    private func taskIcon(_ status: String) -> String {
        switch status {
        case "succeeded": return "checkmark.circle"
        case "failed": return "exclamationmark.circle"
        case "awaiting_approval": return "hand.raised"
        case "leased": return "arrow.triangle.2.circlepath"
        case "cancelled", "denied": return "minus.circle"
        default: return "clock"
        }
    }
    private func taskColor(_ status: String) -> Color {
        switch status {
        case "succeeded": return .green
        case "failed", "awaiting_approval": return .orange
        default: return .secondary
        }
    }
}

struct StatusDot: View {
    let status: String
    var color: Color {
        switch status {
        case "succeeded": return .green
        case "failed", "denied": return .red
        case "awaiting_approval": return .orange
        case "leased": return .blue
        case "cancelled": return .gray
        default: return .yellow
        }
    }
    var body: some View { Circle().fill(color).frame(width: 8, height: 8) }
}

// MARK: - Memory & responsibilities

struct MemoryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onTrack: () -> Void
    @State private var tab = 0
    @State private var query = ""
    @State private var newText = ""
    @State private var newKind = "preference"
    @State private var showAdd = false
    @State private var editing: Memory?
    @State private var editText = ""

    private var filteredMemories: [Memory] {
        store.liveMemories.filter {
            $0.kind == (tab == 0 ? "preference" : "fact") && (query.isEmpty || $0.content.localizedCaseInsensitiveContains(query))
        }
    }
    private var tracked: [Responsibility] {
        store.openResponsibilities.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.notes.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        OrbitPage {
            OrbitPillTabs(titles: ["Preferences", "About you", "Tracking"], selection: $tab)
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search memory", text: $query).textFieldStyle(.plain)
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear search")
                }
            }.padding(14).orbitGlass(in: RoundedRectangle(cornerRadius: 18))
            if tab == 2 { trackingList } else { memoryList }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button {
                    if tab == 2 { onTrack() }
                    else { newKind = tab == 0 ? "preference" : "fact"; showAdd = true }
                } label: {
                    Label(tab == 2 ? "Track something" : "Add memory", systemImage: "plus")
                        .fontWeight(.semibold).padding(.horizontal, 10).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            }.frame(maxWidth: 680).padding(.horizontal, 20).padding(.vertical, 12)
        }
        .sheet(isPresented: $showAdd) {
            editor(title: "Add memory", text: $newText) {
                Picker("Kind", selection: $newKind) { Text("Preference").tag("preference"); Text("Fact").tag("fact") }.pickerStyle(.segmented)
            } save: {
                let content = newText, kind = newKind
                newText = ""; showAdd = false
                Task { await model.perform { try await $0.addMemory(kind: kind, content: content) } }
            } cancel: { showAdd = false }
        }
        .sheet(item: $editing) { memory in
            editor(title: "Edit memory", text: $editText) { EmptyView() } save: {
                let content = editText
                editing = nil
                Task { await model.perform { try await $0.updateMemory(id: memory.id, content: content) } }
            } cancel: { editing = nil }
        }
        .refreshable { await model.tick() }
    }

    @ViewBuilder private var memoryList: some View {
        if filteredMemories.isEmpty {
            OrbitEmptyState(symbol: query.isEmpty ? "brain" : "magnifyingglass", title: query.isEmpty ? "A little more you" : "No matches",
                            detail: query.isEmpty ? "Tell Orbit what’s worth remembering." : "Try a different search.")
        } else {
            Text("\(filteredMemories.count) saved").font(.subheadline.weight(.medium)).foregroundStyle(.secondary).padding(.top, 8)
        }
        ForEach(filteredMemories) { memory in
            OrbitSolidCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: tab == 0 ? "slider.horizontal.3" : "person.crop.circle")
                        .font(.title3).foregroundStyle(.secondary).frame(width: 26).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 10) {
                        Text(memory.content).font(.body).textSelection(.enabled)
                        Text(memory.updatedAt.date.formatted(date: .abbreviated, time: .omitted))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Edit") { editing = memory; editText = memory.content }
                        Button("Delete", role: .destructive) { Task { await model.perform { try await $0.deleteMemory(id: memory.id) } } }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                }
            }
        }
    }

    @ViewBuilder private var trackingList: some View {
        if tracked.isEmpty {
            OrbitEmptyState(symbol: query.isEmpty ? "bookmark" : "magnifyingglass", title: query.isEmpty ? "Keep it on your radar" : "No matches",
                            detail: query.isEmpty ? "Follow-ups, deadlines, and things you’re waiting on." : "Try a different search.")
        }
        ForEach(tracked) { responsibility in
            OrbitSolidCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "bookmark").font(.title3).foregroundStyle(.secondary).frame(width: 26).padding(.top, 2)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(responsibility.title).font(.body.weight(.medium))
                        if let due = responsibility.dueAt {
                            Label(due.date.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if let next = responsibility.nextCheckAt {
                            Text("Checking \(next.date, style: .relative)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer(minLength: 0)
                    Menu {
                        Button("Mark done") { Task { await model.perform { try await $0.setResponsibilityStatus(id: responsibility.id, status: "done") } } }
                        Button("Stop tracking", role: .destructive) { Task { await model.perform { try await $0.setResponsibilityStatus(id: responsibility.id, status: "cancelled") } } }
                    } label: { Image(systemName: "ellipsis").frame(width: 36, height: 36) }
                }
            }
        }
    }

    private func editor<Extra: View>(title: String, text: Binding<String>, @ViewBuilder extra: () -> Extra, save: @escaping () -> Void, cancel: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.title2.weight(.semibold))
            extra()
            TextField("Something to remember", text: text, axis: .vertical)
                .lineLimit(3...8).textFieldStyle(.plain).padding(16)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 18))
            HStack {
                Button("Cancel", action: cancel).buttonStyle(.bordered)
                Spacer()
                Button("Save", action: save).buttonStyle(.borderedProminent)
                    .disabled(text.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.controlSize(.large)
        }
        .padding(28).frame(minWidth: 300, idealWidth: 420)
        .background { OrbitBackdrop() }
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
    }
}
