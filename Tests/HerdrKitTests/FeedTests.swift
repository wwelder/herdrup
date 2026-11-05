import XCTest
@testable import HerdrKit

/// The feed reads the cards scripts write, and the owner's answers herdr records beside them.
final class FeedTests: XCTestCase {
    private let question = """
    {"title":"Add to the knowledge graph?","body":"## Notes\\nMixture-of-Depths","date":"2026-11-05T09:00:00+08:00",
     "actions":[{"id":"add","label":"Add to KG"},{"id":"skip","label":"Skip","role":"destructive"}],
     "input":"Why?","confirm":"Add it?","expires":"2026-11-06T00:00:00.500Z"}
    """

    func testAQuestionIsPendingUntilAnsweredSettledOrExpired() throws {
        let card = try FeedCards.entry(FeedCardFile(source: "kg", id: "mod", card: question))
        XCTAssertEqual(card.id, "kg/mod")
        XCTAssertEqual(card.title, "Add to the knowledge graph?")
        XCTAssertEqual(card.body, "## Notes\nMixture-of-Depths")
        XCTAssertEqual(card.date, Date(timeIntervalSince1970: 1_793_840_400))
        XCTAssertEqual(card.actions.map(\.id), ["add", "skip"])
        XCTAssertTrue(card.actions[1].isDestructive)
        XCTAssertEqual(card.input, "Why?")
        XCTAssertNotNil(card.expires)
        let before = Date(timeIntervalSince1970: 1_793_908_800)
        XCTAssertTrue(card.isPending(at: before))
        XCTAssertFalse(card.isPending(at: card.expires!), "an expired card asks no more")

        let answered = try FeedCards.entry(FeedCardFile(
            source: "kg", id: "mod", card: question,
            reply: #"{"action":"skip","text":"seen it","at":"2026-11-05T12:00:00Z"}"#))
        XCTAssertFalse(answered.isPending(at: before))
        XCTAssertEqual(answered.replySummary, "Skip · “seen it”")
        XCTAssertEqual(answered.reply?.at, Date(timeIntervalSince1970: 1_793_880_000))

        let settled = try FeedCards.entry(FeedCardFile(
            source: "kg", id: "x", card: #"{"title":"t","actions":[{"id":"a","label":"A"}],"outcome":"Handled on the Mac"}"#))
        XCTAssertFalse(settled.isPending(at: before))
    }

    func testAnUpdateAsksNothingAndFallsBackToItsFileName() throws {
        let card = try FeedCards.entry(FeedCardFile(source: "oura", id: "2026-11-04", card: #"{"body":"Sleep 84"}"#))
        XCTAssertFalse(card.asks)
        XCTAssertFalse(card.isPending())
        XCTAssertEqual(card.title, "2026-11-04")
        XCTAssertNil(card.date)
        XCTAssertNil(card.replySummary)
    }

    func testSomethingElseIsNotACard() {
        XCTAssertThrowsError(try FeedCards.entry(FeedCardFile(source: "a", id: "b", card: "[1]")))
        XCTAssertThrowsError(try FeedCards.entry(FeedCardFile(source: "a", id: "b", card: nil, error: "too big")))
    }

    func testNewestFirstKeepsUndatedCardsLast() throws {
        let cards = try [#"{"title":"u"}"#, #"{"title":"old","date":"2026-11-03T07:00:00Z"}"#,
                         #"{"title":"new","date":"2026-11-04T07:00:00Z"}"#]
            .enumerated().map { try FeedCards.entry(FeedCardFile(source: "s", id: "\($0.offset)", card: $0.element)) }
        XCTAssertEqual(FeedCards.newestFirst(cards).map(\.title), ["new", "old", "u"])
    }
}
