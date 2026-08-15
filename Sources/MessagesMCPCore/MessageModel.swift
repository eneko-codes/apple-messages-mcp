import Foundation

/// Whether the Messages database can be opened at all.
///
/// `~/Library/Messages/chat.db` sits behind Full Disk Access, which — unlike Calendars,
/// Contacts or Automation — has no usage-description key and no API to request it. A
/// process can only try, fail, and explain. That is why this is a plain enum rather than
/// an authorisation status with a `request` counterpart.
public enum DatabaseAccess: Sendable, Equatable {
    case granted
    /// `open(2)` refused with EPERM or EACCES. On the real path that means Full Disk
    /// Access has not been granted to this binary.
    case denied
    case missing(path: String)
    case failed(String)

    public var isUsable: Bool { self == .granted }
}

/// Where a message's text came from.
///
/// Worth carrying across the seam: a body recovered from `attributedBody` went through
/// the reader in `AttributedBody`, and if that reader ever breaks on a future archive
/// layout this field is what makes the breakage visible instead of silent.
public enum BodySource: String, Sendable, Equatable {
    case textColumn = "text"
    case attributedBody = "attributedBody"
    /// Rich-payload messages — a shared location, a sticker, an Apple Cash request —
    /// carry no text in either place.
    case none = "none"
}

public struct Conversation: Sendable, Equatable {
    /// `chat.ROWID`. Local to this database: it is not a sync identifier and does not
    /// survive a restore onto another Mac.
    public let id: Int64
    public let guid: String
    /// The address the chat is keyed by — a phone number, an email, or a group's
    /// `chat…` identifier.
    public let chatIdentifier: String
    public let displayName: String?
    public let serviceName: String?
    public let isGroup: Bool
    public let participants: [String]
    public let lastMessageDate: Date?
    public let messageCount: Int
    public let unreadCount: Int

    public init(
        id: Int64, guid: String, chatIdentifier: String, displayName: String?,
        serviceName: String?, isGroup: Bool, participants: [String], lastMessageDate: Date?,
        messageCount: Int, unreadCount: Int
    ) {
        self.id = id
        self.guid = guid
        self.chatIdentifier = chatIdentifier
        self.displayName = displayName
        self.serviceName = serviceName
        self.isGroup = isGroup
        self.participants = participants
        self.lastMessageDate = lastMessageDate
        self.messageCount = messageCount
        self.unreadCount = unreadCount
    }

    /// What a human would call this thread: its name if it has one, otherwise whoever
    /// is in it.
    public var label: String {
        if let displayName, !displayName.isEmpty { return displayName }
        if participants.isEmpty { return chatIdentifier }
        return participants.joined(separator: ", ")
    }
}

public struct ConversationPage: Sendable, Equatable {
    public let conversations: [Conversation]
    public let total: Int

    public init(conversations: [Conversation], total: Int) {
        self.conversations = conversations
        self.total = total
    }
}

public struct MessageRecord: Sendable, Equatable {
    /// `message.ROWID`, the id every other tool here takes.
    public let id: Int64
    public let guid: String
    public let date: Date?
    public let dateRead: Date?
    public let dateDelivered: Date?
    public let dateEdited: Date?
    public let isFromMe: Bool
    public let isRead: Bool
    /// `iMessage`, `SMS`, or `RCS` on a recent macOS.
    public let service: String?
    /// The other party's address. Zero for an outgoing message in a group chat, where
    /// the schema records no handle at all.
    public let handle: String?
    public let subject: String?
    public let text: String?
    public let bodySource: BodySource
    public let hasAttachments: Bool
    /// Non-nil unless the row is orphaned — a message whose chat was deleted still sits
    /// in the table until Messages vacuums it.
    public let chatID: Int64?
    public let chatLabel: String?
    /// Non-zero on a tapback, an edit marker or a retraction, which the schema stores as
    /// ordinary messages pointing at another one. Passed through raw: deciding which of
    /// them is worth showing is a judgment, and judgment belongs in Claude.
    public let associatedMessageType: Int

    public init(
        id: Int64, guid: String, date: Date?, dateRead: Date? = nil, dateDelivered: Date? = nil,
        dateEdited: Date? = nil, isFromMe: Bool, isRead: Bool = false, service: String? = nil,
        handle: String? = nil, subject: String? = nil, text: String?,
        bodySource: BodySource = .textColumn, hasAttachments: Bool = false, chatID: Int64? = nil,
        chatLabel: String? = nil, associatedMessageType: Int = 0
    ) {
        self.id = id
        self.guid = guid
        self.date = date
        self.dateRead = dateRead
        self.dateDelivered = dateDelivered
        self.dateEdited = dateEdited
        self.isFromMe = isFromMe
        self.isRead = isRead
        self.service = service
        self.handle = handle
        self.subject = subject
        self.text = text
        self.bodySource = bodySource
        self.hasAttachments = hasAttachments
        self.chatID = chatID
        self.chatLabel = chatLabel
        self.associatedMessageType = associatedMessageType
    }

    /// The thread name is resolved for a whole page at once, after the rows are read, so
    /// a search does not cost one extra query per result.
    public func labelled(_ label: String?) -> MessageRecord {
        MessageRecord(
            id: id, guid: guid, date: date, dateRead: dateRead, dateDelivered: dateDelivered,
            dateEdited: dateEdited, isFromMe: isFromMe, isRead: isRead, service: service,
            handle: handle, subject: subject, text: text, bodySource: bodySource,
            hasAttachments: hasAttachments, chatID: chatID, chatLabel: label,
            associatedMessageType: associatedMessageType)
    }
}

