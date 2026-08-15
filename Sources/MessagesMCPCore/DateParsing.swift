import Foundation

public struct ParsedDate: Sendable, Equatable {
    public let date: Date
    /// True when the caller wrote only a day. `messages_search` widens such a `to` to the
    /// end of that day, so "to 2026-08-12" includes 2026-08-12.
    public let isDateOnly: Bool

    public init(date: Date, isDateOnly: Bool) {
        self.date = date
        self.isDateOnly = isDateOnly
    }
}

/// Parsing and rendering of the three date forms this server accepts.
///
/// Deliberately strict. A lenient parser that guesses at `10/08/2026` will one day read
/// it as 8 October for a caller who meant 10 August, and a search that quietly answers
/// about the wrong two months is worse than one that refuses the input.
public enum DateParsing {

    public static let acceptedForms = """
        - 2026-08-12                  a whole day, local time
        - 2026-08-12T09:00            local time
        - 2026-08-12T09:00:00+02:00   explicit offset
        """

    public static func parse(_ raw: String, argument: String, calendar: Calendar) throws
        -> ParsedDate
    {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)

        if let components = dayComponents(text) {
            guard let day = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: calendar.startOfDay(for: day), isDateOnly: true)
        }

        if let components = localComponents(text) {
            guard let moment = calendar.date(from: components) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(date: moment, isDateOnly: false)
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [ISO8601DateFormatter.Options] = [
            [.withInternetDateTime],
            [.withInternetDateTime, .withFractionalSeconds],
        ]
        for options in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                return ParsedDate(date: moment, isDateOnly: false)
            }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// `YYYY-MM-DD` and nothing else.
    private static func dayComponents(_ text: String) -> DateComponents? {
        let parts = text.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }
        return DateComponents(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` or `YYYY-MM-DDTHH:MM:SS`, with no offset suffix.
    private static func localComponents(_ text: String) -> DateComponents? {
        let halves = text.split(separator: "T", omittingEmptySubsequences: false)
        guard halves.count == 2, var day = dayComponents(String(halves[0])) else { return nil }

        let time = halves[1]
        // A trailing Z or offset means the string is absolute; that is the ISO path.
        guard !time.contains("Z"), !time.contains("+"), time.filter({ $0 == "-" }).isEmpty
        else { return nil }

        let pieces = time.split(separator: ":")
        guard (2...3).contains(pieces.count), pieces.allSatisfy({ $0.count == 2 }),
            let hour = Int(pieces[0]), let minute = Int(pieces[1]),
            (0...23).contains(hour), (0...59).contains(minute)
        else { return nil }
        let second = pieces.count == 3 ? Int(pieces[2]) : 0
        guard let second, (0...59).contains(second) else { return nil }

        day.hour = hour
        day.minute = minute
        day.second = second
        return day
    }

    // MARK: Rendering

    private static let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    private static let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    /// Hand-rolled rather than `DateFormatter` so output does not change shape with the
    /// machine's locale. A model that has learned to read `Mon 10 Aug` should not be
    /// handed `lun 10 ago` on a differently configured Mac.
    public static func day(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.weekday, .day, .month], from: date)
        let weekday = parts.weekday.map { weekdays[($0 - 1) % 7] } ?? "???"
        let month = parts.month.map { months[($0 - 1) % 12] } ?? "???"
        return String(format: "%@ %02d %@", weekday, parts.day ?? 0, month)
    }

    public static func dayWithYear(_ date: Date, calendar: Calendar) -> String {
        let year = calendar.component(.year, from: date)
        return "\(day(date, calendar: calendar)) \(year)"
    }

    public static func time(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }

    /// `2026-08-12T09:00` — the form the search tools accept, so a range this server
    /// echoes back can be pasted straight into the next call.
    public static func roundTrip(_ date: Date, dayOnly: Bool = false, calendar: Calendar) -> String
    {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        let day = String(
            format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        guard !dayOnly else { return day }
        return day + String(format: "T%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
    }
}
