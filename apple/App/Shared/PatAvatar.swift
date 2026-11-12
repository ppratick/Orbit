import OrbitKit
import SwiftUI

/// The assistant's face: a fuzzy creature that breathes and blinks. Its eyes are drawn on top of
/// an eyeless render so they can close; its color is a hue shift of the blue original.
struct PatAvatar: View {
    var size: CGFloat
    var color: String = "blue"
    /// Breathes a little faster while Orbit is working on a reply.
    var lively = false
    @State private var inhale = false
    @State private var blinking = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Eye centers and sizes, as fractions of the square image (measured from the original render).
    private static let eyes: [(x: CGFloat, y: CGFloat)] = [(0.530, 0.394), (0.668, 0.389)]
    private static let eyeSize = CGSize(width: 0.056, height: 0.104)

    static let colors: [(id: String, name: String, hue: Double)] = [
        ("blue", "Blue", 0), ("purple", "Purple", 50), ("pink", "Pink", 105),
        ("orange", "Orange", 180), ("green", "Green", 250), ("teal", "Teal", 320),
    ]
    static func hue(_ id: String) -> Double { colors.first { $0.id == id }?.hue ?? 0 }

    var body: some View {
        ZStack {
            Image("PatAvatar").resizable().interpolation(.high)
                .hueRotation(.degrees(Self.hue(color)))
            ForEach(Self.eyes.indices, id: \.self) { i in
                Ellipse()
                    .fill(Color(white: 0.03))
                    .frame(width: Self.eyeSize.width * size,
                           height: Self.eyeSize.height * size * (blinking ? 0.08 : 1))
                    .position(x: Self.eyes[i].x * size, y: Self.eyes[i].y * size)
            }
        }
        .frame(width: size, height: size)
        // Breathing: a soft squash and stretch anchored at the base, like a body settling.
        .scaleEffect(x: inhale ? 1.012 : 0.992, y: inhale ? 0.982 : 1.022, anchor: .bottom)
        .accessibilityHidden(true)
        .onAppear { breathe() }
        .onChange(of: lively) { _, _ in breathe() }
        .task { await blinkLoop() }
    }

    private func breathe() {
        guard !reduceMotion else { inhale = false; return }
        inhale = false
        withAnimation(.easeInOut(duration: lively ? 1.1 : 2.4).repeatForever(autoreverses: true)) { inhale = true }
    }

    private func blinkLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Double.random(in: 2.2...5.5) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            let times = Int.random(in: 0..<6) == 0 ? 2 : 1   // now and then, a double blink
            for _ in 0..<times {
                withAnimation(.easeIn(duration: 0.07)) { blinking = true }
                try? await Task.sleep(nanoseconds: 110_000_000)
                withAnimation(.easeOut(duration: 0.12)) { blinking = false }
                try? await Task.sleep(nanoseconds: 180_000_000)
            }
        }
    }
}

/// The avatar at the top of the chat with its name underneath, like a contact. Tap to customize.
struct PatHeader: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var store: OrbitStore
    var onTap: () -> Void

    static func name(_ store: OrbitStore) -> String { store.profileText("assistant_name").isEmpty ? "Pat" : store.profileText("assistant_name") }
    static func color(_ store: OrbitStore) -> String { store.profileText("assistant_color").isEmpty ? "blue" : store.profileText("assistant_color") }
    private var name: String { Self.name(store) }
    private var color: String { Self.color(store) }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: -4) {
                PatAvatar(size: OrbitTheme.isMac ? 54 : 64, color: color,
                          lively: model.mainConversationId.map { model.sending.contains($0) } ?? false)
                    .offset(y: 3)
                    .frame(width: OrbitTheme.isMac ? 64 : 76, height: OrbitTheme.isMac ? 64 : 76)
                    .background(Circle().fill(Color(red: 0.12, green: 0.125, blue: 0.14).opacity(0.85)))
                    .orbitGlass(in: Circle(), interactive: true)
                Text(name.uppercased())
                    .font(.system(size: OrbitTheme.isMac ? 13 : 15, weight: .bold)).tracking(1)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .orbitGlass(in: Capsule())
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(name). Customize your assistant")
        .help("Customize \(name)")
    }
}

