import XCTest
@testable import AgentActivityState

/// The home-screen widgets' snapshot: the deep link a tap follows, and how an agent alert
/// that arrives while the app is closed changes it.
final class WidgetSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_620_800)

    private func alert(_ kind: String, pane: String = "w1:p1", session: String = "top-l",
                       extra: [String: Any] = [:]) -> [AnyHashable: Any] {
        var payload: [AnyHashable: Any] = [
            "aps": ["alert": ["title": "jarvis needs attention", "body": "herdr · 1"]],
            "kind": kind, "agent": "jarvis", "pane_id": pane, "session": session,
        ]
        for (key, value) in extra { payload[key] = value }
        return payload
    }

    func testTapOpensTheAskingAgentInItsSessionOrElseTheApp() {
        var snapshot = WidgetSnapshot(host: "r2", apm: 1, running: 0, blocked: 0, usage: [], ask: nil, updatedAt: now)
        XCTAssertEqual(snapshot.tapURL.absoluteString, "herdrup://agents")
        snapshot.ask = .init(agent: "jarvis", request: nil, paneID: "w1:p1", session: "top-l", since: now)
        XCTAssertEqual(AgentActivityDeepLink.agentID(from: snapshot.tapURL), "w1:p1")
        XCTAssertEqual(AgentActivityDeepLink.session(from: snapshot.tapURL), "top-l")
        XCTAssertNil(AgentActivityDeepLink.session(from: AgentActivityDeepLink.url(agentID: "w1:p1")))
    }

    func testANeedsInputAlertBecomesTheAskWithHerdrsRequestOnly() throws {
        let asked = try XCTUnwrap(WidgetSnapshot.applying(
            alert: alert("needs_input", extra: ["request": "git push origin main\nDo you want to proceed?"]),
            to: nil, now: now))
        XCTAssertEqual(asked.ask, .init(agent: "jarvis", request: "git push origin main\nDo you want to proceed?",
                                        paneID: "w1:p1", session: "top-l", since: now))
        XCTAssertEqual(asked.blocked, 1)
        let bare = try XCTUnwrap(WidgetSnapshot.applying(alert: alert("needs_input"), to: nil, now: now))
        XCTAssertNil(bare.ask?.request, "the body's workspace · tab fallback is not a question")
    }

    func testOnlyTheAskingAgentFinishingClearsTheAsk() throws {
        let asked = try XCTUnwrap(WidgetSnapshot.applying(alert: alert("needs_input"), to: nil, now: now))
        XCTAssertNil(WidgetSnapshot.applying(alert: alert("finished", pane: "w2:p1"), to: asked, now: now))
        XCTAssertNil(WidgetSnapshot.applying(alert: alert("finished", session: "top-r"), to: asked, now: now),
                     "pane ids repeat across sessions")
        let cleared = try XCTUnwrap(WidgetSnapshot.applying(alert: alert("died"), to: asked, now: now))
        XCTAssertNil(cleared.ask)
        XCTAssertEqual(cleared.blocked, 0)
    }

    func testGramAndUnknownAlertsLeaveItAlone() {
        XCTAssertNil(WidgetSnapshot.applying(alert: alert("needs_input", extra: ["gram": true]), to: nil, now: now))
        XCTAssertNil(WidgetSnapshot.applying(alert: alert("something_new"), to: nil, now: now))
        XCTAssertNil(WidgetSnapshot.applying(alert: ["aps": [:]], to: nil, now: now), "an older herdr sends no kind")
    }

    func testSameContentIgnoresOnlyTheTimestamp() {
        let a = WidgetSnapshot(host: "r2", apm: 1, running: 2, blocked: 0, usage: [], ask: nil, updatedAt: now)
        var b = a
        b.updatedAt = now.addingTimeInterval(60)
        XCTAssertTrue(a.sameContent(as: b))
        b.apm = 1.2
        XCTAssertFalse(a.sameContent(as: b))
        XCTAssertFalse(a.sameContent(as: nil))
    }
}
