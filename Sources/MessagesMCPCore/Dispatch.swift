import Foundation
import MCP

/// Routes a `tools/call` to the store and renders the answer.
///
/// Never opens `chat.db` and never runs a shortcut — everything goes through
/// `MessageStore`, which is what lets the tests drive every branch below against an
/// in-memory double with no Full Disk Access, no database and no message ever leaving
/// the process.
public struct MessageTools: Sendable {
    private let store: any MessageStore
    private let calendar: Calendar
    private let format: Format

    public init(store: any MessageStore, calendar: Calendar = .current) {
        self.store = store
        self.calendar = calendar
        self.format = Format(calendar: calendar)
    }

    public func handle(_ parameters: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(parameters)
            return .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: false)
        } catch let error as ToolError {
            return .init(
                content: [.text(text: error.message, annotations: nil, _meta: nil)], isError: true)
        } catch {
            return .init(
                content: [
                    .text(
                        text: ToolError.storeFailure(error.localizedDescription).message,
                        annotations: nil, _meta: nil)
                ], isError: true)
        }
    }

    private func run(_ parameters: CallTool.Parameters) async throws -> String {
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

        let access = store.access()
        guard access.isUsable else { throw ToolError.notAuthorized(access) }

        switch parameters.name {
        case ToolCatalog.conversationsName:
            return try await conversations(arguments)

        case ToolCatalog.conversationName:
            return try await conversation(arguments)

        case ToolCatalog.searchName:
            return try await search(arguments)

        case ToolCatalog.attachmentsName:
            let ids = try arguments.idArray("message_ids")
            guard !ids.isEmpty else { throw ToolError.missingArgument("message_ids") }
            return format.attachments(try await store.attachments(messageIDs: ids), requested: ids)

        default:
            throw ToolError.badArgument(
                name: "name", reason: "'\(parameters.name)' is not a tool of this server")
        }
    }

    // MARK: Reads

    private func conversations(_ arguments: Arguments) async throws -> String {
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)
        let query = arguments.optionalString("query")

        let page = try await store.conversations(query: query, limit: limit, offset: offset)
        return format.conversations(page, offset: offset, query: query)
    }

    private func conversation(_ arguments: Arguments) async throws -> String {
        let id = try arguments.requiredID("conversation_id")
        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.conversation(id: id, limit: limit, offset: offset)
        guard !page.messages.isEmpty || offset > 0 else {
            throw ToolError.conversationNotFound(id: id)
        }
        return format.conversationPage(
            page, conversationID: id, offset: offset, limit: limit)
    }

    private func search(_ arguments: Arguments) async throws -> String {
        var filter = MessageFilter()
        filter.query = arguments.optionalString("query")
        filter.participant = arguments.optionalString("participant")
        filter.chatID = try arguments.optionalID("conversation_id")
        filter.from = try arguments.optionalDate("from")
        // A plain day as the upper bound would otherwise exclude that whole day, so a
        // one-day window would always come back empty.
        filter.to = try arguments.optionalDate("to", endOfDayIfDayOnly: true)
        filter.hasAttachment = arguments.optionalBool("has_attachment")
        filter.service = arguments.optionalString("service")
        filter.fromMe = arguments.optionalBool("from_me")
        filter.scanCeiling = Configuration.scanLimit

        if let from = filter.from, let to = filter.to, to < from {
            throw ToolError.endBeforeStart
        }

        let limit = try arguments.int(
            "limit", default: Configuration.searchLimit, in: Configuration.searchLimitRange)
        let offset = try arguments.int("offset", default: 0, in: Configuration.offsetRange)

        let page = try await store.search(filter, limit: limit, offset: offset)
        return format.searchResults(
            page, filter: filter, offset: offset, scanLimit: Configuration.scanLimit)
    }

    // MARK: Write

    /// The only outward-facing tool in this server, and the only one that cannot be
    /// undone. Two gates, both of which must pass:
    ///
    /// 1. `confirm=true`;
    /// 2. a length ceiling, because a runaway body is far more likely to be a mistake
    ///    than an intention.
    ///
    /// There is no recipient allow-list here: the owner chose this tool's own
    /// allow/ask/prohibit switch in Claude Desktop and their own confirmation at send
    /// time as the only guard, in place of a list this server used to enforce.
    private func send(_ arguments: Arguments) async throws -> String {
        let recipient = try arguments.requiredString("recipient")
        let text = try arguments.requiredBody("text")
        guard text.count <= Configuration.maximumSendCharacters else {
            throw ToolError.messageTooLong(
                characters: text.count, maximum: Configuration.maximumSendCharacters)
        }

        guard arguments.bool("confirm") else {
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
