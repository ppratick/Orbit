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
        OrbitScreen(spacing: OrbitTheme.isMac ? 20 : 24) {
            HStack {
                Text(store.liveSchedules.isEmpty ? "Your automations" : "\(store.liveSchedules.filter { $0.status == "active" }.count) active")
                    .font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
                Spacer()
                Button { editing = EditTarget(id: "new", schedule: nil) } label: {
                    Label("New task", systemImage: "plus")
                        .font(.system(size: OrbitTheme.isMac ? 12 : 14, weight: .semibold))
                        .padding(.horizontal, 15).frame(height: OrbitTheme.isMac ? 34 : 42)
                        .foregroundStyle(.black).background(.white, in: Capsule())
                }.buttonStyle(.plain)
            }
            if store.liveSchedules.isEmpty {
                OrbitEmptyState(symbol: "calendar.badge.clock", title: "A little help, on repeat",
                                detail: "Schedule a briefing, an inbox check, or anything you want Orbit to handle later.")
            } else {
                scheduleSection("Upcoming", status: "active")
                scheduleSection("Paused", status: "paused")
                scheduleSection("Finished", status: "done")
            }
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

    @ViewBuilder private func scheduleSection(_ title: String, status: String) -> some View {
        let schedules = store.liveSchedules.filter { $0.status == status }
        if !schedules.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(OrbitTheme.footnote.weight(.medium)).foregroundStyle(.secondary)
                    .padding(.horizontal, 3)
                ForEach(schedules) { schedule in row(schedule) }
            }
        }
    }

    private func row(_ s: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 10) {
                Button { editing = EditTarget(id: s.id, schedule: s) } label: {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: s.status == "paused" ? "pause" : s.status == "done" ? "checkmark" : "calendar.badge.clock")
                            .font(.system(size: OrbitTheme.isMac ? 15 : 19, weight: .medium))
                            .foregroundStyle(s.status == "active" ? Self.tint : .secondary)
                            .frame(width: OrbitTheme.isMac ? 36 : 44, height: OrbitTheme.isMac ? 36 : 44)
                            .background(Self.tint.opacity(s.status == "active" ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(s.title).font(.system(size: OrbitTheme.isMac ? 15 : 18, weight: .semibold))
                                .foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
                            Text(ScheduleText.rule(s)).font(OrbitTheme.footnote).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Menu { actions(s) } label: {
                    Image(systemName: "ellipsis").font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: OrbitTheme.isMac ? 30 : 40, height: OrbitTheme.isMac ? 30 : 40)
                        .contentShape(Circle())
                }
                .menuStyle(.button).buttonStyle(.plain).fixedSize()
                .accessibilityLabel("Options for \(s.title)")
            }
            Text(s.instructions).font(OrbitTheme.body).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            if s.source != "user" {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Added by Orbit", systemImage: "sparkles").font(OrbitTheme.footnote).foregroundStyle(.tertiary)
                    if let reason = s.originReason, !reason.isEmpty {
                        Text(reason).font(OrbitTheme.footnote).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
            }
            if s.status == "active" {
                Label(ScheduleText.next(s).replacingOccurrences(of: "Next: ", with: ""), systemImage: "arrow.turn.down.right")
                    .font(OrbitTheme.footnote.weight(.medium)).foregroundStyle(Self.tint)
            }
            if let status = s.lastStatus {
                Rectangle().fill(OrbitTheme.hairline).frame(height: 0.5)
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 7) {
                        lastBadge(status)
                        Spacer(minLength: 8)
                        if let finished = s.lastFinishedAt?.date {
                            Text(finished.formatted(date: .abbreviated, time: .shortened))
                                .font(OrbitTheme.footnote).foregroundStyle(.tertiary)
                        }
                    }
                    if let result = s.lastResult, !result.isEmpty {
                        Text(result.orbitTypographic).font(OrbitTheme.footnote).foregroundStyle(.secondary)
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(OrbitTheme.isMac ? 18 : 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(OrbitTheme.hairline, lineWidth: 0.5))
        .contextMenu { actions(s) }
    }

    @ViewBuilder private func actions(_ s: Schedule) -> some View {
        Button { runNow(s) } label: { Label("Run now", systemImage: "play") }.disabled(s.lastStatus == "running")
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
        case "running":
            HStack(spacing: 7) { ProgressView().controlSize(.mini); Text("Working on it…") }
                .font(OrbitTheme.footnote).foregroundStyle(Self.tint)
        case "ok": Label("Completed", systemImage: "checkmark.circle").font(OrbitTheme.footnote).foregroundStyle(.secondary)
        case "needs_approval": Label("Waiting for you", systemImage: "hand.raised").font(OrbitTheme.footnote).foregroundStyle(.orange)
        case "failed": Label("Couldn't finish", systemImage: "exclamationmark.circle").font(OrbitTheme.footnote).foregroundStyle(.orange)
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
            ZStack {
                Text(existing == nil ? "New task" : "Edit task")
                    .font(.system(size: 17, weight: .semibold))
                HStack {
                    Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(.secondary).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(action: save) {
                        Group {
                            if saving { ProgressView().controlSize(.small) } else { Text("Save").fontWeight(.semibold) }
                        }
                        .frame(width: 64, height: 32).foregroundStyle(.black)
                        .background(.white, in: Capsule()).opacity(valid && !saving ? 1 : 0.3)
                    }
                    .buttonStyle(.plain).disabled(!valid || saving).keyboardShortcut(.defaultAction)
                }
            }
            .font(OrbitTheme.body).padding(.horizontal, 20).padding(.vertical, 18)
            Rectangle().fill(OrbitTheme.hairline).frame(height: 0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    OrbitGroup(header: "Task") {
                        TextField("Name", text: $title)
                            .font(OrbitTheme.rowTitle).textFieldStyle(.plain)
                            .padding(.horizontal, 16).padding(.vertical, 14)
                        OrbitRowDivider(inset: 16)
                        TextField("What should Orbit do?", text: $instructions, axis: .vertical)
                            .font(OrbitTheme.body).textFieldStyle(.plain).lineLimit(3...6)
                            .padding(16).frame(minHeight: OrbitTheme.isMac ? 88 : 106, alignment: .topLeading)
                    }
                    OrbitGroup(header: "Schedule") {
                        editorRow("Repeat") {
                            Menu {
                                ForEach(Self.repeats, id: \.id) { r in Button(r.name) { repeatKind = r.id } }
                            } label: { menuLabel(Self.repeats.first { $0.id == repeatKind }?.name ?? "") }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        }
                        if repeatKind == "weekly" {
                            HStack(spacing: 6) {
                                ForEach(0..<7, id: \.self) { d in
                                    Button { if days.contains(d) { days.remove(d) } else { days.insert(d) } } label: {
                                        Text(String(ScheduleText.dayNames[d].prefix(2)))
                                            .font(.system(size: 12, weight: .medium))
                                            .frame(maxWidth: .infinity, minHeight: 34)
                                            .background(days.contains(d) ? Color.white : Color.white.opacity(0.05), in: Capsule())
                                            .foregroundStyle(days.contains(d) ? Color.black : .secondary)
                                    }
                                    .buttonStyle(.plain).accessibilityLabel(ScheduleText.dayNames[d])
                                    .accessibilityAddTraits(days.contains(d) ? [.isSelected] : [])
                                }
                            }.padding(.horizontal, 14).padding(.bottom, 12)
                        }
                        OrbitRowDivider(inset: 16)
                        switch repeatKind {
                        case "once":
                            editorRow("When") {
                                DatePicker("When", selection: $runAt, in: Date()..., displayedComponents: [.date, .hourAndMinute]).labelsHidden()
                            }
                        case "interval":
                            editorRow("Every") { Stepper("\(intervalHours) hours", value: $intervalHours, in: 1...24) }
                        default:
                            editorRow("Time") { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute).labelsHidden() }
                        }
                        OrbitRowDivider(inset: 16)
                        editorRow("Time zone") {
                            Menu {
                                ForEach(Self.zones, id: \.self) { z in Button(ScheduleText.zoneName(z)) { timezone = z } }
                            } label: { menuLabel(ScheduleText.zoneName(timezone)) }
                            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
                        }
                    }
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "clock").padding(.top, 1)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(schedulePreview).foregroundStyle(.secondary)
                            Text("Replies in chat · approvals stay on").foregroundStyle(.tertiary)
                        }
                    }
                    .font(OrbitTheme.footnote).padding(.horizontal, 4)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle").font(OrbitTheme.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(20)
            }
        }
        .frame(minWidth: OrbitTheme.isMac ? 420 : nil, idealWidth: 480, minHeight: OrbitTheme.isMac ? 470 : nil)
        .background(Color(white: 0.055).ignoresSafeArea())
        .presentationDetents([.large]).presentationDragIndicator(.visible)
        .preferredColorScheme(.dark).onAppear(perform: load)
    }

    private var schedulePreview: String {
        switch repeatKind {
        case "once": return "Once, \(runAt.formatted(date: .abbreviated, time: .shortened))"
        case "interval": return "Every \(intervalHours) hour\(intervalHours == 1 ? "" : "s")"
        case "daily": return "Every day at \(time.formatted(date: .omitted, time: .shortened))"
        case "weekdays": return "Every weekday at \(time.formatted(date: .omitted, time: .shortened))"
        default: return "\(days.sorted().map { ScheduleText.dayNames[$0] }.joined(separator: ", ")) at \(time.formatted(date: .omitted, time: .shortened))"
        }
    }

    private func editorRow<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        HStack(spacing: 16) {
            Text(title).font(OrbitTheme.body).foregroundStyle(.secondary)
            Spacer(minLength: 8)
            content().font(OrbitTheme.body).tint(.white)
        }
        .padding(.horizontal, 16).frame(minHeight: OrbitTheme.isMac ? 46 : 54)
    }

    private func menuLabel(_ text: String) -> some View {
        HStack {
            Text(text).foregroundStyle(.primary)
            Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
    }

    private func load() {
        guard let s = existing else { return }
        title = s.title; instructions = s.instructions; repeatKind = s.repeat
        if let hm = s.timeOfDay, let d = ScheduleText.hmDate(hm) { time = d }
        if let at = s.runAt?.date { runAt = at }
        days = Set(s.dayList); intervalHours = s.intervalHours ?? 4
        timezone = s.timezone
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
            timezone: timezone)
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
