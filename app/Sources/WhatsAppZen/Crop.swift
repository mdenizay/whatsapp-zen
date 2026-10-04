import AppKit
import SwiftUI

/// Crops and rotates a staged photo before it is sent.
struct CropSheet: View {
    @Environment(\.dismiss) private var dismiss
    let image: PendingImage
    let done: (PendingImage) -> Void

    @State private var working: CGImage?
    /// The crop rectangle in unit coordinates of the picture (top-left origin).
    @State private var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var dragStart: CGRect?

    private static let area = CGSize(width: 520, height: 400)
    private static let minSide: CGFloat = 0.08

    var body: some View {
        VStack(spacing: 14) {
            if let working {
                let fitted = fit(CGSize(width: working.width, height: working.height))
                ZStack(alignment: .topLeading) {
                    Image(decorative: working, scale: 1).resizable().frame(width: fitted.width, height: fitted.height)
                    // Dim everything outside the selection.
                    Path { path in
                        path.addRect(CGRect(origin: .zero, size: fitted))
                        path.addRect(frame(in: fitted))
                    }
                    .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                    Rectangle().strokeBorder(.white, lineWidth: 1.5)
                        .frame(width: frame(in: fitted).width, height: frame(in: fitted).height)
                        .offset(x: frame(in: fitted).minX, y: frame(in: fitted).minY)
                        .contentShape(Rectangle())
                        .gesture(drag(in: fitted) { start, dx, dy in
                            CGRect(x: min(max(start.minX + dx, 0), 1 - start.width), y: min(max(start.minY + dy, 0), 1 - start.height),
                                   width: start.width, height: start.height)
                        })
                    ForEach(0..<4, id: \.self) { corner in
                        let left = corner % 2 == 0, top = corner < 2
                        Circle().fill(.white).frame(width: 14, height: 14).shadow(radius: 1)
                            .position(x: left ? frame(in: fitted).minX : frame(in: fitted).maxX,
                                      y: top ? frame(in: fitted).minY : frame(in: fitted).maxY)
                            .gesture(drag(in: fitted) { start, dx, dy in
                                var minX = start.minX, maxX = start.maxX, minY = start.minY, maxY = start.maxY
                                if left { minX = min(max(start.minX + dx, 0), maxX - Self.minSide) } else { maxX = max(min(start.maxX + dx, 1), minX + Self.minSide) }
                                if top { minY = min(max(start.minY + dy, 0), maxY - Self.minSide) } else { maxY = max(min(start.maxY + dy, 1), minY + Self.minSide) }
                                return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
                            })
                    }
                }
                .frame(width: fitted.width, height: fitted.height)
                .frame(width: Self.area.width, height: Self.area.height)
            }
            HStack {
                Button(L("Rotate"), systemImage: "rotate.right") { rotate() }
                Button(L("Reset")) { crop = CGRect(x: 0, y: 0, width: 1, height: 1) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("Done")) { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .onAppear {
            working = NSBitmapImageRep(data: image.jpeg)?.cgImage
        }
    }

    private func fit(_ size: CGSize) -> CGSize {
        let scale = min(Self.area.width / size.width, Self.area.height / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private func frame(in fitted: CGSize) -> CGRect {
        CGRect(x: crop.minX * fitted.width, y: crop.minY * fitted.height, width: crop.width * fitted.width, height: crop.height * fitted.height)
    }

    /// A drag that turns its translation (as fractions of the picture) into a new crop.
    private func drag(in fitted: CGSize, _ update: @escaping (CGRect, CGFloat, CGFloat) -> CGRect) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .global)
            .onChanged { value in
                let start = dragStart ?? crop
                dragStart = start
                crop = update(start, value.translation.width / fitted.width, value.translation.height / fitted.height)
            }
            .onEnded { _ in dragStart = nil }
    }

    private func rotate() {
        guard let source = working,
              let ctx = CGContext(data: nil, width: source.height, height: source.width, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
        ctx.translateBy(x: 0, y: CGFloat(source.width))
        ctx.rotate(by: -.pi / 2)
        ctx.draw(source, in: CGRect(x: 0, y: 0, width: source.width, height: source.height))
        working = ctx.makeImage()
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    }

    private func apply() {
        guard let source = working else { return dismiss() }
        let rect = CGRect(x: crop.minX * CGFloat(source.width), y: crop.minY * CGFloat(source.height),
                          width: crop.width * CGFloat(source.width), height: crop.height * CGFloat(source.height)).integral
        if let cut = source.cropping(to: rect),
           let data = NSBitmapImageRep(cgImage: cut).representation(using: .jpeg, properties: [.compressionFactor: 0.9]),
           let result = Images.prepare(data) {
            done(result)
        }
        dismiss()
    }
}