/// Rename the assistant and pick its color. Changes sync to every device.
struct PatCustomizeSheet: View {
    @EnvironmentObject var model: AppModel
    let initialName: String
    let initialColor: String
    var close: () -> Void
    @State private var name = ""
    @State private var color = "blue"
    @State private var saving = false
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(spacing: OrbitTheme.isMac ? 18 : 22) {
            HStack {
                Button("Cancel", action: close).buttonStyle(.plain).foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text("Your assistant").font(.system(size: OrbitTheme.isMac ? 14 : 17, weight: .semibold))
                Spacer()
                Button(action: save) {
                    if saving { ProgressView().controlSize(.small) } else { Text("Done").fontWeight(.semibold) }
                }
                .buttonStyle(.plain).disabled(trimmedName.isEmpty || saving)
                .keyboardShortcut(.defaultAction)
            }
            .font(OrbitTheme.body)

            PatAvatar(size: OrbitTheme.isMac ? 132 : 160, color: color)
                .padding(.top, 4)
                .animation(.easeInOut(duration: 0.25), value: color)

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(OrbitTheme.rowSubtitle.weight(.medium)).foregroundStyle(.secondary)
                TextField("e.g. Pat", text: $name)
                    .textFieldStyle(.plain).font(OrbitTheme.body).focused($nameFocused)
                    .autocorrectionDisabled()
                    .onChange(of: name) { _, new in if new.count > 24 { name = String(new.prefix(24)) } }
                    .padding(.horizontal, 12).padding(.vertical, OrbitTheme.isMac ? 8 : 11)
                    .background(OrbitTheme.raisedHigh, in: RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: OrbitTheme.isMac ? 8 : 12, style: .continuous)
                        .stroke(nameFocused ? AboutYouContent.tint.opacity(0.7) : Color.white.opacity(0.08), lineWidth: nameFocused ? 1.2 : 0.5))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Color").font(OrbitTheme.rowSubtitle.weight(.medium)).foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    ForEach(PatAvatar.colors, id: \.id) { option in
                        Button { color = option.id } label: {
                            VStack(spacing: 4) {
                                Image("PatAvatar").resizable().hueRotation(.degrees(option.hue))
                                    .frame(width: OrbitTheme.isMac ? 34 : 40, height: OrbitTheme.isMac ? 34 : 40)
                                    .padding(4)
                                    .background(Circle().fill(color == option.id ? Color.white.opacity(0.12) : .clear))
                                    .overlay(Circle().stroke(color == option.id ? Color.white.opacity(0.6) : .clear, lineWidth: 1.5))
                                Text(option.name).font(.system(size: OrbitTheme.isMac ? 10 : 11))
                                    .foregroundStyle(color == option.id ? .primary : .secondary)
                            }
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(option.name)
                        .accessibilityAddTraits(color == option.id ? [.isSelected] : [])
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(OrbitTheme.footnote).foregroundStyle(.orange)
            }
            Text("Your assistant answers to this name on all your devices.")
                .font(OrbitTheme.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
        }
        .padding(OrbitTheme.isMac ? 20 : 22)
        .frame(minWidth: 360, idealWidth: 440, minHeight: OrbitTheme.isMac ? 470 : nil)
        .background(Color(white: 0.06).ignoresSafeArea())
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
        .onAppear { name = initialName; color = initialColor }
    }

    private func save() {
        saving = true
        error = nil
        Task {
            var failure: String?
            if trimmedName != initialName { failure = await model.saveProfile(section: "assistant_name", content: trimmedName) }
            if failure == nil, color != initialColor { failure = await model.saveProfile(section: "assistant_color", content: color) }
            saving = false
            if let failure { error = failure } else { close() }
        }
    }
}
