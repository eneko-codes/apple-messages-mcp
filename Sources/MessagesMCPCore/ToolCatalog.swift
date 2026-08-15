import Foundation
import MCP

/// The catalogue is the authorisation surface: a tool that is not listed here cannot be
/// called, and the name it is listed under is the label on the permission switch in
/// Claude Desktop. Reads carry no verb prefix; the one write starts with `send_`, so it
/// cannot be mistaken for one of them at a glance.
public enum ToolCatalog {

    public static let statusName = "messages_status"
    public static let conversationsName = "conversations_list"
    public static let conversationName = "conversation_get"
    public static let searchName = "messages_search"
    public static let attachmentsName = "message_attachments"
    public static let sendName = "send_message"

    public static func all() -> [Tool] {
        [status, conversations, conversation, search, attachments, send]
    }

    // MARK: Schema helpers

    private static func object(properties: [String: Value], required: [String] = []) -> Value {
        var schema: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
        ]
        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }
        schema["additionalProperties"] = .bool(false)
        return .object(schema)
    }

    /// Every property here declares one scalar `type`, never a union such as
    /// `["string", "null"]`. Claude Desktop's schema sanitiser drops a property whose
    /// `type` is an array and hands the model a bare `{}` instead; an untyped array is
    /// then serialised to a string before it leaves the client and rejected on arrival.
    /// Found in the sibling contacts server. A test walks the whole catalogue to keep
    /// unions out.
    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func boolean(_ description: String) -> Value {
        .object(["type": .string("boolean"), "description": .string(description)])
    }

    private static func integer(_ description: String, minimum: Int, maximum: Int, default def: Int)
        -> Value
    {
        .object([
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(minimum), "maximum": .int(maximum), "default": .int(def),
        ])
    }

    private static func identifier(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static let limitProperty: Value = integer(
        "Maximum number of rows to return.",
        minimum: Configuration.searchLimitRange.lowerBound,
        maximum: Configuration.searchLimitRange.upperBound,
        default: Configuration.searchLimit)

    private static let offsetProperty: Value = integer(
        "Skip this many rows; use it to page.",
        minimum: Configuration.offsetRange.lowerBound,
        maximum: Configuration.offsetRange.upperBound, default: 0)

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Messages access status",
        description: """
            Reports whether this server can read the Messages database, whether the send \
            shortcut exists, and the exact path of the binary to add to Full Disk Access. \
            Reads no messages.

            Use it when another tool fails on permissions, or when setting the server up. \
            Do not use it to look for messages.
            """,
        inputSchema: object(properties: [:]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    static let conversations = Tool(
        name: conversationsName,
        title: "List conversations",
        description: """
            Lists conversations newest-activity first, with participants, whether each \
            is a group, its message count, unread count and id.

            Start here: conversation_get and the conversation_id filter of \
            messages_search both take the id this returns. An id is chat.ROWID in the \
            local database — it means nothing on another Mac and can change if Messages \
            is restored from a backup, so look it up again rather than reusing one from \
            an earlier conversation.
            """,
        inputSchema: object(properties: [
            "query": string(
                "Optional text matched against the group name, the chat identifier and "
                    + "the participants' addresses."),
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let conversation = Tool(
        name: conversationName,
        title: "Read a conversation",
        description: """
            Returns one page of a thread, NEWEST FIRST, with the sender, timestamp, \
            text and message id of each row. Page backwards through the history with \
            'offset'.

            Needs an id from conversations_list. Messages with no text — a sticker, a \
            shared location, an app payload — are shown as such rather than as blank \
            lines; use message_attachments for what is attached to them.
            """,
        inputSchema: object(
            properties: [
                "conversation_id": identifier("Id returned by conversations_list."),
                "limit": limitProperty,
                "offset": offsetProperty,
            ],
            required: ["conversation_id"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let search = Tool(
        name: searchName,
        title: "Search messages",
        description: """
            Finds messages across the whole archive, newest first. Every filter mirrors \
            a column the database already has, and they combine with AND.

            Text matching happens after each body is decoded, because modern macOS \
            stores the text in a binary blob SQL cannot look inside. That means a \
            search reads rows until it has a page or until it has scanned \
            \(Configuration.scanLimit) of them, and it always says how many it read. If \
            it stopped at the ceiling the answer is the NEWEST matches, not all of \
            them — narrow it with participant, conversation_id or a date range.
            """,
        inputSchema: object(properties: [
            "query": string("Text to find in the message body or subject."),
            "participant": string(
                "A phone number or email, as Messages addresses it. Matches the other "
                    + "party recorded on the message, which for a group chat is absent "
                    + "on your own messages — use conversation_id for a whole group "
                    + "thread."),
            "conversation_id": identifier(
                "Restrict to one conversation, using an id from conversations_list."),
            "from": string("Earliest message date, inclusive. \(dateHelp)"),
            "to": string(
                "Latest message date, exclusive — except a plain day, which covers that "
                    + "whole day. \(dateHelp)"),
            "has_attachment": boolean("True for messages with attachments, false for without."),
            "service": string("Exactly \"iMessage\", \"SMS\" or \"RCS\"."),
            "from_me": boolean("True for messages you sent, false for received."),
            "limit": limitProperty,
            "offset": offsetProperty,
        ]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true,
            openWorldHint: false)
    )

    static let attachments = Tool(
        name: attachmentsName,
        title: "List message attachments",
        description: """
            Lists what is attached to the given messages: file name, type, size, direction, \
            the path on disk and whether the file is still there — old attachments are \
            offloaded to iCloud and leave their row behind.

            Takes ids in bulk, so a whole page of search results costs one call. It lists \
            attachments and never copies or opens one.
            """,
        inputSchema: object(
            properties: [
                "message_ids": .object([
                    "type": .string("array"),
                    "items": .object(["type": .string("integer")]),
                    "description": .string(
                        "Message ids from conversation_get or messages_search."),
                ])
            ],
            required: ["message_ids"]),
        annotations: .init(
            readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)
    )

    // MARK: The one write

    static let send = Tool(
        name: sendName,
        title: "Send a message",
        description: """
            Sends an iMessage or SMS by running the configured shortcut. \
            IT CANNOT BE UNDONE — there is no recall and no undo, and the recipient may \
            read it immediately.

            Requires confirm=true. Show the recipient and the exact text to the person \
            and get their agreement before calling.

            Gated only by this tool's own permission switch in Claude Desktop — set it \
            to "ask" to approve every send, or "prohibit" to disable sending entirely. \
            There is no recipient allow-list here to fall back on.

            It writes nothing to the Messages database: this server only ever reads that \
            file, and a row inserted there would be a forged record of a message nobody \
            sent.
            """,
        inputSchema: object(
            properties: [
                "recipient": string(
                    "Phone number or email, exactly as Messages addresses it. Matching "
                        + "ignores case and phone spacing but never guesses a country code."),
                "text": string("The message body, sent exactly as given."),
                "confirm": boolean("Must be true. Without it the call is refused."),
            ],
            required: ["recipient", "text", "confirm"]),
        annotations: .init(
            readOnlyHint: false,
            // Irreversible and outward-facing. Nothing is deleted, but the client
            // should treat it with the same weight.
            destructiveHint: true, idempotentHint: false, openWorldHint: true)
    )
}
