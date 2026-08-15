import Foundation
import SQLite3

/// Read-only reader for a Messages `chat.db`.
///
/// Takes a path, so the tests point it at a fixture database they build themselves and
/// the owner's real archive is never opened by the suite. `SystemMessageStore` is the
/// only thing that hands it the real one.
///
/// ## Why it can never write
///
/// The file is opened through a URI with `mode=ro&immutable=1`, and the flags exclude
/// `SQLITE_OPEN_READWRITE`. `mode=ro` refuses writes. `immutable=1` goes further and
/// promises SQLite the file cannot change underneath it, so SQLite takes **no locks at
/// all** and never opens the `-wal` or `-shm` sidecars. Messages holds this database
/// open constantly; a reader that took a lock or checkpointed the WAL would be
/// interfering with a running app on the owner's own machine.
///
/// The price of `immutable=1` is honest and worth stating: writes Messages has not yet
/// checkpointed out of its write-ahead log are invisible here. The newest messages can
/// lag by seconds to minutes. That is the correct trade — a message that shows up late
/// is a nuisance, a corrupted archive is not recoverable.
///
/// ## Why every column is probed
///
/// This schema is private. Apple adds, renames and removes columns between releases —
/// `attributedBody` arrived when the `text` column stopped being filled reliably,
/// `date_edited` arrived with editable messages, `service` gained `RCS`. Selecting a
/// column that does not exist fails the whole statement, so the reader asks
/// `PRAGMA table_info` first and substitutes `NULL` for anything absent. Only the
/// handful of columns in `requiredColumns` are treated as load-bearing, and their
/// absence is reported as a bug in this server rather than as a mysterious empty result.
final class ChatDatabase {

