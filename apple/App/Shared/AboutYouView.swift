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
                ProfileField(id: "timezone", fill: Self.currentTimeZone)
            }
            OrbitGroup(header: "School & work") {
                ProfileField(id: "school")
                OrbitRowDivider(inset: OrbitTheme.rowHorizontal)
                ProfileField(id: "work")
            }
            ForEach(ProfileSection.catalog.filter(\.multiline), id: \.id) { field in
                OrbitGroup(header: field.title, footer: field.id == "context"
                           ? "Saves as you type and syncs to your devices. What you write here takes priority over anything Orbit infers." : nil) {
                    ProfileField(id: field.id)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.pendingProfileSuggestions.map(\.id))
    }

    /// e.g. "Eastern Time".
    static var currentTimeZone: String {
        TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier
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
    /// A suggested value offered as a one-tap button while the field is empty (time zone).
    var fill: String? = nil
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
                    TextField(info.question, text: $text)
                        .textFieldStyle(.plain).font(OrbitTheme.body)
                        .focused($focused)
                        .onSubmit(saveNow)
                        #if os(iOS)
                        .textInputAutocapitalization(id == "name" ? .words : .sentences)
                        #endif
                    if let fill, trimmed(text).isEmpty {
                        Button("Use current") {
                            text = fill
                            saveNow()
                        }
                        .buttonStyle(.plain).font(OrbitTheme.rowSubtitle.weight(.semibold))
                        .foregroundStyle(AboutYouContent.tint)
                        .fixedSize()
                        .help(fill)
                        .accessibilityLabel("Use current time zone, \(fill)")
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
        .onTapGesture { focused = true }
        .accessibilityElement(children: .contain)
        .onAppear { text = stored }
        // Another device changed it: show the new value unless the user is mid-edit here.
        .onChange(of: stored) { _, new in if !focused, pending == nil { text = new } }
        .onChange(of: text) { _, _ in scheduleSave() }
        .onChange(of: focused) { _, isFocused in if !isFocused { saveNow() } }
        .onDisappear { if changed { saveNow() } }
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
