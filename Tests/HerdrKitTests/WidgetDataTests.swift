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

    func testPendingRequestDecodes() throws {
        let json = #"{"pane_id":"w1:p1","agent_status":"blocked","pending_request":"Bash command\ngit push\nDo you want to proceed?"}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.pendingRequest, "Bash command\ngit push\nDo you want to proceed?")
        let older = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"pane_id":"w1:p1"}"#.utf8))
        XCTAssertNil(older.pendingRequest)
    }
}
