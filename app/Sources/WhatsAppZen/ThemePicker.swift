import AppKit
import SwiftUI

/// A colour field in the manner of Arc and Zen: drag a dot to choose the
/// colour, add a second dot for a gradient, pick light or dark, and set how
/// strongly the colours wash over the window.
struct ThemePicker: View {
    @ObservedObject private var prefs = Prefs.shared
    @State private var dragging: Int?

    private static let presets: [(Int, Int)] = [
        (0x1DAA61, -1), (0x0A84FF, -1), (0x8E5BE8, -1), (0xE8497F, -1), (0xE8792B, -1), (0x6E6E73, -1),
        (0xF2709C, 0xFF9472), (0x7F7FD5, 0x91EAE4), (0x11998E, 0x38EF7D), (0xF7971E, 0xFFD200), (0x654EA3, 0xEAAFC8), (0x2193B0, 0x6DD5ED),
    ]

    /// Where a colour sits on the field: hue across, vividness down.
    static func position(of hex: Int) -> CGPoint {
        let color = NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return CGPoint(x: h, y: 1 - min(max((s - 0.15) / 0.8, 0), 1))
    }

    static func color(at point: CGPoint) -> Int {
        let color = NSColor(hue: min(max(point.x, 0), 0.999), saturation: 0.15 + 0.8 * (1 - min(max(point.y, 0), 1)), brightness: 0.86, alpha: 1)
            .usingColorSpace(.sRGB) ?? .systemGreen
        return Int(color.redComponent * 255) << 16 | Int(color.greenComponent * 255) << 8 | Int(color.blueComponent * 255)
    }

    private var colors: [Int] {
        guard prefs.themeColor2 >= 0 else { return [prefs.customAccent] }
        return prefs.themeColor3 >= 0 ? [prefs.customAccent, prefs.themeColor2, prefs.themeColor3] : [prefs.customAccent, prefs.themeColor2]
    }

    /// The point straight across the centre of the field: the opposite colour.
    static func opposite(_ point: CGPoint) -> CGPoint {
        CGPoint(x: 1 - min(max(point.x, 0), 1), y: 1 - min(max(point.y, 0), 1))
    }

    /// Moves a dot. With two dots they stay opposite each other, so dragging
    /// either one carries the other across the field.
    private func move(_ index: Int, to point: CGPoint) {
        let paired = prefs.themeColor2 >= 0
        let own = Self.color(at: point), other = Self.color(at: Self.opposite(point))
        // The accent follows the main dot again, not a ready-made theme's.
        prefs.themeAccent = -1
        prefs.themeName = ""
        if colors.count == 3 {
            // Three colours are placed freely.
            switch index {
            case 0: prefs.customAccent = own
            case 1: prefs.themeColor2 = own
            default: prefs.themeColor3 = own
            }
        } else if index == 0 {
            prefs.customAccent = own
            if paired { prefs.themeColor2 = other }
        } else {
            prefs.themeColor2 = own
            prefs.customAccent = other
        }
        prefs.accent = "custom"
        prefs.wallpaper = "theme"
    }

    var body: some View {
        VStack(spacing: 12) {
            field
            HStack(spacing: 8) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button {
                        ThemePreset.clearPalette()
                        prefs.customAccent = preset.0
                        prefs.themeColor2 = preset.1
                        prefs.accent = "custom"
                        prefs.wallpaper = "theme"
                    } label: {
                        Circle()
                            .fill(LinearGradient(colors: [Color(hex: preset.0), Color(hex: preset.1 >= 0 ? preset.1 : preset.0)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20)
                            .overlay(Circle().strokeBorder(.primary.opacity(0.15)))
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack(spacing: 10) {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary)
                Slider(value: $prefs.themeIntensity, in: 0.05...0.6)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onChange(of: prefs.themeIntensity) { _, _ in prefs.wallpaper = "theme" }
            }
            .help(L("How strongly the colours tint the window"))
        }
    }

    private var field: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                // The field shows the colours it stands for, softly, under a dot grid.
                LinearGradient(colors: stride(from: 0.0, through: 1.0, by: 0.125).map { Color(hue: $0, saturation: 0.55, brightness: 0.92) },
                               startPoint: .leading, endPoint: .trailing)
                    .opacity(0.35)
                LinearGradient(colors: [.clear, Color(nsColor: .windowBackgroundColor).opacity(0.75)], startPoint: .top, endPoint: .bottom)
                Canvas { context, canvas in
                    for x in stride(from: 6.0, to: canvas.width, by: 9) {
                        for y in stride(from: 6.0, to: canvas.height, by: 9) {
                            context.fill(Path(ellipseIn: CGRect(x: x, y: y, width: 1.2, height: 1.2)), with: .color(.primary.opacity(0.18)))
                        }
                    }
                }
                // Light or dark, as in the browsers this is borrowed from.
                HStack(spacing: 4) {
                    ForEach([("system", "sparkles"), ("light", "sun.max.fill"), ("dark", "moon.fill")], id: \.0) { mode, icon in
                        Button { prefs.appearance = mode } label: {
                            Image(systemName: icon).font(.system(size: 12))
                                .frame(width: 26, height: 24)
                                .background(prefs.appearance == mode ? AnyShapeStyle(.primary.opacity(0.14)) : AnyShapeStyle(.clear),
                                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 8)
                // One dot, or two for a gradient.
                HStack(spacing: 14) {
                    Button {
                        if prefs.themeColor3 >= 0 { prefs.themeColor3 = -1 } else { prefs.themeColor2 = -1 }
                    } label: { Image(systemName: "minus") }
                        .disabled(prefs.themeColor2 < 0)
                    Button {
                        let first = Self.position(of: prefs.customAccent)
                        if prefs.themeColor2 < 0 {
                            // The second colour starts as the first one's opposite.
                            prefs.themeColor2 = Self.color(at: Self.opposite(first))
                        } else {
                            // The third starts a third of the way round from the first.
                            let x = (first.x + 1.0 / 3).truncatingRemainder(dividingBy: 1)
                            prefs.themeColor3 = Self.color(at: CGPoint(x: x, y: first.y))
                        }
                        prefs.accent = "custom"
                        prefs.wallpaper = "theme"
                    } label: { Image(systemName: "plus") }
                        .disabled(prefs.themeColor2 >= 0 && prefs.themeColor3 >= 0)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 8)

                ForEach(Array(colors.enumerated()), id: \.offset) { index, hex in
                    let point = Self.position(of: hex)
                    Circle().fill(Color(hex: hex))
                        .frame(width: index == 0 ? 34 : 22, height: index == 0 ? 34 : 22)
                        .overlay(Circle().strokeBorder(.white, lineWidth: 3))
                        .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                        // Kept a little inside the field so a dot at the edge stays whole.
                        .position(x: 20 + point.x * (size.width - 40), y: 34 + point.y * (size.height - 68))
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            move(index, to: CGPoint(x: (value.location.x - 20) / (size.width - 40),
                                                    y: (value.location.y - 34) / (size.height - 68)))
                        })
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.08)))
        }
        .frame(height: 190)
    }
}

