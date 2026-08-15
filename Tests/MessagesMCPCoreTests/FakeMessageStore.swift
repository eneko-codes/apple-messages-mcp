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
        let page = matched.dropFirst(offset).prefix(limit)
        return MessagePage(
            messages: Array(page), scanned: matched.count, total: matched.count)
    }

    func search(_ filter: MessageFilter, limit: Int, offset: Int) async throws -> MessagePage {
        if let failure { throw failure }
        lastFilter = filter

        var matched = messagesValue
        if let query = filter.query?.lowercased(), !query.isEmpty {
            matched = matched.filter { ($0.text ?? "").lowercased().contains(query) }
        }
        if let participant = filter.participant?.lowercased(), !participant.isEmpty {
            matched = matched.filter { ($0.handle ?? "").lowercased().contains(participant) }
        }
        if let from = filter.from { matched = matched.filter { ($0.date ?? .distantPast) >= from } }
        if let to = filter.to { matched = matched.filter { ($0.date ?? .distantFuture) <= to } }
        if let hasAttachment = filter.hasAttachment {
            matched = matched.filter { $0.hasAttachments == hasAttachment }
        }

        let page = matched.dropFirst(offset).prefix(limit)
        return MessagePage(messages: Array(page), scanned: matched.count)
    }

    func attachments(messageIDs: [Int64]) async throws -> [AttachmentRecord] {
        if let failure { throw failure }
        return attachmentsValue.filter { messageIDs.contains($0.messageID) }
    }

    func send(recipient: String, text: String, shortcutName: String) async throws -> SendReceipt {
        if let failure { throw failure }
        sent.append((recipient: recipient, text: text, shortcut: shortcutName))
        return SendReceipt(
            recipient: recipient, text: text, shortcutName: shortcutName, output: nil)
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
