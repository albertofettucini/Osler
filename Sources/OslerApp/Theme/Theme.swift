import AppKit
import SwiftUI
import OslerEngine

/// Osler's visual language — the Council design constitution:
///
/// 1. GRAYSCALE-FIRST: all chrome (surfaces, text, icons, borders, hovers) is
///    neutral, zero hue. Color is never decoration.
/// 2. ONE ACCENT HUE, RESERVED FOR MEANING: a single blue appears only where
///    something means something — the working state, the app's one key signal
///    (Run / a live wire), and toggles. Emphasis elsewhere (selected, hover,
///    primary) is a BRIGHTER NEUTRAL, never color.
/// 3. FROSTED-GLASS SURFACES: translucent tint fills + hairline strokes over a
///    blurred backdrop, not solid card colors.
/// 4. FOUR-STEP NEUTRAL TEXT HIERARCHY; light and dark both first-class.
/// 5. FUNCTIONAL COLOR IS MINIMAL: only error carries a hue.
/// 6. PERSONALITY VIA ONE BACKGROUND TINT: the user picks a backdrop wash
///    (BackdropTint) — the chrome stays grayscale, so every wash works.
enum Theme {
    // MARK: Dynamic colour plumbing

    /// A colour that resolves per system appearance at draw time.
    private static func dyn(_ lightHex: UInt, _ darkHex: UInt) -> Color {
        dyn(lightHex, 1, darkHex, 1)
    }

