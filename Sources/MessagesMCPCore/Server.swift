import Foundation

public enum MessagesMCPServer {

    public static let name = "apple-messages-mcp"
    public static let version = "2.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that lists come in pages and what a result says when it leaves something out,
    /// that reading and sending take different routes with different permissions, and that
    /// the send gate is the client's switch rather than the model's restraint.
    public static let instructions = """
        Access to Messages on this Mac. Reading and sending take different routes.

        Workflow: conversations_list to see what exists, conversation_get for one thread, \
        messages_search across everything, message_attachments for what is attached to the \
        messages those return. Ids are row ids in the local database; they are not sync \
        identifiers and do not survive a restore onto another Mac, so look them up again \
        rather than reusing one from earlier in the conversation.

        LISTS COME IN PAGES. Those four tools return one page of rows, newest first for \
        conversations and messages. When rows exist that a result does not hold, its first \
        lines say how many there are and the offset of the next page: pass limit and \
        offset. A limit or an offset outside its range is moved to the nearest allowed \
        value, and the first lines say which one was used; an id outside its range is \
        refused. A message's text is shown on one line of at most \
        \(Configuration.textWidth) characters. When a longer one was clipped the first \
        lines say so, and no tool of this server reads one message in full.

        A SEARCH CAN STOP EARLY. messages_search reads messages newest first and stops \
        after \(Configuration.scanLimit) of them. When it stops there, the first lines say \
        so and give the to_date that goes on from the oldest message it read; older \
        messages were not looked at. from_date and to_date are both inclusive: to_date \
        covers the whole day, minute or second it names.

        READING comes from the local Messages database, opened read-only and read through \
        its write-ahead log, so the newest messages are included. That file is protected, \
        so every read tool needs Full Disk Access granted by hand in System Settings — \
        there is no permission dialog for it and no Info.plist key that asks. \
        messages_status says whether it is granted and what to do if not.

        The database schema is Apple's and undocumented. It changes between macOS \
        releases, and message text lives in one of two places depending on age; a message \
        with no text in either is shown as such, never as a blank line.

        SENDING goes through a shortcut in the Shortcuts app instead, so send_message \
        works even when the database cannot be opened at all.

        send_message CANNOT BE UNDONE. There is no recall. It requires confirm=true. \
        There is no recipient allow-list enforced by this server — the only guards are \
        this tool's own permission switch in Claude Desktop and showing the recipient and \
        the exact text to the person before calling it.

        EVERY CALL IS BOUNDED. A call that has not finished after \
        \(MessageTools.defaultTimeout.components.seconds) seconds is abandoned and answered \
        with an error saying so. For send_message that error means the message may or may \
        not have been sent: check Messages before trying again.

        This server can never modify or delete a message. Those are the record of what was \
        said, and no tool here rewrites them.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function opens a database by itself.
    public static func run(store: any MessageStore = SystemMessageStore()) async {
        Diagnostics.started(version: version)
        await serveStandardStreams(handler: handler(tools: MessageTools(store: store)))
    }

    public static func handler(tools: MessageTools) -> MCPHandler {
        MCPHandler(
            name: name, version: version, instructions: instructions,
            catalog: ToolCatalog.all(), tools: tools)
    }
}
