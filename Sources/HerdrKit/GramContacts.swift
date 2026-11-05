import Foundation

/// One agent in Gram's contact list: its roster row while it runs, and its Gram history
/// (herdr's entries about it, the Grams it sent, the owner's posts to it).
public struct GramContact: Identifiable, Equatable, Sendable {
    public enum Key: Hashable, Sendable {
        /// The agent in a pane of a herdr session (`default` for the unnamed one).
        case pane(session: String, paneID: String)
        /// A sender or recipient known only by name: an older Gram, a relayed agent.
        case name(String)
        /// The shared queue: the owner's posts any agent may grab.
        case queue
    }

    public let key: Key
    /// The task the agent works on (its pane title), else its name.
    public var name: String
    /// The last part of the agent's working directory ("monorepo").
    public var folder: String?
    /// The roster row, while the agent runs.
    public var agent: AgentInfo?
    /// The newest message in its history.
    public var last: GramMessage?
    public var unread: Int
    /// The agent is waiting on the owner: blocked now, or an unanswered `blocked` entry.
    public var waiting: Bool

    public init(key: Key, name: String, folder: String? = nil, agent: AgentInfo? = nil,
                last: GramMessage? = nil, unread: Int = 0, waiting: Bool = false) {
        self.key = key
        self.name = name
        self.folder = folder
        self.agent = agent
        self.last = last
        self.unread = unread
        self.waiting = waiting
    }

    public var id: String {
        switch key {
        case .pane(let session, let paneID): return "\(session)/\(paneID)"
        case .name(let name): return "@\(name)"
        case .queue: return "queue"
        }
    }

    /// The last part of a path ("/home/x/Code/monorepo" → "monorepo"), nil for none or "/".
    public static func folder(of cwd: String?) -> String? {
        guard let cwd else { return nil }
        let name = (cwd as NSString).lastPathComponent
        return name.isEmpty || name == "/" ? nil : name
    }
}

/// Gram's messages grouped by agent, with every running agent listed even before it has
/// written. Built from the loaded messages and the roster of every session shown.
public struct GramContactIndex: Sendable {
    public let contacts: [GramContact]
    /// Agent names (an agent's `name`, a Gram's `from`) to the pane they belong to.
    private let aliases: [String: GramContact.Key]

    /// `connectedSession` names the session whose roster rows carry no `session`.
    public init(messages: [GramMessage], agents: [AgentInfo], connectedSession: String) {
        let live = agents.filter { !$0.isSubagent && !$0.paneID.isEmpty }
        func paneKey(_ agent: AgentInfo) -> GramContact.Key {
            .pane(session: agent.session ?? connectedSession, paneID: agent.paneID)
        }
        // The newest stamped Gram names an agent's pane; a running agent's name wins.
        var aliases: [String: GramContact.Key] = [:]
        for message in messages.reversed() where message.isFromAgent {
            if let key = Self.stampedKey(message) { aliases[message.from] = key }
        }
        for agent in live { if let name = agent.name, !name.isEmpty { aliases[name] = paneKey(agent) } }
        self.aliases = aliases

        // `messages` is newest first: a contact's first message is its last, and its name
        // and folder come from the newest entry that has them (herdr's entries carry the
        // pane title).
        var byKey: [GramContact.Key: GramContact] = [:]
        var titled: Set<GramContact.Key> = []
        var order: [GramContact.Key] = []
        for message in messages {
            let key = Self.key(of: message, aliases: aliases)
            var contact = byKey[key] ?? GramContact(
                key: key, name: Self.fallbackName(key, message), folder: nil, agent: nil,
                last: message, unread: 0, waiting: message.kind == .blocked && !message.resolved)
            if byKey[key] == nil { order.append(key) }
            if message.isUnread { contact.unread += 1 }
            if contact.folder == nil { contact.folder = message.folder }
            if message.kind != nil, titled.insert(key).inserted { contact.name = message.from }
            byKey[key] = contact
        }
        // Every running agent, history or not; what it shows now wins.
        for agent in live {
            let key = paneKey(agent)
            var contact = byKey[key] ?? GramContact(
                key: key, name: "", folder: nil, agent: nil, last: nil, unread: 0, waiting: false)
            if byKey[key] == nil { order.append(key) }
            contact.agent = agent
            contact.name = agent.name.flatMap { $0.isEmpty ? nil : $0 } ?? agent.activityText
                ?? agent.terminalTitleStripped ?? agent.agent ?? agent.paneID
            contact.folder = GramContact.folder(of: agent.cwd) ?? contact.folder
            contact.waiting = agent.agentStatus == "blocked"
            byKey[key] = contact
        }
        // Waiting first, then the latest conversation; agents with no history by name.
        contacts = order.compactMap { byKey[$0] }.sorted { a, b in
            if a.waiting != b.waiting { return a.waiting }
            let at = a.last?.createdUnixMs ?? 0, bt = b.last?.createdUnixMs ?? 0
            if at != bt { return at > bt }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    /// The contact a message belongs to.
    public func key(of message: GramMessage) -> GramContact.Key {
        Self.key(of: message, aliases: aliases)
    }

    private static func stampedKey(_ message: GramMessage) -> GramContact.Key? {
        guard let paneID = message.paneID, let session = message.session else { return nil }
        return .pane(session: session, paneID: paneID)
    }

    private static func key(of message: GramMessage, aliases: [String: GramContact.Key]) -> GramContact.Key {
        if let key = stampedKey(message) { return key }
        let name = message.isFromAgent ? message.from : message.to
        guard let name else { return .queue }
        return aliases[name] ?? .name(name)
    }

    private static func fallbackName(_ key: GramContact.Key, _ message: GramMessage) -> String {
        switch key {
        case .pane(_, let paneID): return message.isFromAgent ? message.from : paneID
        case .name(let name): return GramMessage.agentName(from: name)
        case .queue: return "Shared queue"
        }
    }
}
