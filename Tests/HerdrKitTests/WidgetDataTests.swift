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

    func testASubagentFoldsUnderItsCallerAndCountsTowardNothing() throws {
        func info(_ json: String) throws -> AgentInfo { try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)) }
        let list = AgentList(agents: [
            try info(#"{"pane_id":"w1:p1","workspace_id":"w1","agent":"claude","agent_status":"idle"}"#),
            try info(#"{"pane_id":"w1:p2","workspace_id":"w1","agent":"codex","agent_status":"working","subagent":true}"#),
            try info(#"{"pane_id":"w1:p3","workspace_id":"w1","agent":"codex","agent_status":"blocked","subagent":true}"#),
            try info(#"{"pane_id":"w2:p1","workspace_id":"w2","agent":"claude","agent_status":"working"}"#),
            try info(#"{"pane_id":"w3:p1","workspace_id":"w3","agent":"codex","agent_status":"idle","subagent":true}"#),
        ], livePaneIDs: ["w1:p1", "w1:p2", "w1:p3", "w2:p1", "w3:p1"])
        XCTAssertEqual(list.subagents["w1:p1"]?.map(\.info.paneID), ["w1:p3", "w1:p2"], "most urgent first")
        // The idle caller sorts with its blocked subagent; a subagent without a caller stands alone.
        XCTAssertEqual(list.rows.map(\.info.paneID), ["w1:p1", "w2:p1", "w3:p1"])
        XCTAssertEqual(list.sections.first?.group, .needsYou)
        XCTAssertEqual(list.activityContent.needsYouCount, 0, "a blocked subagent is its caller's to answer")
        XCTAssertEqual(list.activityContent.workingCount, 1)
    }

    func testAnIdleAgentWithBackgroundWorkIsRunning() throws {
        func info(_ json: String) throws -> AgentInfo { try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)) }
        let list = AgentList(agents: [
            try info(#"{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","background":"20 local agents"}"#),
            try info(#"{"pane_id":"w1:p2","agent":"claude","agent_status":"idle"}"#),
        ], livePaneIDs: ["w1:p1", "w1:p2"])
        XCTAssertEqual(list.rows.first { $0.info.paneID == "w1:p1" }?.group, .working)
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

    func testGramContactsGroupByAgentAndListEveryRunningAgent() throws {
        func info(_ json: String) throws -> AgentInfo { try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8)) }
        func message(_ id: String, _ dir: GramDirection, from: String, to: String? = nil, ms: UInt64,
                     kind: GramEventKind? = nil, pane: String? = nil, session: String? = nil,
                     cwd: String? = nil, read: Bool = true) -> GramMessage {
            GramMessage(id: id, direction: dir, from: from, to: to, text: id, createdUnixMs: ms, readByOwner: read,
                        kind: kind, paneID: pane, session: session, cwd: cwd)
        }
        let agents = [
            try info(#"{"pane_id":"w1:p1","agent":"claude","agent_status":"idle","terminal_title_stripped":"Assistant feature","cwd":"/home/x/Code/monorepo"}"#),
            try info(#"{"pane_id":"w2:p1","agent":"claude","agent_status":"blocked","name":"artemis","cwd":"/home/x/seo"}"#),
            try info(#"{"pane_id":"w3:p1","agent":"codex","agent_status":"working","subagent":true}"#),
            try info(#"{"pane_id":"w1:p1","agent":"claude","agent_status":"working","terminal_title_stripped":"Crawl health"}"#).inSession("top-r"),
        ]
        // Newest first, as Gram lists them.
        let messages = [
            message("post", .ownerToAgent, from: "owner", to: "artemis", ms: 6),
            message("recap", .agentToOwner, from: "Assistant feature", ms: 5, kind: .recap, pane: "w1:p1",
                    session: "top-l", cwd: "/home/x/Code/monorepo", read: false),
            message("sent", .agentToOwner, from: "w1:p1", ms: 4, pane: "w1:p1", session: "top-l", read: false),
            message("old", .agentToOwner, from: "artemis", ms: 3),
            message("gone", .agentToOwner, from: "Old task", ms: 2, kind: .recap, pane: "w9:p1", session: "top-l",
                    cwd: "/home/x/Code"),
            message("queue", .ownerToAgent, from: "owner", ms: 1),
        ]
        let index = GramContactIndex(messages: messages, agents: agents, connectedSession: "top-l")
        let byID = Dictionary(uniqueKeysWithValues: index.contacts.map { ($0.id, $0) })

        XCTAssertEqual(index.contacts.first?.id, "top-l/w2:p1", "the agent waiting on the owner comes first")
        XCTAssertEqual(byID["top-l/w2:p1"]?.name, "artemis")
        XCTAssertEqual(byID["top-l/w2:p1"]?.folder, "seo")
        XCTAssertEqual(byID["top-l/w2:p1"]?.last?.id, "post", "the owner's post to a name joins that agent")
        XCTAssertEqual(index.key(of: messages[3]), .pane(session: "top-l", paneID: "w2:p1"))

        XCTAssertEqual(byID["top-l/w1:p1"]?.name, "Assistant feature")
        XCTAssertEqual(byID["top-l/w1:p1"]?.folder, "monorepo")
        XCTAssertEqual(byID["top-l/w1:p1"]?.unread, 2, "its recap and its own Gram")
        XCTAssertEqual(GramContactIndex.unreadContactCount(in: messages), 1, "the tab badges contacts, not messages")

        XCTAssertEqual(byID["top-r/w1:p1"]?.name, "Crawl health", "another session's agent, with no history yet")
        XCTAssertNil(byID["top-r/w1:p1"]?.last)
        XCTAssertNil(byID["top-l/w3:p1"], "a subagent is no contact")

        XCTAssertEqual(byID["top-l/w9:p1"]?.name, "Old task", "an agent that is gone keeps its history")
        XCTAssertEqual(byID["top-l/w9:p1"]?.folder, "Code")
        XCTAssertNotNil(byID["queue"])
    }

    func testPendingRequestDecodes() throws {
        let json = #"{"pane_id":"w1:p1","agent_status":"blocked","pending_request":"Bash command\ngit push\nDo you want to proceed?"}"#
        let info = try JSONDecoder().decode(AgentInfo.self, from: Data(json.utf8))
        XCTAssertEqual(info.pendingRequest, "Bash command\ngit push\nDo you want to proceed?")
        let older = try JSONDecoder().decode(AgentInfo.self, from: Data(#"{"pane_id":"w1:p1"}"#.utf8))
        XCTAssertNil(older.pendingRequest)
    }
}
