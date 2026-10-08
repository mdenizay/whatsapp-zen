import Foundation
import SwiftUI

/// WhatsApp's text formatting: *bold*, _italic_, ~strikethrough~, `code` and
/// ```monospace``` blocks, with links made clickable. Markers only count at
/// word edges, as on the phone, so snake_case and 2*3*4 stay as typed.
enum MessageFormat {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Markdown's doubled markers (**bold**, __italic__, ~~strike~~), common
    /// in text pasted from elsewhere, as WhatsApp's single ones. Sent text is
    /// converted too, so the other side sees the formatting as well.
    static func normalized(_ text: String) -> String {
        guard text.contains("**") || text.contains("__") || text.contains("~~") else { return text }
        var out = text
        for (double, single) in [("\\*\\*", "*"), ("__", "_"), ("~~", "~")] {
            out = out.replacingOccurrences(of: "\(double)(?=\\S)([^\\n]+?)(?<=\\S)\(double)", with: "\(single)$1\(single)",
                                           options: .regularExpression)
        }
        return out
    }

    /// The scheme of the links put on "@Name" mentions; the row that shows
    /// the text opens that person's chat for them.
    static let mentionScheme = "zen-mention"

    /// `mentions` maps the names that may appear after "@" to the ids of the
    /// people; an empty id (yourself) is marked but not linked.
    static func attributed(_ raw: String, mentions: [String: String] = [:], mentionColor: Color = Theme.accent) -> AttributedString {
        let text = normalized(raw)
        let chars = Array(text)
        var links: [(range: Range<Int>, url: URL)] = []
        if !mentions.isEmpty {
            // Longest names first, so "@Ali Veli" is not taken for "@Ali".
            let names = mentions.keys.sorted { $0.count > $1.count }
            var i = 0
            while i < chars.count {
                if chars[i] == "@", i == 0 || !chars[i - 1].isLetter {
                    if let name = names.first(where: { name in
                        let end = i + 1 + name.count
                        return end <= chars.count && String(chars[(i + 1)..<end]) == name && (end == chars.count || !chars[end].isLetter)
                    }) {
                        let end = i + 1 + name.count
                        let target = mentions[name] ?? ""
                        if let url = URL(string: "\(mentionScheme):\(target.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")") {
                            links.append((i..<end, url))
                        }
                        i = end
                        continue
                    }
                }
                i += 1
            }
        }
        if let detector {
            var offset = 0
            var cursor = text.startIndex
            for match in detector.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                guard let url = match.url, let range = Range(match.range, in: text) else { continue }
                offset += text.distance(from: cursor, to: range.lowerBound)
                let length = text[range].count
                links.append((offset..<offset + length, url))
                offset += length
                cursor = range.upperBound
            }
        }
        func inLink(_ i: Int) -> Bool { links.contains { $0.range.contains(i) } }

        var out = AttributedString()
        func emit(_ lo: Int, _ hi: Int, _ intent: InlinePresentationIntent, _ strike: Bool) {
            var start = lo
            while start < hi {
                var end = hi
                var url: URL?
                for link in links {
                    if link.range.contains(start) {
                        end = min(hi, link.range.upperBound)
                        url = link.url
                        break
                    }
                    if link.range.lowerBound > start { end = min(end, link.range.lowerBound) }
                }
                var piece = AttributedString(String(chars[start..<end]))
                if !intent.isEmpty { piece.inlinePresentationIntent = intent }
                if strike { piece.strikethroughStyle = .single }
                if let url, url.scheme == mentionScheme {
                    // A mention: named, not underlined, and a link only to someone else.
                    piece.inlinePresentationIntent = intent.union(.stronglyEmphasized)
                    piece.foregroundColor = mentionColor
                    if url.absoluteString.count > mentionScheme.count + 1 { piece.link = url }
                } else if let url {
                    piece.link = url
                    piece.underlineStyle = .single
                }
                out += piece
                start = end
            }
        }

        func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

        /// Where a marker opened at `i` closes, on the same line.
        func closing(of marker: Character, from i: Int, before hi: Int) -> Int? {
            guard i > 0 ? !isWordChar(chars[i - 1]) : true,
                  i + 1 < hi, !chars[i + 1].isWhitespace, chars[i + 1] != marker else { return nil }
            var j = i + 2
            while j < hi {
                let c = chars[j]
                if c.isNewline { return nil }
                if c == marker, !chars[j - 1].isWhitespace, j + 1 == hi || !isWordChar(chars[j + 1]), !inLink(j) {
                    return j
                }
                j += 1
            }
            return nil
        }

        func parse(_ lo: Int, _ hi: Int, _ intent: InlinePresentationIntent, _ strike: Bool) {
            var i = lo
            var plainStart = lo
            while i < hi {
                let c = chars[i]
                guard "*_~`".contains(c), !inLink(i) else {
                    i += 1
                    continue
                }
                // ```a block```, which may span lines and is never formatted inside.
                if c == "`", i + 2 < hi, chars[i + 1] == "`", chars[i + 2] == "`" {
                    var k = i + 3
                    while k + 2 < hi, !(chars[k] == "`" && chars[k + 1] == "`" && chars[k + 2] == "`") { k += 1 }
                    if k + 2 < hi, k > i + 3 {
                        emit(plainStart, i, intent, strike)
                        emit(i + 3, k, intent.union(.code), strike)
                        i = k + 3
                        plainStart = i
                        continue
                    }
                    i += 3
                    continue
                }
                guard let j = closing(of: c, from: i, before: hi) else {
                    i += 1
                    continue
                }
                emit(plainStart, i, intent, strike)
                switch c {
                case "*": parse(i + 1, j, intent.union(.stronglyEmphasized), strike)
                case "_": parse(i + 1, j, intent.union(.emphasized), strike)
                case "~": parse(i + 1, j, intent, true)
                default: emit(i + 1, j, intent.union(.code), strike)
                }
                i = j + 1
                plainStart = i
            }
            emit(plainStart, hi, intent, strike)
        }

        parse(0, chars.count, [], false)
        return out
    }

    /// The text with its markers taken out, for one-line previews.
    static func plain(_ raw: String) -> String {
        String(attributed(raw).characters)
    }
}
