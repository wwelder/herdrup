import Foundation

/// Claude Code answers a `/btw` side question in a panel over its prompt, not in the
/// conversation: neither the question nor the answer reaches its transcript, so only the
/// terminal shows them. While the panel is open it takes every key. A message sent to the pane
/// then is lost, and its Return only closes the panel. Seen on Claude Code 2.1.329.
public enum ClaudeSideAnswer {
    /// What a reply starts with to ask one.
    public static let command = "/btw "

    /// Whether the panel is open on this screen (`HerdrClient.read`, `.visible`): the screen
    /// ends with the panel's key hints, under the questions asked. The hints change with the
    /// panel's state and wrap on a narrow terminal, but always end in "Esc to close". With the
    /// panel closed the screen ends with the prompt, so a conversation that quotes the hints
    /// does not count.
    // ponytail: told by the hints' wording. If Claude Code rewords them this says no, the
    // panel stays open, and the next message to that agent is lost.
    public static func isOpen(screen: String) -> Bool {
        let lines = screen.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return lines.suffix(3).joined(separator: " ").hasSuffix("Esc to close")
            && lines.contains { $0.hasPrefix(command) }
    }
}

/// Closes run one at a time, in the order asked. Two at once would both act on the same
/// screen, and one left running behind a later question would close that question's answer.
// ponytail: one queue for every pane. Per pane if closes ever wait on each other.
private actor SideAnswerCloses {
    static let shared = SideAnswerCloses()
    private var last: Task<Void, Never>?

    func run(_ close: @escaping @Sendable () async -> Void) async {
        let previous = last
        let task = Task {
            await previous?.value
            await close()
        }
        last = task
        await task.value
    }
}

extension HerdrClient {
    /// Closes the side answer's panel if it is open, with Return.
    ///
    /// Not with Escape, the key the panel names: the panel may have closed between the read
    /// and the key, and Escape on a working agent interrupts its turn. Return closes the panel
    /// in every state it has (answering, answered, scrolled), and without the panel it does
    /// nothing to an agent whose prompt is empty.
    public nonisolated func closeClaudeSideAnswer(pane: String) async {
        await SideAnswerCloses.shared.run {
            guard let screen = try? await self.read(pane: pane, source: .visible, format: .text),
                  ClaudeSideAnswer.isOpen(screen: screen.text) else { return }
            // `pane.send_keys`: a plain key, with none of `agent.send_keys`' turn bookkeeping.
            try? await self.sendPaneKeys(pane: pane, keys: ["Enter"])
            // herdr looks at the prompt before it types into it: let Claude Code redraw it.
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
    }
}
