import OrbitKit
import SwiftUI

/// Sidebar → Scheduled. Tasks Orbit carries out on a schedule; each run reports back in the chat.
struct ScheduledView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onCompose: (String) -> Void
    @State private var editing: EditTarget?
    @State private var deleting: Schedule?

    struct EditTarget: Identifiable { let id: String; let schedule: Schedule? }
    static let tint = Color(red: 0.25, green: 0.62, blue: 0.95)

    var body: some View {
        OrbitScreen(spacing: OrbitTheme.isMac ? 18 : 22) {
            if store.liveSchedules.isEmpty {
                OrbitEmptyState(symbol: "calendar.badge.clock", title: "Nothing scheduled",
                                detail: "Have Orbit do something on a schedule, like a weekday inbox check or a Sunday plan for the week.")
                Button { onCompose("Every weekday at 8 AM, ") } label: {
                    Label("Ask Orbit in chat", systemImage: "bubble.left")
                }
                .buttonStyle(OrbitButtonStyle(kind: .secondary, fullWidth: false))
                .frame(maxWidth: .infinity)
            } else {
                OrbitGroup(header: "Your tasks", footer: "Results arrive in the chat. Anything that needs approval still waits for you.") {
                    ForEach(Array(store.liveSchedules.enumerated()), id: \.element.id) { index, schedule in
                        if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal) }
                        row(schedule)
                    }
                }
            }
            QuietHoursGroup()
            Color.clear.frame(height: 60)
        }
        .overlay(alignment: .bottom) {
            HStack {
                Spacer()
                Button { editing = EditTarget(id: "new", schedule: nil) } label: {
                    Label("New task", systemImage: "plus")
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
            .frame(maxWidth: OrbitTheme.pageWidth)
            .padding(.horizontal, OrbitTheme.pagePadding)
        }
        .sheet(item: $editing) { target in
            ScheduleEditor(existing: target.schedule) { editing = nil }
                .environmentObject(model).environmentObject(store)
        }
        .confirmationDialog("Delete this scheduled task?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                guard let s = deleting else { return }
                deleting = nil
                Task { await model.perform { try await $0.deleteSchedule(id: s.id) } }
            }
        } message: { Text("“\(deleting?.title ?? "")” won’t run again. Past results stay in the chat.") }
        .refreshable { await model.tick() }
    }

    private func row(_ s: Schedule) -> some View {
        Button { editing = EditTarget(id: s.id, schedule: s) } label: {
            HStack(alignment: .top, spacing: 12) {
                OrbitIconTile(symbol: s.status == "paused" ? "pause.fill" : s.status == "done" ? "checkmark" : "clock.fill",
                              tint: s.status == "active" ? Self.tint : Color(white: 0.32))
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.title).font(OrbitTheme.rowTitle)
                    Text(ScheduleText.rule(s)).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        OrbitBadge(text: ScheduleText.next(s), tint: s.status == "active" ? Self.tint : .secondary)
                        if let status = s.lastStatus { lastBadge(status) }
                    }
                    if let result = s.lastResult, !result.isEmpty {
                        Text(result.orbitTypographic).font(OrbitTheme.footnote).foregroundStyle(.tertiary).lineLimit(2)
                            .multilineTextAlignment(.leading)
                    }
                }
                Spacer(minLength: 8)
                Menu { actions(s) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).contentShape(Rectangle())
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Options for \(s.title)")
            }
            .padding(.horizontal, OrbitTheme.rowHorizontal)
            .padding(.vertical, OrbitTheme.rowVertical)
            .contentShape(Rectangle())
        }
        .buttonStyle(OrbitRowButtonStyle())
        .contextMenu { actions(s) }
    }

    @ViewBuilder private func actions(_ s: Schedule) -> some View {
        Button { runNow(s) } label: { Label("Run now", systemImage: "play") }
        Button { editing = EditTarget(id: s.id, schedule: s) } label: { Label("Edit", systemImage: "pencil") }
        if s.status == "active" {
            Button { setStatus(s, "paused") } label: { Label("Pause", systemImage: "pause") }
        } else if s.status == "paused" {
            Button { setStatus(s, "active") } label: { Label("Resume", systemImage: "play.circle") }
        }
        Button(role: .destructive) { deleting = s } label: { Label("Delete", systemImage: "trash") }
    }

    /// Starts a run, then keeps syncing briefly so "Running…" turns into the result without a manual refresh.
    private func runNow(_ s: Schedule) {
        Task {
            guard let api = model.api else { return }
            do { store.upsert(schedule: try await api.runSchedule(id: s.id)) } catch { model.banner = error.localizedDescription; return }
            for _ in 0..<12 {
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                await store.sync(using: api)
                if store.schedules[s.id]?.lastStatus != "running" { break }
            }
        }
    }

    private func setStatus(_ s: Schedule, _ status: String) {
        Task {
            guard let api = model.api else { return }
            do { store.upsert(schedule: try await api.setScheduleStatus(id: s.id, status: status)); await store.sync(using: api) }
            catch { model.banner = error.localizedDescription }
        }
    }

    @ViewBuilder private func lastBadge(_ status: String) -> some View {
        switch status {
        case "running": OrbitBadge(text: "Running…", tint: Self.tint)
        case "ok": OrbitBadge(text: "Last run OK", tint: .green)
        case "needs_approval": OrbitBadge(text: "Needs approval", tint: .orange)
        case "failed": OrbitBadge(text: "Last run failed", tint: Color(red: 1, green: 0.42, blue: 0.4))
        case "deferred": OrbitBadge(text: "Held for quiet hours", tint: .secondary)
        default: EmptyView()
        }
    }
}

