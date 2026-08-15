import Foundation

/// The only type that touches this Mac. Below it is the owner's real archive and the
/// Shortcuts app; above it, everything runs against a double.
///
/// Two doors, deliberately different:
///
/// - **Reading** goes straight to `~/Library/Messages/chat.db`, opened read-only and
///   immutable. Messages exposes no framework and no useful scripting dictionary, so the
///   database is the only complete source — and it costs the broadest permission on the
///   Mac, Full Disk Access.
/// - **Sending** goes through a shortcut. It could not go through the database in any
///   case: inserting a row does not deliver anything, it only forges a record of a
///   message that was never sent. Shortcuts is the supported way to hand Messages a real
///   send, and it keeps this server's own handle on the file strictly read-only.
public struct SystemMessageStore: MessageStore {

    private let databasePath: String
    private let shortcutsExecutable: String

    /// Where Messages keeps its database. Re-exported here because `ChatDatabase` is
    /// deliberately internal — the SQLite layer is not part of this module's surface, and
    /// a public default argument cannot name an internal type.
    public static var defaultDatabasePath: String { ChatDatabase.defaultPath }

    /// The path is injectable only so `messages_status` can be exercised against a
    /// fixture. Nothing in the running server passes anything but the default.
    public init(
        databasePath: String = SystemMessageStore.defaultDatabasePath,
        shortcutsExecutable: String = "/usr/bin/shortcuts"
    ) {
        self.databasePath = databasePath
        self.shortcutsExecutable = shortcutsExecutable
    }

    public func access() -> DatabaseAccess {
        ChatDatabase.probeAccess(path: databasePath)
    }

    /// Opened per call rather than held.
    ///
    /// A long-lived handle on a file another application is actively writing buys nothing
    /// here — with `immutable=1` there is no page cache worth keeping warm and no
    /// connection state to reuse — and it would keep a descriptor on the owner's archive
    /// open for the life of the process.
    private func open() throws -> ChatDatabase {
        let database = try ChatDatabase(path: databasePath)
        try database.verifySchema()
        return database
    }

    public func status(sendShortcut: String) async throws -> StoreStatus {
        let access = access()
        guard access.isUsable else {
            return StoreStatus(
                access: access, databasePath: databasePath, openedReadOnly: true,
                sendShortcutInstalled: shortcutIsInstalled(sendShortcut))
        }

        let database = try open()
        return StoreStatus(
            access: .granted,
            databasePath: databasePath,
            openedReadOnly: true,
            dateUnit: try database.dateUnit(),
            conversationCount: try database.count(of: "chat"),
            messageCount: try database.count(of: "message"),
            attachmentCount: try database.count(of: "attachment"),
            newestMessageDate: try database.newestMessageDate(),
            sendShortcutInstalled: shortcutIsInstalled(sendShortcut))
    }

    public func conversations(query: String?, limit: Int, offset: Int) async throws
        -> ConversationPage
    {
        let all = try open().conversations()
        var matches = all
        if let needle = query, !needle.isEmpty {
            matches = all.filter { conversation in
                conversation.label.localizedCaseInsensitiveContains(needle)
                    || conversation.chatIdentifier.localizedCaseInsensitiveContains(needle)
                    || conversation.participants.contains {
                        $0.localizedCaseInsensitiveContains(needle)
                    }
            }
        }
        // Newest first, and a chat that has never held a message sorts last rather than
        // in 1970.
        matches.sort {
            ($0.lastMessageDate ?? .distantPast) > ($1.lastMessageDate ?? .distantPast)
        }
        let page = matches.dropFirst(offset).prefix(limit)
        return ConversationPage(conversations: Array(page), total: matches.count)
    }

    public func conversation(id: Int64, limit: Int, offset: Int) async throws -> MessagePage {
        let database = try open()
        guard try database.conversationExists(id: id) else {
            throw ToolError.conversationNotFound(id: id)
        }
        let total = try database.messageCount(inConversation: id)
        let rows = try database.messages(inConversation: id, limit: limit, offset: offset)
        let label = try database.chatLabels(ids: [id])[id]
        return MessagePage(
            messages: rows.map { $0.labelled(label) },
            scanned: rows.count, hitScanCeiling: false, total: total)
    }

