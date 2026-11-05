import Foundation

// HerdrUp's feed: cards scripts on the machine write to
// `~/.config/herdr/feeds/<source>/<id>.json`, served whole by `feed.list` over the owner's own
// connection (the SSH connection is the encryption, so a private summary needs no public URL).
// A card is something to read, or a question: actions to pick and/or a text field. The owner
// answers with `feed.act`; herdr records the answer beside the card (`<id>.reply.json`) and runs
// the source's `on-reply` script.

/// One card file from `feed.list`: its JSON and the owner's answer, unparsed, or why the
/// machine could not serve it.
public struct FeedCardFile: Decodable, Sendable, Equatable {
    public let source: String
    public let id: String
    public let card: String?
    public let reply: String?
    public let error: String?

    public init(source: String, id: String, card: String?, reply: String? = nil, error: String? = nil) {
        self.source = source
        self.id = id
        self.card = card
        self.reply = reply
        self.error = error
    }
}

/// A button on a card. `role: "destructive"` draws it red.
public struct FeedAction: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let label: String
    public let role: String?

    public var isDestructive: Bool { role == "destructive" }
}

/// The owner's answer, as herdr recorded it.
public struct FeedReply: Codable, Sendable, Hashable {
    public let action: String?
    public let text: String?
    public let at: Date?

    public init(action: String?, text: String?, at: Date?) {
        self.action = action
        self.text = text
        self.at = at
    }
}

/// One card, as the timeline and the reader show it.
public struct FeedEntry: Identifiable, Codable, Sendable, Hashable {
    /// `source/id`: the file's own name, so read and starred marks survive a rewrite.
    public let id: String
    public let source: String
    public let cardID: String
    public let title: String
    /// Markdown.
    public let body: String
    /// The timeline's preview; nil previews the body.
    public let summary: String?
    public let date: Date?
    public let link: URL?
    public let actions: [FeedAction]
    /// The text field's placeholder: present when the card takes text.
    public let input: String?
    /// Asked again before an action is sent.
    public let confirm: String?
    public let expires: Date?
    /// What the script made of the answer, written back into the card.
    public let outcome: String?
    public var reply: FeedReply?

    /// Whether the card asks the owner something.
    public var asks: Bool { !actions.isEmpty || input != nil }

    /// Still waiting for the owner: it asks, and is neither answered, settled by its script,
    /// nor expired.
    public func isPending(at now: Date = Date()) -> Bool {
        asks && reply == nil && outcome == nil && !isExpired(at: now)
    }

    public func isExpired(at now: Date = Date()) -> Bool { expires.map { $0 <= now } ?? false }

    /// The answer in a few words: the chosen action's label, then the text.
    public var replySummary: String? {
        guard let reply else { return nil }
        let label = reply.action.map { id in actions.first { $0.id == id }?.label ?? id }
        let parts = [label, reply.text.map { "“\($0)”" }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

public enum FeedCards {
    public enum Failure: Error, Equatable { case notACard }

    /// The card in `file`; throws when its JSON is not an object.
    public static func entry(_ file: FeedCardFile) throws -> FeedEntry {
        guard let json = file.card,
              let card = try? JSONDecoder().decode(Card.self, from: Data(json.utf8)) else {
            throw Failure.notACard
        }
        let reply = file.reply
            .flatMap { try? JSONDecoder().decode(Reply.self, from: Data($0.utf8)) }
            .map { FeedReply(action: $0.action, text: $0.text, at: $0.at.flatMap(parseDate)) }
        let body = card.body ?? ""
        let title = card.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return FeedEntry(
            id: file.source + "/" + file.id, source: file.source, cardID: file.id,
            title: title.isEmpty ? file.id : title, body: body,
            summary: card.summary?.isEmpty == false ? card.summary : nil,
            date: card.date.flatMap(parseDate), link: card.link.flatMap { URL(string: $0) },
            actions: card.actions ?? [], input: card.input, confirm: card.confirm,
            expires: card.expires.flatMap(parseDate), outcome: card.outcome, reply: reply)
    }

    /// Newest first; undated cards last, in their given order.
    public static func newestFirst(_ entries: [FeedEntry]) -> [FeedEntry] {
        entries.enumerated().sorted { a, b in
            switch (a.element.date, b.element.date) {
            case let (x?, y?): return x != y ? x > y : a.offset < b.offset
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return a.offset < b.offset
            }
        }.map(\.element)
    }

    /// ISO 8601, with or without fractional seconds.
    static func parseDate(_ text: String) -> Date? {
        for formatter in isoFormatters { if let date = formatter.date(from: text) { return date } }
        return nil
    }

    private static let isoFormatters: [ISO8601DateFormatter] = {
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions.insert(.withFractionalSeconds)
        return [plain, fractional]
    }()

    private struct Card: Decodable {
        let title: String?
        let body: String?
        let summary: String?
        let date: String?
        let link: String?
        let actions: [FeedAction]?
        let input: String?
        let confirm: String?
        let expires: String?
        let outcome: String?
    }

    private struct Reply: Decodable {
        let action: String?
        let text: String?
        let at: String?
    }
}