    private static func dyn(_ lightHex: UInt, _ lightAlpha: CGFloat,
                            _ darkHex: UInt, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return isDark
                ? NSColor(hex: darkHex, alpha: darkAlpha)
                : NSColor(hex: lightHex, alpha: lightAlpha)
        })
    }

    // MARK: Base neutrals (§4)

    static let background = dyn(0xF2F2F5, 0x131314)
    /// Solid surface fallback (node cards and anything that must stay opaque).
    static let surface = dyn(0xFFFFFF, 0x1F1F20)
    /// Translucent so the user's backdrop wash tints the canvas too.
    static let canvas = dyn(0xECECEF, 0.55, 0x0E0E0F, 0.55)
    /// Dot-lattice canvas texture.
    static let gridDot = dyn(0x1A1A1C, 0.13, 0xFFFFFF, 0.09)
    static let gridLine = gridDot

    // MARK: Glass (§3)

    static let panel = dyn(0xFFFFFF, 0.28, 0xFFFFFF, 0.045)
    static let panelRaised = dyn(0xFFFFFF, 0.55, 0xFFFFFF, 0.08)
    static let hairline = dyn(0x000000, 0.08, 0xFFFFFF, 0.16)
    static let hoverFill = dyn(0x000000, 0.10, 0xFFFFFF, 0.12)
    static let cardFill = dyn(0xFFFFFF, 0.28, 0xFFFFFF, 0.045)
    static let cardFillHover = dyn(0xFFFFFF, 0.45, 0xFFFFFF, 0.09)
    static let cardBorder = dyn(0x000000, 0.08, 0xFFFFFF, 0.16)

    static let nodeSurface = dyn(0xFFFFFF, 0x1F1F20)
    static let nodeSurfaceRaised = dyn(0xFFFFFF, 0x2A2A2C)
    static let nodeBorder = dyn(0x000000, 0.08, 0xFFFFFF, 0.16)

    /// Neutral container fills (chips, wells, icon plates).
    static let surfaceLowest = dyn(0xFFFFFF, 0x1F1F20)
    static let surfaceContainer = dyn(0x000000, 0.05, 0xFFFFFF, 0.06)
    static let surfaceContainerHigh = dyn(0x000000, 0.08, 0xFFFFFF, 0.10)
    static let surfaceVariant = dyn(0x000000, 0.05, 0xFFFFFF, 0.06)

    // MARK: Borders / outlines

    static let outline = dyn(0x1A1A1C, 0.72, 0xF2F2F5, 0.75)
    static let outlineVariant = dyn(0x000000, 0.14, 0xFFFFFF, 0.20)

    // MARK: Text (§4)

    // Sub and dim are INK AT ALPHA, not fixed grays: alpha text blends with
    // whatever backdrop wash sits behind it, so contrast survives every tint —
    // a fixed mid-gray can vanish on a wash of matching luminance. On neutral
    // surfaces the resolved colours match the spec's #6B6B70/#BDBFC4 steps.
    static let textPrimary = dyn(0x1A1A1C, 0xF2F2F5)
    static let textSecondary = dyn(0x1A1A1C, 0.72, 0xF2F2F5, 0.75)
    static let textFaint = dyn(0x1A1A1C, 0.48, 0xF2F2F5, 0.52)

    // MARK: Emphasis — a brighter neutral, never color (§2)

    static let emphasisFill = dyn(0x1A1A1C, 0xF2F2F5)
    static let onEmphasis = dyn(0xFFFFFF, 0x1A1A1C)

    // MARK: The one accent (§2)

    static let accent = dyn(0x3380F2, 0x66A8FF)
    static let accentBright = dyn(0x3380F2, 0x66A8FF)
    static let accentSoft = dyn(0x3380F2, 0.12, 0x66A8FF, 0.16)

    // MARK: Functional color (§5)

    static let error = dyn(0xD13D47, 0xFF8C85)

    // MARK: Wires

    static let wire = dyn(0x1A1A1C, 0.22, 0xF2F2F5, 0.22)
    /// Data actually flowing — the app's key signal, so it may be blue.
    static let wireLive = dyn(0x3380F2, 0x66A8FF)

    /// Node type identity colours — the one sanctioned exception to §1:
    /// they encode MEANING (which kind of node is which, at a glance),
    /// not decoration. All other chrome stays grayscale.
    static func nodeTint(_ kind: NodeKind) -> Color {
        switch kind {
        case .input: return dyn(0x0E9384, 0x35C7B4)     // teal
        case .agent: return dyn(0x7B5BE6, 0x9B7BFF)     // violet
        case .condition: return dyn(0xC17A06, 0xE0A64B) // amber
        case .output: return dyn(0x2563EB, 0x6E9BFF)    // blue
        case .unknown: return textFaint
        }
    }

    static func nodeGlyph(_ kind: NodeKind) -> String {
        switch kind {
        case .input: return "text.cursor"
        case .agent: return "brain"
        case .condition: return "arrow.triangle.branch"
        case .output: return "square.and.arrow.down"
        case .unknown: return "questionmark.diamond"
        }
    }

    /// Run-state colour: working = the accent, error = the one functional hue,
    /// everything else is a neutral step (§5 — no green, no yellow).
    static func stateColor(_ state: NodeRunState) -> Color {
        switch state {
        case .idle: return textFaint
        case .running: return accent
        case .done: return dyn(0x4D5257, 0xE0E6ED)    // bright neutral
        case .failed: return error
        case .skipped: return dyn(0x8C8F94, 0x999EA8) // mid neutral
        }
    }

    /// Soft chip background for a run state.
    static func stateChipBackground(_ state: NodeRunState) -> Color {
        switch state {
        case .idle: return surfaceContainer
        case .running: return accentSoft
        case .done: return dyn(0x000000, 0.07, 0xFFFFFF, 0.10)
        case .failed: return dyn(0xD13D47, 0.12, 0xFF8C85, 0.16)
        case .skipped: return dyn(0x000000, 0.05, 0xFFFFFF, 0.06)
        }
    }
}

private extension NSColor {
    convenience init(hex: UInt, alpha: CGFloat = 1) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }
}

// MARK: - Typography (design-system roles → system fonts)

