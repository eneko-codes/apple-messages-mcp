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

    /// `mode=ro&immutable=1` is the one thing that stops this server from ever being
    /// capable of altering Messages' own storage: `mode=ro` refuses writes, and
    /// `immutable=1` tells SQLite the file cannot change underneath it, so no lock is
    /// taken and no `-wal`/`-shm` sidecar is touched.
    @Test("The chat.db URI is always read-only and immutable")
    func databaseURIIsReadOnlyAndImmutable() {
        let uri = ChatDatabase.uri(forPath: "/Users/owner/Library/Messages/chat.db")
        #expect(uri.hasPrefix("file:"))
        #expect(uri.hasSuffix("?mode=ro&immutable=1"))
    }

    /// An unescaped `?` or `#` in the path would start the query string or fragment
    /// early, letting a crafted path override the mode or open a different file
    /// entirely. Percent-encoding everything outside the unreserved set is what stops
    /// that from ever being possible.
    @Test("A path with reserved characters cannot smuggle a different mode into the URI")
    func databaseURIEncodesReservedCharacters() {
        let uri = ChatDatabase.uri(forPath: "/tmp/evil?mode=rw#chat.db")
        #expect(uri.hasSuffix("?mode=ro&immutable=1"))
        #expect(!uri.contains("evil?mode=rw"))
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
