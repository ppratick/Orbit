import SwiftUI

// Native Liquid Glass on current systems; readable material on older OS versions.
struct OrbitGlassModifier<S: Shape>: ViewModifier {
    let shape: S
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @ViewBuilder func body(content: Content) -> some View {
        if reduceTransparency {
            content.background(OrbitPalette.surface, in: shape)
                .overlay(shape.stroke(Color.primary.opacity(0.12), lineWidth: 1))
        } else if #available(iOS 26.0, macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: shape)
                .overlay(shape.stroke(
                    LinearGradient(colors: [.white.opacity(0.42), .white.opacity(0.06), .white.opacity(0.22)], startPoint: .topLeading, endPoint: .bottomTrailing),
                    lineWidth: 0.75
                ).allowsHitTesting(false))
                .shadow(color: .black.opacity(0.22), radius: 12, y: 6)
        } else {
            content.background(.regularMaterial, in: shape)
                .overlay(shape.stroke(Color.white.opacity(0.18), lineWidth: 0.5))
        }
    }
}

extension View {
    func orbitGlass<S: Shape>(in shape: S, interactive: Bool = false) -> some View {
        modifier(OrbitGlassModifier(shape: shape, interactive: interactive))
    }

    @ViewBuilder func orbitInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

enum OrbitPalette {
    static let surface = Color.black
    static let sidebar = Color(white: 0.09)
    static let assistantBubble = Color(red: 0.125, green: 0.125, blue: 0.125)
    static let userBubble = Color(red: 0.145, green: 0.290, blue: 0.620)
}

struct OrbitBackdrop: View {
    var body: some View { OrbitPalette.surface.ignoresSafeArea() }
}

struct OrbitGlassGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) { content() }
        } else {
            content()
        }
    }
}

struct OrbitCircleButton: View {
    let symbol: String
    let label: String
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .orbitGlass(in: Circle(), interactive: true)
        .accessibilityLabel(label)
    }
}

struct OrbitEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: OrbitTheme.isMac ? 8 : 10) {
            Image(systemName: symbol).font(.system(size: OrbitTheme.isMac ? 22 : 26, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: OrbitTheme.isMac ? 52 : 64, height: OrbitTheme.isMac ? 52 : 64)
                .background(OrbitTheme.raised, in: Circle())
                .overlay(Circle().stroke(OrbitTheme.hairline, lineWidth: 0.5))
                .padding(.bottom, 4)
            Text(title).font(.system(size: OrbitTheme.isMac ? 15 : 18, weight: .semibold))
            if !detail.isEmpty {
                Text(detail).font(OrbitTheme.isMac ? .system(size: 12.5) : .system(size: 15)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 300)
            }
        }
        .padding(.vertical, OrbitTheme.isMac ? 36 : 48).frame(maxWidth: .infinity)
    }
}

struct OrbitMenuButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                Capsule().fill(.white).frame(width: 21, height: 2.5)
                Capsule().fill(.white).frame(width: 13, height: 2.5)
            }
            .frame(width: 46, height: 46)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .orbitGlass(in: Circle(), interactive: true)
        .accessibilityLabel("Open sidebar")
        .accessibilityIdentifier("orbit.sidebar.open")
    }
}

// MARK: - Orbit design system (everything outside the chat)
//
// Glass is reserved for floating controls (header buttons, the add button). Content sits on
// solid, slightly raised surfaces grouped like native inset lists, which reads better on black.

enum OrbitTheme {
    #if os(macOS)
    static let isMac = true
    #else
    static let isMac = false
    #endif

    // Surfaces
    static let raised = Color(white: 0.105)          // grouped section background
    static let raisedHigh = Color(white: 0.155)      // inset detail panels, fields inside sections
    static let selection = Color.white.opacity(0.085)
    static let hairline = Color.white.opacity(0.075)

    // Spacing & shape
    static let pageWidth: CGFloat = 640
    static let pagePadding: CGFloat = isMac ? 28 : 20
    static let sectionSpacing: CGFloat = isMac ? 26 : 30
    static let sectionRadius: CGFloat = isMac ? 14 : 22
    static let rowHorizontal: CGFloat = isMac ? 14 : 16
    static let rowVertical: CGFloat = isMac ? 9 : 13
    static let rowMinHeight: CGFloat = isMac ? 40 : 52
    static let tileSize: CGFloat = isMac ? 26 : 32
    static let controlHeight: CGFloat = isMac ? 34 : 50

