import Foundation

public struct ParsedDate: Sendable, Equatable {
    /// The first instant of what the caller wrote.
    public let date: Date
    /// The first instant after what the caller wrote: the end of that day, minute, second
    /// or millisecond. It is what makes `to_date` inclusive at the precision it was given
    /// in, so that "to 2026-08-12" includes all of 2026-08-12 and "to 09:00" all of 09:00.
    public let end: Date

    public init(date: Date, end: Date) {
        self.date = date
        self.end = end
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
            // The start of the day, not midnight: where a clock change skips midnight the
            // day still exists and starts an hour later.
            guard let moment = existing(components, calendar: calendar),
                let next = calendar.date(byAdding: .day, value: 1, to: moment)
            else { throw ToolError.badDate(argument: argument, value: text) }
            return ParsedDate(
                date: calendar.startOfDay(for: moment), end: calendar.startOfDay(for: next))
        }

        if let local = localComponents(text) {
            guard let moment = existing(local.components, calendar: calendar) else {
                throw ToolError.badDate(argument: argument, value: text)
            }
            return ParsedDate(
                date: moment, end: moment.addingTimeInterval(local.hasSeconds ? 1 : 60))
        }

        // Only reached for a string carrying its own offset or Z suffix, where the
        // machine's time zone is irrelevant.
        let optionSets: [(options: ISO8601DateFormatter.Options, unit: TimeInterval)] = [
            ([.withInternetDateTime], 1),
            ([.withInternetDateTime, .withFractionalSeconds], 0.001),
        ]
        for (options, unit) in optionSets {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = options
            if let moment = formatter.date(from: text) {
                return ParsedDate(date: moment, end: moment.addingTimeInterval(unit))
            }
        }

        throw ToolError.badDate(argument: argument, value: text)
    }

    /// The moment the components name, or `nil` when the calendar has no such moment:
    /// 30 February, or an hour a clock change skips. `Calendar.date(from:)` would roll
    /// either one forward to a moment that does exist, and a search would then answer
    /// about a day nobody asked for. Only the fields the caller wrote are compared.
    private static func existing(_ components: DateComponents, calendar: Calendar) -> Date? {
        guard let date = calendar.date(from: components) else { return nil }
        let found = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let written: [(Int?, Int?)] = [
            (components.year, found.year), (components.month, found.month),
            (components.day, found.day), (components.hour, found.hour),
            (components.minute, found.minute), (components.second, found.second),
        ]
        return written.allSatisfy { asked, got in asked == nil || asked == got } ? date : nil
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
    private static func localComponents(_ text: String) -> (components: DateComponents, hasSeconds: Bool)? {
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
        return (day, pieces.count == 3)
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

    /// `2026-08-12T09:00:07` — a form the search tool accepts, so a date this server
    /// prints can be pasted straight into the next call. To the second, because that is
    /// the precision `to_date` is inclusive at: the second printed for the oldest message a
    /// scan reached is the one the next scan must start from.
    public static func roundTrip(_ date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02dT%02d:%02d:%02d", parts.year ?? 0, parts.month ?? 0,
            parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}
