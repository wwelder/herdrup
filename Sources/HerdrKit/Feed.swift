import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// HerdrUp's feed: RSS 2.0 and Atom files a script wrote to `~/.config/herdr/feeds/` on the
// machine, served whole by `feed.list` over the owner's own connection, and parsed here. A
// private summary (sleep, a digest) never needs a public URL or a key of its own: the SSH
// connection is the encryption.

/// One file from `feed.list`: its XML, or why the machine could not serve it.
public struct FeedFile: Decodable, Sendable, Equatable {
    public let name: String
    public let xml: String?
    public let error: String?

    public init(name: String, xml: String?, error: String? = nil) {
        self.name = name
        self.xml = xml
        self.error = error
    }
}

/// One item of a feed, as the timeline and the reader show it.
public struct FeedEntry: Identifiable, Codable, Sendable, Equatable, Hashable {
    /// Stable across refreshes: the file, then the item's guid (or its link, or its title
    /// and date), so read and starred marks survive a rewrite of the file.
    public let id: String
    /// The file it came from: the filter key.
    public let feed: String
    public let feedTitle: String
    public let title: String
    public let link: URL?
    public let date: Date?
    public let author: String?
    /// The item's content, HTML as RSS carries it, or plain text.
    public let content: String
    /// The content as plain text on one line, for the timeline.
    public let excerpt: String
}

/// A parsed feed file.
public struct FeedChannel: Sendable, Equatable {
    public let title: String
    /// Newest first; undated items last, in file order.
    public let entries: [FeedEntry]
}

public enum FeedParser {
    public enum Failure: Error, Equatable { case notAFeed }

    /// Parses an RSS 2.0 or Atom document from `file`. The title falls back to the file name.
    public static func parse(_ xml: String, file: String) throws -> FeedChannel {
        let collector = Collector()
        let parser = XMLParser(data: Data(xml.utf8))
        parser.delegate = collector
        guard parser.parse() || !collector.items.isEmpty, collector.isFeed else { throw Failure.notAFeed }
        let fallback = (file as NSString).deletingPathExtension
        let feedTitle = collector.channelTitle.isEmpty ? fallback : collector.channelTitle
        let entries = collector.items.map { item -> FeedEntry in
            let content = item.content.isEmpty ? item.summary : item.content
            let date = parseDate(item.published) ?? parseDate(item.updated)
            let key = [item.guid, item.link, item.title + "|" + item.published]
                .first { !$0.isEmpty } ?? ""
            return FeedEntry(
                id: file + "#" + key, feed: file, feedTitle: feedTitle,
                title: item.title.isEmpty ? FeedText.plain(content, limit: 80) : item.title,
                link: URL(string: item.link), date: date,
                author: item.author.isEmpty ? nil : item.author,
                // RSS's own split: `description` is the teaser when the article is in `content`.
                content: content, excerpt: FeedText.plain(item.summary.isEmpty ? content : item.summary, limit: 300))
        }
        let sorted = entries.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
        return FeedChannel(title: feedTitle, entries: sorted)
    }

    /// RFC 822 (RSS) or ISO 8601 (Atom).
    static func parseDate(_ text: String) -> Date? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for formatter in isoFormatters { if let date = formatter.date(from: text) { return date } }
        for formatter in rfc822Formatters { if let date = formatter.date(from: text) { return date } }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return [plain, fractional]
    }()

    private static let rfc822Formatters: [DateFormatter] = [
        "EEE, d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm:ss zzz", "EEE, d MMM yyyy HH:mm Z",
        "d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss zzz", "yyyy-MM-dd",
    ].map { format in
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = format
        return formatter
    }

    private struct Item {
        var title = "", link = "", guid = "", published = "", updated = ""
        var summary = "", content = "", author = ""
    }

    /// Collects the channel title and each `<item>` / `<entry>`, by element name with any
    /// namespace prefix kept (`content:encoded`, `dc:creator`).
    private final class Collector: NSObject, XMLParserDelegate {
        var channelTitle = ""
        var items: [Item] = []
        var isFeed = false
        private var path: [String] = []
        private var item: Item?
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if path.isEmpty { isFeed = name == "rss" || name == "feed" || name == "rdf:RDF" }
            path.append(name)
            text = ""
            if name == "item" || name == "entry" { item = Item() }
            // Atom's link is an attribute; the page link is `alternate` or has no rel.
            if name == "link", item != nil, let href = attributes["href"],
               (attributes["rel"] ?? "alternate") == "alternate" {
                item?.link = href
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

        func parser(_ parser: XMLParser, foundCDATA block: Data) {
            text += String(decoding: block, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            defer { path.removeLast(); text = "" }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = path.count >= 2 ? path[path.count - 2] : ""
            if name == "item" || name == "entry" {
                if let item { items.append(item) }
                item = nil
                return
            }
            guard item != nil else {
                if name == "title", parent == "channel" || parent == "feed", channelTitle.isEmpty {
                    channelTitle = value
                }
                return
            }
            switch name {
            case "title" where parent == "item" || parent == "entry": item?.title = value
            case "link" where !value.isEmpty && (item?.link.isEmpty ?? false): item?.link = value
            case "guid", "id": item?.guid = value
            case "pubDate", "published", "dc:date": item?.published = value
            case "updated": item?.updated = value
            case "description", "summary": item?.summary = value
            case "content:encoded", "content": item?.content = value
            case "dc:creator", "author" where !value.isEmpty && !value.contains("\n"): item?.author = value
            case "name" where parent == "author": item?.author = value
            default: break
            }
        }
    }
}

/// HTML as the timeline shows it: tags dropped, the common entities decoded, whitespace
/// collapsed.
public enum FeedText {
    public static func plain(_ html: String, limit: Int) -> String {
        var text = html.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return text.count > limit ? String(text.prefix(limit)) + "…" : text
    }

    /// Whether `content` is HTML rather than plain text: it has at least one tag.
    public static func looksLikeHTML(_ content: String) -> Bool {
        content.range(of: "</?[a-zA-Z][^>]*>", options: .regularExpression) != nil
    }

    // `&amp;` last, so `&amp;lt;` stays `&lt;`.
    private static let entities = [("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                                   ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")]
}
