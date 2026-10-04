import AppKit
import MapKit
import SwiftUI

/// A shared location: a small map with a pin, opening in Maps on click.
struct LocationCard: View {
    struct Place: Equatable {
        let latitude: Double
        let longitude: Double
        /// The place's name, when the sender attached one.
        let name: String

        var url: URL? {
            var parts = URLComponents(string: "https://maps.apple.com/")
            parts?.queryItems = [URLQueryItem(name: "ll", value: "\(latitude),\(longitude)")]
                + (name.isEmpty ? [] : [URLQueryItem(name: "q", value: name)])
            return parts?.url
        }
    }

    let place: Place
    let onBubble: Bool

    @State private var map: NSImage?

    private static let size = CGSize(width: 250, height: 136)

    /// Reads the coordinates out of a location message as the core words it:
    /// "📍 Location[: name]" on one line, a maps link on the next.
    static func place(in text: String) -> Place? {
        guard text.hasPrefix("📍"), let range = text.range(of: "maps.apple.com/?ll=") else { return nil }
        let numbers = text[range.upperBound...].prefix { $0.isNumber || $0 == "." || $0 == "," || $0 == "-" }.split(separator: ",")
        guard numbers.count == 2, let latitude = Double(numbers[0]), let longitude = Double(numbers[1]) else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        let name = first.contains(":") ? first.split(separator: ":", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "" : ""
        return Place(latitude: latitude, longitude: longitude, name: name)
    }

    var body: some View {
        Button {
            if let url = place.url { NSWorkspace.shared.open(url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack {
                    if let map {
                        Image(nsImage: map).resizable().scaledToFill()
                    } else {
                        Rectangle().fill(.quaternary)
                    }
                    Image(systemName: "mappin.circle.fill")
                        .font(.system(size: 30))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .red)
                        .shadow(radius: 2, y: 1)
                }
                .frame(width: Self.size.width, height: Self.size.height)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack(spacing: 5) {
                    Image(systemName: "location.fill").font(.caption)
                    Text(place.name.isEmpty ? L("Location") : place.name).lineLimit(2)
                    Spacer(minLength: 0)
                    Image(systemName: "arrow.up.forward").font(.caption).opacity(0.7)
                }
                .font(.callout.weight(.medium))
                .frame(width: Self.size.width, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(L("Open in Maps"))
        .task(id: place) { map = await MapSnapshots.image(for: place, size: Self.size) }
    }
}

/// Small static maps, drawn once per place and kept in memory.
enum MapSnapshots {
    private static let cache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 40
        return c
    }()

    static func image(for place: LocationCard.Place, size: CGSize) async -> NSImage? {
        let key = "\(place.latitude),\(place.longitude)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude),
                                            latitudinalMeters: 900, longitudinalMeters: 900)
        options.size = size
        guard let snapshot = try? await MKMapSnapshotter(options: options).start() else { return nil }
        cache.setObject(snapshot.image, forKey: key)
        return snapshot.image
    }
}
