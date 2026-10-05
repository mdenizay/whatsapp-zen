import AppKit
import SwiftUI

/// A ready-made look: the palette of a well-known editor theme, mapped onto
/// the window, the chat list, the bubbles and the accent.
struct ThemePreset: Identifiable {
    let id: String
    let name: String
    let dark: Bool
    let base: Int
    let sidebar: Int
    let bubbleIn: Int
    let bubbleOut: Int
    let accent: Int
    /// A second palette colour, for the faint glow across the background.
    let glow: Int

    static let all: [ThemePreset] = [
        ThemePreset(id: "darcula", name: "Darcula", dark: true, base: 0x2B2B2B, sidebar: 0x3C3F41, bubbleIn: 0x3C3F41, bubbleOut: 0x214283, accent: 0xCC7832, glow: 0x6897BB),
        ThemePreset(id: "dracula", name: "Dracula", dark: true, base: 0x282A36, sidebar: 0x21222C, bubbleIn: 0x44475A, bubbleOut: 0x6272A4, accent: 0xBD93F9, glow: 0xFF79C6),
        ThemePreset(id: "tokyo-night", name: "Tokyo Night", dark: true, base: 0x1A1B26, sidebar: 0x16161E, bubbleIn: 0x292E42, bubbleOut: 0x3D59A1, accent: 0x7AA2F7, glow: 0xBB9AF7),
        ThemePreset(id: "nord", name: "Nord", dark: true, base: 0x2E3440, sidebar: 0x272C36, bubbleIn: 0x3B4252, bubbleOut: 0x5E81AC, accent: 0x88C0D0, glow: 0x81A1C1),
        ThemePreset(id: "catppuccin-mocha", name: "Catppuccin Mocha", dark: true, base: 0x1E1E2E, sidebar: 0x181825, bubbleIn: 0x313244, bubbleOut: 0x7C5CC4, accent: 0xCBA6F7, glow: 0x89B4FA),
        ThemePreset(id: "gruvbox-dark", name: "Gruvbox Dark", dark: true, base: 0x282828, sidebar: 0x1D2021, bubbleIn: 0x3C3836, bubbleOut: 0xAF3A03, accent: 0xFE8019, glow: 0xFABD2F),
        ThemePreset(id: "one-dark", name: "One Dark", dark: true, base: 0x282C34, sidebar: 0x21252B, bubbleIn: 0x3E4451, bubbleOut: 0x4D78CC, accent: 0x61AFEF, glow: 0xC678DD),
        ThemePreset(id: "monokai", name: "Monokai", dark: true, base: 0x272822, sidebar: 0x1E1F1C, bubbleIn: 0x3E3D32, bubbleOut: 0xB81C55, accent: 0xF92672, glow: 0xA6E22E),
        ThemePreset(id: "solarized-dark", name: "Solarized Dark", dark: true, base: 0x002B36, sidebar: 0x00212B, bubbleIn: 0x073642, bubbleOut: 0x1E6FA8, accent: 0x268BD2, glow: 0x2AA198),
        ThemePreset(id: "github-dark", name: "GitHub Dark", dark: true, base: 0x0D1117, sidebar: 0x010409, bubbleIn: 0x21262D, bubbleOut: 0x1F6FEB, accent: 0x58A6FF, glow: 0x3FB950),
        ThemePreset(id: "rose-pine", name: "Rosé Pine", dark: true, base: 0x191724, sidebar: 0x1F1D2E, bubbleIn: 0x26233A, bubbleOut: 0x31748F, accent: 0xC4A7E7, glow: 0xEBBCBA),
        ThemePreset(id: "night-owl", name: "Night Owl", dark: true, base: 0x011627, sidebar: 0x010E1A, bubbleIn: 0x0B2942, bubbleOut: 0x1D5FA8, accent: 0x82AAFF, glow: 0xC792EA),
        ThemePreset(id: "synthwave", name: "SynthWave '84", dark: true, base: 0x262335, sidebar: 0x241B2F, bubbleIn: 0x34294F, bubbleOut: 0xB8389C, accent: 0xFF7EDB, glow: 0x36F9F6),
        ThemePreset(id: "everforest", name: "Everforest", dark: true, base: 0x2D353B, sidebar: 0x232A2E, bubbleIn: 0x3D484D, bubbleOut: 0x5A7A4A, accent: 0xA7C080, glow: 0x83C092),
        ThemePreset(id: "ayu-mirage", name: "Ayu Mirage", dark: true, base: 0x1F2430, sidebar: 0x1A1F29, bubbleIn: 0x2F3545, bubbleOut: 0x3A6EA5, accent: 0xFFCC66, glow: 0x73D0FF),
        ThemePreset(id: "whatsapp-dark", name: "WhatsApp Dark", dark: true, base: 0x0B141A, sidebar: 0x111B21, bubbleIn: 0x202C33, bubbleOut: 0x005C4B, accent: 0x00A884, glow: 0x53BDEB),
        ThemePreset(id: "solarized-light", name: "Solarized Light", dark: false, base: 0xFDF6E3, sidebar: 0xEEE8D5, bubbleIn: 0xEEE8D5, bubbleOut: 0x1E6FA8, accent: 0x268BD2, glow: 0x2AA198),
        ThemePreset(id: "github-light", name: "GitHub Light", dark: false, base: 0xFFFFFF, sidebar: 0xF6F8FA, bubbleIn: 0xEAEEF2, bubbleOut: 0x0969DA, accent: 0x0969DA, glow: 0x1A7F37),
        ThemePreset(id: "catppuccin-latte", name: "Catppuccin Latte", dark: false, base: 0xEFF1F5, sidebar: 0xE6E9EF, bubbleIn: 0xCCD0DA, bubbleOut: 0x8839EF, accent: 0x8839EF, glow: 0x1E66F5),
        ThemePreset(id: "gruvbox-light", name: "Gruvbox Light", dark: false, base: 0xFBF1C7, sidebar: 0xF2E5BC, bubbleIn: 0xEBDBB2, bubbleOut: 0xAF3A03, accent: 0xAF3A03, glow: 0xB57614),
        ThemePreset(id: "rose-pine-dawn", name: "Rosé Pine Dawn", dark: false, base: 0xFAF4ED, sidebar: 0xFFFAF3, bubbleIn: 0xF2E9E1, bubbleOut: 0x286983, accent: 0x907AA9, glow: 0xD7827E),
        ThemePreset(id: "nord-light", name: "Nord Light", dark: false, base: 0xECEFF4, sidebar: 0xE5E9F0, bubbleIn: 0xD8DEE9, bubbleOut: 0x5E81AC, accent: 0x5E81AC, glow: 0x88C0D0),
    ]