    // Type
    static let rowTitle: Font = isMac ? .system(size: 13, weight: .medium) : .system(size: 16, weight: .medium)
    static let rowSubtitle: Font = isMac ? .system(size: 11.5) : .system(size: 13.5)
    static let body: Font = isMac ? .system(size: 13) : .system(size: 16)
    static let sectionHeader: Font = isMac ? .system(size: 11, weight: .semibold) : .system(size: 13, weight: .semibold)
    static let footnote: Font = isMac ? .system(size: 11) : .system(size: 13)
    static let pageTitle: Font = .system(size: isMac ? 22 : 28, weight: .bold, design: .rounded)
}

/// A rounded-square symbol tile, like the icons in iOS Settings.
struct OrbitIconTile: View {
    let symbol: String
    var tint: Color = .gray
    var size: CGFloat = OrbitTheme.tileSize
    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [tint.opacity(0.95), tint.opacity(0.72)], startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

/// A grouped section: optional small header above, rows on a raised surface, optional footer below.
struct OrbitGroup<Content: View>: View {
    var header: String? = nil
    var footer: String? = nil
    var trailingHeader: AnyView? = nil
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if header != nil || trailingHeader != nil {
                HStack(alignment: .firstTextBaseline) {
                    if let header {
                        Text(header.uppercased()).font(OrbitTheme.sectionHeader).tracking(0.6).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    trailingHeader
                }
                .padding(.horizontal, OrbitTheme.rowHorizontal)
            }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
            if let footer {
                Text(footer).font(OrbitTheme.footnote).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, OrbitTheme.rowHorizontal)
            }
        }
    }
}

/// Divider inset to line up with row text (past the icon tile), like a native grouped list.
struct OrbitRowDivider: View {
    var inset: CGFloat = OrbitTheme.rowHorizontal + OrbitTheme.tileSize + 12
    var body: some View {
        Rectangle().fill(OrbitTheme.hairline).frame(height: 0.5).padding(.leading, inset)
    }
}

enum OrbitRowAccessory {
    case none, chevron, external, value(String), add
}

/// The standard row: icon tile, title, optional subtitle, trailing accessory.
struct OrbitRow<Trailing: View>: View {
    var symbol: String? = nil
    var tint: Color = .gray
    let title: String
    var subtitle: String? = nil
    var accessory: OrbitRowAccessory = .none
    var titleColor: Color = .primary
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 12) {
            if let symbol { OrbitIconTile(symbol: symbol, tint: tint) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(OrbitTheme.rowTitle).foregroundStyle(titleColor)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
            trailing()
            switch accessory {
            case .none: EmptyView()
            case .chevron: Image(systemName: "chevron.right").font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold)).foregroundStyle(.tertiary)
            case .external: Image(systemName: "arrow.up.right").font(.system(size: OrbitTheme.isMac ? 11 : 13, weight: .semibold)).foregroundStyle(.tertiary)
            case .add: Image(systemName: "plus").font(.system(size: OrbitTheme.isMac ? 12 : 15, weight: .semibold)).foregroundStyle(.secondary)
            case .value(let v): Text(v).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.rowVertical)
        .frame(minHeight: OrbitTheme.rowMinHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
}

extension OrbitRow where Trailing == EmptyView {
    init(symbol: String? = nil, tint: Color = .gray, title: String, subtitle: String? = nil, accessory: OrbitRowAccessory = .none, titleColor: Color = .primary) {
        self.init(symbol: symbol, tint: tint, title: title, subtitle: subtitle, accessory: accessory, titleColor: titleColor) { EmptyView() }
    }
}

/// Row button feedback: a soft highlight on press, matching native list rows.
struct OrbitRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? OrbitTheme.selection : .clear)
            .contentShape(Rectangle())
    }
}

