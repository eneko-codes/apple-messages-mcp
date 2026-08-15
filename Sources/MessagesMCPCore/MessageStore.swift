import Foundation

/// The seam between the tool layer and this Mac.
///
/// Everything above this protocol is exercised by the tests against an in-memory double;
/// everything below it touches either the owner's real Messages database or the Shortcuts
/// app. Keeping the boundary this thin is what makes the untested surface small enough to
/// check by hand — and it is what lets the suite run with no Full Disk Access and, above
/// all, without ever sending a message to anybody.
public protocol MessageStore: Sendable {
    /// Cheap enough to call on every request: it probes the file, it does not open the
    /// database.
    func access() -> DatabaseAccess

    func status(sendShortcut: String) async throws -> StoreStatus

    /// `query` matches the display name, the chat identifier and the participants.
    func conversations(query: String?, limit: Int, offset: Int) async throws -> ConversationPage

    /// Newest first. A thread is read backwards from now — that is the direction a person
    /// reads one, and it is the only direction in which a first page is useful.
    func conversation(id: Int64, limit: Int, offset: Int) async throws -> MessagePage

    func search(_ filter: MessageFilter, limit: Int, offset: Int) async throws -> MessagePage

    /// Bulk, because attachments are looked up for a page of messages at a time and one
    /// call per message would be a round trip per row.
    func attachments(messageIDs: [Int64]) async throws -> [AttachmentRecord]

    /// IRREVERSIBLE. There is no recall, no undo and no edit window: once Messages hands
    /// this to the network it belongs to the recipient.
    ///
    /// The allow-list and the `confirm` flag are enforced in `MessagesTools`, above this
    /// protocol, so both are provable in the suite without a store that can actually send.
    func send(recipient: String, text: String, shortcutName: String) async throws -> SendReceipt
}