    public func search(_ filter: MessageFilter, limit: Int, offset: Int) async throws
        -> MessagePage
    {
        let database = try open()
        if let chatID = filter.chatID, try !database.conversationExists(id: chatID) {
            throw ToolError.conversationNotFound(id: chatID)
        }

        let handleIDs = try filter.participant.map { try database.handleIDs(matching: $0) }
        let wanted = limit + offset
        var kept: [MessageRecord] = []

        let scan = try database.scanMessages(
            chatID: filter.chatID, handleIDs: handleIDs, service: filter.service,
            hasAttachment: filter.hasAttachment, fromMe: filter.fromMe,
            ceiling: filter.scanCeiling
        ) { record in
            if filter.accepts(record) { kept.append(record) }
            return kept.count < wanted
        }

        let page = Array(kept.dropFirst(offset))
        let labels = try database.chatLabels(ids: page.compactMap(\.chatID))
        return MessagePage(
            messages: page.map { $0.labelled($0.chatID.flatMap { labels[$0] }) },
            scanned: scan.scanned, hitScanCeiling: scan.hitCeiling, total: nil)
    }

    public func attachments(messageIDs: [Int64]) async throws -> [AttachmentRecord] {
        try open().attachments(messageIDs: messageIDs)
    }

    // MARK: Sending

    /// Runs the configured shortcut with `{"recipient": …, "text": …}` on its input.
    ///
    /// THE ONLY OUTWARD-FACING CODE IN THIS REPOSITORY. Everything that decides *whether*
    /// to call it — the allow-list, `confirm=true`, the length guard — lives above the
    /// store seam in `MessagesTools`, where the tests can prove it without a store that
    /// can send.
    public func send(recipient: String, text: String, shortcutName: String) async throws
        -> SendReceipt
    {
        guard shortcutIsInstalled(shortcutName) == true else {
            throw ToolError.sendShortcutMissing(name: shortcutName)
        }

        // Passed as a file rather than on the command line: an argv entry is visible to
        // every process on the machine through `ps`, and a message body is the owner's
        // private text.
        let payload: [String: String] = ["recipient": recipient, "text": text]
        let inputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("apple-messages-mcp-\(UUID().uuidString).json")
        do {
            let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            try data.write(to: inputURL, options: [.atomic, .completeFileProtection])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: inputURL.path)
        } catch {
            throw ToolError.sendFailed(
                shortcut: shortcutName, detail: "could not stage the input: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: inputURL) }

        let result = try run(
            arguments: ["run", shortcutName, "--input-path", inputURL.path], timeout: 30)
        guard result.status == 0 else {
            let detail = result.standardError.isEmpty
                ? "exit status \(result.status)" : result.standardError
            throw ToolError.sendFailed(shortcut: shortcutName, detail: detail)
        }

        let output = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        return SendReceipt(
            recipient: recipient, text: text, shortcutName: shortcutName,
            output: output.isEmpty ? nil : output)
    }

    /// `nil` when the question could not be answered — no `shortcuts` binary, or the
    /// listing failed. That is different from "the shortcut is missing", and status has
    /// to be able to say which.
    private func shortcutIsInstalled(_ name: String) -> Bool? {
        guard FileManager.default.isExecutableFile(atPath: shortcutsExecutable) else { return nil }
        guard let result = try? run(arguments: ["list"], timeout: 10), result.status == 0 else {
            return nil
        }
        return result.standardOutput
            .split(separator: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == name }
    }

    private struct ProcessResult {
        let status: Int32
        let standardOutput: String
        let standardError: String
    }

    /// A shortcut can block forever on a dialog — a permission prompt, or an action
    /// waiting for input — and an MCP server that never answers looks to the client
    /// exactly like one that crashed. The deadline turns that into a message.
    private func run(arguments: [String], timeout: TimeInterval) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shortcutsExecutable)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw ToolError.sendFailed(
                shortcut: arguments.count > 1 ? arguments[1] : "shortcuts",
                detail: error.localizedDescription)
        }

        // Read before waiting: a pipe buffer that fills would deadlock a process that is
        // still writing while this side waits for it to exit.
        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            usleep(50_000)
        }
        if process.isRunning {
            process.terminate()
            throw ToolError.sendFailed(
                shortcut: arguments.count > 1 ? arguments[1] : "shortcuts",
                detail:
                    "it was still running after \(Int(timeout))s and was stopped. Shortcuts may be "
                    + "waiting on a dialog; check Messages before retrying.")
        }

        return ProcessResult(
            status: process.terminationStatus,
            standardOutput: String(decoding: outputData, as: UTF8.self),
            standardError: String(decoding: errorData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
