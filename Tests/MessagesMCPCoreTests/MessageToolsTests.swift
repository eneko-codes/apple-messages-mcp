import Foundation
import MCP
import Testing

@testable import MessagesMCPCore

/// Drives the tool layer end to end against `FakeMessageStore`. No test here opens
/// `chat.db`, and no test here sends anything: the send path is asserted against what the
/// double recorded, never against a message anyone received.
@Suite("Tool dispatch")
struct MessageToolsTests {

    private func call(
        _ name: String, _ arguments: [String: Value] = [:],
        store: FakeMessageStore = FakeMessageStore()
    ) async -> (text: String, isError: Bool) {
        let tools = MessageTools(store: store, calendar: Fixtures.calendar)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        guard case .text(let text, _, _) = result.content.first else {
            return ("(no text content)", true)
        }
        return (text, result.isError ?? false)
    }

    private func stocked() -> FakeMessageStore {
        let store = FakeMessageStore()
        store.conversationsValue = [
            Fixtures.conversation(id: 1, name: "Ane", identifier: "+34600000001"),
            Fixtures.conversation(
                id: 2, name: "Cuadrilla", identifier: "chat123", isGroup: true,
                participants: ["+34600000001", "+34600000002"]),
        ]
        store.messagesValue = [
            Fixtures.message(id: 10, chatID: 1, text: "bring the bread", at: Fixtures.now),
            Fixtures.message(
                id: 11, chatID: 1, text: "on my way", fromMe: true,
                at: Fixtures.date(2026, 8, 8, 9, 0)),
            Fixtures.message(
                id: 12, chatID: 2, text: "photos from Sunday",
                at: Fixtures.date(2026, 8, 7, 20, 0), hasAttachments: true),
        ]
        store.attachmentsValue = [
            AttachmentRecord(
                messageID: 12, id: 99, guid: "ATT-99", path: "/invented/photo.heic",
                transferName: "photo.heic", uti: "public.heic", mimeType: "image/heic",
                totalBytes: 1024, isOutgoing: false, createdDate: Fixtures.now,
                existsOnDisk: true)
        ]
        return store
    }

    // MARK: Catalogue

    @Test("Every tool has a unique name, title and description")
    func catalogueIsWellFormed() {
        let tools = ToolCatalog.all()
        let names = tools.map(\.name)
        #expect(names.count == Set(names).count)
        for tool in tools {
            #expect(tool.description?.isEmpty == false, "\(tool.name) has no description")
            #expect(tool.title?.isEmpty == false, "\(tool.name) has no title")
        }
    }

    /// Claude Desktop's schema sanitiser drops a property whose `type` is a union and
    /// hands the model a bare `{}` instead. The fault stays invisible until a caller
    /// happens to use that field, so the whole catalogue is walked rather than reviewed.
    @Test("No property declares a union type")
    func noUnionTypesInSchemas() {
        for tool in ToolCatalog.all() {
            guard case .object(let schema) = tool.inputSchema,
                case .object(let properties)? = schema["properties"]
            else { continue }
            for (property, definition) in properties {
                guard case .object(let fields) = definition else { continue }
                if case .array = fields["type"] {
                    Issue.record("\(tool.name).\(property) declares a union type")
                }
            }
        }
    }

    @Test("Only send_message is marked as a write")
    func annotationsAreHonest() {
        for tool in ToolCatalog.all() {
            let isRead = tool.name != ToolCatalog.sendName
            #expect(tool.annotations.readOnlyHint == isRead, "\(tool.name) is mis-annotated")
        }
    }

    // MARK: Access

    @Test("A read is refused, with instructions, when the database cannot be opened")
    func readsRefusedWithoutFullDiskAccess() async {
        let store = stocked()
        store.accessValue = .denied
        let (text, isError) = await call(ToolCatalog.conversationsName, store: store)
        #expect(isError)
        #expect(text.contains("Full Disk Access"))
    }

    @Test("messages_status answers even when the database is unreachable")
    func statusWorksWithoutAccess() async {
        let store = stocked()
        store.accessValue = .denied
        let (text, isError) = await call(ToolCatalog.statusName, store: store)
        #expect(!isError)
        #expect(!text.isEmpty)
    }

    /// Sending goes through Shortcuts rather than the database, so it must keep working
    /// when Full Disk Access has never been granted.
    @Test("send_message does not require database access")
    func sendWorksWithoutDatabaseAccess() async {
        let store = stocked()
        store.accessValue = .denied
        let (_, isError) = await call(
            ToolCatalog.sendName,
            [
                "recipient": .string("+34600000001"), "text": .string("hello"),
                "confirm": .bool(true),
            ],
            store: store)
        #expect(!isError)
        #expect(store.sent.count == 1)
    }

    // MARK: Reads

    @Test("conversations_list reports what exists")
    func conversationsAreListed() async {
        let (text, isError) = await call(ToolCatalog.conversationsName, store: stocked())
        #expect(!isError)
        #expect(text.contains("Ane"))
        #expect(text.contains("Cuadrilla"))
    }

