import Foundation

@testable import MessagesMCPCore

/// An in-memory `MessageStore`.
///
/// Every test in this suite runs against this double. Nothing here opens `chat.db`, and
/// nothing here can send: `sent` records what a send *would* have been, and the suite
/// asserts against that record rather than against a message anyone received.
final class FakeMessageStore: MessageStore, @unchecked Sendable {

    var accessValue: DatabaseAccess = .granted
    var conversationsValue: [Conversation] = []
    var messagesValue: [MessageRecord] = []
    var attachmentsValue: [AttachmentRecord] = []
    var sendShortcutInstalled = true

    /// Set to make the next call fail, so the error path is reachable.
    var failure: (any Error)?

    /// How many rows a search reads before it stops, in place of the filter's own ceiling,
    /// so a test reaches the ceiling with a handful of invented rows.
    var scanCeiling: Int?

    /// What the shortcut printed, for the receipt.
    var shortcutOutput: String?

    /// Makes every call take this long, so the deadline above the store is reachable.
    var delay: Duration?

    private func pause() async {
        if let delay { try? await Task.sleep(for: delay) }
    }

    /// Every send this store was asked to perform. Nothing leaves the process.
    private(set) var sent: [(recipient: String, text: String, shortcut: String)] = []
    private(set) var lastFilter: MessageFilter?

    func access() -> DatabaseAccess { accessValue }

    func status(sendShortcut: String) async throws -> StoreStatus {
        if let failure { throw failure }
        return StoreStatus(
            access: accessValue,
            databasePath: "/invented/chat.db",
            openedReadOnly: true,
            dateUnit: .nanoseconds,
            conversationCount: conversationsValue.count,
            messageCount: messagesValue.count,
            attachmentCount: attachmentsValue.count,
            newestMessageDate: messagesValue.compactMap(\.date).max(),
            sendShortcutInstalled: sendShortcutInstalled)
    }

    func conversations(query: String?, limit: Int, offset: Int) async throws -> ConversationPage {
        if let failure { throw failure }
        var matched = conversationsValue
        if let query = query?.lowercased(), !query.isEmpty {
            matched = matched.filter {
                ($0.displayName ?? "").lowercased().contains(query)
                    || $0.chatIdentifier.lowercased().contains(query)
                    || $0.participants.contains { $0.lowercased().contains(query) }
            }
        }
        let page = matched.dropFirst(offset).prefix(limit)
        return ConversationPage(conversations: Array(page), total: matched.count)
    }

    func conversation(id: Int64, limit: Int, offset: Int) async throws -> MessagePage {
        if let failure { throw failure }
        let matched = messagesValue.filter { $0.chatID == id }
        guard !matched.isEmpty || conversationsValue.contains(where: { $0.id == id }) else {
            throw ToolError.conversationNotFound(id: id)
        }
        let page = matched.dropFirst(offset).prefix(limit)
        return MessagePage(
            messages: Array(page), scanned: matched.count, total: matched.count)
    }

    /// The same walk the real store does. The filters SQL decides (conversation,
    /// participant, attachment, direction and the date range) choose the rows that are
    /// read, in the order given, newest first; the text query is applied to each row read.
    /// The walk stops one match past the page, to learn whether another page exists, or at
    /// the ceiling on rows read.
    func search(_ filter: MessageFilter, limit: Int, offset: Int) async throws -> MessagePage {
        await pause()
        if let failure { throw failure }
        lastFilter = filter

        var dates = MessageFilter()
        dates.from = filter.from
        dates.to = filter.to
        let readable = messagesValue.filter { record in
            if let chatID = filter.chatID, record.chatID != chatID { return false }
            if let participant = filter.participant?.lowercased(),
                !(record.handle ?? "").lowercased().contains(participant)
            { return false }
            if let hasAttachment = filter.hasAttachment, record.hasAttachments != hasAttachment {
                return false
            }
            if let fromMe = filter.fromMe, record.isFromMe != fromMe { return false }
            return dates.accepts(record)
        }

        let ceiling = scanCeiling ?? filter.scanCeiling
        let wanted = offset + limit + 1
        var scanned = 0
        var matched = 0
        var page: [MessageRecord] = []
        var oldest: Date?
        for record in readable.prefix(ceiling) {
            scanned += 1
            oldest = record.date ?? oldest
            guard filter.accepts(record) else { continue }
            matched += 1
            if matched > offset, page.count < limit { page.append(record) }
            if matched == wanted { break }
        }
        let hasMore = matched == wanted
        return MessagePage(
            messages: page, scanned: scanned, hitScanCeiling: !hasMore && scanned == ceiling,
            total: hasMore ? nil : matched, hasMore: hasMore, oldestScanned: oldest)
    }

    func attachments(messageIDs: [Int64]) async throws -> [AttachmentRecord] {
        if let failure { throw failure }
        return attachmentsValue.filter { messageIDs.contains($0.messageID) }
    }

    func send(recipient: String, text: String, shortcutName: String) async throws -> SendReceipt {
        await pause()
        if let failure { throw failure }
        sent.append((recipient: recipient, text: text, shortcut: shortcutName))
        return SendReceipt(
            recipient: recipient, text: text, shortcutName: shortcutName, output: shortcutOutput)
    }
}

// MARK: - Fixtures

enum Fixtures {

    static let now = date(2026, 8, 9, 12, 0)

    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Madrid")!
        return calendar
    }

    static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0)
        -> Date
    {
        calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// Invented throughout. No handle, name or body here comes from a real conversation.
    static func conversation(
        id: Int64, name: String?, identifier: String, isGroup: Bool = false,
        participants: [String] = []
    ) -> Conversation {
        Conversation(
            id: id, guid: "iMessage;-;\(identifier)", chatIdentifier: identifier,
            displayName: name, serviceName: "iMessage", isGroup: isGroup,
            participants: participants.isEmpty ? [identifier] : participants,
            lastMessageDate: now, messageCount: 2, unreadCount: 0)
    }

    static func message(
        id: Int64, chatID: Int64, text: String?, fromMe: Bool = false,
        handle: String = "+34600000001", at date: Date = now, hasAttachments: Bool = false,
        bodySource: BodySource = .textColumn
    ) -> MessageRecord {
        MessageRecord(
            id: id, guid: "GUID-\(id)", date: date, isFromMe: fromMe, isRead: true,
            service: "iMessage", handle: handle, text: text, bodySource: bodySource,
            hasAttachments: hasAttachments, chatID: chatID, chatLabel: "Fixture chat")
    }
}
