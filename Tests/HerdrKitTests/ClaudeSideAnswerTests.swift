import XCTest
@testable import HerdrKit

/// The screens are Claude Code 2.1.329's, captured from a session blocked in a command.
final class ClaudeSideAnswerTests: XCTestCase {
    private let blocked = """
    ⏺ Block reading from wait.fifo until a reply arrives · 32s
      ⎿  $ cat ./wait.fifo (33s)
         (ctrl+b ctrl+b (twice) to run in background)

    · Perambulating… (35s · ↓ 282 tokens)

    """

    private let prompt = """
    ────────────────────────────────────────
    ❯
    ────────────────────────────────────────
      -- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle)
    """

    func testThePanelIsOpenWhileTheScreenEndsWithItsKeyHints() {
        let first = blocked + """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
          /btw what is 9+9? answer with just the number

            18

          c to copy · f to fork · Esc to close


        """
        let later = blocked + """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
          /btw what is 7+7? answer with just the number
          /btw what is 9+9? answer with just the number

            18

          ⇧←/→ to browse · c to copy · f to fork · x to clear history · Esc to close
        """
        let answering = blocked + """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
          /btw what is 4+4? answer with just the number
          /btw write about 400 words on the history of the tmux terminal multiplexer
            ✻ Answering…
          ⇧←/→ to browse · x to clear history · Esc to close
        """
        // 52 columns, as on a phone: the hints wrap and a long answer scrolls.
        let narrow = blocked + """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
          /btw what is 4+4? answer with just the number
          /btw write about 400 words on the history of …

            In 2007, Nicholas Marriott began writing a
            replacement. He was working on OpenBSD at the  ↓

          ↑/↓ to scroll · ⇧←/→ to browse · c to copy · f
          to fork · x to clear history · Esc to close
        """
        let narrowAnswering = blocked + """
        ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
          /btw what is 4+4? answer with just the number
          /btw write about 400 words on the history of …
            ✻ Answering…
          ⇧←/→ to browse · x to clear history · Esc to
          close
        """
        for screen in [first, later, answering, narrow, narrowAnswering] {
            XCTAssertTrue(ClaudeSideAnswer.isOpen(screen: screen), screen)
        }
    }

    func testAClosedPanelIsNotOpenEvenWhenTheConversationQuotesItsHints() {
        XCTAssertFalse(ClaudeSideAnswer.isOpen(screen: blocked + prompt))
        XCTAssertFalse(ClaudeSideAnswer.isOpen(
            screen: "⏺ Ask with /btw. Its panel ends with:\n  /btw question\n  c to copy · f to fork · Esc to close\n\n" + prompt))
        XCTAssertFalse(ClaudeSideAnswer.isOpen(screen: ""))
    }

    func testAnotherPanelThatClosesWithEscapeIsNotTheSideAnswer() {
        XCTAssertFalse(ClaudeSideAnswer.isOpen(screen: blocked + "  Background tasks\n  1 shell running\n  Esc to close"))
    }
}
