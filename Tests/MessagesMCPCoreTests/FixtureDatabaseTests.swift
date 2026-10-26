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
        sqlite3_close(writer)
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
