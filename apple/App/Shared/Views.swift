import OrbitKit
import SwiftUI

// MARK: - Root

struct RootView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore

    var body: some View {
        Group {
            if model.isPaired {
                #if os(macOS)
                MacRoot()
                #else
                TabView {
                    NavigationStack { ConversationListView() }.tabItem { Label("Chat", systemImage: "bubble.left.and.bubble.right") }
                    NavigationStack { ApprovalsView() }.tabItem { Label("Approvals", systemImage: "checkmark.shield") }.badge(store.pendingApprovals.count)
                    NavigationStack { WorkView() }.tabItem { Label("Activity", systemImage: "list.bullet.rectangle") }
                    NavigationStack { MemoryView() }.tabItem { Label("Memory", systemImage: "brain") }
                    NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gear") }
                }
                #endif
            } else {
                PairingView()
            }
        }
        .overlay(alignment: .top) {
            if let b = model.banner {
                Text(b).font(.callout).padding(10).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10)).padding()
                    .onTapGesture { model.banner = nil }
                    .task { try? await Task.sleep(nanoseconds: 5_000_000_000); model.banner = nil }
            }
        }
        .onAppear { model.start() }
    }
}

#if os(macOS)
struct MacRoot: View {
    @EnvironmentObject var store: OrbitStore
    enum Section: String, CaseIterable, Identifiable { case chat = "Chat", approvals = "Approvals", activity = "Activity", memory = "Memory", settings = "Settings"; var id: String { rawValue } }
    @State private var section: Section? = .chat

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                HStack {
                    Text(s.rawValue)
                    if s == .approvals, !store.pendingApprovals.isEmpty { Spacer(); Text("\(store.pendingApprovals.count)").foregroundStyle(.orange) }
                }.tag(s)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170)
        } detail: {
            NavigationStack {
                switch section ?? .chat {
                case .chat: ConversationListView()
                case .approvals: ApprovalsView()
                case .activity: WorkView()
                case .memory: MemoryView()
                case .settings: SettingsView()
                }
            }
        }
    }
}
#endif

// MARK: - Pairing

struct PairingView: View {
    @EnvironmentObject var model: AppModel
    @State private var server = ""
    @State private var code = ""
    @State private var admin = ""
    @State private var name = DeviceName.current
    @State private var busy = false

    var body: some View {
        Form {
            Section("Connect to your Orbit server") {
                TextField("https://orbit.<you>.workers.dev", text: $server).autocorrectionDisabled()
                TextField("Device name", text: $name)
            }
            Section(header: Text("Pairing code"), footer: Text("Create a code on an already-paired device (Settings → Pair another device). For your first device, paste the admin token instead; it is used once and not stored.")) {
                TextField("Code from another device", text: $code).autocorrectionDisabled()
                SecureField("…or admin token (first device only)", text: $admin)
            }
            Button(busy ? "Pairing…" : "Pair this device") {
                busy = true
                Task { await model.pair(server: server, code: code, adminToken: admin, name: name); busy = false }
            }.disabled(busy || server.isEmpty || (code.isEmpty && admin.isEmpty))
        }
        .formStyle(.grouped)
        .frame(maxWidth: 520)
        .onAppear { server = model.serverURL }
    }
}

// MARK: - Conversations & chat

