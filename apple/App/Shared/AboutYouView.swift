import OrbitKit
import SwiftUI

/// Settings → About you. Optional sections the user writes in their own words, plus facts Orbit
/// noticed in conversation waiting for review. The profile changes only when the user edits it
/// or accepts a suggestion.
struct AboutYouContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    @State private var editing: EditingSection?
    @State private var resolving: Set<String> = []

    struct EditingSection: Identifiable { let id: String }
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
            OrbitGroup(header: "Your profile",
                       footer: "Synced to your devices. What you write here takes priority over anything Orbit infers.") {
                ForEach(Array(ProfileSection.catalog.enumerated()), id: \.element.id) { index, section in
                    if index > 0 { OrbitRowDivider() }
                    sectionRow(section)
                }
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.pendingProfileSuggestions.map(\.id))
        .sheet(item: $editing) { target in
            ProfileSectionEditor(sectionId: target.id, initialText: store.profileText(target.id)) { editing = nil }
        }
    }

    private func sectionRow(_ section: (id: String, title: String, question: String, symbol: String)) -> some View {
        let text = store.profileText(section.id).trimmingCharacters(in: .whitespacesAndNewlines)
        return Button { editing = EditingSection(id: section.id) } label: {
            HStack(alignment: text.isEmpty ? .center : .top, spacing: 12) {
                OrbitIconTile(symbol: section.symbol, tint: text.isEmpty ? Color(white: 0.3) : Self.tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text(section.title).font(OrbitTheme.rowTitle)
                    Text(text.isEmpty ? section.question : text.replacingOccurrences(of: "\n", with: " · "))
                        .font(OrbitTheme.rowSubtitle)
                        .foregroundStyle(text.isEmpty ? .tertiary : .secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 8)
                Image(systemName: text.isEmpty ? "plus" : "chevron.right")
                    .font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold)).foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity)
            }
            .padding(.horizontal, OrbitTheme.rowHorizontal)
            .padding(.vertical, OrbitTheme.rowVertical)
            .frame(minHeight: OrbitTheme.rowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(OrbitRowButtonStyle())
        .accessibilityLabel(section.title)
        .accessibilityValue(text.isEmpty ? "Empty" : text)
        .accessibilityHint(text.isEmpty ? "Add details" : "Edit")
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

/// Sheet for writing one About you section.
struct ProfileSectionEditor: View {
    @EnvironmentObject var model: AppModel
    let sectionId: String
    let initialText: String
    var close: () -> Void
    @State private var text = ""
    @State private var saving = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var info: (id: String, title: String, question: String, symbol: String) {
        ProfileSection.catalog.first { $0.id == sectionId } ?? (sectionId, sectionId.capitalized, "", "person.fill")
    }
    private var unchanged: Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines) == initialText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: OrbitTheme.isMac ? 16 : 20) {
            HStack {
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(info.title).font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: .semibold))
                Spacer()
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small) } else { Text("Save").fontWeight(.semibold) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(unchanged ? Color.secondary : Color.white)
                .disabled(unchanged || saving)
                .keyboardShortcut(.defaultAction)
            }
            .font(OrbitTheme.body)

            HStack(alignment: .top, spacing: 12) {
                OrbitIconTile(symbol: info.symbol, tint: AboutYouContent.tint)
                Text(info.question).font(OrbitTheme.body).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(5...14).textFieldStyle(.plain).font(OrbitTheme.body).focused($focused)
                .padding(14)
                .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 10 : 16, style: .continuous)
                    .stroke(focused ? Color.white.opacity(0.2) : OrbitTheme.hairline, lineWidth: focused ? 1 : 0.5))
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(OrbitTheme.footnote).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Short notes are fine — one idea per line works best. Leave it empty to skip this section.")
                .font(OrbitTheme.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(OrbitTheme.isMac ? 20 : 22)
        .frame(minWidth: 340, idealWidth: 460, minHeight: OrbitTheme.isMac ? 340 : nil)
        .background(Color(white: 0.06).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(!unchanged)
        .preferredColorScheme(.dark)
        .onAppear {
            text = initialText
            focused = true
        }
    }

    private var placeholder: String {
        switch sectionId {
        case "basics": return "e.g. I’m Sam. Eastern time."
        case "work": return "e.g. Junior studying CS at CMU"
        case "people": return "e.g. Maya — my sister, lives in Chicago"
        case "routines": return "e.g. Gym before class on weekdays"
        case "goals": return "e.g. Land a summer internship"
        default: return "Anything else worth knowing"
        }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            error = await model.saveProfile(section: sectionId, content: text)
            saving = false
            if error == nil { close() }
        }
    }
}
