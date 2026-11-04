import XCTest
@testable import HerdrKit

/// What the home-screen widgets take from the roster: each provider's remaining usage and a
/// blocked agent's request.
final class WidgetDataTests: XCTestCase {
    private func account(_ json: String) throws -> CredentialAccount {
        try JSONDecoder().decode(CredentialAccount.self, from: Data(json.utf8))
    }

    func testUsageIsTheActiveAccountsTightestWindowPerProvider() throws {
        let accounts = try [
            account(#"{"id":"c1","kind":"claude","label":"a","active":false,"usage":{"windows":[{"label":"weekly","used_percent":90}]}}"#),
            account(#"{"id":"c2","kind":"claude","label":"b","active":true,"usage":{"windows":[{"label":"5h","used_percent":20,"resets_at":"1793620800"},{"label":"weekly","used_percent":45}]}}"#),
            account(#"{"id":"x1","kind":"codex","label":"c","active":true,"usage":{"primary_used_percent":12}}"#),
            account(#"{"id":"o1","kind":"omp","label":"d","active":true,"usage":{"windows":[{"label":"5h","used_percent":99}]}}"#),
        ]
        let usage = providerUsage(accounts: accounts)
        XCTAssertEqual(usage.map(\.provider), ["claude", "codex"], "omp has no widget slot")
        XCTAssertEqual(usage[0].remainingPercent, 55, "the active account, by its weekly window")
        XCTAssertEqual(usage[0].window, "weekly")
        XCTAssertNil(usage[0].resetsAt)
        XCTAssertEqual(usage[1].remainingPercent, 88, "an older daemon's flat field still counts")
        XCTAssertEqual(usage[1].window, "5h")
    }

    func testAProviderWithoutUsageIsLeftOut() throws {
        let accounts = try [account(#"{"id":"c","kind":"claude","label":"a","active":true}"#)]
        XCTAssertEqual(providerUsage(accounts: accounts), [])
    }

    func testTheLiveActivityAsksOnlyWhileTheLeadNeedsYou() throws {
        func list(_ status: String) throws -> AgentList {
            let json = #"{"pane_id":"w1:p1","agent":"claude","agent_status":"\#(status)","pending_request":"Proceed?"}"#
            return AgentList(agents: [try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))], livePaneIDs: ["w1:p1"])
        }
        XCTAssertEqual(try list("blocked").activityContent.question, "Proceed?")
        XCTAssertNil(try list("working").activityContent.question)
    }

    func testASubagentGetsNoRowAndCountsTowardNothing() throws {
        func info(_ json: String) throws -> AgentInfo { try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)) }
        let list = AgentList(agents: [
            try info(#"{"pane_id":"w1:p1","agent":"claude","agent_status":"working"}"#),
            try info(#"{"pane_id":"w1:p2","agent":"codex","agent_status":"blocked","subagent":true}"#),
        ], livePaneIDs: ["w1:p1", "w1:p2"])
        XCTAssertEqual(list.rows.map(\.info.paneID), ["w1:p1"])
        XCTAssertEqual(list.activityContent.needsYouCount, 0, "a blocked subagent is its orchestrator's to answer")
        XCTAssertEqual(list.activityContent.workingCount, 1)
    }

    func testGramEventFieldsDecode() throws {
        let json = #"{"id":"g1","direction":"agent_to_owner","from":"jarvis","text":"Proceed?","created_unix_ms":1,"read_by_owner":false,"kind":"blocked","pane_id":"w2:p1","session":"top-l","resolved":true}"#
        let message = try JSONDecoder().decode(GramMessage.self, from: Data(json.utf8))
        XCTAssertEqual(message.kind, .blocked)
        XCTAssertEqual(message.paneID, "w2:p1")
        XCTAssertEqual(message.session, "top-l")
        XCTAssertTrue(message.resolved)
        let plain = try JSONDecoder().decode(GramMessage.self, from: Data(#"{"id":"g2","direction":"agent_to_owner","from":"a","text":"hi","created_unix_ms":1,"read_by_owner":false,"kind":"someday"}"#.utf8))
        XCTAssertNil(plain.kind, "an unknown kind from a newer daemon is an ordinary message")
        XCTAssertFalse(plain.resolved)
    }

    func testPendingRequestDecodes() throws {
        let json = #"{"pane_id":"w1:p1","agent_status":"blocked","pending_request":"Bash command\ngit push\nDo you want to proceed?"}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.pendingRequest, "Bash command\ngit push\nDo you want to proceed?")
        let older = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"pane_id":"w1:p1"}"#.utf8))
        XCTAssertNil(older.pendingRequest)
    }
}
