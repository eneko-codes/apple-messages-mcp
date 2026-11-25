import Foundation
import Synchronization

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never opens `chat.db` and never runs a shortcut — everything goes through
/// `MessageStore`, which is what lets the tests drive every branch below against an
/// in-memory double with no Full Disk Access, no database and no message ever leaving
/// the process.
public struct MessageTools: ToolHandler {
    private let store: any MessageStore
    private let calendar: Calendar
    private let format: Format
    private let timeout: Duration

    /// Longer than the longest legitimate call, a send that first lists the shortcuts and
    /// then runs one, so that the store's own deadlines answer first and say what
    /// happened. It stays under the 60 s a client commonly waits, and so under
    /// `ToolStandard.timeLimit`, so the answer is ours and not the client's "no result".
    public static let defaultTimeout = Duration.seconds(50)

    public init(
        store: any MessageStore, calendar: Calendar = .current,
        timeout: Duration = MessageTools.defaultTimeout
    ) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
        self.timeout = timeout
    }

    public func handle(_ parameters: ToolCall) async -> ToolOutput {
        let started = ContinuousClock.now
        let outcome = await Deadline.run(within: timeout) {
            do {
                return Result<String, any Error>.success(try await run(parameters))
            } catch {
                return .failure(error)
            }
        }
        switch outcome {
        case .success(let text)?:
            return ToolOutput(text: text, isError: false)
        case .failure(let error)?:
            return failure(error, tool: parameters.name, since: started)
        case nil:
            return failure(
                ToolError.timedOut(
                    seconds: Int(timeout.components.seconds),
                    sending: parameters.name == ToolCatalog.sendName),
                tool: parameters.name, since: started)
        }
    }

    private func failure(
        _ error: any Error, tool: String, since started: ContinuousClock.Instant
    ) -> ToolOutput {
        Diagnostics.toolFailed(tool, error: error, since: started)
        let known = error as? ToolError ?? ToolError.storeFailure(error.localizedDescription)
        return ToolOutput(text: known.message, isError: true)
    }

    private func run(_ parameters: ToolCall) async throws -> String {
        let arguments = Arguments(parameters.arguments, calendar: calendar)

        // Reported before the access check, because "what is wrong and how do I fix it"
        // is exactly the question asked when the database cannot be opened.
        if parameters.name == ToolCatalog.statusName {
            return format.status(
                try await store.status(sendShortcut: Configuration.sendShortcutName),
                binaryPath: Self.binaryPath)
        }

        // send_message goes through the Shortcuts app, not the database, so it is the one
        // tool that still works when Full Disk Access has never been granted.
        if parameters.name == ToolCatalog.sendName {
            return try await send(arguments)
        }

        guard ToolCatalog.readNames.contains(parameters.name) else {
            throw ToolError.unknownTool(parameters.name)
        }
        let access = store.access()
        guard access.isUsable else { throw ToolError.notAuthorized(access) }

        switch parameters.name {
        case ToolCatalog.conversationsName: return try await conversations(arguments)
        case ToolCatalog.conversationName: return try await conversation(arguments)
        case ToolCatalog.searchName: return try await search(arguments)
        default: return try await attachments(arguments)
        }
    }

    // MARK: Reads

    /// A page the store already cut to at most `limit` rows, with what it leaves out said
    /// first. When its text would still be longer than a result may be, it holds fewer
    /// rows; `notices` is asked again for the rows that stay, so it names the right offset.
    private static func page<Row>(
        of rows: [Row], notices: ([Row]) -> [String], render: ([Row]) -> String
    ) -> String {
        ToolStandard.fitting(max(rows.count, 1)) { size in
            let shown = Array(rows.prefix(size))
            return ToolStandard.withNotices(notices(shown), render(shown))
        }
    }

    private func conversations(_ arguments: Arguments) async throws -> String {
        let page = try arguments.page(
            defaultLimit: Configuration.defaultConversationLimit,
            limits: Configuration.conversationLimitRange)
        let query = try arguments.optionalString("query")

        let found = try await store.conversations(query: query, limit: page.limit, offset: page.offset)
        return Self.page(of: found.conversations) { shown in
            arguments.notices + [
                Notice.page(
                    offset: page.offset, count: shown.count, total: found.total, things: "conversations")
            ].compactMap { $0 }
        } render: {
            format.conversations($0, total: found.total, query: query)
        }
    }

    private func conversation(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredID("conversation_id")
        let page = try arguments.page(
            defaultLimit: Configuration.defaultMessageLimit, limits: Configuration.messageLimitRange)

        let found = try await store.conversation(id: id, limit: page.limit, offset: page.offset)
        let total = found.total ?? page.offset + found.messages.count
        return Self.page(of: found.messages) { shown in
            arguments.notices + [
                Notice.page(offset: page.offset, count: shown.count, total: total, things: "messages"),
                shown.contains(where: Format.isClipped) ? Format.clippedNotice : nil,
            ].compactMap { $0 }
        } render: {
            format.conversationPage($0, conversationID: id, total: total)
        }
    }

    private func search(_ arguments: Arguments) async throws -> String {
        var filter = MessageFilter()
        filter.query = try arguments.optionalString("query")
        filter.participant = try arguments.optionalString("participant")
        filter.chatID = try arguments.optionalID("conversation_id")
        let from = try arguments.optionalDate("from_date")
        let to = try arguments.optionalDate("to_date")
        // to_date covers the whole day, minute or second it names, so a range of one day
        // is not empty; it is refused only when even its last moment is before from_date.
        if let from, let to, to.end <= from.date { throw ToolError.endBeforeStart }
        filter.from = from?.date
        filter.to = to?.end
        filter.hasAttachment = try arguments.optionalBool("has_attachment")
        filter.service = try arguments.optionalString("service")
        filter.fromMe = try arguments.optionalBool("from_me")
        filter.scanCeiling = Configuration.scanLimit

        let page = try arguments.page(
            defaultLimit: Configuration.defaultMessageLimit, limits: Configuration.messageLimitRange)

        let found = try await store.search(filter, limit: page.limit, offset: page.offset)
        return Self.page(of: found.messages) { shown in
            var notices = arguments.notices
            if found.hitScanCeiling { notices.append(scanStopped(found)) }
            // With no total, the scan stopped on a match beyond this page: more exist.
            // After the ceiling the total counts only what the scan reached, and says so.
            notices.append(
                contentsOf: [
                    Notice.page(
                        offset: page.offset, count: shown.count, total: found.total,
                        things: found.hitScanCeiling ? "messages found before the scan stopped" : "messages"),
                    shown.contains(where: Format.isClipped) ? Format.clippedNotice : nil,
                ].compactMap { $0 })
            return notices
        } render: {
            format.searchResults($0, page: found, filter: filter)
        }
    }

    /// Rows older than the last one scanned were never looked at. `to_date` set to that
    /// row's second is the call that looks at them: it is inclusive, so the scan resumes
    /// on the same second and nothing between the two scans is skipped. `offset` goes back
    /// to zero with it, because it counts matches from the start of the new, older range.
    private func scanStopped(_ found: MessagePage) -> String {
        let narrowBy =
            found.oldestScanned.map {
                "to_date=\(DateParsing.roundTrip($0, calendar: calendar)) with offset=0 to go on from "
                    + "the oldest message scanned, or by participant or conversation_id"
            } ?? "to_date, participant or conversation_id"
        return Notice.scanStopped(after: found.scanned, things: "messages", narrowBy: narrowBy)
    }

    private func attachments(_ arguments: Arguments) async throws -> String {
        let ids = try arguments.requiredIDs("message_ids", atMost: Configuration.maximumMessageIDs)
        let page = try arguments.page(
            defaultLimit: Configuration.defaultAttachmentLimit,
            limits: Configuration.attachmentLimitRange)

        let all = try await store.attachments(messageIDs: ids)
            .sorted { ($0.messageID, $0.id) < ($1.messageID, $1.id) }
        return ToolStandard.page(
            of: all, limit: page.limit, offset: page.offset, things: "attachments",
            notices: arguments.notices
        ) {
            format.attachments($0, total: all.count, requested: Set(ids).count)
        }
    }

    // MARK: Write

    /// The only outward-facing tool in this server, and the only one that cannot be
    /// undone. Two gates, both of which must pass:
    ///
    /// 1. `confirm=true`;
    /// 2. a length ceiling on the body and on the recipient, because a runaway one is far
    ///    more likely to be a mistake than an intention.
    ///
    /// There is no recipient allow-list here: the owner chose this tool's own
    /// allow/ask/prohibit switch in Claude Desktop and their own confirmation at send
    /// time as the only guard, in place of a list this server used to enforce.
    private func send(_ arguments: Arguments) async throws -> String {
        let recipient = try arguments.requiredString("recipient")
        guard recipient.count <= Configuration.maximumRecipientCharacters else {
            throw ToolError.badArgument(
                name: "recipient",
                reason: "it is \(recipient.count) characters; a phone number or an email address "
                    + "of at most \(Configuration.maximumRecipientCharacters) was expected")
        }
        let text = try arguments.requiredBody("text")
        guard text.count <= Configuration.maximumSendCharacters else {
            throw ToolError.messageTooLong(
                characters: text.count, maximum: Configuration.maximumSendCharacters)
        }

        guard try arguments.bool("confirm") else {
            throw ToolError.confirmationRequired(action: "Sending a message")
        }

        let receipt = try await store.send(
            recipient: recipient, text: text, shortcutName: Configuration.sendShortcutName)
        return format.sent(receipt)
    }

    static var binaryPath: String {
        CommandLine.arguments.first.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            ?? "(unknown)"
    }
}
