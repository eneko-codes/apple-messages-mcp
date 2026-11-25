import Foundation
import Testing

@testable import MessagesMCPCore

/// The subprocess runner below the store seam, run against a stand-in for
/// `/usr/bin/shortcuts`: a shell script this suite writes into a temporary directory. The
/// real `shortcuts` tool is never run and nothing is sent.
///
/// Everything goes through the listing (`shortcuts list`), which uses the same runner as a
/// send and needs no input file.
@Suite("Shortcut deadline")
struct ShortcutDeadlineTests {

    private final class StandIn {
        let directory: URL
        var path: String { directory.appendingPathComponent("shortcuts").path }

        /// `list` and `run` are the shell lines the stand-in executes for each subcommand.
        init(list: String = "echo 'Claude Send Message'", run: String) throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("apple-messages-mcp-standin-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                if [ "$1" = "list" ]; then
                \(list)
                exit 0
                fi
                \(run)

                """
            try script.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }

        func store(listTimeout: TimeInterval = 10, runTimeout: TimeInterval = 10) -> SystemMessageStore {
            SystemMessageStore(
                databasePath: directory.appendingPathComponent("absent.db").path, shortcutsExecutable: path,
                shortcutListTimeout: listTimeout, shortcutRunTimeout: runTimeout)
        }

        deinit { try? FileManager.default.removeItem(at: directory) }
    }

    private func installed(_ store: SystemMessageStore) async throws -> Bool? {
        try await store.status(sendShortcut: Configuration.sendShortcutName).sendShortcutInstalled
    }

    @Test("A listing that never finishes is stopped at its deadline, and reads as 'could not be checked'")
    func stuckListingIsStopped() async throws {
        // `exec`, so the process the store stops is the one that is waiting, and nothing is
        // left running behind it.
        let standIn = try StandIn(list: "exec sleep 60", run: "exit 0")
        let started = ContinuousClock.now
        #expect(try await installed(standIn.store(listTimeout: 0.5)) == nil)
        #expect(ContinuousClock.now - started < .seconds(20))
    }

    @Test("Output larger than a pipe holds is read whole")
    func largeOutputIsRead() async throws {
        // Past the 64 KB a pipe buffers, with the name on the last line: a reader that waited
        // for the exit first would leave the stand-in blocked on its own output, and one
        // that stopped reading early would never see the name.
        let standIn = try StandIn(
            list: "head -c 200000 /dev/zero | tr '\\0' 'o'; echo; echo 'Claude Send Message'", run: "exit 0")
        #expect(try await installed(standIn.store()) == true)
    }

    @Test("A shortcut that is listed is found, one that is not is reported missing, and a failed listing is neither")
    func listingIsRead() async throws {
        // Each stand-in is held in a constant: it deletes its script when it goes away.
        let listed = try StandIn(run: "exit 0")
        #expect(try await installed(listed.store()) == true)
        let other = try StandIn(list: "echo 'Another Shortcut'", run: "exit 0")
        #expect(try await installed(other.store()) == false)
        let failing = try StandIn(list: "exit 3", run: "exit 0")
        #expect(try await installed(failing.store()) == nil)
    }

    @Test("A send to a shortcut that is not listed is refused, and nothing is run")
    func missingShortcut() async throws {
        let standIn = try StandIn(list: "echo 'Another Shortcut'", run: "exit 0")
        await #expect(throws: ToolError.sendShortcutMissing(name: Configuration.sendShortcutName)) {
            _ = try await standIn.store().send(
                recipient: "+34600000001", text: "TESTING: invented",
                shortcutName: Configuration.sendShortcutName)
        }
    }
}
