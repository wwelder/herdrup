import XCTest

/// On a wide window (iPad, and the Mac build, which uses the same split layout) Gram is one
/// conversation: its sidebar column would hold a title and empty space. So the column gives
/// way to the icon rail while Gram is open, and comes back on the way out.
final class GramSidebarTests: XCTestCase {
    func testTheSidebarGivesWayToTheRailWhileGramIsOpen() throws {
        guard UIDevice.current.userInterfaceIdiom == .pad else {
            throw XCTSkip("Exercises the split layout")
        }
        let app = XCUIApplication()
        app.launchEnvironment["HERDR_SCREENSHOT_MOCK"] = "list"
        // The simulator may remember a minimised sidebar from another test.
        app.launchArguments += ["-ui.sidebarMinimized", "NO"]
        app.launch()
        let minimise = app.buttons["Minimise sidebar"].firstMatch
        let expand = app.buttons["Expand sidebar"].firstMatch
        XCTAssertTrue(minimise.waitForExistence(timeout: 15), "the home opens with its sidebar")
        attach(app, "1-agents-with-sidebar")

        app.buttons["Gram"].firstMatch.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "on Gram the column has given way to the rail")
        XCTAssertFalse(minimise.exists, "and is not also on screen")
        attach(app, "2-gram-with-rail")

        // The rail's Gram icon selects Gram and does not open the column.
        app.buttons["Gram"].firstMatch.tap()
        XCTAssertTrue(expand.exists, "the rail stays on Gram")

        app.buttons["Feed"].firstMatch.tap()
        XCTAssertTrue(minimise.waitForExistence(timeout: 5), "leaving Gram brings the column back")
        attach(app, "3-feed-with-sidebar")

        // The chevron still opens the column on Gram for whoever asks.
        app.buttons["Gram"].firstMatch.tap()
        XCTAssertTrue(expand.waitForExistence(timeout: 5), "back on Gram, the rail again")
        expand.tap()
        XCTAssertTrue(minimise.waitForExistence(timeout: 5), "the chevron opens the column on Gram")
        attach(app, "4-gram-column-opened-by-hand")
    }
}
