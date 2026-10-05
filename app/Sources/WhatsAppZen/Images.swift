import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Image loading and conversion. Everything is decoded at display size, never
/// at full resolution, which is most of what keeps memory low.
enum Images {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.totalCostLimit = 12 << 20
        return c
    }()

    private static let queue = DispatchQueue(label: "images", qos: .userInitiated, attributes: .concurrent)

    private static func decode(_ source: CGImageSource, maxPixel: CGFloat) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ] as CFDictionary)
    }

    private static func image(_ cg: CGImage) -> NSImage {
        NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Loads a file downsampled to at most `maxPixel` on its long edge.
    static func load(path: String, maxPixel: CGFloat) async -> NSImage? {
        let key = "\(path)#\(Int(maxPixel))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        return await withCheckedContinuation { cont in
            queue.async {
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = decode(src, maxPixel: maxPixel) else {
                    cont.resume(returning: nil)
                    return
                }
                let img = image(cg)
                cache.setObject(img, forKey: key, cost: cg.bytesPerRow * cg.height)
                cont.resume(returning: img)
            }
        }
    }

    /// Decodes a file without keeping it: for the full-size viewer, whose
    /// pictures are far too large to hold on to.
    static func loadUncached(path: String, maxPixel: CGFloat) async -> NSImage? {
        await withCheckedContinuation { cont in
            queue.async {
                guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                      let cg = decode(src, maxPixel: maxPixel) else {
                    cont.resume(returning: nil)
                    return
                }
                cont.resume(returning: image(cg))
            }
        }
    }

    /// Drops every decoded image and hands freed memory back to the system.
    static func trim() {
        cache.removeAllObjects()
        malloc_zone_pressure_relief(nil, 0)
    }

    /// An already decoded image, if it is still in memory. Lets a view that is
    /// rebuilt show its picture at once instead of flashing the placeholder.
    static func cached(path: String, maxPixel: CGFloat) -> NSImage? {
        cache.object(forKey: "\(path)#\(Int(maxPixel))" as NSString)
    }

    /// The tiny blurred preview WhatsApp embeds in media messages.
    static func thumbnail(base64: String?) -> NSImage? {
        guard let base64, let data = Data(base64Encoded: base64) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Avatars

    private static var avatarKeys: [String: NSString] = [:]
    private static var avatarPaths: [String: (path: String, at: Date)] = [:]

    /// Profile photo for a jid at a point size, or nil when there is none.
    static func avatar(jid: String, size: CGFloat) async -> NSImage? {
        // Rows are rebuilt constantly while scrolling; remember the answer
        // (including "no photo") for a while instead of asking the core again.
        let account = Core.active
        let known = await MainActor.run { avatarPaths["\(account)/\(jid)"] }
        var path = ""
        if let known, Date().timeIntervalSince(known.at) < 600 {
            path = known.path
        } else {
            path = (try? await Core.call("avatar", ["jid": jid], account: account)) ?? ""
            let found = path
            await MainActor.run { avatarPaths["\(account)/\(jid)"] = (found, Date()) }
        }
        let file = path
        guard !file.isEmpty else { return nil }
        let img = await load(path: file, maxPixel: size * 2)
        await MainActor.run { avatarKeys[jid] = "\(file)#\(Int(size * 2))" as NSString }
        return img
    }

    @MainActor
    static func forgetAvatar(_ jid: String) {
        if let key = avatarKeys.removeValue(forKey: jid) { cache.removeObject(forKey: key) }
        avatarPaths = avatarPaths.filter { !$0.key.hasSuffix("/\(jid)") }
    }

    // MARK: Sending

    private static func jpeg(_ cg: CGImage, quality: CGFloat) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// Converts arbitrary image data into what gets sent: a JPEG capped at
    /// 1600px plus the small embedded thumbnail.
    static func prepare(_ data: Data) -> PendingImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let full = decode(src, maxPixel: 1600),
              let small = decode(src, maxPixel: 72),
              let preview = decode(src, maxPixel: 240),
              let body = jpeg(full, quality: 0.82),
              let thumb = jpeg(small, quality: 0.5) else { return nil }
        return PendingImage(jpeg: body, thumb: thumb.base64EncodedString(), width: full.width, height: full.height,
                            preview: image(preview))
    }

    private static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Images on the pasteboard: copied files first, then raw image data.
    static func fromPasteboard(_ pb: NSPasteboard = .general) -> [PendingImage] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        let files = urls.filter(isImage).compactMap { try? Data(contentsOf: $0) }.compactMap(prepare)
        if !files.isEmpty { return files }
        // Copied text often carries an image rendering too (e.g. from Office);
        // only treat the pasteboard as an image when there is no text.
        if pb.string(forType: .string) != nil { return [] }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pb.data(forType: type), let img = prepare(data) { return [img] }
        }
        return []
    }

    /// Resolves dropped items (files or image data) into staged images.
    static func fromDrop(_ providers: [NSItemProvider], completion: @escaping @MainActor ([PendingImage]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var result: [PendingImage] = []
        func add(_ data: Data?) {
            if let data, let img = prepare(data) {
                lock.lock()
                result.append(img)
                lock.unlock()
            }
            group.leave()
        }
        for p in providers {
            group.enter()
            if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    add(url.flatMap { isImage($0) ? try? Data(contentsOf: $0) : nil })
                }
            } else if p.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                _ = p.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in add(data) }
            } else {
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let images = result
            Task { @MainActor in completion(images) }
        }
    }
}
