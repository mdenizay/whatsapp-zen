import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

extension Color {
    /// A color with separate light and dark values.
    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

extension Color {
    /// A fixed colour from 0xRRGGBB.
    init(hex: Int) {
        self.init(light: UInt32(hex), dark: UInt32(hex))
    }
}

enum Theme {
    static var accent: Color {
        let entry = Prefs.shared.accentEntry
        return Color(light: entry.light, dark: entry.dark)
    }
    /// Outgoing bubbles carry white text, so this stays dark enough in both modes.
    static var bubbleOut: Color {
        let entry = Prefs.shared.accentEntry
        return Color(light: entry.bubbleLight, dark: entry.bubbleDark)
    }
    static let bubbleIn = Color(light: 0xECECEF, dark: 0x2B2B2F)
    static let readTick = Color(light: 0x2E9BE6, dark: 0x5CC4F5)
    /// Read ticks on top of the green outgoing bubble.
    static let readTickOnBubble = Color(light: 0xA6E9FF, dark: 0x9BE3FF)

    private static let senderColors: [Color] = [
        Color(light: 0xC2410C, dark: 0xFDBA74), Color(light: 0x7C3AED, dark: 0xC4B5FD),
        Color(light: 0x0E7490, dark: 0x67E8F9), Color(light: 0xBE185D, dark: 0xF9A8D4),
        Color(light: 0x15803D, dark: 0x86EFAC), Color(light: 0x1D4ED8, dark: 0x93C5FD),
    ]

    /// A stable per-person color for names in group chats.
    static func senderColor(_ jid: String) -> Color {
        senderColors[Int(jid.utf8.reduce(UInt32(7)) { $0 &* 31 &+ UInt32($1) } % UInt32(senderColors.count))]
    }
}

struct AvatarView: View {
    let jid: String
    let name: String
    let size: CGFloat
    /// Bumped by the store when some profile photo changed.
    var tick = 0

    @State private var image: NSImage?

    private var initials: String {
        let letters = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }
        return letters.joined().uppercased()
    }

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                let color = Theme.senderColor(jid)
                LinearGradient(colors: [color.opacity(0.35), color.opacity(0.18)], startPoint: .top, endPoint: .bottom)
                if jid.hasSuffix("@g.us") || initials.isEmpty || name.hasPrefix("+") {
                    Image(systemName: jid.hasSuffix("@g.us") ? "person.2.fill" : "person.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(color)
                } else {
                    Text(initials).font(.system(size: size * 0.38, weight: .semibold, design: .rounded)).foregroundStyle(color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Prefs.shared.squareAvatars ? AnyShape(RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)) : AnyShape(Circle()))
        .task(id: "\(jid)#\(tick)") { image = await Images.avatar(jid: jid, size: size) }
        .accessibilityLabel(name)
    }
}

struct StatusTicks: View {
    let status: Int
    /// True when drawn on the green outgoing bubble.
    var onBubble = false

    var body: some View {
        switch status {
        case Status.failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(onBubble ? .white : .red)
        case Status.pending:
            Image(systemName: "clock")
        case Status.sent:
            TickShape(double: false).stroke(style: Self.stroke).frame(width: 10, height: 8)
        default:
            TickShape(double: true).stroke(style: Self.stroke).frame(width: 15, height: 8)
                .foregroundStyle(status == Status.read
                    ? AnyShapeStyle(onBubble ? Theme.readTickOnBubble : Theme.readTick)
                    // Delivered but not read (or the reader hides read receipts):
                    // on the green bubble, grey would all but disappear.
                    : (onBubble ? AnyShapeStyle(.white.opacity(0.78)) : AnyShapeStyle(.secondary)))
        }
    }

    private static let stroke = StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round)
}

/// WhatsApp-style ticks: one check, or two overlapping ones where the second
/// starts at the point it emerges from behind the first.
struct TickShape: Shape {
    let double: Bool

    func path(in rect: CGRect) -> Path {
        // Drawn on a 15x8 (double) or 10x8 (single) grid.
        let sx = rect.width / (double ? 15 : 10), sy = rect.height / 8
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * sx, y: rect.minY + y * sy) }
        var path = Path()
        path.move(to: point(0.7, 4.4))
        path.addLine(to: point(3.4, 7.2))
        path.addLine(to: point(9.3, 0.8))
        if double {
            path.move(to: point(7.3, 6.0))
            path.addLine(to: point(8.4, 7.2))
            path.addLine(to: point(14.3, 0.8))
        }
        return path
    }
}

struct UnreadBadge: View {
    let count: Int

    var body: some View {
        Text(count > 999 ? "999+" : "\(count)")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 19, minHeight: 19)
            .background(Theme.accent, in: Capsule())
    }
}

/// A round icon button on plain (untinted) glass.
struct GlassIconButton: View {
    let icon: String
    let help: String
    var size: CGFloat = 30
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size * 0.45, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Circle())
        .help(help)
    }
}

struct ConnectionDot: View {
    let connected: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(connected ? Theme.accent : .orange).frame(width: 7, height: 7)
            Text(connected ? L("Connected") : L("Connecting…")).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Shown until the phone scans the code.
struct PairingView: View {
    @EnvironmentObject var store: AppStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 44) {
            VStack(alignment: .leading, spacing: 18) {
                Text(L("Link to WhatsApp")).font(.largeTitle.weight(.bold))
                VStack(alignment: .leading, spacing: 12) {
                    step(1, L("Open WhatsApp on your phone"))
                    step(2, L("Settings → Linked Devices → Link a Device"))
                    step(3, L("Point your phone at this code"))
                }
                if let error = store.errorText {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
                if model.accounts.count > 1 {
                    Button(L("Cancel pairing")) { model.remove(store, unlink: false) }
                        .buttonStyle(.glass)
                        .padding(.top, 6)
                }
            }
            Group {
                if store.state == "qr", let image = Self.qrImage(store.qr) {
                    Image(nsImage: image).interpolation(.none).resizable()
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                } else {
                    ProgressView().controlSize(.large)
                }
            }
            .frame(width: 250, height: 250)
            .padding(14)
            .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(colors: [Theme.accent.opacity(0.18), .clear], startPoint: .topLeading, endPoint: .bottomTrailing)
        )
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(spacing: 10) {
            Text("\(number)").font(.callout.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Theme.accent, in: Circle())
            Text(text).font(.title3)
        }
    }

    static func qrImage(_ code: String) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(code.utf8)
        filter.correctionLevel = "L"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }
}