    func apply(to prefs: Prefs = .shared) {
        prefs.appearance = dark ? "dark" : "light"
        prefs.accent = "custom"
        prefs.customAccent = accent
        prefs.themeAccent = accent
        prefs.themeColor2 = glow
        prefs.themeColor3 = -1
        prefs.themeBase = base
        prefs.themeSidebar = sidebar
        prefs.bubbleInColor = bubbleIn
        prefs.bubbleOutColor = bubbleOut
        // The palette's own colours carry the look; the glow stays faint.
        prefs.themeIntensity = 0.08
        prefs.wallpaper = "theme"
        prefs.themeName = id
    }

    /// Back to the app's own look.
    static func reset(_ prefs: Prefs = .shared) {
        prefs.appearance = "system"
        prefs.accent = "green"
        prefs.customAccent = 0x1DAA61
        prefs.themeColor2 = Prefs.defaultSecond
        prefs.themeIntensity = 0.22
        prefs.wallpaper = "theme"
        clearPalette(prefs)
    }

    /// Drops everything a ready-made theme set outright, leaving the colour dots.
    static func clearPalette(_ prefs: Prefs = .shared) {
        prefs.themeColor3 = -1
        prefs.themeAccent = -1
        prefs.themeBase = -1
        prefs.themeSidebar = -1
        prefs.bubbleInColor = -1
        prefs.bubbleOutColor = -1
        prefs.themeName = ""
    }
}

