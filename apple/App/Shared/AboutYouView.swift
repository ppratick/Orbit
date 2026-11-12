import OrbitKit
import SwiftUI

/// Settings → About you. One page of fields the user fills in directly; every field saves as you
/// type and syncs to the other devices. Facts Orbit noticed in conversation wait at the top for
/// review and change nothing until accepted.
struct AboutYouContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var resolving: Set<String> = []

    static let tint = Color(red: 0.58, green: 0.42, blue: 0.98)

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.sectionSpacing) {
            OrbitHero(symbol: "person.crop.circle.fill", tint: Self.tint, title: "About you",
                      detail: "Optional. Orbit reads this before it replies, so it can skip the questions it already knows the answers to.")
            if !store.pendingProfileSuggestions.isEmpty {
                OrbitGroup(header: "Suggested from your chats",
                           footer: "Orbit noticed these in conversation. Nothing changes in your profile unless you add it.") {
                    ForEach(Array(store.pendingProfileSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                        if index > 0 { OrbitRowDivider(inset: OrbitTheme.rowHorizontal) }
                        suggestionRow(suggestion)
                    }
                }
                .transition(.opacity)
            }
            OrbitGroup(header: "Basics") {
                ProfileField(id: "name")
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "timezone", options: Self.timeZoneOptions)
            }
            OrbitGroup(header: "School & work") {
                ProfileField(id: "school")
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "year", options: ProfileSection.yearOptions)
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "work")
            }
            OrbitGroup(header: "Routines") {
                ProfileField(id: "wake", isTime: true)
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "bedtime", isTime: true)
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "routines")
            }
            OrbitGroup(header: "Goals & interests") { ProfileField(id: "goals") }
            OrbitGroup(header: "Anything else",
                       footer: "Saves as you go and syncs to your devices. What you set here takes priority over anything Orbit infers.") {
                ProfileField(id: "context")
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.pendingProfileSuggestions.map(\.id))
    }

    /// This device's zone first, then common ones, by their everyday names ("Eastern Time").
    static var timeZoneOptions: [String] {
        let ids = ["Pacific/Honolulu", "America/Anchorage", "America/Los_Angeles", "America/Denver", "America/Phoenix",
                   "America/Chicago", "America/New_York", "Europe/London", "Europe/Paris", "Asia/Kolkata",
                   "Asia/Shanghai", "Asia/Tokyo", "Australia/Sydney"]
        func name(_ zone: TimeZone) -> String {
            zone.identifier == "America/Phoenix" ? "Arizona Time"
                : zone.localizedName(for: .generic, locale: .current) ?? zone.identifier
        }
        var out = [name(.current)]
        for id in ids { if let z = TimeZone(identifier: id), !out.contains(name(z)) { out.append(name(z)) } }
        return out
    }

    private func suggestionRow(_ suggestion: ProfileSuggestion) -> some View {
        let busy = resolving.contains(suggestion.id)
        return VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 8 : 10) {
            HStack(spacing: 6) {
                OrbitBadge(text: ProfileSection.title(for: suggestion.section), tint: Self.tint)
                Spacer(minLength: 6)
                Text(suggestion.createdAt.date.formatted(.relative(presentation: .named)))
                    .font(OrbitTheme.footnote).foregroundStyle(.tertiary)
            }
            Text(suggestion.content.orbitTypographic).font(OrbitTheme.body)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Dismiss") { resolve(suggestion, accept: false) }
                    .buttonStyle(OrbitButtonStyle(kind: .secondary, fullWidth: false))
                Button { resolve(suggestion, accept: true) } label: {
                    Label("Add", systemImage: "plus")
                }
                .accessibilityLabel("Add to \(ProfileSection.title(for: suggestion.section))")
                .buttonStyle(OrbitButtonStyle(kind: .primary, fullWidth: false))
            }
            .disabled(busy)
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical + 2)
    }

    private func resolve(_ suggestion: ProfileSuggestion, accept: Bool) {
        resolving.insert(suggestion.id)
        Task {
            await model.resolveSuggestion(suggestion, accept: accept)
            resolving.remove(suggestion.id)
        }
    }
}

