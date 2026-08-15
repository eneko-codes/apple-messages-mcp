import Foundation
import MCP

/// Typed access to a `tools/call` argument bag.
///
/// Nothing here is an edit: this server never modifies a message, so there is no
/// "clear this field" affordance and no `FieldEdit`. An absent argument simply means
/// the filter is not applied.
public struct Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    // MARK: Scalars

    public func requiredString(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// The one argument that keeps its own whitespace and line breaks. Trimming a message
    /// body would quietly rewrite what someone agreed to send.
    public func requiredBody(_ name: String) throws -> String {
        guard let raw = values[name]?.stringValue else { throw ToolError.missingArgument(name) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return raw
    }

    public func optionalString(_ name: String) -> String? {
        guard let text = values[name]?.stringValue else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func bool(_ name: String, default fallback: Bool = false) -> Bool {
        values[name]?.boolValue ?? fallback
    }

    /// Tri-state: absent means "do not filter on this", which is not the same as `false`.
    public func optionalBool(_ name: String) -> Bool? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        return raw.boolValue
    }

    /// Clamps rather than rejects: a model asking for 500 results means "as many as you
    /// will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = values[name] else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "an integer was expected")
        }
        return Swift.min(Swift.max(number, range.lowerBound), range.upperBound)
    }

    /// A row id. Unlike a limit this is never clamped — a wrong id must fail, not resolve
    /// to a neighbouring conversation.
    public func requiredID(_ name: String) throws -> Int64 {
        guard let raw = values[name] else { throw ToolError.missingArgument(name) }
        if let number = raw.intValue { return Int64(number) }
        // Large integers survive some clients as strings, and refusing one would be a
        // technicality rather than a safeguard.
        if let text = raw.stringValue, let number = Int64(text) { return number }
        throw ToolError.badArgument(
            name: name, reason: "a numeric id from conversations_list was expected")
    }

    /// An id that may simply not have been given. Absent and malformed stay distinct:
    /// omitting `conversation_id` means "across all conversations", whereas a value that
    /// is not a number is a mistake worth naming.
    public func optionalID(_ name: String) throws -> Int64? {
        guard let raw = values[name] else { return nil }
        if case .null = raw { return nil }
        return try requiredID(name)
    }

    public func idArray(_ name: String) throws -> [Int64] {
        guard let raw = values[name] else { return [] }
        if case .null = raw { return [] }
        // A single id where an array is expected is a common and harmless slip.
        if let number = raw.intValue { return [Int64(number)] }
        if let text = raw.stringValue, let number = Int64(text) { return [number] }
        guard let entries = raw.arrayValue else {
            throw ToolError.badArgument(name: name, reason: "an array of numeric ids was expected")
        }
        return try entries.map { entry in
            if let number = entry.intValue { return Int64(number) }
            if let text = entry.stringValue, let number = Int64(text) { return number }
            throw ToolError.badArgument(name: name, reason: "every id must be a number")
        }
    }

    // MARK: Dates

    /// `to` given as a plain day covers that whole day.
    ///
    /// Without this, "from 2026-08-01 to 2026-08-12" would stop at midnight and drop
    /// everything sent on the 12th — the off-by-one-day that makes a search look like it
    /// lost messages.
    public func optionalDate(_ name: String, endOfDayIfDayOnly: Bool = false) throws -> Date? {
        guard let raw = optionalString(name) else { return nil }
        let parsed = try DateParsing.parse(raw, argument: name, calendar: calendar)
        guard endOfDayIfDayOnly, parsed.isDateOnly else { return parsed.date }
        return calendar.date(byAdding: .day, value: 1, to: parsed.date) ?? parsed.date
    }
}
