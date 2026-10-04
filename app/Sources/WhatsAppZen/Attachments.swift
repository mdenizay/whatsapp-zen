import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// A video or document staged for sending.
struct PendingFile: Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    /// "video" or "document", as the core's send_file command expects.
    let kind: String
    let mime: String
    let bytes: Int
    var thumb = ""
    var width = 0
    var height = 0
    var seconds = 0
    var preview: NSImage?

    var sizeText: String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

enum Attachments {
    static func isImage(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) ?? false
    }

    /// Describes a non-image file; videos also get a poster frame and duration.
    static func file(at url: URL) async -> PendingFile? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
              values.isDirectory != true else { return nil }
        let type = UTType(filenameExtension: url.pathExtension)
        let isVideo = type?.conforms(to: .movie) ?? false
        var file = PendingFile(url: url, name: url.lastPathComponent, kind: isVideo ? "video" : "document",
                               mime: type?.preferredMIMEType ?? "application/octet-stream", bytes: values.fileSize ?? 0)
        guard isVideo else { return file }

        let asset = AVURLAsset(url: url)
        if let duration = try? await asset.load(.duration) { file.seconds = Int(duration.seconds.rounded()) }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        if let frame = try? await generator.image(at: .zero).image {
            file.width = frame.width
            file.height = frame.height
            file.preview = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
            file.thumb = jpegThumb(frame)?.base64EncodedString() ?? ""
        }
        return file
    }

    /// The small JPEG WhatsApp embeds in a message as its blurred placeholder.
    private static func jpegThumb(_ image: CGImage) -> Data? {
        let scale = 72 / CGFloat(max(image.width, image.height))
        let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(origin: .zero, size: size))
        guard let small = ctx.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: small).representation(using: .jpeg, properties: [.compressionFactor: 0.5])
    }

    /// File URLs currently on the pasteboard (files copied in Finder).
    static func fileURLs(on pb: NSPasteboard = .general) -> [URL] {
        (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// The file URL carried by a dropped item, if it is a file.
    static func fileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}

/// Plays voice messages in place. One clip at a time.
final class AudioPlayer: NSObject, ObservableObject, AVAudioPlayerDelegate {
    static let shared = AudioPlayer()

    @Published private(set) var playingID: String?
    @Published private(set) var progress = 0.0

    private var player: AVAudioPlayer?
    private var timer: Timer?

    func toggle(id: String, path: String) {
        if playingID == id {
            stop()
            return
        }
        stop()
        guard let player = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: path)) else {
            // Not a format the system decodes: hand it to whatever app can.
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
            return
        }
        player.delegate = self
        player.play()
        self.player = player
        playingID = id
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self, let p = self.player, p.duration > 0 else { return }
            self.progress = p.currentTime / p.duration
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        player?.stop()
        player = nil
        playingID = nil
        progress = 0
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stop() }
}
