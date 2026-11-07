import Foundation
import WidgetKit
import HerdrKit

/// Keeps the home-screen widgets' snapshot (`WidgetSnapshot`) in step with what the app sees,
/// and reloads the widgets when it changes. While the app is closed, the notification service
/// extension updates the waiting agent from herdr's alerts instead.
@MainActor
enum WidgetSync {
    /// A snapshot whose content has not changed is still rewritten this often, so the
    /// widgets' "updated" age stays honest while the app is open.
    private static let refreshAge: TimeInterval = 10 * 60

    static func update(host: String, session: String, list: AgentList,
                       accounts: [CredentialAccount], apm: Double?) {
        let previous = WidgetSnapshot.load()
        let content = list.activityContent
        var ask: WidgetSnapshot.Ask?
        if content.statusWord == "needsYou", let lead = list.activityLead {
            ask = .init(agent: lead.title, request: lead.info.pendingRequest,
                        paneID: lead.info.paneID, session: lead.info.session ?? session,
                        since: lead.info.statusSinceUnixMs.map { Date(timeIntervalSince1970: Double($0) / 1000) } ?? Date())
        }
        let usage = providerUsage(accounts: accounts).map {
            WidgetSnapshot.Usage(provider: $0.provider, remainingPercent: $0.remainingPercent,
                                 window: $0.window, resetsAt: $0.resetsAt)
        }
        let snapshot = WidgetSnapshot(
            host: host, apm: apm ?? previous?.apm, running: content.workingCount,
            blocked: content.needsYouCount,
            // accounts.list can lag the first agent list; keep the last usage until it lands.
            usage: usage.isEmpty ? previous?.usage ?? [] : usage,
            ask: ask, updatedAt: Date())
        if snapshot.sameContent(as: previous), let previous,
           Date().timeIntervalSince(previous.updatedAt) < refreshAge { return }
        snapshot.save()
        WidgetCenter.shared.reloadAllTimelines()
    }
}
