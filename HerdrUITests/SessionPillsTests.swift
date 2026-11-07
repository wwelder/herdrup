import XCTest

/// #347: the Agents home on a machine with several herdr sessions. The `sessions` mock
/// lists work, personal and default as running and scratch as stopped, and the home is
/// on "work"; every session answers with the demo roster (3 agents need you).
final class SessionPillsTests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    /// The list opens on All (every session's agents); each running session has a pill.
    func testRunningSessionsShowAsPillsWithAllSelected() {
        let app = XCUIApplication.launched(mock: "sessions")

        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].waitForExistence(timeout: 12),
                      "the roster should have loaded")

        // Labels are what VoiceOver reads: name, then the needs-you count. All sums them.
        let all = app.buttons["All, 9 need you"]
        XCTAssertTrue(all.waitForExistence(timeout: 6), "All should count every session's waiting agents")
        XCTAssertTrue(all.isSelected, "the list should open on every session")

        let work = app.buttons["work, 3 need you"]
        XCTAssertTrue(work.exists, "the current session should have a pill")
        XCTAssertFalse(work.isSelected, "a session pill is a filter, off while All shows")
        XCTAssertFalse(app.buttons["personal, 3 need you"].isSelected)
        XCTAssertTrue(app.buttons["default, 3 need you"].exists, "the default session should have a pill")

        // A stopped session can't be listed, so it gets no pill.
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'scratch'")).firstMatch.exists,
                       "a stopped session must not be offered")
    }

    /// All lists the other sessions' agents, each led by its session; a pill filters to one.
    func testAllListsEverySessionsAgentsAndAPillFiltersToOne() {
        let app = XCUIApplication.launched(mock: "sessions")
        let fromPersonal = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'personal · '")).firstMatch

        XCTAssertTrue(fromPersonal.waitForExistence(timeout: 12),
                      "All should list another session's agents, labelled with that session")

        let work = app.buttons["work, 3 need you"]
        work.tap()
        XCTAssertTrue(work.waitForExistence(timeout: 1.5))
        XCTAssertTrue(work.isSelected, "the tapped session should be the filter")
        XCTAssertTrue(fromPersonal.waitForNonExistence(timeout: 3), "a session filter hides the others' agents")

        app.buttons["All, 9 need you"].tap()
        XCTAssertTrue(fromPersonal.waitForExistence(timeout: 3), "All brings every session back")
    }

    /// #386: switching shows the new session's agents from what the app already saw (the
    /// pills check every session), instead of an empty screen until its own list loads.
    /// In this mock the switched-to session takes 4 s to answer its own `agent.list`.
    func testSwitchingShowsTheNewSessionsAgentsWithoutWaitingForItsLoad() {
        let app = XCUIApplication.launched(mock: "sessions")

        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].waitForExistence(timeout: 12),
                      "the roster should have loaded")
        let personal = app.buttons["personal, 3 need you"]
        XCTAssertTrue(personal.waitForExistence(timeout: 6), "the pills should have checked the other sessions")

        personal.tap()

        XCTAssertTrue(app.buttons["personal, 3 need you"].waitForExistence(timeout: 1.5),
                      "the pills should stay up through the switch")
        XCTAssertTrue(app.buttons["personal, 3 need you"].isSelected, "the tapped session should be the filter")
        XCTAssertTrue(app.staticTexts["mcb-air/mcb-air"].waitForExistence(timeout: 1.5),
                      "the new session's agents should show at once, not after its 4 s load")
    }
}
