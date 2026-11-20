import Foundation

/// What the home-screen widgets show. It is saved in the app group by whoever saw the machine
/// last: the app, from its roster, accounts and Live Activity, or the notification service
/// extension, from an agent alert that arrived while the app was closed. A widget cannot reach
/// the machine itself, so this is all it has.
///
/// Foundation-only, like AgentActivityState.swift beside it, so SwiftPM can test it.
struct WidgetSnapshot: Codable, Equatable {
    struct Usage: Codable, Equatable {
        /// "claude" or "codex".
        var provider: String
        /// Percent left in the account's tightest rate-limit window.
        var remainingPercent: Double
        /// That window's label, e.g. "5h" or "weekly".
        var window: String
        var resetsAt: Date?
    }

    /// The agent waiting on the owner, and what it asks.
    struct Ask: Codable, Equatable {
        var agent: String
        /// The lines above its menu, as herdr read them; nil when herdr could not.
        var request: String?
        var paneID: String
        /// The herdr session it lives in; nil means the app's own session at the time.
        var session: String?
        var since: Date
    }

    var host: String
    var apm: Double?
    var running: Int
    var blocked: Int
    var usage: [Usage]
    var ask: Ask?
    var updatedAt: Date

    var apmText: String? { AgentActivityState.apmText(apm) }

    /// Where a tap goes: straight to the waiting agent to answer it, else the app.
    var tapURL: URL {
        AgentActivityDeepLink.url(agentID: ask?.paneID, session: ask?.session)
    }

    static let appGroup = "group.inc.simcast.herdrup"
    private static let key = "widget.snapshot"

    static func load(from defaults: UserDefaults? = UserDefaults(suiteName: appGroup)) -> WidgetSnapshot? {
        guard let data = defaults?.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    func save(to defaults: UserDefaults? = UserDefaults(suiteName: WidgetSnapshot.appGroup)) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults?.set(data, forKey: Self.key)
    }

    /// The same snapshot apart from when it was taken: what decides whether widgets reload.
    func sameContent(as other: WidgetSnapshot?) -> Bool {
        guard var other else { return false }
        other.updatedAt = updatedAt
        return other == self
    }

    /// Fold in an agent alert from herdr's push payload, received while the app may be closed.
    /// `needs_input` makes that agent the one asking; `finished` or `died` for the agent that
    /// was asking clears it. Nil when the alert is not about an agent or changes nothing.
    static func applying(alert payload: [AnyHashable: Any], to current: WidgetSnapshot?,
                         now: Date) -> WidgetSnapshot? {
        guard payload["gram"] == nil,
              let kind = payload["kind"] as? String,
              let paneID = payload["pane_id"] as? String, !paneID.isEmpty else { return nil }
        let session = payload["session"] as? String
        var next = current ?? WidgetSnapshot(host: "", apm: nil, running: 0, blocked: 0, usage: [],
                                             ask: nil, updatedAt: now)
        switch kind {
        case "needs_input":
            // Not the alert body: without a request herdr falls back to "workspace · tab".
            let request = (payload["request"] as? String)
                ?? (payload["herdr_ask"] as? [String: Any])?["question"] as? String
            next.ask = Ask(agent: (payload["agent"] as? String) ?? "An agent", request: request,
                           paneID: paneID, session: session, since: now)
            next.blocked = max(next.blocked, 1)
        case "finished", "died":
            guard let ask = next.ask, ask.paneID == paneID, ask.session == session else { return nil }
            next.ask = nil
            next.blocked = max(next.blocked - 1, 0)
        default:
            return nil
        }
        next.updatedAt = now
        return next
    }
}
