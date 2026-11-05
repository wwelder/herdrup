import XCTest
@testable import HerdrKit

/// The feed reads what scripts write: RSS 2.0 (HTML in `description` or `content:encoded`)
/// and Atom, newest first, with ids stable enough to carry read and starred marks.
final class FeedTests: XCTestCase {
    func testRSSItemsAreParsedNewestFirstWithTheirHTML() throws {
        let xml = """
        <?xml version="1.0"?>
        <rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/" xmlns:dc="http://purl.org/dc/elements/1.1/">
        <channel><title>Oura</title><link>https://ouraring.com</link>
          <image><title>logo</title></image>
          <item><title>Sleep 78</title><guid>2026-11-03</guid><pubDate>Mon, 03 Nov 2026 07:00:00 +0000</pubDate>
            <description>older</description></item>
          <item><title>Sleep 84 &amp; readiness 79</title><guid>2026-11-04</guid>
            <pubDate>Tue, 04 Nov 2026 07:02:00 GMT</pubDate><dc:creator>oura-digest</dc:creator>
            <description>short</description>
            <content:encoded><![CDATA[<p>Deep sleep <b>1 h 41 min</b> &amp; HRV 52&nbsp;ms.</p>]]></content:encoded></item>
          <item><title>Undated</title></item>
        </channel></rss>
        """
        let channel = try FeedParser.parse(xml, file: "oura.xml")
        XCTAssertEqual(channel.title, "Oura")
        XCTAssertEqual(channel.entries.map(\.title), ["Sleep 84 & readiness 79", "Sleep 78", "Undated"])
        let newest = channel.entries[0]
        XCTAssertEqual(newest.id, "oura.xml#2026-11-04")
        XCTAssertEqual(newest.feedTitle, "Oura")
        XCTAssertEqual(newest.author, "oura-digest")
        XCTAssertEqual(newest.content, "<p>Deep sleep <b>1 h 41 min</b> &amp; HRV 52&nbsp;ms.</p>")
        XCTAssertEqual(newest.excerpt, "Deep sleep 1 h 41 min & HRV 52 ms.")
        XCTAssertEqual(newest.date, Date(timeIntervalSince1970: 1_793_775_720))
        XCTAssertNil(channel.entries[2].date)
        XCTAssertEqual(channel.entries[2].id, "oura.xml#Undated|")
    }

    func testAtomEntriesUseTheAlternateLinkAndAuthorName() throws {
        let xml = """
        <feed xmlns="http://www.w3.org/2005/Atom"><title>Digest</title>
          <entry><title>Week 45</title><id>urn:week-45</id><updated>2026-11-04T09:30:00.250Z</updated>
            <link rel="self" href="https://example.com/self"/><link href="https://example.com/w45"/>
            <author><name>Herd</name></author>
            <content type="html">&lt;h2&gt;Done&lt;/h2&gt;</content></entry>
        </feed>
        """
        let entry = try XCTUnwrap(FeedParser.parse(xml, file: "digest.xml").entries.first)
        XCTAssertEqual(entry.id, "digest.xml#urn:week-45")
        XCTAssertEqual(entry.link, URL(string: "https://example.com/w45"))
        XCTAssertEqual(entry.author, "Herd")
        XCTAssertEqual(entry.content, "<h2>Done</h2>")
        XCTAssertNotNil(entry.date)
    }

    func testAFeedWithoutATitleIsNamedAfterItsFile() throws {
        let channel = try FeedParser.parse("<rss><channel><item><title>x</title></item></channel></rss>", file: "notes.xml")
        XCTAssertEqual(channel.title, "notes")
    }

    func testSomethingElseIsNotAFeed() {
        XCTAssertThrowsError(try FeedParser.parse("<html><body>hi</body></html>", file: "a.xml"))
        XCTAssertThrowsError(try FeedParser.parse("not xml", file: "a.xml"))
    }

    func testPlainTextIsNotHTML() {
        XCTAssertTrue(FeedText.looksLikeHTML("<p>hi</p>"))
        XCTAssertFalse(FeedText.looksLikeHTML("HRV < 40 ms for 3 days"))
    }
}
