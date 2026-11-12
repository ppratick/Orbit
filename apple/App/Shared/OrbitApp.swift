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
                #if os(macOS)
                .background { OrbitWindowAppearance() }
                .onAppear {
                    if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
                       let icon = NSImage(contentsOf: iconURL) {
                        NSApplication.shared.applicationIconImage = icon
                    }
                }
                .ignoresSafeArea(.container, edges: .top)
                #endif
                #if os(iOS)
                .onAppear { OrbitApp.sharedModel = model }
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
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
        Settings { SettingsView().environmentObject(model).environmentObject(model.store).preferredColorScheme(.dark).frame(width: 520, height: 640) }
        #endif
    }
}

#if os(macOS)
import AppKit

private struct OrbitWindowAppearance: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WindowView() }
    func updateNSView(_ nsView: NSView, context: Context) {}
    private final class WindowView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.styleMask.insert(.fullSizeContentView)
            window.backgroundColor = .black
            window.toolbar = nil
            window.isMovableByWindowBackground = true
        }
    }
}
#endif