struct ConversationListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var query = ""
    @State private var hits: [APIClient.SearchHit] = []
    @State private var openId: String?

    var body: some View {
        List {
            if !hits.isEmpty {
                Section("Search results") {
                    ForEach(hits) { h in
                        NavigationLink(value: h.conversationId) { VStack(alignment: .leading) { Text(h.title).font(.headline); Text(h.snippet).font(.caption).foregroundStyle(.secondary) } }
                    }
                }
            }
            Section {
                ForEach(store.sortedConversations) { c in
                    NavigationLink(value: c.id) {
                        VStack(alignment: .leading) {
                            Text(c.title).lineLimit(1)
                            Text(c.updatedAt.date, style: .relative).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { Button("Archive") { Task { await model.perform { try await $0.archive(c.id) } } } }
                }
            }
        }
        .navigationTitle("Orbit")
        .navigationDestination(for: String.self) { ChatView(conversationId: $0) }
        .navigationDestination(item: $openId) { ChatView(conversationId: $0) }
        .searchable(text: $query, prompt: "Search conversations")
        .onSubmit(of: .search) { Task { hits = (try? await model.api?.search(query)) ?? [] } }
        .onChange(of: query) { _, q in if q.isEmpty { hits = [] } }
        .toolbar {
            Button { Task { openId = await model.newConversation() } } label: { Label("New chat", systemImage: "square.and.pencil") }
        }
        .refreshable { await model.tick() }
    }
}

struct ChatView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    let conversationId: String
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(store.chat(conversationId)) { m in MessageBubble(message: m).id(m.id) }
                        if model.sending.contains(conversationId) { ProgressView().padding(.leading, 12).id("typing") }
                        if model.failedSend[conversationId] != nil {
                            Button("Couldn't send — tap to retry") { Task { await model.retry(in: conversationId) } }.font(.callout).padding(.leading, 12)
                        }
                    }
                    .padding()
                }
                .onChange(of: store.chat(conversationId).count) { _, _ in
                    withAnimation { proxy.scrollTo(store.chat(conversationId).last?.id, anchor: .bottom) }
                }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Message Orbit", text: $draft, axis: .vertical).lineLimit(1...6).textFieldStyle(.plain)
                    .onSubmit(sendDraft)
                Button(action: sendDraft) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || model.sending.contains(conversationId))
                    .keyboardShortcut(.return, modifiers: .command)
            }
            .padding(10)
        }
        .navigationTitle(store.conversations[conversationId]?.title ?? "Chat")
    }

    private func sendDraft() {
        let text = draft
        draft = ""
        Task { await model.send(text, in: conversationId) }
    }
}

struct MessageBubble: View {
    let message: Message
    var isUser: Bool { message.role == "user" }
    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Text(LocalizedStringKey(message.content))
                .textSelection(.enabled)
                .padding(10)
                .background(isUser ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}

// MARK: - Approvals

struct ApprovalsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore

    var body: some View {
        List {
            if store.pendingApprovals.isEmpty { Text("Nothing is waiting for you.").foregroundStyle(.secondary) }
            ForEach(store.pendingApprovals) { a in
                VStack(alignment: .leading, spacing: 8) {
                    Text(a.summary).font(.headline)
                    // Show the exact parameters that will run — approval is bound to them server-side.
                    if case .object(let params)? = a.params {
                        ForEach(params.keys.sorted(), id: \.self) { k in
                            HStack(alignment: .top) {
                                Text(k).font(.caption.monospaced()).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
                                Text(params[k]?.display ?? "").font(.caption).textSelection(.enabled)
                            }
                        }
                    }
                    HStack {
                        Button("Approve") { Task { await model.decide(a.id, approve: true) } }.buttonStyle(.borderedProminent)
                        Button("Deny", role: .destructive) { Task { await model.decide(a.id, approve: false) } }.buttonStyle(.bordered)
                        Spacer()
                        Text("expires \(a.expiresAt.date, style: .relative)").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Approvals")
        .task { await model.loadApprovalDetails() }
        .refreshable { await model.tick(); await model.loadApprovalDetails() }
    }
}

// MARK: - Activity (tasks, notifications, history)

struct WorkView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var tab = 0

    var body: some View {
        List {
            Picker("", selection: $tab) { Text("Tasks").tag(0); Text("Notifications").tag(1); Text("History").tag(2) }.pickerStyle(.segmented)
            switch tab {
            case 0:
                ForEach(store.recentTasks.prefix(100)) { t in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { StatusDot(status: t.status); Text(t.summary).lineLimit(2) }
                        Text("\(t.status.replacingOccurrences(of: "_", with: " ")) · \(t.target) · \(t.updatedAt.date, style: .relative) ago").font(.caption).foregroundStyle(.secondary)
                        if let e = t.error, t.status == "failed" { Text(e).font(.caption).foregroundStyle(.red) }
                    }
                    .swipeActions {
                        if t.status == "queued" || t.status == "awaiting_approval" {
                            Button("Cancel", role: .destructive) { Task { await model.perform { try await $0.cancel(taskId: t.id) } } }
                        }
                    }
                }
            case 1:
                ForEach(store.sortedNotifications.prefix(150)) { n in
                    VStack(alignment: .leading) {
                        Text(n.title).font(n.readAt == nil ? .headline : .body)
                        Text(n.body).font(.caption).foregroundStyle(.secondary).lineLimit(6)
                        Text(n.createdAt.date, style: .relative).font(.caption2).foregroundStyle(.tertiary)
                    }
                    .onAppear { if n.readAt == nil { Task { await model.perform { try await $0.markRead(notificationId: n.id) } } } }
                }
            default:
                ForEach(store.sortedActivity.prefix(200)) { a in
                    VStack(alignment: .leading) {
                        Text(a.summary)
                        Text("\(a.type) · \(a.createdAt.date.formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Activity")
        .refreshable { await model.tick() }
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
    @State private var newText = ""
    @State private var newKind = "preference"
    @State private var editing: Memory?
    @State private var editText = ""

    var body: some View {
        List {
            Section("Ongoing responsibilities") {
                if store.openResponsibilities.isEmpty { Text("Nothing tracked").foregroundStyle(.secondary) }
                ForEach(store.openResponsibilities) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.title)
                        HStack {
                            Text(r.kind).font(.caption.bold())
                            if let due = r.dueAt { Text("due \(due.date.formatted(date: .abbreviated, time: .shortened))").font(.caption) }
                            if let next = r.nextCheckAt { Text("· next check \(next.date, style: .relative)").font(.caption) }
                        }.foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button("Done") { Task { await model.perform { try await $0.setResponsibilityStatus(id: r.id, status: "done") } } }.tint(.green)
                        Button("Drop", role: .destructive) { Task { await model.perform { try await $0.setResponsibilityStatus(id: r.id, status: "cancelled") } } }
                    }
                }
            }
            Section("Add memory") {
                Picker("Kind", selection: $newKind) { Text("Preference").tag("preference"); Text("Fact").tag("fact") }
                TextField("e.g. I prefer meetings after 10am", text: $newText)
                Button("Save") {
                    let t = newText, k = newKind
                    newText = ""
                    Task { await model.perform { try await $0.addMemory(kind: k, content: t) } }
                }.disabled(newText.isEmpty)
            }
            ForEach(["preference", "fact"], id: \.self) { kind in
                Section(kind == "preference" ? "Preferences" : "Facts") {
                    ForEach(store.liveMemories.filter { $0.kind == kind }) { m in
                        VStack(alignment: .leading) {
                            Text(m.content)
                            Text("\(m.source) · \(m.updatedAt.date.formatted(date: .abbreviated, time: .omitted))").font(.caption2).foregroundStyle(.secondary)
                        }
                        .contextMenu { Button("Edit") { editing = m; editText = m.content } }
                        .swipeActions {
                            Button("Delete", role: .destructive) { Task { await model.perform { try await $0.deleteMemory(id: m.id) } } }
                            Button("Edit") { editing = m; editText = m.content }
                        }
                    }
                }
            }
        }
        .navigationTitle("Memory")
        .sheet(item: $editing) { m in
            VStack(alignment: .leading) {
                Text("Edit memory").font(.headline)
                TextField("", text: $editText, axis: .vertical).lineLimit(2...8)
                HStack {
                    Button("Cancel") { editing = nil }
                    Spacer()
                    Button("Save") {
                        let t = editText
                        editing = nil
                        Task { await model.perform { try await $0.updateMemory(id: m.id, content: t) } }
                    }.buttonStyle(.borderedProminent)
                }
            }.padding().frame(minWidth: 320)
        }
        .refreshable { await model.tick() }
    }
}