    @Test("conversation_get returns one thread")
    func conversationReturnsThread() async {
        let (text, isError) = await call(
            ToolCatalog.conversationName, ["conversation_id": .int(1)], store: stocked())
        #expect(!isError)
        #expect(text.contains("bring the bread"))
        #expect(!text.contains("photos from Sunday"))
    }

    @Test("An unknown conversation id says so rather than returning nothing")
    func unknownConversationIsNamed() async {
        let (text, isError) = await call(
            ToolCatalog.conversationName, ["conversation_id": .int(999)], store: stocked())
        #expect(isError)
        #expect(text.contains("999"))
    }

    @Test("messages_search passes every filter through to the store")
    func searchPassesFilters() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.searchName,
            [
                "query": .string("bread"), "participant": .string("+34600000001"),
                "from": .string("2026-08-01"), "to": .string("2026-08-09"),
                "has_attachment": .bool(false),
            ],
            store: store)
        #expect(!isError)
        #expect(store.lastFilter?.query == "bread")
        #expect(store.lastFilter?.participant == "+34600000001")
        #expect(store.lastFilter?.hasAttachment == false)
        #expect(store.lastFilter?.from != nil)
    }

    /// A plain day read literally would exclude that whole day, so a one-day window would
    /// always come back empty.
    @Test("A plain day as 'to' covers that whole day")
    func rangeEndCoversTheDay() async {
        let store = stocked()
        _ = await call(
            ToolCatalog.searchName,
            ["query": .string("bread"), "to": .string("2026-08-09")], store: store)
        let to = store.lastFilter?.to
        #expect(to != nil)
        #expect((to ?? .distantPast) > Fixtures.date(2026, 8, 9, 23, 0))
    }

    @Test("A range that ends before it starts is refused")
    func invertedRangeIsRefused() async {
        let (_, isError) = await call(
            ToolCatalog.searchName,
            ["from": .string("2026-08-09"), "to": .string("2026-08-01")], store: stocked())
        #expect(isError)
    }

    @Test("message_attachments takes several ids at once")
    func attachmentsAcceptBulkIDs() async {
        let (text, isError) = await call(
            ToolCatalog.attachmentsName,
            ["message_ids": .array([.int(12), .int(10)])], store: stocked())
        #expect(!isError)
        #expect(text.contains("photo.heic"))
    }

    @Test("An unknown tool name is refused")
    func unknownToolIsRefused() async {
        let (_, isError) = await call("messages_delete_everything", store: stocked())
        #expect(isError)
    }

    // MARK: The send gates

    /// There is deliberately no recipient allow-list here any more: the owner removed it
    /// along with the connector setting that used to configure it, choosing this tool's
    /// own permission switch in Claude Desktop as the only gate. A send to a recipient
    /// nobody pre-approved must still go through as long as it is confirmed — the switch
    /// and the confirmation are the whole guard now.
    @Test("There is no recipient allow-list: any recipient goes through once confirmed")
    func anyRecipientIsAccepted() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.sendName,
            [
                "recipient": .string("+34699999999"), "text": .string("hello"),
                "confirm": .bool(true),
            ],
            store: store)
        #expect(!isError)
        #expect(store.sent.first?.recipient == "+34699999999")
    }

    @Test("Without confirm=true nothing is sent")
    func sendRequiresConfirmation() async {
        let store = stocked()
        let (text, isError) = await call(
            ToolCatalog.sendName,
            ["recipient": .string("+34600000001"), "text": .string("hello")],
            store: store)
        #expect(isError)
        #expect(store.sent.isEmpty)
        #expect(text.contains("confirm"))
    }

    @Test("A runaway body is refused before it reaches anyone")
    func overlongBodyIsRefused() async {
        let store = stocked()
        let (_, isError) = await call(
            ToolCatalog.sendName,
            [
                "recipient": .string("+34600000001"),
                "text": .string(String(repeating: "a", count: 4_001)),
                "confirm": .bool(true),
            ],
            store: store)
        #expect(isError)
        #expect(store.sent.isEmpty)
    }

    /// `normalizeRecipient` no longer guards a send — it is what `participant` search
    /// matching uses to treat a spaced or unspaced number as the same handle — but its
    /// behaviour is worth pinning directly now that the send allow-list test that used to
    /// exercise it is gone.
    @Test("Recipient normalisation ignores formatting differences in a number")
    func normalisationIgnoresFormatting() {
        #expect(
            Configuration.normalizeRecipient("+34 600 000 001")
                == Configuration.normalizeRecipient("+34600000001"))
        #expect(
            Configuration.normalizeRecipient("+34600000001")
                != Configuration.normalizeRecipient("600000001"))
    }

    @Test("A store failure is reported rather than swallowed")
    func storeFailureIsReported() async {
        let store = stocked()
        store.failure = ToolError.storeFailure("database is locked")
        let (text, isError) = await call(ToolCatalog.conversationsName, store: store)
        #expect(isError)
        #expect(text.contains("locked"))
    }
}