extension Font {
    /// display-lg — big greeting headers.
    static let oslerDisplay = Font.system(size: 42, weight: .bold, design: .default)
    /// headline-md — section titles.
    static func oslerHeadline(_ size: CGFloat = 22) -> Font {
        .system(size: size, weight: .semibold)
    }
    /// body — general UI text.
    static func oslerBody(_ size: CGFloat = 13, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    /// label-sm — small mono labels (chips, section headers, metadata).
    static func oslerLabel(_ size: CGFloat = 11, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - Glass building blocks

/// The frosted card used on the start screen and panels (§3): thin tint fill
/// plus hairline stroke — never a solid card colour.
struct GlassCard: ViewModifier {
    var cornerRadius: CGFloat = 12
    var raised = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(raised ? Theme.panelRaised : Theme.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Theme.hairline)
            )
            .shadow(color: .black.opacity(0.04), radius: raised ? 14 : 9, y: raised ? 6 : 3)
    }
}

extension View {
    func glassCard(cornerRadius: CGFloat = 12, raised: Bool = false) -> some View {
        modifier(GlassCard(cornerRadius: cornerRadius, raised: raised))
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - Backdrop tint (§6)

/// The one source of personality: an optional background wash — a solid
/// colour or a two-colour diagonal gradient — rendered at ~50% opacity over
/// the base backdrop. Chrome is strictly grayscale, so every wash works.
struct BackdropTint: Identifiable, Equatable {
    /// Swatches are grouped rather than poured out as one wall of colour —
    /// a palette reads as considered, a grid of 40 dots reads as a paint box.
    enum Family {
        case paper    // near-white surfaces; painted at full strength on cards
        case solid
        case gradient
    }

    let id: String
    let name: String
    let colors: [UInt] // 1 = solid, 2 = diagonal gradient

    init(_ id: String, _ name: String, _ colors: [UInt]) {
        self.id = id
        self.name = name
        self.colors = colors
    }

    static let paperIDs: Set<String> = ["white", "pearl"]

    var family: Family {
        if Self.paperIDs.contains(id) { return .paper }
        return colors.count > 1 ? .gradient : .solid
    }

    static func all(_ family: Family) -> [BackdropTint] {
        all.filter { $0.family == family }
    }

    var gradient: LinearGradient {
        LinearGradient(colors: colors.map { Color(hex: $0) },
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    static let all: [BackdropTint] = [
        BackdropTint("white", "White", [0xFFFFFF]),
        BackdropTint("pearl", "Pearl", [0xE7E7EC]),
        BackdropTint("blue", "Blue", [0x3373F7]),
        BackdropTint("cyan", "Cyan", [0x1AADE6]),
        BackdropTint("teal", "Teal", [0x149994]),
        BackdropTint("green", "Green", [0x33A852]),
        BackdropTint("lime", "Lime", [0x94C22E]),
        BackdropTint("amber", "Amber", [0xF7A31F]),
        BackdropTint("orange", "Orange", [0xF57524]),
        BackdropTint("rose", "Rose", [0xED3D66]),
        BackdropTint("pink", "Pink", [0xF26BBD]),
        BackdropTint("violet", "Violet", [0x8A4DF0]),
        BackdropTint("indigo", "Indigo", [0x5752E0]),
        BackdropTint("sky", "Sky", [0x59A6FA]),
        BackdropTint("emerald", "Emerald", [0x1AB880]),
        BackdropTint("gold", "Gold", [0xEBBD2E]),
        BackdropTint("coral", "Coral", [0xFA7366]),
        BackdropTint("crimson", "Crimson", [0xD11A3D]),
        BackdropTint("magenta", "Magenta", [0xD92E9E]),
        BackdropTint("lavender", "Lavender", [0xA88FEB]),
        BackdropTint("slate", "Slate", [0x576680]),
        BackdropTint("graphite", "Graphite", [0x666B75]),
        BackdropTint("mint", "Mint", [0x7FE0C3]),
        BackdropTint("ice", "Ice", [0xA8D8F0]),
        BackdropTint("peach", "Peach", [0xFFC49E]),
        BackdropTint("flamingo", "Flamingo", [0xFF9EAA]),
        BackdropTint("blush", "Blush", [0xE8B4C8]),
        BackdropTint("sand", "Sand", [0xD9C29A]),
        BackdropTint("olive", "Olive", [0x8A8F4A]),
        BackdropTint("forest", "Forest", [0x2E5E42]),
        BackdropTint("navy", "Navy", [0x2C3E6B]),
        BackdropTint("wine", "Wine", [0x7A2F4F]),
        BackdropTint("chocolate", "Chocolate", [0x6B4A2F]),
        BackdropTint("storm", "Storm", [0x4A5A6E]),
        BackdropTint("sunset", "Sunset", [0xFA8C26, 0xE63373]),
        BackdropTint("ocean", "Ocean", [0x3373F7, 0x1AB880]),
        BackdropTint("twilight", "Twilight", [0x5752E0, 0xD92E9E]),
        BackdropTint("aurora", "Aurora", [0x2EE6C0, 0x8A4DF0]),
        BackdropTint("flame", "Flame", [0xF7A31F, 0xD11A3D]),
        BackdropTint("meadow", "Meadow", [0x94C22E, 0x149994]),
        BackdropTint("deepsea", "Deep Sea", [0x2C3E6B, 0x1AADE6]),
        BackdropTint("candy", "Candy", [0xF26BBD, 0x59A6FA]),
        BackdropTint("dawn", "Dawn", [0xFFC49E, 0x8A4DF0]),
    ]

    static func by(id: String) -> BackdropTint? {
        all.first { $0.id == id }
    }
}
