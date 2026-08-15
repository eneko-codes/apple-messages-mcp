import Foundation
import MCP

public enum MessagesMCPServer {

    public static let name = "apple-messages-mcp"
    public static let version = "1.0.0"

    /// Returned from `initialize`. It carries what per-tool descriptions cannot state
    /// once: that reading and sending take different routes with different permissions,
    /// and that the send gate is a configured list rather than the model's restraint.
    public static let instructions = """
        Access to Messages on this Mac. Reading and sending take different routes.

        READING comes from the local Messages database, opened read-only and immutable. \
        That file is protected, so every read tool needs Full Disk Access granted by hand \
        in System Settings — there is no permission dialog for it and no Info.plist key \
        that asks. messages_status says whether it is granted and what to do if not.

        The database schema is Apple's and undocumented. It changes between macOS \
        releases, and message text lives in one of two places depending on age, so every \
        record says where its body came from.

        SENDING goes through a shortcut in the Shortcuts app instead, so send_message \
        works even when the database cannot be opened at all.

        send_message CANNOT BE UNDONE. There is no recall. It requires confirm=true. \
        There is no recipient allow-list enforced by this server — the only guards are \
        this tool's own permission switch in Claude Desktop and showing the recipient and \
        the exact text to the person before calling it.

        Workflow: conversations_list to see what exists, conversation_get for one thread, \
        messages_search across everything. Ids are row ids in the local database; they are \
        not sync identifiers and do not survive a restore onto another Mac, so look them \
        up again rather than reusing one from earlier in the conversation.

        This server can never modify or delete a message. Those are the record of what was \
        said, and no tool here rewrites them.
        """

    /// The store is a parameter so the whole server can be driven by a double. Nothing
    /// in this function opens a database by itself.
    public static func run(store: any MessageStore = SystemMessageStore()) async throws {
        let tools = MessageTools(store: store)
        let server = Server(
            name: name,
            version: version,
            instructions: instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: ToolCatalog.all())
        }
        await server.withMethodHandler(CallTool.self) { await tools.handle($0) }

        // The default StdioTransport logger is a no-op handler. Leave it that way: a
        // logger writing to stdout would interleave with the JSON-RPC stream and break
        // every response after the first log line.
        try await server.start(transport: StdioTransport())
        await server.waitUntilCompleted()
    }
}
