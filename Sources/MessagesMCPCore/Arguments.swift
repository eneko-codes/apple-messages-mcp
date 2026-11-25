import Foundation

/// Typed access to a `tools/call` argument bag.
///
/// Nothing here is an edit: this server never modifies a message, so there is no
/// "clear this field" affordance and no `FieldEdit`. An absent argument simply means
/// the filter is not applied.
///
/// A class, not a struct, so that reading a number can also record that it was moved into
/// its range without every reader having to be `mutating`. One instance serves one call and
/// never leaves it. The tool puts `notices` before the data.
public final class Arguments {
    private let values: [String: Value]
    private let calendar: Calendar

    /// One sentence for each number that was moved into its range, in the order read.
    public private(set) var notices: [String] = []

    public init(_ values: [String: Value]?, calendar: Calendar) {
        self.values = values ?? [:]
        self.calendar = calendar
    }

    /// `nil` when the argument is absent or null, which mean the same: not given.
    private func given(_ name: String) -> Value? {
        guard let raw = values[name], !raw.isNull else { return nil }
        return raw
    }

    // MARK: Text and flags

    private func text(_ name: String) throws -> String? {
        guard let raw = given(name) else { return nil }
        guard let text = raw.stringValue else {
            throw ToolError.badArgument(name: name, reason: "text was expected")
        }
        return text
    }

    public func requiredString(_ name: String) throws -> String {
        guard let raw = try text(name) else { throw ToolError.missingArgument(name) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return trimmed
    }

    /// The one argument that keeps its own whitespace and line breaks. Trimming a message
    /// body would quietly rewrite what someone agreed to send.
    public func requiredBody(_ name: String) throws -> String {
        guard let raw = try text(name) else { throw ToolError.missingArgument(name) }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ToolError.badArgument(name: name, reason: "it is empty")
        }
        return raw
    }

    /// Empty text is "not given", as an absent argument is.
    public func optionalString(_ name: String) throws -> String? {
        guard let raw = try text(name) else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Tri-state: absent means "do not filter on this", which is not the same as `false`.
    public func optionalBool(_ name: String) throws -> Bool? {
        guard let raw = given(name) else { return nil }
        guard let flag = raw.boolValue else {
            throw ToolError.badArgument(name: name, reason: "true or false was expected")
        }
        return flag
    }

    public func bool(_ name: String, default fallback: Bool = false) throws -> Bool {
        try optionalBool(name) ?? fallback
    }

    // MARK: Quantities

    /// A quantity: a number of rows. Outside its range it is moved to the nearest allowed
    /// value, and `notices` gains the sentence that says which value was used. A model
    /// asking for 500 results means "as many as you will give me".
    public func int(_ name: String, default fallback: Int, in range: ClosedRange<Int>) throws
        -> Int
    {
        guard let raw = given(name) else { return fallback }
        guard let number = raw.intValue else {
            throw ToolError.badArgument(name: name, reason: "a whole number was expected")
        }
        return ToolStandard.clamp(number, to: range, argument: name, notices: &notices)
    }

    /// The `limit` and `offset` of a listing, read the same way by every tool that pages.
    public func page(defaultLimit: Int, limits: ClosedRange<Int>) throws -> (limit: Int, offset: Int) {
        (
            try int("limit", default: defaultLimit, in: limits),
            try int("offset", default: 0, in: Configuration.offsetRange)
        )
    }

    // MARK: Identifiers

    /// A row id. Unlike a limit this is never moved into its range: a wrong id must fail,
    /// not resolve to a neighbouring conversation. Like every other number it has to
    /// arrive as a number: digits inside text are refused, as they are for a limit.
    private func identifier(_ raw: Value, name: String) throws -> Int64 {
        let range = Configuration.identifierRange
        guard let number = raw.intValue, range.contains(number) else {
            throw ToolError.badArgument(
                name: name,
                reason: "an id, a whole number from \(range.lowerBound) to \(range.upperBound), was expected")
        }
        return Int64(number)
    }

    public func requiredID(_ name: String) throws -> Int64 {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        return try identifier(raw, name: name)
    }

    /// An id that may simply not have been given. Absent and malformed stay distinct:
    /// omitting `conversation_id` means "across all conversations", whereas a value that
    /// is not a number is a mistake worth naming.
    public func optionalID(_ name: String) throws -> Int64? {
        try given(name).map { try identifier($0, name: name) }
    }

    /// At least one id and at most `maximum`. A longer list is refused, not shortened: the
    /// ids dropped would be rows the caller believes were looked at.
    public func requiredIDs(_ name: String, atMost maximum: Int) throws -> [Int64] {
        guard let raw = given(name) else { throw ToolError.missingArgument(name) }
        // A single id where an array is expected is a common and harmless slip.
        guard let entries = raw.arrayValue else { return [try identifier(raw, name: name)] }
        guard !entries.isEmpty else { throw ToolError.missingArgument(name) }
        guard entries.count <= maximum else {
            throw ToolError.badArgument(
                name: name,
                reason: "it holds \(entries.count) ids and one call takes at most \(maximum); split them over several calls")
        }
        return try entries.map { try identifier($0, name: name) }
    }

    // MARK: Dates

    public func optionalDate(_ name: String) throws -> ParsedDate? {
        guard let raw = try optionalString(name) else { return nil }
        return try DateParsing.parse(raw, argument: name, calendar: calendar)
    }
}
