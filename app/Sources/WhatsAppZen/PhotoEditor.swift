import AppKit
import SwiftUI

/// One mark drawn on a photo. Points are in unit coordinates of the picture,
/// origin at the top left, so they survive any change of display size.
struct Mark {
    enum Kind { case pen, arrow, rect }

    var kind: Kind
    var points: [CGPoint]
    var color: NSColor
    /// Line width as a fraction of the picture's longer side.
    var width: CGFloat
}

/// A photo being prepared for sending.
final class EditablePhoto: ObservableObject, Identifiable {
    let id = UUID()
    @Published var image: CGImage
    @Published var marks: [Mark] = []
    private let original: CGImage

    init?(_ pending: PendingImage) {
        guard let cg = NSBitmapImageRep(data: pending.jpeg)?.cgImage else { return nil }
        image = cg
        original = cg
    }

    var size: CGSize { CGSize(width: image.width, height: image.height) }

    func reset() {
        image = original
        marks = []
    }

    /// The picture with its marks drawn in.
    func flattened() -> CGImage {
        guard !marks.isEmpty,
              let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return image }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Marks use a top-left origin; Core Graphics a bottom-left one.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        for mark in marks {
            ctx.addPath(Self.path(for: mark, in: CGSize(width: w, height: h)))
            ctx.setStrokeColor(mark.color.cgColor)
            ctx.setLineWidth(mark.width * max(w, h))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.strokePath()
        }
        return ctx.makeImage() ?? image
    }

    /// Makes the marks part of the picture, before a crop or rotation.
    func bake() {
        image = flattened()
        marks = []
    }

    static func path(for mark: Mark, in size: CGSize) -> CGPath {
        let points = mark.points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        let path = CGMutablePath()
        guard let first = points.first, let last = points.last else { return path }
        switch mark.kind {
        case .pen:
            path.addLines(between: points)
            if points.count == 1 { path.addLine(to: first) }
        case .rect:
            path.addRect(CGRect(x: min(first.x, last.x), y: min(first.y, last.y), width: abs(last.x - first.x), height: abs(last.y - first.y)))
        case .arrow:
            path.move(to: first)
            path.addLine(to: last)
            let angle = atan2(last.y - first.y, last.x - first.x)
            let head = max(mark.width * max(size.width, size.height) * 4, 10)
            for side in [-1.0, 1.0] {
                path.move(to: last)
                path.addLine(to: CGPoint(x: last.x - head * cos(angle + side * 0.5), y: last.y - head * sin(angle + side * 0.5)))
            }
        }
        return path
    }

    func rotate() {
        bake()
        guard let ctx = CGContext(data: nil, width: image.height, height: image.width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(image.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let turned = ctx.makeImage() { image = turned }
    }

    func crop(to unit: CGRect) {
        bake()
        let rect = CGRect(x: unit.minX * CGFloat(image.width), y: unit.minY * CGFloat(image.height),
                          width: unit.width * CGFloat(image.width), height: unit.height * CGFloat(image.height)).integral
        if let cut = image.cropping(to: rect) { image = cut }
    }

    /// The finished photo, ready to send.
    func export() -> PendingImage? {
        guard let data = NSBitmapImageRep(cgImage: flattened()).representation(using: .jpeg, properties: [.compressionFactor: 0.9]) else { return nil }
        return Images.prepare(data)
    }
}

/// The screen photos pass through before they are sent: look at them, crop,
/// rotate, draw on them, add a caption.
struct PhotoSendSheet: View {
    @EnvironmentObject var store: AppStore
    let chat: Chat

    private enum Tool { case none, pen, arrow, rect, crop }

    @State private var photos: [EditablePhoto] = []
    @State private var index = 0
    @State private var tool = Tool.none
    @State private var color = NSColor.systemRed
    @State private var caption = ""
    @State private var draft: Mark?
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?
    @FocusState private var captionFocused: Bool

    private static let area = CGSize(width: 660, height: 440)
    private static let colors: [NSColor] = [.systemRed, .systemYellow, .systemGreen, .systemBlue, .white, .black]

    private var current: EditablePhoto? { photos.indices.contains(index) ? photos[index] : nil }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            if let photo = current {
                PhotoCanvas(photo: photo, area: Self.area, draft: draft, cropping: tool == .crop, crop: $crop, onDrag: drag, onCropDrag: cropDrag)
                    .id(photo.id)
            } else {
                Color.clear.frame(width: Self.area.width, height: Self.area.height)
            }
            if photos.count > 1 { strip }
            HStack(spacing: 8) {
                TextField(L("Add a caption"), text: $caption)
                    .textFieldStyle(.roundedBorder)
                    .focused($captionFocused)
                    .onSubmit(send)
                Button(L("Cancel")) { store.pendingPhotos = [] }.keyboardShortcut(.cancelAction)
                Button(photos.count > 1 ? L("Send %lld", photos.count) : L("Send"), action: send)
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(photos.isEmpty)
            }
        }
        .padding(16)
        .frame(width: Self.area.width + 32)
        .onAppear {
            photos = store.pendingPhotos.compactMap(EditablePhoto.init)
            captionFocused = true
        }
    }

    private var toolbar: some View {
        HStack(spacing: 6) {
            toolButton(.pen, "pencil.tip", L("Draw"))
            toolButton(.arrow, "arrow.up.right", L("Arrow"))
            toolButton(.rect, "rectangle", L("Rectangle"))
            Divider().frame(height: 18)
            ForEach(Self.colors, id: \.self) { swatch in
                Button { color = swatch } label: {
                    Circle().fill(Color(nsColor: swatch)).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: 0.5))
                        .overlay(Circle().strokeBorder(.primary, lineWidth: color == swatch ? 2 : 0).padding(-3))
                }
                .buttonStyle(.plain)
            }
            Divider().frame(height: 18).padding(.leading, 4)
            if tool == .crop {
                Button(L("Apply")) {
                    current?.crop(to: crop)
                    tool = .none
                }
                .buttonStyle(.borderedProminent).tint(Theme.accent).labelStyle(.titleOnly)
                Button(L("Cancel")) { tool = .none }.labelStyle(.titleOnly)
            } else {
                Button(L("Crop"), systemImage: "crop") {
                    crop = CGRect(x: 0, y: 0, width: 1, height: 1)
                    tool = .crop
                }
                Button(L("Rotate"), systemImage: "rotate.right") { current?.rotate() }
            }
            Spacer()
            Button(L("Undo"), systemImage: "arrow.uturn.backward") {
                if current?.marks.isEmpty == false { current?.marks.removeLast() }
            }
            .keyboardShortcut("z")
            .disabled(current?.marks.isEmpty != false)
            Button(L("Reset")) { current?.reset() }.labelStyle(.titleOnly)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.bordered)
    }

    private func toolButton(_ kind: Tool, _ icon: String, _ title: String) -> some View {
        Group {
            if tool == kind {
                Button(title, systemImage: icon) { tool = .none }.buttonStyle(.borderedProminent).tint(Theme.accent)
            } else {
                Button(title, systemImage: icon) { tool = kind }.buttonStyle(.bordered)
            }
        }
        .help(title)
    }

    /// The other photos in this batch.
    private var strip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(photos.enumerated()), id: \.element.id) { position, photo in
                    Image(decorative: photo.image, scale: 1).resizable().scaledToFill()
                        .frame(width: 52, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: position == index ? 2.5 : 0))
                        .overlay(alignment: .topTrailing) {
                            Button {
                                photos.remove(at: position)
                                index = min(index, max(photos.count - 1, 0))
                                if photos.isEmpty { store.pendingPhotos = [] }
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .padding(2)
                        }
                        .onTapGesture {
                            tool = tool == .crop ? .none : tool
                            index = position
                        }
                }
            }
        }
        .frame(height: 56)
    }

    /// A drag on the picture with a drawing tool selected.
    private func drag(_ point: CGPoint, _ ended: Bool) {
        guard let photo = current else { return }
        let kind: Mark.Kind
        switch tool {
        case .pen: kind = .pen
        case .arrow: kind = .arrow
        case .rect: kind = .rect
        default: return
        }
        var mark = draft ?? Mark(kind: kind, points: [point], color: color, width: 0.006)
        if kind == .pen {
            mark.points.append(point)
        } else {
            mark.points = [mark.points[0], point]
        }
        if ended {
            photo.marks.append(mark)
            draft = nil
        } else {
            draft = mark
        }
    }

    private func cropDrag(_ update: (CGRect) -> CGRect, _ ended: Bool) {
        let start = dragStart ?? crop
        dragStart = ended ? nil : start
        crop = update(start)
    }

    private func send() {
        let reply = store.replyTo?.id
        for (position, photo) in photos.enumerated() {
            guard let image = photo.export() else { continue }
            store.send(image: image, caption: position == 0 ? caption : "", to: chat.jid, replyTo: position == 0 ? reply : nil)
        }
        store.replyTo = nil
        store.pendingPhotos = []
    }
}

