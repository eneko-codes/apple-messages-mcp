import Foundation
import Testing

@testable import MessagesMCPCore

/// Pins the handful of invariants that live below `MessageStore` but are still pure
/// functions, free of SQLite and Shortcuts I/O, so they can be proven directly rather
/// than only by hand. Everything else below that seam — the real database, the real
/// shortcut — stays out of this suite by design and is verified by hand.
@Suite("Core invariants")
struct CoreInvariantsTests {

    // MARK: Read-only database

    /// `mode=ro` is what makes SQLite refuse every write, and the URI is deliberately not
    /// `immutable=1`: that flag skips the write-ahead log and would hide the newest
    /// messages, and it is a promise that nothing changes the file while Messages is
    /// running — which is false.
    @Test("The chat.db URI is read-only and never immutable")
    func databaseURIIsReadOnly() {
        let uri = ChatDatabase.uri(forPath: "/Users/owner/Library/Messages/chat.db")
        #expect(uri == "file:/Users/owner/Library/Messages/chat.db?mode=ro")
        #expect(!uri.contains("immutable"))
    }

    /// An unescaped `?` or `#` in the path would start the query string or fragment
    /// early, letting a crafted path override the mode or open a different file
    /// entirely. Percent-encoding everything outside the unreserved set is what stops
    /// that from ever being possible.
    @Test("immutable is used only when no process has the database open")
    func immutableOnlyWithoutSidecars() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-messages-mcp-sidecars-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("chat.db").path

        #expect(ChatDatabase.openingURI(forPath: path).hasSuffix("?mode=ro&immutable=1"))
        FileManager.default.createFile(atPath: path + "-wal", contents: Data())
        #expect(ChatDatabase.openingURI(forPath: path).hasSuffix("?mode=ro&immutable=1"))
        FileManager.default.createFile(atPath: path + "-shm", contents: Data())
        #expect(ChatDatabase.openingURI(forPath: path).hasSuffix("?mode=ro"))
    }

    @Test("A path with reserved characters cannot smuggle a different mode into the URI")
    func databaseURIEncodesReservedCharacters() {
        let uri = ChatDatabase.uri(forPath: "/tmp/evil?mode=rw#chat.db")
        #expect(uri.hasSuffix("?mode=ro"))
        #expect(uri.components(separatedBy: "?").count == 2)
        #expect(!uri.contains("#"))
    }

    @Test("A permission refusal is told apart from a missing file")
    func errnoClassification() {
        #expect(ChatDatabase.classify(errno: EPERM, path: "/x") == .denied)
        #expect(ChatDatabase.classify(errno: EACCES, path: "/x") == .denied)
        #expect(ChatDatabase.classify(errno: ENOENT, path: "/x") == .missing(path: "/x"))
        #expect(ChatDatabase.isPermissionDenied(code: 23, systemErrno: 0))  // SQLITE_AUTH
        #expect(ChatDatabase.isPermissionDenied(code: 14, systemErrno: EPERM))  // CANTOPEN + EPERM
        #expect(!ChatDatabase.isPermissionDenied(code: 14, systemErrno: ENOENT))
    }

    // MARK: Apple absolute time

    /// Getting this unit wrong shifts every timestamp by 31 years — a bug plausible
    /// enough to ship. The two readings are eight orders of magnitude apart, so both
    /// sides of the boundary are checked rather than just one.
    @Test("The date unit is decided correctly on both sides of the nanosecond floor")
    func appleAbsoluteTimeUnitBoundary() {
        #expect(AppleAbsoluteTime.unit(ofRawValue: 370_000_000) == .seconds)  // ~2012, in seconds
        #expect(AppleAbsoluteTime.unit(ofRawValue: 790_000_000_000_000_000) == .nanoseconds)  // ~2026
    }

    @Test("Apple absolute time round-trips through both units")
    func appleAbsoluteTimeRoundTrips() {
        let date = Date(timeIntervalSince1970: 1_754_000_000)  // an arbitrary 2025 instant
        for unit: AppleTimeUnit in [.seconds, .nanoseconds] {
            let raw = AppleAbsoluteTime.rawValue(from: date, unit: unit)
            let decoded = AppleAbsoluteTime.date(fromRawValue: raw)
            #expect(decoded.map { abs($0.timeIntervalSince(date)) < 1 } == true)
        }
    }

    /// The schema uses 0 for "never happened" — an unread message has `date_read = 0`.
    /// Decoding that as 2001-01-01 would be this store telling its first lie.
    @Test("A raw value of 0 means the event never happened, not 2001-01-01")
    func appleAbsoluteTimeZeroIsNil() {
        #expect(AppleAbsoluteTime.date(fromRawValue: 0) == nil)
    }

    // MARK: attributedBody

    /// The byte layout `NSArchiver` writes for a plain `NSString`, per the reader's own
    /// documented format: a one-character type descriptor, a single-byte length, then
    /// the UTF-8 body.
    @Test("attributedBody text is recovered from a typedstream-archived NSString")
    func attributedBodyRecoversPlainText() {
        var bytes: [UInt8] = [0x84, 0x01, 0x2b]
        let text = "bring the bread"
        bytes.append(UInt8(text.utf8.count))
        bytes.append(contentsOf: Array(text.utf8))
        #expect(AttributedBody.text(from: Data(bytes)) == text)
    }

    /// A schema or archive-format change should surface as no text, never as garbage in
    /// a transcript.
    @Test("A blob that is not a recognisable typedstream archive decodes to nil")
    func attributedBodyRefusesGarbage() {
        #expect(AttributedBody.text(from: Data([0x00, 0x01, 0x02, 0x03])) == nil)
    }
}
