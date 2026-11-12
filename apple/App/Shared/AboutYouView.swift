import OrbitKit
import SwiftUI

/// Settings → About you. A plain form: every field has a clear label above its own box, with an
/// example of what to write. Fields save as you go and sync to your other devices. Facts Orbit
/// noticed in conversation wait at the top for review and change nothing until accepted.
struct AboutYouContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var resolving: Set<String> = []

    static let tint = Color(red: 0.58, green: 0.42, blue: 0.98)

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.sectionSpacing) {
            OrbitHero(symbol: "person.crop.circle.fill", tint: Self.tint, title: "About you",
                      detail: "All optional. Orbit reads this before it replies, so it doesn’t have to ask.")
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
            FormCard(title: "Your name", symbol: "person.fill") {
                HStack(alignment: .top, spacing: 12) {
                    ProfileField(id: "first_name")
                    ProfileField(id: "last_name")
                }
                ProfileField(id: "nickname")
            }
            FormCard(title: "Location", symbol: "globe.americas.fill") {
                ProfileField(id: "timezone", options: Self.timeZoneOptions)
            }
            FormCard(title: "School & work", symbol: "graduationcap.fill") {
                ProfileField(id: "school")
                ProfileField(id: "major")
                HStack(alignment: .top, spacing: 12) {
                    ProfileField(id: "year", options: ProfileSection.yearOptions)
                    ProfileField(id: "work", options: ProfileSection.workOptions)
                }
            }
            FormCard(title: "More about you", symbol: "star.fill") {
                ProfileField(id: "goals")
                ProfileField(id: "context")
            }
            Text("Saves as you go and syncs to your devices. What you enter here takes priority over anything Orbit infers.")
                .font(OrbitTheme.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, OrbitTheme.rowHorizontal)
                .padding(.top, -OrbitTheme.sectionSpacing / 2)
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

/// A titled card holding a group of labeled fields.
private struct FormCard<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 12 : 16) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold))
                    .foregroundStyle(AboutYouContent.tint)
                Text(title).font(.system(size: OrbitTheme.isMac ? 13 : 16, weight: .semibold))
            }
            .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(OrbitTheme.isMac ? 16 : 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
    }
}

/// One labeled field in its own box: a text box, a notes box, or a dropdown when it has options.
/// Typed fields save a moment after typing stops, on Return, and when focus leaves.
struct ProfileField: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    let id: String
    /// Ready-made choices: the field becomes a dropdown.
    var options: [String] = []
    @State private var text = ""
    @State private var pending: Task<Void, Never>?
    @State private var error: String?
    @FocusState private var focused: Bool

    private var info: (id: String, title: String, question: String, symbol: String, multiline: Bool) {
        ProfileSection.catalog.first { $0.id == id } ?? (id, id.capitalized, "", "person.fill", false)
    }
    private var stored: String { store.profileText(id) }
    private var changed: Bool { trimmed(text) != trimmed(stored) }
    private var boxRadius: CGFloat { OrbitTheme.isMac ? 8 : 12 }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(info.title)
                .font(OrbitTheme.rowSubtitle.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Group {
                if !options.isEmpty {
                    dropdown
                } else if info.multiline {
                    TextField(info.question, text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .focused($focused)
                } else {
                    TextField(info.question, text: $text)
                        .focused($focused)
                        .onSubmit(saveNow)
                        #if os(iOS)
                        .textInputAutocapitalization(["first_name", "last_name", "nickname", "school"].contains(id) ? .words : .sentences)
                        #endif
                        .autocorrectionDisabled(["first_name", "last_name", "nickname"].contains(id))
                }
            }
            .textFieldStyle(.plain).font(OrbitTheme.body)
            .padding(.horizontal, OrbitTheme.isMac ? 10 : 12)
            .padding(.vertical, OrbitTheme.isMac ? 8 : 11)
            .frame(maxWidth: .infinity, minHeight: OrbitTheme.isMac ? 32 : 44, alignment: .leading)
            .background(OrbitTheme.raisedHigh, in: RoundedRectangle(cornerRadius: boxRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: boxRadius, style: .continuous)
                .stroke(focused ? AboutYouContent.tint.opacity(0.7) : Color.white.opacity(0.08), lineWidth: focused ? 1.2 : 0.5))
            .contentShape(RoundedRectangle(cornerRadius: boxRadius, style: .continuous))
            .onTapGesture { if options.isEmpty { focused = true } }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(OrbitTheme.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { text = stored }
        // Another device changed it: show the new value unless the user is mid-edit here.
        .onChange(of: stored) { _, new in if !focused, pending == nil { text = new } }
        .onChange(of: text) { _, _ in if options.isEmpty { scheduleSave() } }
        .onChange(of: focused) { _, isFocused in if !isFocused { saveNow() } }
        .onDisappear { if changed { saveNow() } }
    }

    /// A menu of choices; a saved value that isn't one of them still shows and stays selectable.
    private var dropdown: some View {
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
                Image(systemName: "chevron.down").font(.system(size: OrbitTheme.isMac ? 10 : 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel(info.title)
        .accessibilityValue(trimmed(text).isEmpty ? "Not set" : text)
    }

    private func set(_ value: String) {
        text = value
        saveNow()
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