/// First-run setup: the choices that shape the app, a page at a time.
struct SetupWizard: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var prefs = Prefs.shared
    @ObservedObject private var notifier = Notifier.shared
    /// WA_SETUP=<n> (demo snapshots) starts on page n.
    @State private var page = min(Int(ProcessInfo.processInfo.environment["WA_SETUP"] ?? "") ?? 0, 4)

    private static let pages = 5

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch page {
                case 0: welcome
                case 1: step(L("Pick your colours"), L("Drag the dot, or add a second one for a gradient.")) { ThemePicker() }
                case 2: step(L("Messages"), L("How conversations should look.")) { messages }
                case 3: step(L("Notifications"), L("How you want to hear about new messages.")) { notifications }
                default: step(L("Privacy"), L("Keep your chats to yourself.")) { privacy }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 28)
            .padding(.top, 26)

            HStack {
                if page > 0 {
                    Button(L("Back")) { page -= 1 }
                } else {
                    Button(L("Skip")) { model.showingSetup = false }
                }
                Spacer()
                HStack(spacing: 6) {
                    ForEach(0..<Self.pages, id: \.self) { index in
                        Circle().fill(index == page ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.quaternary)).frame(width: 7, height: 7)
                    }
                }
                Spacer()
                Button(page == Self.pages - 1 ? L("Done") : L("Continue")) {
                    if page == Self.pages - 1 { model.showingSetup = false } else { page += 1 }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(18)
        }
        .frame(width: 460, height: 480)
        .tint(Theme.accent)
    }

    private var welcome: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(L("Welcome to WhatsApp Zen")).font(.title.weight(.bold))
            Text(L("A light, native WhatsApp for your Mac. Let's set it up the way you like it; everything here can be changed later in Settings."))
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    private func step(_ title: String, _ subtitle: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).foregroundStyle(.secondary).padding(.bottom, 12)
            content()
        }
    }

    private var messages: some View {
        VStack(alignment: .leading, spacing: 14) {
            // A sample, so the choices can be seen as they are made.
            VStack(spacing: 4) {
                sample(L("How does this look?"), mine: false)
                sample(L("Just right 👌"), mine: true)
            }
            .padding(12)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack {
                Text(L("Text Size"))
                Slider(value: $prefs.fontSize, in: 11...18, step: 1)
            }
            HStack {
                Text(L("Bubble Corners"))
                Slider(value: $prefs.bubbleRadius, in: 4...22, step: 1)
            }
            Picker(L("Font"), selection: $prefs.fontDesign) {
                Text(L("Standard")).tag("default")
                Text(L("Rounded")).tag("rounded")
                Text(L("Serif")).tag("serif")
                Text(L("Monospaced")).tag("monospaced")
            }
            .pickerStyle(.segmented)
            Toggle(L("Turn emoticons like :) into emoji"), isOn: $prefs.emoticons)
        }
    }

    private func sample(_ text: String, mine: Bool) -> some View {
        HStack {
            if mine { Spacer() }
            Text(text).font(.system(size: prefs.fontSize, design: prefs.design))
                .foregroundStyle(mine ? .white : .primary)
                .padding(.horizontal, 11).padding(.vertical, 7)
                .background(mine ? Theme.bubbleOut : Theme.bubbleIn, in: RoundedRectangle(cornerRadius: prefs.bubbleRadius, style: .continuous))
            if !mine { Spacer() }
        }
    }

    private var notifications: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("Show Notifications"), isOn: $notifier.enabled)
            Toggle(L("Play Sound"), isOn: $notifier.sound).disabled(!notifier.enabled)
            Toggle(L("Message Preview"), isOn: $notifier.preview).disabled(!notifier.enabled)
            Toggle(L("Show unread count in the menu bar"), isOn: $prefs.menuBarCount)
            if let store = model.active {
                Toggle(L("Open at Login"), isOn: Binding(get: { store.launchAtLogin }, set: { store.setLaunchAtLogin($0) }))
            }
        }
        .toggleStyle(.switch)
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(L("Lock the app with Touch ID"), isOn: $prefs.appLock)
            Toggle(L("Download photos automatically"), isOn: $prefs.autoDownload)
            Text(L("Single chats can be locked from their info panel. Locked chats hide their previews and need Touch ID to open."))
                .font(.callout).foregroundStyle(.secondary)
        }
        .toggleStyle(.switch)
    }
}