/// Human wording for schedules, shared by the list and the editor.
enum ScheduleText {
    static let dayNames = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]

    static func time(_ hm: String?) -> String {
        guard let hm, let date = hmDate(hm) else { return "" }
        return date.formatted(date: .omitted, time: .shortened)
    }
    static func hmDate(_ hm: String) -> Date? {
        let parts = hm.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: Date())
    }
    static func zoneName(_ id: String) -> String {
        TimeZone(identifier: id)?.localizedName(for: .generic, locale: .current) ?? id
    }
    static func rule(_ s: Schedule) -> String {
        let zone = s.timezone == TimeZone.current.identifier ? "" : " · \(zoneName(s.timezone))"
        switch s.repeat {
        case "once":
            guard let at = s.runAt?.date else { return "Once" }
            return "Once, \(at.formatted(date: .abbreviated, time: .shortened))\(zone)"
        case "interval": return "Every \(s.intervalHours ?? 1) hour\((s.intervalHours ?? 1) == 1 ? "" : "s")"
        case "daily": return "Every day at \(time(s.timeOfDay))\(zone)"
        case "weekdays": return "Weekdays at \(time(s.timeOfDay))\(zone)"
        default: return "Every \(s.dayList.map { dayNames[$0] }.joined(separator: ", ")) at \(time(s.timeOfDay))\(zone)"
        }
    }
    static func next(_ s: Schedule) -> String {
        switch s.status {
        case "paused": return "Paused"
        case "done": return "Finished"
        default:
            guard let next = s.nextRunAt?.date else { return "Not scheduled" }
            let cal = Calendar.current
            let when = cal.isDateInToday(next) ? "Today \(next.formatted(date: .omitted, time: .shortened))"
                : cal.isDateInTomorrow(next) ? "Tomorrow \(next.formatted(date: .omitted, time: .shortened))"
                : next.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
            return "Next: \(when)"
        }
    }
}