/// One About you field, edited in place. Short fields sit beside their label; notes get a
/// multi-line box. Saves a moment after typing stops, on Return, and when focus leaves.
struct ProfileField: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    let id: String
    /// Ready-made choices: the field becomes a pick list (time zone, year).
    var options: [String] = []
    /// The field holds a time of day, picked with a time picker (wake-up, bedtime).
    var isTime = false
    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @State private var error: String?
    @FocusState private var focused: Bool

    private var info: (id: String, title: String, question: String, symbol: String, multiline: Bool) {
        ProfileSection.catalog.first { $0.id == id } ?? (id, id.capitalized, "", "person.fill", false)
    }
    private var stored: String { store.profileText(id) }
    private var changed: Bool { trimmed(text) != trimmed(stored) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if info.multiline {
                TextField(info.question, text: $text, axis: .vertical)
                    .lineLimit(2...8)
                    .textFieldStyle(.plain).font(OrbitTheme.body)
                    .focused($focused)
            } else {
                HStack(spacing: 12) {
                    Text(info.title).font(OrbitTheme.rowTitle)
                        .frame(width: OrbitTheme.isMac ? 82 : 96, alignment: .leading)
                    if !options.isEmpty { optionPicker } else if isTime { timePicker } else {
                        TextField(info.question, text: $text)
                            .textFieldStyle(.plain).font(OrbitTheme.body)
                            .focused($focused)
                            .onSubmit(saveNow)
                            #if os(iOS)
                            .textInputAutocapitalization(id == "name" ? .words : .sentences)
                            #endif
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(OrbitTheme.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.isMac ? 10 : 13)
        .frame(minHeight: OrbitTheme.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { if options.isEmpty, !isTime { focused = true } }
        .accessibilityElement(children: .contain)
        .onAppear { text = stored }
        // Another device changed it: show the new value unless the user is mid-edit here.
        .onChange(of: stored) { _, new in if !focused, pending == nil { text = new } }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: focused) { _, isFocused in if !isFocused { saveNow() } }
        .onDisappear { if changed { saveNow() } }
    }

    private func set(_ value: String) {
        text = value
        saveNow()
    }

    /// A menu of choices; an unknown saved value (typed before, or synced) still shows and stays selectable.
    private var optionPicker: some View {
        Menu {
            ForEach(options.contains(text) || trimmed(text).isEmpty ? options : [text] + options, id: \.self) { option in
                Button { set(option) } label: {
                    if option == text { Label(option, systemImage: "checkmark") } else { Text(option) }
                }
            }
            if !trimmed(text).isEmpty {
                Divider()
                Button("Clear", role: .destructive) { set("") }
            }
        } label: {
            HStack(spacing: 6) {
                Text(trimmed(text).isEmpty ? info.question : text)
                    .foregroundStyle(trimmed(text).isEmpty ? Color.secondary.opacity(0.7) : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: OrbitTheme.isMac ? 10 : 12, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .font(OrbitTheme.body)
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(info.title)
        .accessibilityValue(trimmed(text).isEmpty ? "Not set" : text)
    }

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "h:mm a"
        return f
    }()

    /// Empty until set; then a native time picker plus a clear button.
    @ViewBuilder private var timePicker: some View {
        if let date = Self.timeFormat.date(from: trimmed(text)) {
            DatePicker(info.title, selection: Binding(get: { date }, set: { set(Self.timeFormat.string(from: $0)) }),
                       displayedComponents: .hourAndMinute)
                .labelsHidden()
                #if os(macOS)
                .datePickerStyle(.stepperField)
                #endif
            Spacer(minLength: 4)
            Button { set("") } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain).accessibilityLabel("Clear \(info.title.lowercased())")
        } else {
            Button {
                let defaultTime = id == "bedtime" ? "11:00 PM" : "7:00 AM"
                set(defaultTime)
            } label: {
                HStack {
                    Text("Add").foregroundStyle(AboutYouContent.tint).fontWeight(.semibold)
                    Spacer(minLength: 0)
                }
                .font(OrbitTheme.body).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Add \(info.title.lowercased()) time")
        }
    }

    private func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func scheduleSave() {
        pending?.cancel()
        guard changed else { pending = nil; return }
        pending = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            await save()
        }
    }

    private func saveNow() {
        pending?.cancel()
        guard changed else { pending = nil; return }
        pending = Task { await save() }
    }

    private func save() async {
        let value = text
        let failure = await model.saveProfile(section: id, content: value)
        guard !Task.isCancelled else { return } // a newer save superseded this one
        error = failure
        pending = nil
    }
}