    /// `sqlite3_bind_text` must copy: the Swift string backing the pointer is gone by the
    /// time the statement runs.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    static var defaultPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/Messages/chat.db")
    }

    private let handle: OpaquePointer
    let path: String

    /// Column names actually present, per table.
    private var presentColumns: [String: Set<String>] = [:]

    // MARK: Opening

    /// SQLite URI for a path, always read-only and immutable.
    ///
    /// Static and pure so the one string that decides whether this server can write is
    /// asserted directly in a test rather than inferred from behaviour.
    static func uri(forPath path: String) -> String {
        // Everything outside this set is percent-encoded. '?' would start the query
        // string, '#' the fragment and '%' an escape, so a path containing one of them
        // would otherwise open a different file — or a writable one.
        let unreserved = CharacterSet(
            charactersIn:
                "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~/:@!$&'()*+,;=")
        let encoded = path.addingPercentEncoding(withAllowedCharacters: unreserved) ?? path
        return "file:\(encoded)?mode=ro&immutable=1"
    }

    /// Distinguishes "not there" from "not allowed" before SQLite is involved.
    ///
    /// SQLite reports both as `SQLITE_CANTOPEN`, and the two need completely different
    /// advice. `open(2)` is the only thing that knows which it is: Full Disk Access
    /// denial surfaces as EPERM, and a hidden parent directory as ENOENT.
    static func probeAccess(path: String) -> DatabaseAccess {
        let descriptor = open(path, O_RDONLY)
        if descriptor >= 0 {
            close(descriptor)
            return .granted
        }
        switch errno {
        case EPERM, EACCES: return .denied
        case ENOENT, ENOTDIR: return .missing(path: path)
        default: return .failed(String(cString: strerror(errno)))
        }
    }

    init(path: String) throws {
        self.path = path

        var pointer: OpaquePointer?
        // No SQLITE_OPEN_READWRITE and no SQLITE_OPEN_CREATE: a typo in the path must
        // fail, never conjure an empty database next to the real one.
        let flags = SQLITE_OPEN_READONLY | SQLITE_OPEN_URI | SQLITE_OPEN_NOMUTEX
        let code = sqlite3_open_v2(Self.uri(forPath: path), &pointer, flags, nil)
        guard code == SQLITE_OK, let pointer else {
            let detail = pointer.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(code)"
            if pointer != nil { sqlite3_close(pointer) }
            throw ToolError.notAuthorized(
                code == SQLITE_CANTOPEN ? Self.probeAccess(path: path) : .failed(detail))
        }
        self.handle = pointer
    }

    deinit { sqlite3_close(handle) }

    // MARK: Schema

    /// Columns this server cannot work without, per table. Everything else degrades to
    /// `NULL` and a slightly poorer answer.
    static let requiredColumns: [String: [String]] = [
        "message": ["guid", "date", "is_from_me"],
        "chat": ["guid", "chat_identifier"],
        "handle": ["id"],
        "chat_message_join": ["chat_id", "message_id"],
        "chat_handle_join": ["chat_id", "handle_id"],
        "attachment": ["guid"],
        "message_attachment_join": ["message_id", "attachment_id"],
    ]

    func columns(of table: String) throws -> Set<String> {
        if let cached = presentColumns[table] { return cached }
        var names: Set<String> = []
        // Interpolated because PRAGMA does not accept a bound parameter. Every caller
        // passes a literal from `requiredColumns`; nothing user-supplied reaches here.
        try query("PRAGMA table_info(\(table))") { statement in
            if let name = Self.text(statement, 1) { names.insert(name) }
        }
        presentColumns[table] = names
        return names
    }

    /// Throws the moment a load-bearing column is gone, so the failure names the schema
    /// change instead of surfacing as empty results three tools later.
    func verifySchema() throws {
        for (table, required) in Self.requiredColumns.sorted(by: { $0.key < $1.key }) {
            let present = try columns(of: table)
            guard !present.isEmpty else {
                throw ToolError.schemaUnsupported(table: table, missing: required)
            }
            let missing = required.filter { !present.contains($0) }
            guard missing.isEmpty else {
                throw ToolError.schemaUnsupported(table: table, missing: missing)
            }
        }
    }

    /// `alias.column`, or the literal `NULL` when this macOS does not have that column.
    ///
    /// Keeps the column indices in the row readers fixed whatever the schema is missing,
    /// which is what stops a schema change from silently shifting every field by one.
    private func selected(_ table: String, _ alias: String, _ column: String) throws -> String {
        try columns(of: table).contains(column) ? "\(alias).\(column)" : "NULL"
    }

    private func has(_ table: String, _ column: String) throws -> Bool {
        try columns(of: table).contains(column)
    }

    // MARK: Statement plumbing

    /// `row` returns false to abandon the rest of the result set.
    ///
    /// Stopping matters: a search reads newest-first and usually has its page after a few
    /// dozen rows, and stepping the remaining ceiling of rows to discard them would cost
    /// the whole scan for nothing.
    private func queryStopping(
        _ sql: String, bind: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Bool
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK,
            let statement
        else {
            throw ToolError.storeFailure(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        try bind(statement)
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if try !row(statement) { return }
            case SQLITE_DONE: return
            default: throw ToolError.storeFailure(String(cString: sqlite3_errmsg(handle)))
            }
        }
    }

    private func query(
        _ sql: String, bind: (OpaquePointer) throws -> Void = { _ in },
        row: (OpaquePointer) throws -> Void
    ) throws {
        try queryStopping(sql, bind: bind) { statement in
            try row(statement)
            return true
        }
    }

    /// Exposed for the test that proves this handle refuses writes. Nothing in the server
    /// calls it.
    func executeForTesting(_ sql: String) -> Int32 {
        sqlite3_exec(handle, sql, nil, nil, nil)
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
            let raw = sqlite3_column_text(statement, index)
        else { return nil }
        return String(cString: raw)
    }

    private static func integer(_ statement: OpaquePointer, _ index: Int32) -> Int64 {
        sqlite3_column_int64(statement, index)
    }

    private static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard sqlite3_column_type(statement, index) == SQLITE_BLOB,
            let bytes = sqlite3_column_blob(statement, index)
        else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, index)))
    }

    private static func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, transient)
    }

    // MARK: Counts and units

    func count(of table: String) throws -> Int {
        var total = 0
        try query("SELECT COUNT(*) FROM \(table)") { total = Int(Self.integer($0, 0)) }
        return total
    }

    /// Which unit this particular database stores `message.date` in.
    ///
    /// Decided from the largest value present, because the two readings are eight orders
    /// of magnitude apart. An empty table answers `.nanoseconds`: that is what a Mac
    /// running a supported macOS will write, and the answer only matters once there is a
    /// row to read.
    func dateUnit() throws -> AppleTimeUnit {
        var maximum: Int64 = 0
        try query("SELECT MAX(date) FROM message") { maximum = Self.integer($0, 0) }
        guard maximum != 0 else { return .nanoseconds }
        return AppleAbsoluteTime.unit(ofRawValue: maximum)
    }

    func newestMessageDate() throws -> Date? {
        var maximum: Int64 = 0
        try query("SELECT MAX(date) FROM message") { maximum = Self.integer($0, 0) }
        return AppleAbsoluteTime.date(fromRawValue: maximum)
    }

    // MARK: Conversations

    /// Every chat, with its participants and aggregates.
    ///
    /// Read whole rather than paged in SQL: the `chat` table holds one row per
    /// conversation — hundreds, where `message` holds hundreds of thousands — and the
    /// label a caller searches on is assembled from a second table, which SQL cannot
    /// filter on without a join this reader would then have to keep in step with the
    /// schema. Paging happens above, on the sorted result.
    func conversations() throws -> [Conversation] {
        var participants: [Int64: [String]] = [:]
        try query(
            """
            SELECT j.chat_id, h.id
            FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id
            ORDER BY h.id
            """
        ) { statement in
            let chatID = Self.integer(statement, 0)
            if let handle = Self.text(statement, 1) {
                participants[chatID, default: []].append(handle)
            }
        }

        let unreadExpression =
            try has("message", "is_read")
            ? """
            (SELECT COUNT(*) FROM chat_message_join j JOIN message m ON m.ROWID = j.message_id
             WHERE j.chat_id = c.ROWID AND m.is_from_me = 0 AND IFNULL(m.is_read, 0) = 0)
            """
            : "0"

        var results: [Conversation] = []
        try query(
            """
            SELECT c.ROWID, c.guid, c.chat_identifier,
                   \(try selected("chat", "c", "display_name")),
                   \(try selected("chat", "c", "service_name")),
                   \(try selected("chat", "c", "style")),
                   (SELECT MAX(m.date) FROM chat_message_join j JOIN message m
                    ON m.ROWID = j.message_id WHERE j.chat_id = c.ROWID),
                   (SELECT COUNT(*) FROM chat_message_join j WHERE j.chat_id = c.ROWID),
                   \(unreadExpression)
            FROM chat c
            """
        ) { statement in
            let id = Self.integer(statement, 0)
            let style = Self.integer(statement, 5)
            let people = participants[id] ?? []
            results.append(
                Conversation(
                    id: id,
                    guid: Self.text(statement, 1) ?? "",
                    chatIdentifier: Self.text(statement, 2) ?? "",
                    displayName: Self.text(statement, 3),
                    serviceName: Self.text(statement, 4),
                    // 43 is the group style and 45 the one-to-one style. Neither is
                    // documented, so participant count is kept as a second opinion:
                    // a mislabelled group is confusing, a group treated as one-to-one
                    // hides who else is in it.
                    isGroup: style == 43 || people.count > 1,
                    participants: people,
                    lastMessageDate: AppleAbsoluteTime.date(
                        fromRawValue: Self.integer(statement, 6)),
                    messageCount: Int(Self.integer(statement, 7)),
                    unreadCount: Int(Self.integer(statement, 8))))
        }
        return results
    }

    func conversationExists(id: Int64) throws -> Bool {
        var found = false
        try query(
            "SELECT 1 FROM chat WHERE ROWID = ?",
            bind: { sqlite3_bind_int64($0, 1, id) },
            row: { _ in found = true })
        return found
    }

    func messageCount(inConversation id: Int64) throws -> Int {
        var total = 0
        try query(
            "SELECT COUNT(*) FROM chat_message_join WHERE chat_id = ?",
            bind: { sqlite3_bind_int64($0, 1, id) },
            row: { total = Int(Self.integer($0, 0)) })
        return total
    }

    // MARK: Messages

    /// The one SELECT every message-reading tool shares, so the column indices in
    /// `readMessage` are true for all of them.
    private func messageSelect(joinChat: Bool) throws -> String {
        let chatIDExpression =
            joinChat
            ? "j.chat_id"
            : "(SELECT j2.chat_id FROM chat_message_join j2 WHERE j2.message_id = m.ROWID LIMIT 1)"

        return """
            SELECT m.ROWID, m.guid, m.date, m.is_from_me,
                   \(try selected("message", "m", "text")),
                   \(try selected("message", "m", "attributedBody")),
                   \(try selected("message", "m", "subject")),
                   \(try selected("message", "m", "service")),
                   h.id,
                   \(try selected("message", "m", "is_read")),
                   \(try selected("message", "m", "date_read")),
                   \(try selected("message", "m", "date_delivered")),
                   \(try selected("message", "m", "date_edited")),
                   \(try selected("message", "m", "associated_message_type")),
                   EXISTS(SELECT 1 FROM message_attachment_join a WHERE a.message_id = m.ROWID),
                   \(chatIDExpression)
            """
    }

    private static func readMessage(_ statement: OpaquePointer) -> MessageRecord {
        // The text column is authoritative when it is filled. Modern Messages leaves it
        // NULL and puts the body in attributedBody instead — and an empty string there is
        // as good as absent, which is what the trim check catches.
        var body = text(statement, 4)
        var source = BodySource.textColumn
        if body?.isEmpty ?? true {
            body = blob(statement, 5).flatMap { AttributedBody.text(from: $0) }
            source = body == nil ? .none : .attributedBody
        }

        return MessageRecord(
            id: integer(statement, 0),
            guid: text(statement, 1) ?? "",
            date: AppleAbsoluteTime.date(fromRawValue: integer(statement, 2)),
            dateRead: AppleAbsoluteTime.date(fromRawValue: integer(statement, 10)),
            dateDelivered: AppleAbsoluteTime.date(fromRawValue: integer(statement, 11)),
            dateEdited: AppleAbsoluteTime.date(fromRawValue: integer(statement, 12)),
            isFromMe: integer(statement, 3) == 1,
            isRead: integer(statement, 9) == 1,
            service: text(statement, 7),
            handle: text(statement, 8),
            subject: text(statement, 6),
            text: body,
            bodySource: source,
            hasAttachments: integer(statement, 14) == 1,
            chatID: sqlite3_column_type(statement, 15) == SQLITE_NULL
                ? nil : integer(statement, 15),
            associatedMessageType: Int(integer(statement, 13)))
    }

    /// One page of a thread, newest first.
    ///
    /// `LIMIT`/`OFFSET` are safe to push into SQL here because nothing is filtered above:
    /// what SQL counts and what the caller receives are the same rows.
    func messages(inConversation id: Int64, limit: Int, offset: Int) throws -> [MessageRecord] {
        var results: [MessageRecord] = []
        try query(
            """
            \(try messageSelect(joinChat: true))
            FROM chat_message_join j
            JOIN message m ON m.ROWID = j.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            WHERE j.chat_id = ?
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT ? OFFSET ?
            """,
            bind: { statement in
                sqlite3_bind_int64(statement, 1, id)
                sqlite3_bind_int(statement, 2, Int32(limit))
                sqlite3_bind_int(statement, 3, Int32(offset))
            },
            row: { results.append(Self.readMessage($0)) })
        return results
    }

    /// Handles whose address matches, under the same normalisation the send allow-list
    /// uses. Returns their `handle.ROWID`s, which is what `message.handle_id` points at.
    func handleIDs(matching participant: String) throws -> [Int64] {
        let wanted = Configuration.normalizeRecipient(participant)
        var matches: [Int64] = []
        let uncanonicalized = try selected("handle", "h", "uncanonicalized_id")
        try query("SELECT h.ROWID, h.id, \(uncanonicalized) FROM handle h") { statement in
            let candidates = [Self.text(statement, 1), Self.text(statement, 2)].compactMap { $0 }
            if candidates.contains(where: { Configuration.normalizeRecipient($0) == wanted }) {
                matches.append(Self.integer(statement, 0))
            }
        }
        return matches
    }

    /// Streams messages newest-first through `consume`, which stops the scan by returning
    /// false.
    ///
    /// Only the predicates SQL can decide are pushed down. The date range is deliberately
    /// not among them: `message.date` may hold either unit, so a bound expressed in one
    /// of them would silently exclude rows stored in the other. Dates are compared above,
    /// on the converted value, where both readings are already resolved.
    func scanMessages(
        chatID: Int64?, handleIDs: [Int64]?, service: String?, hasAttachment: Bool?,
        fromMe: Bool?, ceiling: Int, consume: (MessageRecord) -> Bool
    ) throws -> (scanned: Int, hitCeiling: Bool) {
        var conditions: [String] = []
        var boundService: String?

        if chatID != nil { conditions.append("j.chat_id = ?1") }
        if let handleIDs {
            // An empty list means the participant matched no handle at all. Nothing can
            // match, and an unguarded `IN ()` is a syntax error.
            guard !handleIDs.isEmpty else { return (0, false) }
            conditions.append(
                "m.handle_id IN (\(handleIDs.map(String.init).joined(separator: ",")))")
        }
        if let service {
            if try has("message", "service") {
                conditions.append("m.service = ?2 COLLATE NOCASE")
                boundService = service
            } else {
                // No service column at all: filtering on it can only be answered "none",
                // never "all", or the filter would silently do nothing.
                conditions.append("0")
            }
        }
        if let hasAttachment {
            let exists = "EXISTS(SELECT 1 FROM message_attachment_join a WHERE a.message_id = m.ROWID)"
            conditions.append(hasAttachment ? exists : "NOT \(exists)")
        }
        if let fromMe {
            conditions.append("m.is_from_me = \(fromMe ? 1 : 0)")
        }

        let joinChat = chatID != nil
        let source =
            joinChat
            ? """
            FROM chat_message_join j
            JOIN message m ON m.ROWID = j.message_id
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            """
            : """
            FROM message m
            LEFT JOIN handle h ON h.ROWID = m.handle_id
            """
        let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")

        var scanned = 0
        var stoppedEarly = false
        try queryStopping(
            """
            \(try messageSelect(joinChat: joinChat))
            \(source)
            \(whereClause)
            ORDER BY m.date DESC, m.ROWID DESC
            LIMIT \(ceiling)
            """,
            bind: { statement in
                if let chatID { sqlite3_bind_int64(statement, 1, chatID) }
                if let boundService { Self.bind(statement, 2, boundService) }
            },
            row: { statement in
                scanned += 1
                guard consume(Self.readMessage(statement)) else {
                    stoppedEarly = true
                    return false
                }
                return true
            })
        // Reaching the ceiling means the answer is "the newest N matches", not "the
        // matches", and the caller has to be able to say so.
        return (scanned, scanned >= ceiling && !stoppedEarly)
    }

    /// Human-readable names for a set of chats, so a search result can say which thread
    /// each hit came from without a round trip per row.
    func chatLabels(ids: [Int64]) throws -> [Int64: String] {
        guard !ids.isEmpty else { return [:] }
        let identifiers = Set(ids).map(String.init).joined(separator: ",")
        var labels: [Int64: String] = [:]
        try query(
            """
            SELECT c.ROWID, \(try selected("chat", "c", "display_name")), c.chat_identifier
            FROM chat c WHERE c.ROWID IN (\(identifiers))
            """
        ) { statement in
            let name = Self.text(statement, 1)
            labels[Self.integer(statement, 0)] =
                (name?.isEmpty == false ? name : nil) ?? Self.text(statement, 2) ?? ""
        }
        return labels
    }

    // MARK: Attachments

    func attachments(messageIDs: [Int64]) throws -> [AttachmentRecord] {
        guard !messageIDs.isEmpty else { return [] }
        let identifiers = messageIDs.map(String.init).joined(separator: ",")
        let manager = FileManager.default

        var results: [AttachmentRecord] = []
        try query(
            """
            SELECT j.message_id, a.ROWID, a.guid,
                   \(try selected("attachment", "a", "filename")),
                   \(try selected("attachment", "a", "transfer_name")),
                   \(try selected("attachment", "a", "uti")),
                   \(try selected("attachment", "a", "mime_type")),
                   \(try selected("attachment", "a", "total_bytes")),
                   \(try selected("attachment", "a", "is_outgoing")),
                   \(try selected("attachment", "a", "created_date"))
            FROM message_attachment_join j
            JOIN attachment a ON a.ROWID = j.attachment_id
            WHERE j.message_id IN (\(identifiers))
            ORDER BY j.message_id, a.ROWID
            """
        ) { statement in
            // Stored with a literal leading "~", which is not a path any API will open.
            let stored = Self.text(statement, 3)
            let expanded = stored.map { ($0 as NSString).expandingTildeInPath }
            results.append(
                AttachmentRecord(
                    messageID: Self.integer(statement, 0),
                    id: Self.integer(statement, 1),
                    guid: Self.text(statement, 2) ?? "",
                    path: expanded,
                    transferName: Self.text(statement, 4),
                    uti: Self.text(statement, 5),
                    mimeType: Self.text(statement, 6),
                    totalBytes: Self.integer(statement, 7),
                    isOutgoing: Self.integer(statement, 8) == 1,
                    createdDate: AppleAbsoluteTime.date(fromRawValue: Self.integer(statement, 9)),
                    existsOnDisk: expanded.map { manager.fileExists(atPath: $0) } ?? false))
        }
        return results
    }
}
