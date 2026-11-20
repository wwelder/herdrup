import Foundation

/// Claude Code answers a `/btw` side question in a panel over its prompt, not in the
/// conversation: neither the question nor the answer reaches its transcript, so only the
/// terminal shows them. While the panel is open it takes every key. A message sent to the pane
/// then is lost, and its Return only closes the panel. Seen on Claude Code 2.1.329.
public enum ClaudeSideAnswer {
    /// What a reply starts with to ask one.
    public static let command = "/btw "

    /// Whether the panel is open on this screen (`HerdrClient.read`, `.visible`). Its key
    /// hints are the last line Claude Code draws; with the panel closed that line is the
    /// prompt's own footer, so a conversation that quotes the hints does not count.
    // ponytail: told by the hints' wording. If Claude Code rewords them this says no, the
    // panel stays open, and the next message to that agent is lost.
    public static func isOpen(screen: String) -> Bool {
        screen.split(whereSeparator: \.isNewline)
            .last { !$0.allSatisfy(\.isWhitespace) }
            .map { $0.contains("to copy") && $0.contains("Esc to close") } ?? false
    }
}

extension HerdrClient {
    /// Closes the side answer's panel if it is open. Escape goes only to a pane that shows
    /// the panel: on a working agent without it, Escape interrupts the turn.
    public func closeClaudeSideAnswer(pane: String) async {
        guard let screen = try? await read(pane: pane, source: .visible, format: .text),
              ClaudeSideAnswer.isOpen(screen: screen.text) else { return }
        // `pane.send_keys`, because `agent.send_keys` records an Escape as an aborted turn.
        try? await sendPaneKeys(pane: pane, keys: ["Escape"])
        // A lone Escape is told from the start of a key sequence by the pause after it.
        try? await Task.sleep(nanoseconds: 300_000_000)
    }
}
