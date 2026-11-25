import Foundation

public enum ToolError: Error, Equatable {
    case notAuthorized(DatabaseAccess)
    case missingArgument(String)
    case badArgument(name: String, reason: String)
    case badDate(argument: String, value: String)
    case endBeforeStart
    case conversationNotFound(id: Int64)
    case noMessageIDs
    case confirmationRequired(action: String)
    case messageTooLong(characters: Int, maximum: Int)
    case sendShortcutMissing(name: String)
    case sendFailed(shortcut: String, detail: String)
    case schemaUnsupported(table: String, missing: [String])
    case storeFailure(String)
    case unknownTool(String)
    case timedOut(seconds: Int, sending: Bool)

    /// Another program's own words (SQLite's, the `shortcuts` tool's), cut to what an
    /// error may repeat, with the length of the whole so the cut is not silent.
    static func detail(_ text: String) -> String {
        let width = Configuration.errorDetailWidth
        guard text.count > width else { return text }
        return String(text.prefix(width)) + "… (the first \(width) of \(text.count) characters)"
    }

    public var message: String {
        switch self {
        case .notAuthorized(let access):
            return Self.accessMessage(access)

        case .missingArgument(let name):
            return "Missing required argument '\(name)'."

        case .badArgument(let name, let reason):
            return "Argument '\(name)' is not valid: \(reason)"

        case .badDate(let argument, let value):
            return """
                Argument '\(argument)' is not a date this server accepts, or names a day \
                or a time that does not exist: '\(ToolStandard.echo(value))'

                Use one of:
                \(DateParsing.acceptedForms)

                from_date and to_date are both inclusive: to_date covers the whole day, \
                minute or second it names.
                """

        case .endBeforeStart:
            return """
                'to_date' ends before 'from_date' begins. Give a range that starts before \
                it ends, or leave one of them out: from_date alone runs to the newest \
                message, to_date alone from the oldest. Each takes one of:
                \(DateParsing.acceptedForms)
                """

        case .conversationNotFound(let id):
            return """
                No conversation exists with id \(id).

                Conversation ids are chat.ROWID in the local database — local to this Mac,
                and reassigned if Messages is restored from a backup. Call
                conversations_list again rather than reusing an id from an earlier
                conversation.
                """

        case .noMessageIDs:
            return """
                No message ids were given.

                Pass the ids from conversation_get or messages_search, as an array:
                message_ids: [1234, 1235].
                """

        case .confirmationRequired(let action):
            return """
                \(action) requires confirm=true.

                A sent message CANNOT BE RECALLED. Show the recipient and the exact text to
                the person, get their agreement, and only then call again with confirm=true.
                """

        case .messageTooLong(let characters, let maximum):
            return """
                The message is \(characters) characters; the maximum is \(maximum).

                This is a guard, not a protocol limit. Something this long arriving on
                someone's phone is more likely to be a runaway than a message. Shorten it,
                or send it in parts that were each meant to be sent.
                """

        case .sendShortcutMissing(let name):
            return """
                No shortcut named '\(name)' is installed.

                The send path runs a shortcut rather than writing to the database, because
                the database is Messages' own record and this server never writes to it.

                Create it in Shortcuts.app:
                  1. New Shortcut, named exactly '\(name)'.
                  2. "Receive Text input from Shortcuts", with nothing set for no input.
                  3. Add "Send Message", body = Shortcut Input, and pick the recipient.
                  4. Check it appears in:  shortcuts list

                A shortcut that hard-codes its recipient is the safer shape: the recipient
                then never depends on what this server passes in.
                """

        case .sendFailed(let shortcut, let detail):
            return """
                Running the shortcut '\(shortcut)' failed: \(Self.detail(detail))

                The message may or may not have been sent — a shortcut can fail after its
                Send Message action. Check Messages before trying again, so nobody receives
                the same thing twice.

                If this is the first run, macOS may be waiting on an automation consent
                dialog behind another window:
                  System Settings → Privacy & Security → Automation → apple-messages-mcp
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad → Automatización)
                """

        case .schemaUnsupported(let table, let missing):
            return """
                The Messages database is not the shape this server understands: table
                '\(table)' has no column \(missing.map { "'\($0)'" }.joined(separator: ", ")).

                This schema is private and undocumented, and Apple changes it between
                releases. That is a bug in this server, not something to configure — the
                columns it depends on are pinned in its test suite, and one of them has
                moved.
                """

        case .storeFailure(let detail):
            return "The Messages database returned an error: \(Self.detail(detail))"

        case .unknownTool(let name):
            return "'\(ToolStandard.echo(name))' is not a tool of this server."

        case .timedOut(let seconds, let sending):
            let consequence =
                sending
                ? """
                    THE MESSAGE MAY OR MAY NOT HAVE BEEN SENT. The shortcut was still running \
                    when this call gave up on it. Check the conversation in Messages before \
                    trying again, so nobody receives the same thing twice.
                    """
                : """
                    This tool only reads, so nothing was changed. Ask for less: a lower \
                    limit, or a search narrowed by conversation_id, participant, from_date or \
                    to_date. messages_status says whether the database still answers at all.
                    """
            return """
                The call did not finish within \(seconds) seconds and was abandoned.

                \(consequence)
                """
        }
    }

    static func accessMessage(_ access: DatabaseAccess) -> String {
        switch access {
        case .granted:
            return "Full Disk Access granted; the Messages database is readable."

        case .denied:
            return """
                No access to the Messages database: macOS refused to open it.

                ~/Library/Messages/chat.db is behind FULL DISK ACCESS. Unlike Calendars or
                Contacts there is no consent dialog for it and no Info.plist key that can
                ask — it is granted by hand, once, and it cannot be requested by any process:

                  System Settings → Privacy & Security → Full Disk Access →
                  "+" → add the server binary → enable "apple-messages-mcp"
                  (Spanish UI: Ajustes del Sistema → Privacidad y seguridad →
                   Acceso total al disco)

                The binary to add is the one Claude Desktop runs, under
                  ~/Library/Application Support/Claude/Claude Extensions/
                Call messages_status to print the exact path this process was launched from.

                Then quit and reopen Claude Desktop: the grant is resolved when the process
                starts, so a server already running will keep failing until it is restarted.
                """

        case .missing(let path):
            return """
                No Messages database at \(path).

                Either Messages has never been used on this Mac, or the file has been moved.
                Nothing here can create it — open Messages, sign in, and let it write its
                own store.

                Note that a missing file and a forbidden one look alike from outside: if
                Full Disk Access is not granted, the parent directory cannot even be listed.
                """

        case .failed(let detail):
            return """
                Could not open the Messages database: \(Self.detail(detail))

                Messages holds it open with a write-ahead log, which this server reads but
                never writes — it opens the file read-only, and a read-only reader in WAL
                mode does not block the app. An error here means something else: a corrupt
                file, a database written by a newer SQLite than this binary links against, or
                a -shm index file this process is not allowed to map.
                """
        }
    }
}
