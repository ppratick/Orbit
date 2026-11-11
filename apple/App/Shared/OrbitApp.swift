import OrbitKit
import SwiftUI
#if os(iOS)
import BackgroundTasks
#endif

@main
struct OrbitApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var phase

    #if os(iOS)
    static let refreshTaskId = "orbit.refresh"
    init() {
        // Opportunistic background refresh. iOS decides when (often every few hours, sometimes never);
        // the cloud keeps working regardless — this only shortens the delay for iPhone-routed tasks.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.refreshTaskId, using: nil) { task in
            Task { @MainActor in
                OrbitApp.scheduleRefresh()
                let work = Task { await OrbitApp.sharedModel?.tick() }
                task.expirationHandler = { work.cancel() }
                await work.value
                task.setTaskCompleted(success: true)
            }
        }
    }
    @MainActor static weak var sharedModel: AppModel?
    static func scheduleRefresh() {
        let req = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        req.earliestBeginDate = Date(timeIntervalSinceNow: 20 * 60)
        try? BGTaskScheduler.shared.submit(req)
    }
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.store)
                #if os(iOS)
                .onAppear { OrbitApp.sharedModel = model }
                #endif
        }
        .onChange(of: phase) { _, p in
            #if os(iOS)
            switch p {
            case .active: model.start()
            case .background: model.stop(); OrbitApp.scheduleRefresh()
            default: break
            }
            #endif
        }
        #if os(macOS)
        // The Mac companion keeps running from the menu bar so device tasks execute while windows are closed.
        MenuBarExtra("Orbit", systemImage: model.store.pendingApprovals.isEmpty ? "circle.circle" : "exclamationmark.circle") {
            MenuContent().environmentObject(model).environmentObject(model.store)
        }
        Settings { SettingsView().environmentObject(model).environmentObject(model.store).frame(width: 520, height: 640) }
        #endif
    }
}

#if os(macOS)
struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var body: some View {
        Text(model.isPaired ? "Orbit companion running" : "Not paired")
        if let s = store.lastSyncAt { Text("Synced \(s.formatted(date: .omitted, time: .shortened))") }
        Divider()
        ForEach(store.pendingApprovals.prefix(5)) { a in
            Menu(a.summary) {
                Button("Approve") { Task { await model.decide(a.id, approve: true) } }
                Button("Deny") { Task { await model.decide(a.id, approve: false) } }
            }
        }
        if !store.pendingApprovals.isEmpty { Divider() }
        Button("Sync now") { Task { await model.tick() } }
        Button("Quit Orbit") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
    }
}
#endif