public struct MessagePage: Sendable, Equatable {
    public let messages: [MessageRecord]
    /// How many rows the store read to build this page. A text query is applied after
    /// the body is decoded, so it cannot be counted by SQL.
    public let scanned: Int
    /// True when the scan stopped at its ceiling rather than at the end of the data, so
    /// the answer is "the newest N matches", not "the matches".
    public let hitScanCeiling: Bool
    /// Known only where SQL alone decides the result set — a whole conversation. `nil`
    /// for a text search.
    public let total: Int?

    public init(
        messages: [MessageRecord], scanned: Int = 0, hitScanCeiling: Bool = false,
        total: Int? = nil
    ) {
        self.messages = messages
        self.scanned = scanned
        self.hitScanCeiling = hitScanCeiling
        self.total = total
    }
}

/// Every filter here mirrors a column the database already has. Nothing is computed:
/// a filter exists to avoid hauling a hundred thousand rows across the boundary, not
/// to form an opinion about them.
public struct MessageFilter: Sendable, Equatable {
    public var query: String?
    public var participant: String?
    public var chatID: Int64?
    public var from: Date?
    public var to: Date?
    public var hasAttachment: Bool?
    public var service: String?
    public var fromMe: Bool?
    /// How many rows the store may read before giving up. Carried on the filter so the
    /// store never has to know about `Configuration`.
    public var scanCeiling: Int = 20_000

    public init() {}

    /// The two predicates SQL cannot answer.
    ///
    /// The date range is decided here because `message.date` may hold seconds or
    /// nanoseconds and only the converted value is comparable. The text query is decided
    /// here because a modern body lives in `attributedBody`, a binary archive SQL cannot
    /// look inside — matching only the `text` column would quietly miss most of the
    /// recent archive, which is the worst possible failure for a search.
    public func accepts(_ record: MessageRecord) -> Bool {
        if from != nil || to != nil {
            // A row with no date cannot be shown to fall inside a range, and guessing
            // either way would be a judgment.
            guard let date = record.date else { return false }
            if let from, date < from { return false }
            if let to, date >= to { return false }
        }
        if let query, !query.isEmpty {
            let searchable = [record.text, record.subject].compactMap { $0 }
            guard searchable.contains(where: { $0.localizedCaseInsensitiveContains(query) })
            else { return false }
        }
        return true
    }
}

public struct AttachmentRecord: Sendable, Equatable {
    public let messageID: Int64
    public let id: Int64
    public let guid: String
    /// Absolute path, tilde expanded. The file lives under `~/Library/Messages/`, so
    /// reading it needs the same Full Disk Access the database does.
    public let path: String?
    public let transferName: String?
    public let uti: String?
    public let mimeType: String?
    public let totalBytes: Int64
    public let isOutgoing: Bool
    public let createdDate: Date?
    /// False for an attachment that was offloaded to iCloud or deleted from disk while
    /// its row survived — common enough that omitting it would mislead.
    public let existsOnDisk: Bool

    public init(
        messageID: Int64, id: Int64, guid: String, path: String?, transferName: String?,
        uti: String?, mimeType: String?, totalBytes: Int64, isOutgoing: Bool, createdDate: Date?,
        existsOnDisk: Bool
    ) {
        self.messageID = messageID
        self.id = id
        self.guid = guid
        self.path = path
        self.transferName = transferName
        self.uti = uti
        self.mimeType = mimeType
        self.totalBytes = totalBytes
        self.isOutgoing = isOutgoing
        self.createdDate = createdDate
        self.existsOnDisk = existsOnDisk
    }
}

/// What `messages_status` reports. Everything in it is a fact about the machine, so a
/// misconfiguration is visible without having to infer it from odd behaviour.
public struct StoreStatus: Sendable, Equatable {
    public let access: DatabaseAccess
    public let databasePath: String
    public let openedReadOnly: Bool
    public let dateUnit: AppleTimeUnit?
    public let conversationCount: Int?
    public let messageCount: Int?
    public let attachmentCount: Int?
    public let newestMessageDate: Date?
    /// Whether `/usr/bin/shortcuts` exists and lists the configured shortcut. `nil` when
    /// the check could not be run at all.
    public let sendShortcutInstalled: Bool?

    public init(
        access: DatabaseAccess, databasePath: String, openedReadOnly: Bool,
        dateUnit: AppleTimeUnit? = nil, conversationCount: Int? = nil, messageCount: Int? = nil,
        attachmentCount: Int? = nil, newestMessageDate: Date? = nil,
        sendShortcutInstalled: Bool? = nil
    ) {
        self.access = access
        self.databasePath = databasePath
        self.openedReadOnly = openedReadOnly
        self.dateUnit = dateUnit
        self.conversationCount = conversationCount
        self.messageCount = messageCount
        self.attachmentCount = attachmentCount
        self.newestMessageDate = newestMessageDate
        self.sendShortcutInstalled = sendShortcutInstalled
    }
}

/// The record of a send that already happened. There is no way to take one back, so this
/// exists to be shown to the person afterwards, not to be acted on.
public struct SendReceipt: Sendable, Equatable {
    public let recipient: String
    public let text: String
    public let shortcutName: String
    /// Whatever the shortcut printed, if anything. Shortcuts that end in "Send Message"
    /// usually print nothing.
    public let output: String?

    public init(recipient: String, text: String, shortcutName: String, output: String?) {
        self.recipient = recipient
        self.text = text
        self.shortcutName = shortcutName
        self.output = output
    }
}
