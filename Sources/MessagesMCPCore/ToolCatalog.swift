import Foundation

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

    /// The tools that read the database, and so need Full Disk Access.
    static let readNames: Set = [conversationsName, conversationName, searchName, attachmentsName]

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

    /// A `default` is advertised only where omitting the argument really means that value.
    /// An id has none: leaving one out means "no filter", or is refused.
    private static func integer(
        _ description: String, range: ClosedRange<Int>, default def: Int? = nil
    ) -> Value {
        var schema: [String: Value] = [
            "type": .string("integer"), "description": .string(description),
            "minimum": .int(range.lowerBound), "maximum": .int(range.upperBound),
        ]
        if let def { schema["default"] = .int(def) }
        return .object(schema)
    }

    private static func identifier(_ description: String) -> Value {
        integer(description, range: Configuration.identifierRange)
    }

    private static let dateHelp = """
        Accepts 2026-08-12 (whole day), 2026-08-12T09:00 (local time), or \
        2026-08-12T09:00:00+02:00 (explicit offset).
        """

    private static func limit(_ things: String, range: ClosedRange<Int>, default def: Int) -> Value {
        integer("Maximum number of \(things) in one page.", range: range, default: def)
    }

    private static let offset = integer(
        """
        Number of rows to skip. A result that does not hold every row says, in its first \
        lines, the offset to pass for the next page.
        """, range: Configuration.offsetRange, default: 0)

    private static let readOnly = Tool.Annotations(
        readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false)

    /// Said by both tools whose rows carry a message's text.
    private static let clippedText = """
        A message's text is shown on one line of at most \(Configuration.textWidth) \
        characters; when a longer one was clipped the first lines of the result say so, and \
        no tool of this server reads one message in full
        """

    // MARK: Reads

    static let status = Tool(
        name: statusName,
        title: "Messages access status",
        description: """
            Reports whether this server can read the Messages database, whether the send \
            shortcut exists, the limits the other tools work to, and the exact path of the \
            binary to add to Full Disk Access. Reads no messages.

            Use it when another tool fails on permissions, or when setting the server up. \
            Do not use it to look for messages.
            """,
        inputSchema: object(properties: [:]),
        annotations: readOnly)

    static let conversations = Tool(
        name: conversationsName,
        title: "List conversations",
        description: """
            Lists conversations, \(Configuration.defaultConversationLimit) to a page, the \
            one with the newest message first, each with its name and participants, whether \
            it is a group, its message count, unread count, service and id. When more exist than \
            the page holds, the first lines of the result say how many there are and the \
            offset of the next page: pass limit (up to \
            \(Configuration.conversationLimitRange.upperBound)) and offset. query keeps \
            only the conversations whose name, identifier or participants contain a text.

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
            "limit": limit(
                "conversations", range: Configuration.conversationLimitRange,
                default: Configuration.defaultConversationLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let conversation = Tool(
        name: conversationName,
        title: "Read a conversation",
        description: """
            Returns the \(Configuration.defaultMessageLimit) newest messages of one \
            conversation, NEWEST FIRST, each with its timestamp, sender, text and message \
            id. When the thread holds more, the first lines of the result say how many \
            there are and the offset of the next page: pass limit (up to \
            \(Configuration.messageLimitRange.upperBound)) and offset to go further back. \
            \(clippedText).

            Needs an id from conversations_list. Messages with no text — a sticker, a \
            shared location, an app payload — are shown as such rather than as blank \
            lines; use message_attachments for what is attached to them.
            """,
        inputSchema: object(
            properties: [
                "conversation_id": identifier("Id returned by conversations_list."),
                "limit": limit(
                    "messages", range: Configuration.messageLimitRange,
                    default: Configuration.defaultMessageLimit),
                "offset": offset,
            ],
            required: ["conversation_id"]),
        annotations: readOnly)

    static let search = Tool(
        name: searchName,
        title: "Search messages",
        description: """
            Finds messages across every conversation, newest first, \
            \(Configuration.defaultMessageLimit) to a page, each with its timestamp, \
            sender, conversation, text and message id. When more match, the first lines of \
            the result give the offset of the next page: pass limit (up to \
            \(Configuration.messageLimitRange.upperBound)) and offset. The filters combine \
            with AND: query, participant, conversation_id, from_date and to_date (both \
            inclusive), has_attachment, service and from_me. \(clippedText).

            A search reads messages newest first until it has the page, and stops after \
            \(Configuration.scanLimit) of them: text is matched after each body is decoded, \
            because modern macOS stores it in a binary blob SQL cannot look inside. When it \
            stops there, the first lines say so and give the to_date that goes on from the \
            oldest message it read; messages older than that were not looked at. \
            conversation_id, participant, from_date, to_date, has_attachment, service and \
            from_me narrow what is read. query does not.
            """,
        inputSchema: object(properties: [
            "query": string("Text to find in the message body or subject, ignoring case."),
            "participant": string(
                "A phone number or email, as Messages addresses it. Matches the other "
                    + "party recorded on the message, which for a group chat is absent "
                    + "on your own messages — use conversation_id for a whole group "
                    + "thread."),
            "conversation_id": identifier(
                "Restrict to one conversation, using an id from conversations_list."),
            "from_date": string(
                "Earliest message date, inclusive. Alone, it runs to the newest message. \(dateHelp)"),
            "to_date": string(
                "Latest message date, inclusive: it covers the whole day, minute or second "
                    + "it names. Alone, it runs from the oldest message. \(dateHelp)"),
            "has_attachment": boolean("True for messages with attachments, false for without."),
            "service": string(
                "The service a message went through, as Messages records it and ignoring "
                    + "case: \"iMessage\", \"SMS\" or \"RCS\". A value Messages never "
                    + "recorded matches nothing."),
            "from_me": boolean("True for messages you sent, false for received."),
            "limit": limit(
                "messages", range: Configuration.messageLimitRange,
                default: Configuration.defaultMessageLimit),
            "offset": offset,
        ]),
        annotations: readOnly)

    static let attachments = Tool(
        name: attachmentsName,
        title: "List message attachments",
        description: """
            Lists what is attached to the given messages, \
            \(Configuration.defaultAttachmentLimit) attachments to a page in message id \
            order: file name, type, size, direction, creation date, the path on disk and \
            whether the file is still there — old attachments are offloaded to iCloud and \
            leave their row behind. When the messages hold more attachments than the page, \
            the first lines of the result say how many there are and the offset of the next \
            page: pass limit (up to \(Configuration.attachmentLimitRange.upperBound)) and \
            offset.

            Takes up to \(Configuration.maximumMessageIDs) message ids in one call, so a \
            whole page of search results costs one call; a longer list is refused, so split \
            it. It lists attachments and never copies or opens one.
            """,
        inputSchema: object(
            properties: [
                "message_ids": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("integer"),
                        "minimum": .int(Configuration.identifierRange.lowerBound),
                        "maximum": .int(Configuration.identifierRange.upperBound),
                    ]),
                    "minItems": .int(1),
                    "maxItems": .int(Configuration.maximumMessageIDs),
                    "description": .string(
                        "Message ids from conversation_get or messages_search, at most "
                            + "\(Configuration.maximumMessageIDs) in one call."),
                ]),
                "limit": limit(
                    "attachments", range: Configuration.attachmentLimitRange,
                    default: Configuration.defaultAttachmentLimit),
                "offset": offset,
            ],
            required: ["message_ids"]),
        annotations: readOnly)

    // MARK: The one write

    static let send = Tool(
        name: sendName,
        title: "Send a message",
        description: """
            Sends an iMessage or SMS by running the configured shortcut. \
            IT CANNOT BE UNDONE — there is no recall and no undo, and the recipient may \
            read it immediately. Returns a receipt: the recipient, the text sent and the \
            first \(Configuration.shortcutOutputWidth) characters of what the shortcut \
            printed, the rest of which cannot be read afterwards.

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
                    "Phone number or email, exactly as Messages addresses it, at most "
                        + "\(Configuration.maximumRecipientCharacters) characters."),
                "text": string(
                    "The message body, sent exactly as given. At most "
                        + "\(Configuration.maximumSendCharacters) characters; a longer one is refused."),
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