/// Segmented control with a sliding indicator.
struct OrbitSegmented: View {
    let titles: [String]
    @Binding var selection: Int
    var badges: [Int: Int] = [:]
    @Namespace private var indicator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(titles.indices, id: \.self) { index in
                Button {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.85)) { selection = index }
                } label: {
                    HStack(spacing: 5) {
                        Text(titles[index])
                        if let count = badges[index], count > 0 {
                            Text("\(count)").font(.system(size: OrbitTheme.isMac ? 10 : 11, weight: .bold)).monospacedDigit()
                                .padding(.horizontal, 5).frame(minWidth: 16, minHeight: 16)
                                .background(Color.orange, in: Capsule()).foregroundStyle(.black)
                        }
                    }
                    .font(.system(size: OrbitTheme.isMac ? 12 : 14, weight: selection == index ? .semibold : .medium))
                    .foregroundStyle(selection == index ? .primary : .secondary)
                    .frame(maxWidth: .infinity, minHeight: OrbitTheme.isMac ? 26 : 34)
                    .background {
                        if selection == index {
                            Capsule().fill(Color.white.opacity(0.13))
                                .matchedGeometryEffect(id: "segment", in: indicator)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == index ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(OrbitTheme.raised, in: Capsule())
        .overlay(Capsule().stroke(OrbitTheme.hairline, lineWidth: 0.5))
    }
}

/// Primary / secondary / destructive full-width buttons used on every non-chat screen.
struct OrbitButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive }
    var kind: Kind = .primary
    var fullWidth = true
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: OrbitTheme.isMac ? 13 : 16, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, OrbitTheme.isMac ? 14 : 20)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: OrbitTheme.controlHeight)
            .background(background, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 14, style: .continuous))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: configuration.isPressed)
            .contentShape(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 9 : 14, style: .continuous))
    }
    private var foreground: Color {
        switch kind {
        case .primary: return .black
        case .secondary: return .white
        case .destructive: return Color(red: 1, green: 0.42, blue: 0.4)
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return .white
        case .secondary: return Color.white.opacity(0.1)
        case .destructive: return Color(red: 1, green: 0.3, blue: 0.28).opacity(0.14)
        }
    }
}

extension ButtonStyle where Self == OrbitButtonStyle {
    static var orbitPrimary: OrbitButtonStyle { OrbitButtonStyle(kind: .primary) }
    static var orbitSecondary: OrbitButtonStyle { OrbitButtonStyle(kind: .secondary) }
    static var orbitDestructive: OrbitButtonStyle { OrbitButtonStyle(kind: .destructive) }
}

