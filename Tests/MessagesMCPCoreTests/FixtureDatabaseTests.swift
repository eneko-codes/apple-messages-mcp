import Foundation
import SQLite3
import Testing

@testable import MessagesMCPCore

/// Exercises `SystemMessageStore` — the one type that speaks SQL — against a database this
/// suite builds itself in a temporary directory.
///
/// The tables carry the columns `ChatDatabase.requiredColumns` depends on, plus the ones
/// the readers use. Every chat, handle and message below is invented. The owner's real
/// archive is never opened, copied or read by this suite.
private final class Fixture {
    let directory: URL
    /// The writer stays open for the fixture's lifetime with automatic checkpoints off,
    /// the way Messages keeps the real file: rows written after `checkpoint()` live only
    /// in the `-wal` file until the writer closes.
    private let writer: OpaquePointer

    var path: String { directory.appendingPathComponent("chat.db").path }

    init(omitting omitted: Set<String> = []) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-messages-mcp-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        var pointer: OpaquePointer?
        guard sqlite3_open(directory.appendingPathComponent("chat.db").path, &pointer) == SQLITE_OK,
            let pointer
        else { throw FixtureError.sqlite("open") }
        writer = pointer

        let messageColumns = [
            "ROWID INTEGER PRIMARY KEY", "guid TEXT", "text TEXT", "attributedBody BLOB",
            "handle_id INTEGER", "service TEXT", "date INTEGER", "date_read INTEGER",
            "is_from_me INTEGER", "is_read INTEGER", "associated_message_type INTEGER",
        ].filter { column in !omitted.contains(String(column.split(separator: " ")[0])) }

        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA wal_autocheckpoint = 0")
        try execute("CREATE TABLE message (\(messageColumns.joined(separator: ", ")))")
        try execute(
            "CREATE TABLE chat (ROWID INTEGER PRIMARY KEY, guid TEXT, chat_identifier TEXT, "
                + "display_name TEXT, service_name TEXT, style INTEGER)")
        try execute("CREATE TABLE handle (ROWID INTEGER PRIMARY KEY, id TEXT)")
        try execute("CREATE TABLE chat_message_join (chat_id INTEGER, message_id INTEGER)")
        try execute("CREATE TABLE chat_handle_join (chat_id INTEGER, handle_id INTEGER)")
        try execute(
            "CREATE TABLE attachment (ROWID INTEGER PRIMARY KEY, guid TEXT, filename TEXT, "
                + "transfer_name TEXT)")
        try execute(
            "CREATE TABLE message_attachment_join (message_id INTEGER, attachment_id INTEGER)")
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(writer, sql, nil, nil, &error) == SQLITE_OK else {
            let detail = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw FixtureError.sqlite(detail)
        }
    }

    /// Closes the writer and removes the sidecars, leaving a self-contained database.
    /// SQLite checkpoints when its last connection closes, so nothing is lost; the system
    /// library keeps the files afterwards (it persists the WAL), so they are deleted here
    /// to reproduce a database nobody has open.
    func closeWriterAndRemoveSidecars() {
        sqlite3_close(writer)
        closed = true
        try? FileManager.default.removeItem(atPath: path + "-wal")
        try? FileManager.default.removeItem(atPath: path + "-shm")
    }

    private var closed = false

    /// Moves everything written so far into the main file and empties the log.
    func checkpoint() throws { try execute("PRAGMA wal_checkpoint(TRUNCATE)") }

    func insertChat() throws {
        try execute("INSERT INTO handle VALUES (1, '+34600000001')")
        try execute(
            "INSERT INTO chat VALUES (1, 'iMessage;-;+34600000001', '+34600000001', NULL, 'iMessage', 45)"
        )
        try execute("INSERT INTO chat_handle_join VALUES (1, 1)")
    }

    func insertMessage(id: Int, text: String, at date: Date, fromMe: Bool = false) throws {
        let raw = AppleAbsoluteTime.rawValue(from: date, unit: .nanoseconds)
        try execute(
            """
            INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read,
                                 associated_message_type)
            VALUES (\(id), 'GUID-\(id)', '\(text)', 1, 'iMessage', \(raw), \(fromMe ? 1 : 0), 1, 0)
            """)
        try execute("INSERT INTO chat_message_join VALUES (1, \(id))")
    }

    deinit {
        if !closed { sqlite3_close(writer) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum FixtureError: Error { case sqlite(String) }

@Suite("Messages database")
struct FixtureDatabaseTests {

    private static func date(_ day: Int, _ hour: Int) -> Date {
        Calendar(identifier: .gregorian).date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 8, day: day, hour: hour))!
    }

    /// Two messages checkpointed into the main file, two more left only in the WAL.
    private func populated() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.insertChat()
        try fixture.insertMessage(id: 1, text: "first", at: Self.date(10, 9))
        try fixture.insertMessage(id: 2, text: "second", at: Self.date(10, 10), fromMe: true)
        try fixture.checkpoint()
        try fixture.insertMessage(id: 3, text: "only in the log", at: Self.date(11, 9))
        try fixture.insertMessage(id: 4, text: "also only in the log", at: Self.date(11, 10))
        return fixture
    }

    private func store(_ fixture: Fixture) -> SystemMessageStore {
        SystemMessageStore(databasePath: fixture.path, shortcutsExecutable: "/nonexistent")
    }

    @Test("Messages still in the write-ahead log are read")
    func readsThroughTheWAL() async throws {
        let fixture = try populated()
        let walSize =
            (try FileManager.default.attributesOfItem(atPath: fixture.path + "-wal")[.size]
            as? NSNumber)?.intValue ?? 0
        #expect(walSize > 0, "the fixture should be holding rows in its WAL")

        let page = try await store(fixture).conversation(id: 1, limit: 10, offset: 0)
        #expect(page.total == 4)
        #expect(page.messages.map(\.id) == [4, 3, 2, 1])
        #expect(page.messages.first?.text == "also only in the log")
    }

    @Test("A database nobody has open any more is still read")
    func readsAfterTheWriterQuits() async throws {
        let fixture = try populated()
        fixture.closeWriterAndRemoveSidecars()
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-shm"))

        let page = try await store(fixture).conversation(id: 1, limit: 10, offset: 0)
        #expect(page.total == 4)
        // Reading it created nothing beside the file.
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: fixture.path + "-shm"))
    }

    @Test("A search sees the log too")
    func searchReadsThroughTheWAL() async throws {
        let fixture = try populated()
        var filter = MessageFilter()
        filter.query = "log"
        let page = try await store(fixture).search(filter, limit: 10, offset: 0)
        #expect(page.messages.map(\.id) == [4, 3])
    }

    @Test("status counts the newest rows and reports the size of the log")
    func status() async throws {
        let fixture = try populated()
        let status = try await store(fixture).status(sendShortcut: "unused")
        #expect(status.access == .granted)
        #expect(status.messageCount == 4)
        #expect(status.conversationCount == 1)
        #expect(status.newestMessageDate == Self.date(11, 10))
        #expect((status.walBytes ?? 0) > 0)
    }

    @Test("The handle this server opens refuses every write")
    func refusesWrites() throws {
        let fixture = try populated()
        let database = try ChatDatabase(path: fixture.path)
        #expect(database.executeForTesting("UPDATE message SET text = 'x'") != SQLITE_OK)
        #expect(database.executeForTesting("DELETE FROM message") != SQLITE_OK)
        #expect(database.executeForTesting("CREATE TABLE intruder (x)") != SQLITE_OK)
    }

    @Test("A missing load-bearing column is reported as a schema change, not an empty result")
    func missingRequiredColumn() async throws {
        let fixture = try Fixture(omitting: ["is_from_me"])
        await #expect(throws: ToolError.schemaUnsupported(table: "message", missing: ["is_from_me"])) {
            _ = try await store(fixture).conversations(query: nil, limit: 10, offset: 0)
        }
    }

    @Test("A missing optional column degrades to NULL instead of failing")
    func missingOptionalColumn() async throws {
        let fixture = try Fixture(omitting: ["date_read", "is_read"])
        try fixture.insertChat()
        try execute(fixture)
        let page = try await store(fixture).conversation(id: 1, limit: 10, offset: 0)
        #expect(page.messages.map(\.id) == [1])
        #expect(page.messages.first?.dateRead == nil)
    }

    private func execute(_ fixture: Fixture) throws {
        // Written without the omitted columns, so it exercises the same path the reader does.
        try fixture.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, "
                + "associated_message_type) VALUES (1, 'G', 'hello', 1, 'iMessage', "
                + "\(AppleAbsoluteTime.rawValue(from: Self.date(10, 9), unit: .nanoseconds)), 0, 0)")
        try fixture.execute("INSERT INTO chat_message_join VALUES (1, 1)")
    }

    // MARK: Paging and bounding a search where the rows are read

    /// Ten messages an hour apart, id 10 the newest; the even ones mention bread.
    private func archive() throws -> Fixture {
        let fixture = try Fixture()
        try fixture.insertChat()
        for id in 1...10 {
            try fixture.insertMessage(
                id: id, text: id.isMultiple(of: 2) ? "bread \(id)" : "other \(id)", at: Self.date(10, id))
        }
        return fixture
    }

    @Test("A search stops one match past its page, and the next page starts where it ended")
    func searchPagesChain() async throws {
        let fixture = try archive()
        var filter = MessageFilter()
        filter.query = "bread"

        let first = try await store(fixture).search(filter, limit: 2, offset: 0)
        #expect(first.messages.map(\.id) == [10, 8])
        #expect(first.hasMore && first.total == nil && !first.hitScanCeiling)
        // It read no further than the match that proved another page exists.
        #expect(first.scanned == 5)

        let second = try await store(fixture).search(filter, limit: 2, offset: 2)
        #expect(second.messages.map(\.id) == [6, 4])
        #expect(second.hasMore)

        let last = try await store(fixture).search(filter, limit: 2, offset: 4)
        #expect(last.messages.map(\.id) == [2])
        #expect(!last.hasMore && last.total == 5 && !last.hitScanCeiling)

        let past = try await store(fixture).search(filter, limit: 2, offset: 9)
        #expect(past.messages.isEmpty && past.total == 5)
    }

    @Test("The ceiling counts the rows read, and the oldest one read is reported")
    func scanCeiling() async throws {
        let fixture = try archive()
        var filter = MessageFilter()
        filter.query = "bread"
        filter.scanCeiling = 3

        let page = try await store(fixture).search(filter, limit: 5, offset: 0)
        #expect(page.scanned == 3)
        #expect(page.hitScanCeiling && !page.hasMore)
        #expect(page.messages.map(\.id) == [10, 8])
        #expect(page.total == 2)
        #expect(page.oldestScanned == Self.date(10, 8))
    }

    @Test("A date range chooses the rows that are read, so an old period is reached under the ceiling")
    func dateRangeNarrowsTheScan() async throws {
        let fixture = try archive()
        var filter = MessageFilter()
        filter.query = "bread"
        filter.scanCeiling = 3
        // The end is the first moment no longer wanted: one second past message 4.
        filter.to = Self.date(10, 4).addingTimeInterval(1)

        let older = try await store(fixture).search(filter, limit: 5, offset: 0)
        #expect(older.messages.map(\.id) == [4, 2])
        #expect(older.scanned == 3 && older.hitScanCeiling)
        #expect(older.oldestScanned == Self.date(10, 2))

        filter.from = Self.date(10, 3)
        let window = try await store(fixture).search(filter, limit: 5, offset: 0)
        #expect(window.messages.map(\.id) == [4])
        #expect(window.scanned == 2 && !window.hitScanCeiling && window.total == 1)
    }

    @Test("A row stored in seconds is found by the same date range as one stored in nanoseconds")
    func dateRangeReadsBothUnits() async throws {
        let fixture = try Fixture()
        try fixture.insertChat()
        try fixture.insertMessage(id: 2, text: "nanoseconds", at: Self.date(5, 10))
        try fixture.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, "
                + "associated_message_type) VALUES (1, 'G1', 'seconds', 1, 'iMessage', "
                + "\(AppleAbsoluteTime.rawValue(from: Self.date(5, 9), unit: .seconds)), 0, 1, 0)")
        try fixture.execute("INSERT INTO chat_message_join VALUES (1, 1)")
        // No date at all: it cannot be shown to fall inside a range.
        try fixture.execute(
            "INSERT INTO message (ROWID, guid, text, handle_id, service, date, is_from_me, is_read, "
                + "associated_message_type) VALUES (3, 'G3', 'undated', 1, 'iMessage', 0, 0, 1, 0)")
        try fixture.execute("INSERT INTO chat_message_join VALUES (1, 3)")

        var filter = MessageFilter()
        filter.from = Self.date(5, 0)
        filter.to = Self.date(6, 0)
        #expect(try await store(fixture).search(filter, limit: 5, offset: 0).messages.map(\.id) == [2, 1])

        // Half an hour after the row stored in seconds, so the bound falls between the two.
        filter.from = Self.date(5, 9).addingTimeInterval(1800)
        #expect(try await store(fixture).search(filter, limit: 5, offset: 0).messages.map(\.id) == [2])

        filter.from = nil
        filter.to = Self.date(5, 9).addingTimeInterval(1800)
        let untilThen = try await store(fixture).search(filter, limit: 5, offset: 0)
        #expect(untilThen.messages.map(\.id) == [1])
        #expect(untilThen.scanned == 1)

        #expect(try await store(fixture).search(MessageFilter(), limit: 5, offset: 0).messages.count == 3)
    }

    @Test("Conversations with the same latest message are ordered by id, so a page boundary stays put")
    func conversationsOrderHasNoTies() async throws {
        let fixture = try populated()
        for id in [2, 3, 4] {
            try fixture.execute("INSERT INTO chat VALUES (\(id), 'G\(id)', 'chat\(id)', NULL, 'iMessage', 43)")
        }
        let all = try await store(fixture).conversations(query: nil, limit: 10, offset: 0)
        #expect(all.conversations.map(\.id) == [1, 4, 3, 2])
        #expect(all.total == 4)
        let page = try await store(fixture).conversations(query: nil, limit: 2, offset: 1)
        #expect(page.conversations.map(\.id) == [4, 3])
    }

    @Test("conversation_get pages through the real database, each page starting where the last ended")
    func threadPagesChain() async throws {
        let fixture = try archive()
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let tools = MessageTools(store: store(fixture), calendar: utc)
        var shown: [String] = []
        for (offset, expected) in [
            (0, "Showing 1–4 of 10 messages. Pass offset=4 for the next page."),
            (4, "Showing 5–8 of 10 messages. Pass offset=8 for the next page."),
            (8, "Showing 9–10 of 10 messages. That is all."),
        ] {
            let result = await tools.handle(
                .init(name: ToolCatalog.conversationName, arguments: ["conversation_id": 1, "limit": 4, "offset": .int(offset)]))
            #expect(!result.isError)
            #expect(result.text.hasPrefix(expected + "\n\n"))
            shown += result.text.components(separatedBy: "\n").filter { $0.contains("  id=") }
        }
        #expect(shown.count == 10)
        #expect(shown.first?.hasSuffix("bread 10  id=10") == true)
        #expect(shown.last?.hasSuffix("other 1  id=1") == true)

        let search = await tools.handle(
            .init(name: ToolCatalog.searchName, arguments: ["query": "bread", "to_date": "2026-08-10T04:00", "limit": 1]))
        #expect(search.text.hasPrefix("Showing 1–1 messages; more exist. Pass offset=1 for the next page.\n\n"))
        #expect(search.text.contains("bread 4  id=4"))
    }

    @Test("A path with no database is reported missing, and nothing is created there")
    func missingFile() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-messages-mcp-absent-\(UUID().uuidString).db").path
        let store = SystemMessageStore(databasePath: path, shortcutsExecutable: "/nonexistent")
        #expect(store.access() == .missing(path: path))
        await #expect(throws: ToolError.self) {
            _ = try await store.conversations(query: nil, limit: 1, offset: 0)
        }
        #expect(!FileManager.default.fileExists(atPath: path))
    }
}