/// Global quiet hours: scheduled runs that fall inside are held until they end.
struct QuietHoursGroup: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var enabled = false
    @State private var start = ScheduleText.hmDate("22:00") ?? Date()
    @State private var end = ScheduleText.hmDate("07:00") ?? Date()
    @State private var loaded = false

    private var stored: String { store.profileText("quiet_hours") }

    var body: some View {
        OrbitGroup(header: "Quiet hours", footer: "Scheduled tasks that would run in this window wait until it ends. You can turn this off per task.") {
            Toggle(isOn: $enabled) {
                OrbitRow(symbol: "moon.fill", tint: Color(red: 0.42, green: 0.36, blue: 0.9), title: "Hold runs overnight")
            }
            .toggleStyle(.switch).padding(.trailing, OrbitTheme.rowHorizontal)
            if enabled {
                OrbitRowDivider()
                HStack {
                    Text("From").font(OrbitTheme.rowTitle)
                    Spacer()
                    DatePicker("From", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                    Text("to").foregroundStyle(.secondary).font(OrbitTheme.body)
                    DatePicker("To", selection: $end, displayedComponents: .hourAndMinute).labelsHidden()
                }
                .padding(.horizontal, OrbitTheme.rowHorizontal)
                .padding(.vertical, OrbitTheme.rowVertical)
            }
        }
        .onAppear(perform: load)
        .onChange(of: stored) { _, _ in load() }
        .onChange(of: enabled) { _, _ in save() }
        .onChange(of: start) { _, _ in save() }
        .onChange(of: end) { _, _ in save() }
    }

    private static func hm(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    private func load() {
        loaded = false
        let parts = stored.split(separator: "-").map(String.init)
        enabled = parts.count == 2
        if parts.count == 2, let s = ScheduleText.hmDate(parts[0]), let e = ScheduleText.hmDate(parts[1]) { start = s; end = e }
        DispatchQueue.main.async { loaded = true }
    }

    private func save() {
        guard loaded else { return }
        let value = enabled ? "\(Self.hm(start))-\(Self.hm(end))" : ""
        guard value != stored else { return }
        Task {
            if let error = await model.saveProfile(section: "quiet_hours", content: value) { model.banner = error }
        }
    }
}

/// Create or edit a scheduled task.
struct ScheduleEditor: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    let existing: Schedule?
    var close: () -> Void
    @State private var title = ""
    @State private var instructions = ""
    @State private var repeatKind = "weekdays"
    @State private var time = ScheduleText.hmDate("08:00") ?? Date()
    @State private var runAt = Date().addingTimeInterval(3600)
    @State private var days: Set<Int> = [1]
    @State private var intervalHours = 4
    @State private var timezone = TimeZone.current.identifier
    @State private var respectQuiet = true
    @State private var saving = false
    @State private var error: String?

    static let repeats: [(id: String, name: String)] = [("once", "Once"), ("daily", "Every day"), ("weekdays", "Weekdays"), ("weekly", "Weekly"), ("interval", "Every few hours")]
    static var zones: [String] {
        var ids = [TimeZone.current.identifier]
        for id in ["Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Phoenix", "America/Chicago",
                   "America/New_York", "Europe/London", "Europe/Paris", "Asia/Kolkata", "Asia/Kathmandu", "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney"]
            where !ids.contains(id) { ids.append(id) }
        return ids
    }

    private var valid: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty && !instructions.trimmingCharacters(in: .whitespaces).isEmpty
            && (repeatKind != "weekly" || !days.isEmpty)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                Spacer()
                Text(existing == nil ? "New scheduled task" : "Edit task").font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: .semibold))
                Spacer()
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save").fontWeight(.semibold) }
                }
                .buttonStyle(.plain).disabled(!valid || saving).keyboardShortcut(.defaultAction)
            }
            .font(OrbitTheme.body)
            .padding(OrbitTheme.isMac ? 20 : 22)

            ScrollView {
                VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 16 : 20) {
                    field("Title") { TextField("e.g. Morning inbox check", text: $title) }
                    field("What should Orbit do?") {
                        TextField("e.g. Check my email and tell me what needs a reply today", text: $instructions, axis: .vertical).lineLimit(3...8)
                    }
                    field("Repeat") {
                        Menu {
                            ForEach(Self.repeats, id: \.id) { r in Button(r.name) { repeatKind = r.id } }
                        } label: { menuLabel(Self.repeats.first { $0.id == repeatKind }?.name ?? "") }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    switch repeatKind {
                    case "once":
                        field("When") { DatePicker("When", selection: $runAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden() }
                    case "interval":
                        field("Every") { Stepper("\(intervalHours) hour\(intervalHours == 1 ? "" : "s")", value: $intervalHours, in: 1...24) }
                    default:
                        if repeatKind == "weekly" {
                            field("On") {
                                HStack(spacing: 6) {
                                    ForEach(0..<7, id: \.self) { d in
                                        Button { if days.contains(d) { days.remove(d) } else { days.insert(d) } } label: {
                                            Text(String(ScheduleText.dayNames[d].prefix(2)))
                                                .font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold))
                                                .frame(maxWidth: .infinity, minHeight: OrbitTheme.isMac ? 26 : 34)
                                                .background(days.contains(d) ? ScheduledView.tint : Color.white.opacity(0.08), in: Capsule())
                                                .foregroundStyle(days.contains(d) ? Color.white : Color.secondary)
                                        }
                                        .buttonStyle(.plain)
                                        .accessibilityLabel(ScheduleText.dayNames[d]).accessibilityAddTraits(days.contains(d) ? [.isSelected] : [])
                                    }
                                }
                            }
                        }
                        field("At") { DatePicker("At", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                    }
                    field("Time zone") {
                        Menu {
                            ForEach(Self.zones, id: \.self) { z in Button(ScheduleText.zoneName(z)) { timezone = z } }
                        } label: { menuLabel(ScheduleText.zoneName(timezone)) }
                        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                    }
                    Toggle("Wait until quiet hours end", isOn: $respectQuiet).font(OrbitTheme.body).toggleStyle(.switch)
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill").font(OrbitTheme.footnote).foregroundStyle(.orange)
                    }
                    Text("Each run happens in your chat. Sending, buying, deleting or changing things still asks you first.")
                        .font(OrbitTheme.footnote).foregroundStyle(.secondary)
                }
                .padding(.horizontal, OrbitTheme.isMac ? 20 : 22)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 380, idealWidth: 460, minHeight: OrbitTheme.isMac ? 520 : nil)
        .background(Color(white: 0.06).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear(perform: load)
    }

    private func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(OrbitTheme.rowSubtitle.weight(.medium)).foregroundStyle(.secondary)
            content()
                .textFieldStyle(.plain).font(OrbitTheme.body)
                .padding(.horizontal, 12).padding(.vertical, OrbitTheme.isMac ? 8 : 10)
                .frame(maxWidth: .infinity, minHeight: OrbitTheme.isMac ? 32 : 44, alignment: .leading)
                .background(OrbitTheme.raisedHigh, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 12, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.primary)
            Spacer()
            Image(systemName: "chevron.down").font(.system(size: OrbitTheme.isMac ? 10 : 12, weight: .semibold)).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }

    private func load() {
        guard let s = existing else { return }
        title = s.title; instructions = s.instructions; repeatKind = s.repeat
        if let hm = s.timeOfDay, let d = ScheduleText.hmDate(hm) { time = d }
        if let at = s.runAt?.date { runAt = at }
        days = Set(s.dayList); intervalHours = s.intervalHours ?? 4
        timezone = s.timezone; respectQuiet = s.respectQuietHours != 0
    }

    private func save() {
        let c = Calendar.current.dateComponents([.hour, .minute], from: time)
        let draft = ScheduleDraft(
            title: title.trimmingCharacters(in: .whitespaces), instructions: instructions.trimmingCharacters(in: .whitespacesAndNewlines),
            repeat: repeatKind,
            timeOfDay: ["daily", "weekdays", "weekly"].contains(repeatKind) ? String(format: "%02d:%02d", c.hour ?? 8, c.minute ?? 0) : nil,
            days: repeatKind == "weekly" ? days.sorted() : nil,
            intervalHours: repeatKind == "interval" ? intervalHours : nil,
            runAt: repeatKind == "once" ? Millis(onceInstant.timeIntervalSince1970 * 1000) : nil,
            timezone: timezone, respectQuietHours: respectQuiet)
        saving = true
        error = nil
        Task {
            defer { saving = false }
            guard let api = model.api else { return }
            do {
                let saved = existing == nil ? try await api.createSchedule(draft) : try await api.updateSchedule(id: existing!.id, draft)
                store.upsert(schedule: saved)
                await store.sync(using: api)
                close()
            } catch { self.error = error.localizedDescription }
        }
    }

    /// The picker shows the device's wall clock; a one-time task in another zone means that wall time there.
    private var onceInstant: Date {
        guard timezone != TimeZone.current.identifier, let zone = TimeZone(identifier: timezone) else { return runAt }
        var local = Calendar.current
        local.timeZone = .current
        let parts = local.dateComponents([.year, .month, .day, .hour, .minute], from: runAt)
        var there = Calendar.current
        there.timeZone = zone
        return there.date(from: parts) ?? runAt
    }
}
