import XCTest
@testable import HerdrKit

/// A path a machine reports is text. It is never looked up on this device: on a Mac `/home`
/// is an automount point, and asking the file system about a Linux machine's `/home/...`
/// took about 11 ms a path, on the main thread, for every row of the agent list.
final class RemoteFolderTests: XCTestCase {
    func testFolderIsTheLastPartOfTheMachinesPath() {
        XCTAssertEqual(GramContact.folder(of: "/home/channel/Code/monorepo"), "monorepo")
        XCTAssertEqual(GramContact.folder(of: "/home/channel/Code/monorepo/"), "monorepo")
        XCTAssertEqual(GramContact.folder(of: "~/repos/llm-opt"), "llm-opt")
        XCTAssertNil(GramContact.folder(of: "/"))
        XCTAssertNil(GramContact.folder(of: ""))
        XCTAssertNil(GramContact.folder(of: nil))
    }

    func testFolderNeverAsksTheFileSystem() {
        let started = ContinuousClock.now
        for index in 0..<1000 { _ = GramContact.folder(of: "/home/nobody-\(index)/Code/monorepo") }
        // A thousand automount lookups take over ten seconds; a thousand string splits, a millisecond.
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    }
}