extension Color {
    /// The colour as 0xRRGGBB.
    var hex: Int {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        return Int(round(c.redComponent * 255)) << 16 | Int(round(c.greenComponent * 255)) << 8 | Int(round(c.blueComponent * 255))
    }
}

/// The ready-made themes as small previews of a chat.
struct ThemeGallery: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 10, alignment: .top)], spacing: 12) {
            card(name: L("Default"), selected: prefs.themeName.isEmpty && prefs.themeBase < 0,
                 base: Color(nsColor: .textBackgroundColor), sidebar: Color(nsColor: .windowBackgroundColor),
                 bubbleIn: Color(light: 0xECECEF, dark: 0x2B2B2F), bubbleOut: Color(hex: 0x1A9F5A), accent: Color(hex: 0x1DAA61)) {
                ThemePreset.reset()
            }
            ForEach(ThemePreset.all) { theme in
                card(name: theme.name, selected: prefs.themeName == theme.id,
                     base: Color(hex: theme.base), sidebar: Color(hex: theme.sidebar), bubbleIn: Color(hex: theme.bubbleIn),
                     bubbleOut: Color(hex: theme.bubbleOut), accent: Color(hex: theme.accent)) {
                    theme.apply()
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func card(name: String, selected: Bool, base: Color, sidebar: Color, bubbleIn: Color, bubbleOut: Color, accent: Color,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                HStack(spacing: 0) {
                    sidebar.frame(width: 22)
                        .overlay(alignment: .top) {
                            VStack(spacing: 4) {
                                Circle().fill(accent).frame(width: 8, height: 8)
                                ForEach(0..<3, id: \.self) { _ in Capsule().fill(.gray.opacity(0.45)).frame(width: 12, height: 3) }
                            }
                            .padding(.top, 7)
                        }
                    VStack(spacing: 5) {
                        Capsule().fill(bubbleIn).frame(width: 34, height: 10).frame(maxWidth: .infinity, alignment: .leading)
                        Capsule().fill(bubbleOut).frame(width: 40, height: 10).frame(maxWidth: .infinity, alignment: .trailing)
                        Capsule().fill(bubbleIn).frame(width: 26, height: 10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(base)
                }
                .frame(height: 58)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.primary.opacity(0.12)), lineWidth: selected ? 2.5 : 1))
                Text(name).font(.caption).lineLimit(1).foregroundStyle(selected ? .primary : .secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Each colour of the look on its own, and how see-through the window is.
struct ThemeColors: View {
    @ObservedObject private var prefs = Prefs.shared

    var body: some View {
        row(L("Accent"), $prefs.themeAccent, fallback: Theme.accent)
        row(L("Chat background"), $prefs.themeBase, fallback: Color(nsColor: .textBackgroundColor))
        row(L("Chat list"), $prefs.themeSidebar, fallback: Color(nsColor: .windowBackgroundColor))
        row(L("Incoming bubble"), $prefs.bubbleInColor, fallback: Theme.bubbleIn)
        row(L("Outgoing bubble"), $prefs.bubbleOutColor, fallback: Theme.bubbleOut)
        HStack {
            Text(L("Window transparency"))
            Slider(value: Binding(get: { 1 - prefs.windowOpacity }, set: { prefs.windowOpacity = 1 - $0 }), in: 0...0.7)
            Text("\(Int(round((1 - prefs.windowOpacity) * 100)))%").monospacedDigit().foregroundStyle(.secondary).frame(width: 36, alignment: .trailing)
        }
        Button(L("Reset Colours")) { ThemePreset.reset(); prefs.windowOpacity = 1 }
    }

    private func row(_ title: String, _ value: Binding<Int>, fallback: Color) -> some View {
        HStack {
            Text(title)
            Spacer()
            if value.wrappedValue >= 0 {
                Button(L("Default")) {
                    value.wrappedValue = -1
                    prefs.themeName = ""
                }
                .buttonStyle(.link).font(.caption)
            }
            ColorPicker(title, selection: Binding(get: { value.wrappedValue >= 0 ? Color(hex: value.wrappedValue) : fallback },
                                                  set: { value.wrappedValue = $0.hex; prefs.themeName = "" }), supportsOpacity: false)
                .labelsHidden()
        }
    }
}
