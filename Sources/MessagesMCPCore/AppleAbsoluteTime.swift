import Foundation

/// The unit `message.date` is stored in.
///
/// Apple changed it without changing the column: databases written before macOS 10.13
/// hold seconds, everything since holds nanoseconds. A database migrated across that
/// boundary keeps its old rows, so both can appear in one file.
public enum AppleTimeUnit: String, Sendable, Equatable {
    case seconds
    case nanoseconds
}

/// Conversion between Core Data's absolute time and `Date`.
///
/// Kept above the store seam and free of SQLite so the epoch rules — the single most
/// likely thing to be silently wrong by 31 years — are provable in the test suite.
public enum AppleAbsoluteTime {

    /// 2001-01-01T00:00:00Z expressed against the Unix epoch.
    public static let referenceOffset: TimeInterval = 978_307_200

    /// Above this, a raw value can only be nanoseconds.
    ///
    /// The two readings are eight orders of magnitude apart, so the boundary is not a
    /// close call: 1e11 *seconds* after 2001 is the year 5170, and 1e11 *nanoseconds*
    /// after 2001 is 100 seconds past midnight on 2001-01-01. Every real message is far
    /// from both — a 2012 SMS is ~3.7e8 seconds, a 2026 iMessage is ~7.9e17 nanoseconds.
    static let nanosecondFloor: Int64 = 100_000_000_000

    public static func unit(ofRawValue raw: Int64) -> AppleTimeUnit {
        abs(raw) >= nanosecondFloor ? .nanoseconds : .seconds
    }

    /// `nil` for 0, which the schema uses for "never happened" — an unread message has
    /// `date_read = 0`, and rendering that as 2001-01-01 is how a store like this starts
    /// telling lies.
    public static func date(fromRawValue raw: Int64) -> Date? {
        guard raw != 0 else { return nil }
        let seconds: TimeInterval =
            switch unit(ofRawValue: raw) {
            case .nanoseconds: TimeInterval(raw) / 1_000_000_000
            case .seconds: TimeInterval(raw)
            }
        return Date(timeIntervalSince1970: seconds + referenceOffset)
    }

    /// The inverse, needed to write fixture rows and to express a bound in the unit a
    /// given database actually uses.
    public static func rawValue(from date: Date, unit: AppleTimeUnit) -> Int64 {
        let seconds = date.timeIntervalSince1970 - referenceOffset
        switch unit {
        case .seconds: return Int64(seconds.rounded())
        case .nanoseconds: return Int64((seconds * 1_000_000_000).rounded())
        }
    }
}
