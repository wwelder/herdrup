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

    func testThePanelIsOpenWhileItsKeyHintsAreTheLastLine() {
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
        XCTAssertTrue(ClaudeSideAnswer.isOpen(screen: first))
        XCTAssertTrue(ClaudeSideAnswer.isOpen(screen: later), "a later answer adds hints to the line")
    }

    func testAClosedPanelIsNotOpenEvenWhenTheConversationQuotesItsHints() {
        let prompt = """
        ────────────────────────────────────────
        ❯
        ────────────────────────────────────────
          -- INSERT -- ⏵⏵ bypass permissions on (shift+tab to cycle)
        """
        XCTAssertFalse(ClaudeSideAnswer.isOpen(screen: blocked + prompt))
        XCTAssertFalse(ClaudeSideAnswer.isOpen(
            screen: "⏺ The panel ends with: c to copy · f to fork · Esc to close\n\n" + prompt))
        XCTAssertFalse(ClaudeSideAnswer.isOpen(screen: ""))
    }
}
