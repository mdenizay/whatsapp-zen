import AppKit

/// Saving a message's file (a PDF, a photo, a voice note) where the user keeps
/// files, rather than leaving it in the app's own cache.
enum Downloads {
    /// Copies the file into ~/Downloads, fetching it from WhatsApp first if
    /// needed, and returns where it went.
    @MainActor static func save(_ message: Message) async -> URL? {
        guard let folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first,
              let path = await mediaPath(for: message) else { return nil }
        let source = URL(fileURLWithPath: path)
        let target = unique(folder.appendingPathComponent(name(for: message, source: source)))
        do {
            try FileManager.default.copyItem(at: source, to: target)
        } catch {
            return nil
        }
        // What makes the Downloads stack in the Dock bounce, as after a browser download.
        DistributedNotificationCenter.default().post(name: Notification.Name("com.apple.DownloadFileFinished"), object: target.path)
        return target
    }

    /// Asks where to put the file.
    @MainActor static func saveAs(_ message: Message) async -> Bool {
        guard let path = await mediaPath(for: message) else { return false }
        let source = URL(fileURLWithPath: path)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name(for: message, source: source)
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let target = panel.url else { return true }
        try? FileManager.default.removeItem(at: target)
        return (try? FileManager.default.copyItem(at: source, to: target)) != nil
    }

    /// The name the sender gave the file, or one made from its kind and time.
    static func name(for message: Message, source: URL) -> String {
        if let given = message.fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !given.isEmpty {
            let safe = given.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            // A name without an extension would not open; borrow the cached file's.
            return (safe as NSString).pathExtension.isEmpty && !source.pathExtension.isEmpty ? "\(safe).\(source.pathExtension)" : safe
        }
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = "WhatsApp \(message.type.capitalized) \(stamp.string(from: message.date))"
        return source.pathExtension.isEmpty ? base : "\(base).\(source.pathExtension)"
    }

    /// "Report.pdf", then "Report 2.pdf", "Report 3.pdf"…: never over an existing file.
    static func unique(_ url: URL) -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else { return url }
        let folder = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var n = 2
        while true {
            let candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }
}
