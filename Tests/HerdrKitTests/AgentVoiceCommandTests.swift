import XCTest
import Foundation
@testable import HerdrKit

/// The agent-voice command under /bin/sh with fake herdr, pactl and pacat: it holds Space
/// in the pane while the audio plays, stops typing once the audio ends, and backs out with
/// exit 5 (deleting its Spaces) when Claude Code is not listening.
final class AgentVoiceCommandTests: XCTestCase {
    private var home: URL!

    override func setUpWithError() throws {
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("herdrkit-voice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home.appendingPathComponent("bin"),
                                                withIntermediateDirectories: true)
        try fake("herdr", #"echo "$*" >> "$HOME/herdr.log"; case "$*" in *"pane read"*) [ -e "$HOME/listening" ] && echo "listening…";; esac; exit 0"#)
        try fake("pactl", #"echo "$*" >> "$HOME/pactl.log""#)
        try fake("pacat", #"cat > "$HOME/pcm""#)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    func testCommandIsLiteralForLoginShellsAndRefusesPanesItCannotName() {
        XCTAssertTrue(CitadelTransport.isShellLiteral(CitadelTransport.agentVoiceScript))
        XCTAssertNil(CitadelTransport.agentVoiceCommand(pane: "studio/w1:p4", session: nil))
        XCTAssertNil(CitadelTransport.agentVoiceCommand(pane: "w1:p1'", session: nil))
    }

    func testHoldsSpaceWhileTheAudioPlaysAndStopsAfter() throws {
        FileManager.default.createFile(atPath: home.appendingPathComponent("listening").path, contents: nil)
        let audio = Data(repeating: 7, count: 32_000)
        let (status, stderr) = try run(pane: "w1:p1", session: "work", audio: audio)
        XCTAssertEqual(status, 0, stderr)
        XCTAssertEqual(try Data(contentsOf: home.appendingPathComponent("pcm")), audio)
        XCTAssertTrue(try log("pactl").contains { $0.hasPrefix("load-module module-null-sink") })
        XCTAssertTrue(try log("pactl").contains("set-default-source herdrup_mic"))
        Thread.sleep(forTimeInterval: 0.2)
        let spaces = try log("herdr").filter { $0 == "--session work pane send-keys w1:p1 space" }.count
        XCTAssertGreaterThanOrEqual(spaces, 8)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertEqual(try log("herdr").filter { $0.hasSuffix(" space") }.count, spaces,
                       "Space kept coming after the audio ended")
    }

    func testBacksOutWhenClaudeIsNotListening() throws {
        let (status, stderr) = try run(pane: "w1:p1", session: nil, audio: Data(count: 3_200))
        XCTAssertEqual(status, 5)
        XCTAssertTrue(stderr.contains("/voice"), stderr)
        XCTAssertTrue(try log("herdr").contains { $0.hasPrefix("pane send-keys w1:p1 backspace") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("pcm").path))
    }

    // MARK: - helpers

    private func fake(_ name: String, _ body: String) throws {
        let url = home.appendingPathComponent("bin/\(name)")
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }

    private func log(_ name: String) throws -> [String] {
        try String(contentsOf: home.appendingPathComponent("\(name).log"), encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// `/bin/sh -c <command>`, as sshd runs the exec request, with `audio` as stdin.
    private func run(pane: String, session: String?, audio: Data) throws -> (Int32, String) {
        let command = try XCTUnwrap(CitadelTransport.agentVoiceCommand(pane: pane, session: session))
        let input = home.appendingPathComponent("stdin")
        try audio.write(to: input)
        let errors = home.appendingPathComponent("stderr")
        FileManager.default.createFile(atPath: errors.path, contents: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["HOME": home.path, "PATH": home.appendingPathComponent("bin").path + ":/usr/bin:/bin"]
        process.standardInput = try FileHandle(forReadingFrom: input)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = try FileHandle(forWritingTo: errors)
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: errors, encoding: .utf8))
    }
}