/// A labeled text field row for forms inside an OrbitSection.
struct OrbitFieldRow: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var secure = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(OrbitTheme.rowSubtitle.weight(.medium)).foregroundStyle(.secondary)
            Group {
                if secure { SecureField(prompt, text: $text) } else { TextField(prompt, text: $text) }
            }
            .font(OrbitTheme.body).textFieldStyle(.plain).autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
        }
        .padding(.horizontal, OrbitTheme.rowHorizontal)
        .padding(.vertical, OrbitTheme.isMac ? 9 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Small rounded label for statuses and counts.
struct OrbitBadge: View {
    let text: String
    var tint: Color = .secondary
    var body: some View {
        Text(text)
            .font(.system(size: OrbitTheme.isMac ? 10.5 : 12, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(tint.opacity(0.14), in: Capsule())
    }
}

/// Summary number at the top of a page (Activity).
struct OrbitStatTile: View {
    let value: Int
    let label: String
    var tint: Color = .white
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(value)").font(.system(size: OrbitTheme.isMac ? 22 : 28, weight: .semibold, design: .rounded)).monospacedDigit()
                .foregroundStyle(value > 0 ? tint : .secondary)
                .contentTransition(.numericText())
            Text(label).font(OrbitTheme.rowSubtitle).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, OrbitTheme.rowHorizontal).padding(.vertical, OrbitTheme.isMac ? 12 : 14)
        .background(OrbitTheme.raised, in: RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitTheme.sectionRadius, style: .continuous).stroke(OrbitTheme.hairline, lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

/// Scrolling page for non-chat screens: centered column with consistent rhythm.
struct OrbitScreen<Content: View>: View {
    var spacing: CGFloat = OrbitTheme.sectionSpacing
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content() }
                .frame(maxWidth: OrbitTheme.pageWidth)
                .padding(.horizontal, OrbitTheme.pagePadding)
                .padding(.top, OrbitTheme.isMac ? 8 : 6)
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }
}

/// Hero at the top of a detail screen (integrations, assistant).
struct OrbitHero: View {
    let symbol: String
    let tint: Color
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: OrbitTheme.isMac ? 10 : 14) {
            OrbitIconTile(symbol: symbol, tint: tint, size: OrbitTheme.isMac ? 52 : 64)
                .shadow(color: tint.opacity(0.35), radius: 18, y: 6)
            Text(title).font(OrbitTheme.pageTitle)
            Text(detail).font(OrbitTheme.isMac ? .system(size: 13) : .system(size: 15)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, OrbitTheme.isMac ? 6 : 10)
    }
}

extension String {
    /// Straight quotes from server summaries rendered as typographic quotes for display.
    var orbitTypographic: String {
        var out = ""
        var open = true
        for ch in self {
            if ch == "\"" { out.append(open ? "\u{201C}" : "\u{201D}"); open.toggle() }
            else if ch == "'" { out.append("\u{2019}") }
            else { out.append(ch) }
        }
        return out
    }
}

/// Provider visuals, shared by Settings and anywhere accounts are listed.
enum OrbitProvider {
    /// Server keys vary ("icloud_mail"); map them to one visual identity.
    static func key(_ provider: String) -> String {
        let p = provider.lowercased()
        if p.hasPrefix("icloud") { return "icloud" }
        if p.hasPrefix("google") || p == "gmail" { return "google" }
        return p
    }
    static func symbol(_ provider: String) -> String {
        switch key(provider) {
        case "google": return "envelope.fill"
        case "icloud": return "icloud.fill"
        case "github": return "chevron.left.forwardslash.chevron.right"
        case "canvas": return "graduationcap.fill"
        case "chatgpt": return "sparkle"
        default: return "link"
        }
    }
    static func tint(_ provider: String) -> Color {
        switch key(provider) {
        case "google": return Color(red: 0.90, green: 0.30, blue: 0.24)
        case "icloud": return Color(red: 0.25, green: 0.56, blue: 0.98)
        case "github": return Color(white: 0.38)
        case "canvas": return Color(red: 0.89, green: 0.24, blue: 0.20).opacity(0.9)
        case "chatgpt": return Color(red: 0.12, green: 0.67, blue: 0.55)
        default: return .gray
        }
    }
    static func name(_ provider: String) -> String {
        switch key(provider) {
        case "google": return "Google"
        case "icloud": return "iCloud Mail"
        case "github": return "GitHub"
        case "canvas": return "Canvas"
        case "chatgpt": return "ChatGPT"
        default: return provider.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

// SwiftUI equivalents of the supplied liquid-button and animated chat references.
struct OrbitLiquidButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.white)
            .padding(.horizontal, 14).frame(minHeight: 40)
            .orbitGlass(in: Capsule(), interactive: true)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: configuration.isPressed)
    }
}

struct OrbitChatWelcome: View {
    var choose: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    private let suggestions: [(String, String, String)] = [
        ("sun.max", "Plan my day", "Help me plan my day using my calendar and reminders."),
        ("tray", "Check my inbox", "Check my connected email accounts for anything that needs my attention."),
        ("square.and.pencil", "Draft a reply", "Help me draft a reply."),
        ("brain", "Think it through", "/sol Help me think through a decision.")
    ]
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "sparkles")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 66, height: 66).orbitGlass(in: Circle())
            VStack(spacing: 12) {
                Text("How can I help today?")
                    .font(.system(size: 30, weight: .medium))
                    .tracking(-0.8)
                    .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.55)], startPoint: .leading, endPoint: .trailing))
                Rectangle().fill(LinearGradient(colors: [.clear, .white.opacity(0.2), .clear], startPoint: .leading, endPoint: .trailing))
                    .frame(width: 230, height: 1)
                Text("Ask a question, or let Orbit take care of it.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.45))
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                ForEach(suggestions, id: \.1) { item in
                    Button { choose(item.2) } label: {
                        Label(item.1, systemImage: item.0)
                            .font(.system(size: 13, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(OrbitLiquidButtonStyle())
                }
            }.frame(maxWidth: 420)
        }
        .multilineTextAlignment(.center)
        .padding(.horizontal, 8).padding(.vertical, 60)
        .frame(maxWidth: .infinity)
        .opacity(appeared ? 1 : 0)
        .offset(y: appeared || reduceMotion ? 0 : 12)
        .background {
            if !reduceMotion {
                Ellipse().fill(Color.purple.opacity(0.09)).frame(height: 200).blur(radius: 65).allowsHitTesting(false)
            }
        }
        .onAppear { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.5)) { appeared = true } }
    }
}
