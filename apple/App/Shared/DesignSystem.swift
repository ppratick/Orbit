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

struct OrbitCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .orbitGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct OrbitPage<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView {
            OrbitGlassGroup {
                VStack(alignment: .leading, spacing: 20) { content() }
                    .frame(maxWidth: 680)
                    .padding(.horizontal, 20).padding(.vertical, 16)
                    .frame(maxWidth: .infinity)
            }
        }
        .scrollContentBackground(.hidden)
    }
}

struct OrbitEmptyState: View {
    let symbol: String
    let title: String
    let detail: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32, weight: .light))
                .frame(width: 78, height: 78).orbitGlass(in: Circle())
            Text(title).font(.title3.weight(.semibold))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
        }
        .padding(32).frame(maxWidth: .infinity)
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

struct OrbitPillTabs: View {
    let titles: [String]
    @Binding var selection: Int
    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(titles.indices, id: \.self) { index in
                    Button { selection = index } label: {
                        Text(titles[index])
                            .font(.subheadline.weight(selection == index ? .semibold : .medium))
                            .foregroundStyle(selection == index ? .primary : .secondary)
                            .padding(.horizontal, 17).frame(minHeight: 44)
                            .background(selection == index ? Color.primary.opacity(0.12) : .clear, in: Capsule())
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selection == index ? [.isSelected] : [])
                }
            }
        }.scrollIndicators(.hidden)
    }
}

struct OrbitSolidCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)
            .orbitGlass(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
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