/// Shows one photo with its marks and takes drawing and cropping gestures.
private struct PhotoCanvas: View {
    @ObservedObject var photo: EditablePhoto
    let area: CGSize
    let draft: Mark?
    let cropping: Bool
    @Binding var crop: CGRect
    let onDrag: (CGPoint, Bool) -> Void
    let onCropDrag: ((CGRect) -> CGRect, Bool) -> Void

    private static let minSide: CGFloat = 0.08

    private var fitted: CGSize {
        let scale = min(area.width / photo.size.width, area.height / photo.size.height)
        return CGSize(width: photo.size.width * scale, height: photo.size.height * scale)
    }

    private func unit(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / fitted.width, 0), 1), y: min(max(point.y / fitted.height, 0), 1))
    }

    var body: some View {
        let size = fitted
        ZStack(alignment: .topLeading) {
            Image(decorative: photo.image, scale: 1).resizable().frame(width: size.width, height: size.height)
            Canvas { context, _ in
                for mark in photo.marks + (draft.map { [$0] } ?? []) {
                    context.stroke(Path(EditablePhoto.path(for: mark, in: size)), with: .color(Color(nsColor: mark.color)),
                                   style: StrokeStyle(lineWidth: mark.width * max(size.width, size.height), lineCap: .round, lineJoin: .round))
                }
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { onDrag(unit($0.location), false) }
                .onEnded { onDrag(unit($0.location), true) })
            .allowsHitTesting(!cropping)
            if cropping { cropOverlay(size) }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .frame(width: area.width, height: area.height)
        .background(.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func frame(_ size: CGSize) -> CGRect {
        CGRect(x: crop.minX * size.width, y: crop.minY * size.height, width: crop.width * size.width, height: crop.height * size.height)
    }

    @ViewBuilder private func cropOverlay(_ size: CGSize) -> some View {
        let box = frame(size)
        Path { path in
            path.addRect(CGRect(origin: .zero, size: size))
            path.addRect(box)
        }
        .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
        .allowsHitTesting(false)
        Rectangle().strokeBorder(.white, lineWidth: 1.5)
            .frame(width: box.width, height: box.height)
            .contentShape(Rectangle())
            .offset(x: box.minX, y: box.minY)
            .gesture(cropGesture(size) { start, dx, dy in
                CGRect(x: min(max(start.minX + dx, 0), 1 - start.width), y: min(max(start.minY + dy, 0), 1 - start.height),
                       width: start.width, height: start.height)
            })
        ForEach(0..<4, id: \.self) { corner in
            let left = corner % 2 == 0, top = corner < 2
            Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1)
                .position(x: left ? box.minX : box.maxX, y: top ? box.minY : box.maxY)
                .gesture(cropGesture(size) { start, dx, dy in
                    var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                    if left { minX = min(max(start.minX + dx, 0), maxX - Self.minSide) } else { maxX = max(min(start.maxX + dx, 1), minX + Self.minSide) }
                    if top { minY = min(max(start.minY + dy, 0), maxY - Self.minSide) } else { maxY = max(min(start.maxY + dy, 1), minY + Self.minSide) }
                    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                })
        }
    }

    private func cropGesture(_ size: CGSize, _ update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                onCropDrag({ update($0, value.translation.width / size.width, value.translation.height / size.height) }, false)
            }
            .onEnded { value in
                onCropDrag({ update($0, value.translation.width / size.width, value.translation.height / size.height) }, true)
            }
    }
}
