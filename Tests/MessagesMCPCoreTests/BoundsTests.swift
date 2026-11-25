import Foundation
import Testing

@testable import MessagesMCPCore

/// The edges of the tool standard for this server's own tools: each bound and one past it,
/// the text of each notice, pages that chain, the longest result, and the texts the model
/// reads. Every conversation, address, message and file in here is invented, and nothing is
/// sent: a send is checked against what `FakeMessageStore` recorded.
@Suite("Bounds")
struct BoundsTests {

    private typealias Outcome = (text: String, isError: Bool)

    private static func call(
        _ name: String, _ arguments: [String: Value] = [:], store: FakeMessageStore,
        timeout: Duration = MessageTools.defaultTimeout
    ) async -> Outcome {
        let tools = MessageTools(store: store, calendar: Fixtures.calendar, timeout: timeout)
        let result = await tools.handle(.init(name: name, arguments: arguments))
        return (result.text, result.isError)
    }

    // MARK: An invented archive with as many rows as a test asks for

    private static func padded(_ index: Int) -> String {
        String(format: "%04d", index)
    }

    /// `text` made exactly `width` characters long.
    private static func filled(_ text: String, to width: Int) -> String {
        text + String(repeating: "x", count: width - text.count)
    }

    /// An address as long as a row shows one.
    private static let longAddress =
        filled("someone.invented@", to: Configuration.senderColumnWidth - 12) + ".example.com"

    /// A message whose row is the widest an ordinary one gets: a sender and a text that
    /// each fill their width without being clipped, an attachment and an edit.
    private static func wideMessage(_ index: Int, text: String? = nil) -> MessageRecord {
        MessageRecord(
            id: Int64(1_000_000 + index), guid: "GUID-\(index)",
            // A minute apart, newest first, the order the store hands rows over in.
            date: Fixtures.now.addingTimeInterval(TimeInterval(-60 * index)),
            dateEdited: Fixtures.now, isFromMe: false, isRead: true, service: "iMessage",
            handle: longAddress,
            text: text ?? filled("message \(padded(index)) ", to: Configuration.textWidth),
            hasAttachments: true, chatID: 1,
            chatLabel: filled("Invented thread ", to: Configuration.labelColumnWidth))
    }

    /// One listing tool, and an archive that gives it `count` rows of the widest ordinary
    /// width, in the order the tool lists them. `row` is text found in row `index` only.
    private struct Listing: Sendable, CustomTestStringConvertible {
        var tool: String
        var things: String
        var limits: ClosedRange<Int>
        var defaultLimit: Int
        var arguments: [String: Value] = [:]
        /// False for a search: it stops at the first match past the page, so a page that
        /// is not the last cannot say how many matches exist.
        var countsEveryRow = true
        var store: @Sendable (Int) -> FakeMessageStore
        var row: @Sendable (Int) -> String

        var testDescription: String { tool }

        func call(_ count: Int, _ extra: [String: Value] = [:]) async -> Outcome {
            await BoundsTests.call(tool, arguments.merging(extra) { _, new in new }, store: store(count))
        }

        /// The rows of an archive with `count` of them that `text` shows, in order.
        func rows(in text: String, of count: Int) -> [Int] {
            (0..<count).filter { text.contains(row($0)) }
        }

        /// The sentence that places rows `first` to `last` in a listing of `total`.
        func position(_ first: Int, _ last: Int, of total: Int) -> String {
            guard last < total else { return "Showing \(first)–\(last) of \(total) \(things). That is all." }
            return countsEveryRow
                ? "Showing \(first)–\(last) of \(total) \(things). Pass offset=\(last) for the next page."
                : "Showing \(first)–\(last) \(things); more exist. Pass offset=\(last) for the next page."
        }
    }

    private static let conversations = Listing(
        tool: ToolCatalog.conversationsName, things: "conversations",
        limits: Configuration.conversationLimitRange,
        defaultLimit: Configuration.defaultConversationLimit,
        store: { count in
            let store = FakeMessageStore()
            store.conversationsValue = (0..<count).map {
                Conversation(
                    id: Int64(1_000_000 + $0), guid: "iMessage;+;chat\($0)", chatIdentifier: "chat\($0)",
                    displayName: filled("Invented group \(padded($0)) ", to: Configuration.labelColumnWidth),
                    serviceName: "iMessage", isGroup: true,
                    participants: ["+34600000001", "+34600000002", "+34600000003", "someone@example.com"],
                    lastMessageDate: Fixtures.now,
                    messageCount: 123_456, unreadCount: 1_234)
            }
            return store
        },
        row: { "Invented group \(padded($0)) " })

    private static func threadStore(_ count: Int) -> FakeMessageStore {
        let store = FakeMessageStore()
        store.conversationsValue = [Fixtures.conversation(id: 1, name: "Invented thread", identifier: "+34600000001")]
        store.messagesValue = (0..<count).map { wideMessage($0) }
        return store
    }

    private static let thread = Listing(
        tool: ToolCatalog.conversationName, things: "messages", limits: Configuration.messageLimitRange,
        defaultLimit: Configuration.defaultMessageLimit, arguments: ["conversation_id": 1],
        store: threadStore, row: { "message \(padded($0)) " })

    private static let search = Listing(
        tool: ToolCatalog.searchName, things: "messages", limits: Configuration.messageLimitRange,
        defaultLimit: Configuration.defaultMessageLimit, arguments: ["query": "message"],
        countsEveryRow: false, store: threadStore, row: { "message \(padded($0)) " })

    private static let attachments = Listing(
        tool: ToolCatalog.attachmentsName, things: "attachments",
        limits: Configuration.attachmentLimitRange,
        defaultLimit: Configuration.defaultAttachmentLimit, arguments: ["message_ids": [7]],
        store: { count in
            let store = FakeMessageStore()
            // Out of order, as a store may hand them over.
            store.attachmentsValue = (0..<count).reversed().map {
                AttachmentRecord(
                    messageID: 7, id: Int64(1_000_000 + $0), guid: "ATT-\($0)",
                    path: "/Users/user/Library/Messages/Attachments/a1/01/11111111-2222-3333-4444-555555555555/invented-\(padded($0)).heic",
                    transferName: "invented-\(padded($0)).heic", uti: "public.heic", mimeType: "image/heic",
                    totalBytes: 12_345_678, isOutgoing: false, createdDate: Fixtures.now, existsOnDisk: false)
            }
            return store
        },
        row: { "name      invented-\(padded($0)).heic" })

    private static let listings = [conversations, thread, search, attachments]

    // MARK: Pages

    @Test("A call with no optional argument returns one default page, announced before the data", arguments: listings)
    private func defaultPage(_ listing: Listing) async {
        let total = listing.defaultLimit + 5
        let result = await listing.call(total)
        #expect(!result.isError)
        #expect(result.text.hasPrefix(listing.position(1, listing.defaultLimit, of: total) + "\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<listing.defaultLimit))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    @Test("A result that holds every row from the start carries no notice", arguments: listings)
    private func wholeListingHasNoNotice(_ listing: Listing) async {
        let result = await listing.call(listing.defaultLimit)
        #expect(listing.rows(in: result.text, of: listing.defaultLimit).count == listing.defaultLimit)
        #expect(!result.text.contains("Showing"))
        #expect(!result.text.contains("is outside"))
        #expect(!result.text.contains("clipped"))
    }

    @Test("limit at its maximum is used as asked, and a full page of the widest rows fits a result", arguments: listings)
    private func limitAtItsMaximum(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10
        let result = await listing.call(total, ["limit": .int(maximum)])
        #expect(!result.text.contains("is outside"))
        #expect(result.text.hasPrefix(listing.position(1, maximum, of: total) + "\n\n"))
        #expect(listing.rows(in: result.text, of: total) == Array(0..<maximum))
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
    }

    @Test("limit one past either end is moved to the nearest value, and the result says which", arguments: listings)
    private func limitPastItsRange(_ listing: Listing) async {
        let maximum = listing.limits.upperBound
        let total = maximum + 10

        let over = await listing.call(total, ["limit": .int(maximum + 1)])
        #expect(
            over.text.hasPrefix(
                "limit=\(maximum + 1) is outside 1–\(maximum); \(maximum) was used.\n"
                    + listing.position(1, maximum, of: total) + "\n\n"))
        #expect(listing.rows(in: over.text, of: total) == Array(0..<maximum))

        let under = await listing.call(total, ["limit": .int(0)])
        #expect(
            under.text.hasPrefix(
                "limit=0 is outside 1–\(maximum); 1 was used.\n" + listing.position(1, 1, of: total) + "\n\n"))
        #expect(listing.rows(in: under.text, of: total) == [0])
    }

    @Test("Each page starts where the last one ended, and the last says that is all", arguments: listings)
    private func pagesChain(_ listing: Listing) async {
        let first = await listing.call(7, ["limit": .int(3)])
        #expect(first.text.hasPrefix(listing.position(1, 3, of: 7) + "\n\n"))
        #expect(listing.rows(in: first.text, of: 7) == [0, 1, 2])

        let second = await listing.call(7, ["limit": .int(3), "offset": .int(3)])
        #expect(second.text.hasPrefix(listing.position(4, 6, of: 7) + "\n\n"))
        #expect(listing.rows(in: second.text, of: 7) == [3, 4, 5])

        let last = await listing.call(7, ["limit": .int(3), "offset": .int(6)])
        #expect(last.text.hasPrefix("Showing 7–7 of 7 \(listing.things). That is all.\n\n"))
        #expect(listing.rows(in: last.text, of: 7) == [6])
    }

    @Test("An offset past the end returns no row and says so; a negative one is moved to zero", arguments: listings)
    private func offsetEdges(_ listing: Listing) async {
        let past = await listing.call(7, ["offset": .int(7)])
        #expect(!past.isError)
        #expect(past.text.hasPrefix("Showing 0 of 7 \(listing.things): offset=7 is past the end. That is all.\n\n"))
        #expect(listing.rows(in: past.text, of: 7).isEmpty)
        #expect(past.text.contains("(nothing at this offset)"))

        let lastRow = await listing.call(7, ["offset": .int(6)])
        #expect(listing.rows(in: lastRow.text, of: 7) == [6])

        let negative = await listing.call(7, ["offset": .int(-1)])
        let range = Configuration.offsetRange
        #expect(negative.text.hasPrefix("offset=-1 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.\n\n"))
        #expect(listing.rows(in: negative.text, of: 7) == Array(0..<7))
    }

    @Test("A listing with nothing in it says that nothing matched, not that the offset skipped it")
    func emptyListings() async {
        for listing in [Self.conversations, Self.search, Self.attachments] {
            let none = await listing.call(0)
            #expect(!none.isError, "\(listing.tool)")
            #expect(!none.text.contains("(nothing at this offset)"), "\(listing.tool)")
            #expect(!none.text.contains("Showing"), "\(listing.tool)")
        }
        #expect(await Self.conversations.call(0).text.contains("Messages holds no conversations."))
        #expect(await Self.search.call(0).text.contains("No messages matched."))
        #expect(await Self.attachments.call(0).text.contains("That message has no attachment."))
    }

    @Test("A listing states its order")
    func orderIsStated() async {
        #expect(await Self.conversations.call(1).text.contains("ordered by latest message (newest first), then highest id."))
        #expect(await Self.thread.call(1).text.contains("ordered newest first, then highest id."))
        #expect(await Self.search.call(1).text.contains("Ordered newest first, then highest id."))
        #expect(await Self.attachments.call(1).text.contains("ordered by message id, then attachment id."))
    }

    // MARK: Rows wider than any maximum foresaw

    private static let wide = String(repeating: "w", count: 1_000)

    /// Eight UTF-16 units to the character, so a full page of full-width texts is several
    /// results long. The number leads the text, so a row is found without walking it.
    private static func heavyThread(_ count: Int) -> FakeMessageStore {
        let store = threadStore(0)
        store.messagesValue = (0..<count).map {
            wideMessage($0, text: "row-\(padded($0)) " + String(repeating: "👩‍👩‍👧", count: Configuration.textWidth - 9))
        }
        return store
    }

    /// The same four listings over rows far wider than an ordinary one: names and paths a
    /// thousand characters long, which a row shows whole, and texts of heavy characters.
    private static let wideListings: [Listing] = {
        var conversations = Self.conversations
        conversations.store = { count in
            let store = FakeMessageStore()
            store.conversationsValue = (0..<count).map {
                Fixtures.conversation(id: Int64($0 + 1), name: "row-\(padded($0)) \(wide)", identifier: "chat\($0)")
            }
            return store
        }
        var thread = Self.thread
        thread.store = heavyThread
        var search = Self.search
        search.store = heavyThread
        search.arguments = ["query": "row-"]
        var attachments = Self.attachments
        attachments.store = { count in
            let store = FakeMessageStore()
            store.attachmentsValue = (0..<count).map {
                AttachmentRecord(
                    messageID: 7, id: Int64($0 + 1), guid: "ATT-\($0)", path: "/invented/\(wide)/file",
                    transferName: "row-\(padded($0)) .heic", uti: nil, mimeType: nil, totalBytes: 1,
                    isOutgoing: false, createdDate: nil, existsOnDisk: true)
            }
            return store
        }
        return [conversations, thread, search, attachments]
    }()

    @Test("A page of rows too wide to fit holds fewer of them and says where to resume", arguments: wideListings)
    private func widePageShrinks(_ listing: Listing) async throws {
        let maximum = listing.limits.upperBound
        let total = 2 * maximum
        var offset = 0
        var seen: [Int] = []
        while offset < total {
            let result = await listing.call(total, ["limit": .int(maximum), "offset": .int(offset)])
            #expect(result.text.utf16.count <= ToolStandard.longestResult)
            let shown = (0..<total).filter { result.text.contains("row-\(Self.padded($0)) ") }
            let last = try #require(shown.last)
            #expect(shown.first == offset)
            #expect(shown.count < maximum)
            let next = last + 1 < total ? "Pass offset=\(last + 1) for the next page." : "That is all."
            #expect(result.text.hasPrefix("Showing \(offset + 1)–\(last + 1) "))
            #expect(result.text.components(separatedBy: "\n")[0].hasSuffix(next))
            seen += shown
            offset = last + 1
        }
        #expect(seen == Array(0..<total))
    }

    @Test("A name, a participant list or an address longer than its column is shown whole")
    func namesAndAddressesAreNeverCut() async {
        let name = Self.filled("A very long invented group name ", to: 3 * Configuration.labelColumnWidth)
        let address = Self.filled("someone.with.a.long.address@", to: 3 * Configuration.senderColumnWidth) + ".example.com"
        let people = (1...12).map { "+346000000\(Self.padded($0))" }

        let store = FakeMessageStore()
        store.conversationsValue = [
            Fixtures.conversation(id: 1, name: name, identifier: "chat1", isGroup: true, participants: people),
            Fixtures.conversation(id: 2, name: nil, identifier: "chat2", isGroup: true, participants: people),
        ]
        var message = Fixtures.message(id: 10, chatID: 1, text: "hello", handle: address)
        message = message.labelled(name)
        store.messagesValue = [message]

        let list = await Self.call(ToolCatalog.conversationsName, store: store)
        #expect(list.text.contains(name + "  group"))
        #expect(list.text.contains("id=1  with " + people.joined(separator: ", ")))
        #expect(list.text.contains(people.joined(separator: ", ") + "  group"))
        #expect(!list.text.contains("clipped") && !list.text.contains("…"))

        let thread = await Self.call(ToolCatalog.conversationName, ["conversation_id": 1], store: store)
        #expect(thread.text.hasPrefix(name + " · id=1 · 1 message"))
        #expect(thread.text.contains(address + "  hello"))

        let search = await Self.call(ToolCatalog.searchName, ["query": "hello"], store: store)
        #expect(search.text.contains(address + "  [" + name + "]  hello"))
        #expect(!search.text.contains("clipped") && !search.text.contains("…"))
    }

    // MARK: Text clipped inside a row

    @Test("A text one character too long is clipped, and the result says so before the rows", arguments: [thread, search])
    private func longTextIsClipped(_ listing: Listing) async {
        let width = Configuration.textWidth
        let notice = "Text is clipped to \(width) characters in each row. No tool of this server reads one message in full."
        #expect(Format.clippedNotice == notice)

        let long = Self.filled("message long ", to: width + 1)
        let clipped = Self.threadStore(0)
        clipped.messagesValue = [Self.wideMessage(0, text: long)]
        let result = await Self.call(listing.tool, listing.arguments, store: clipped)
        #expect(result.text.hasPrefix(notice + "\n\n"))
        #expect(result.text.contains(String(long.prefix(width - 1)) + "…"))
        #expect(!result.text.contains(String(long.prefix(width))))

        let fits = Self.threadStore(0)
        fits.messagesValue = [Self.wideMessage(0, text: String(long.prefix(width)))]
        let whole = await Self.call(listing.tool, listing.arguments, store: fits)
        #expect(!whole.text.contains("clipped"))
        #expect(whole.text.contains(String(long.prefix(width))))
    }

    @Test("A text of several lines becomes one line, and its length is counted on that line")
    func linesAreJoined() async {
        let store = Self.threadStore(0)
        store.messagesValue = [Self.wideMessage(0, text: "first line\n\n  second line  \nthird")]
        let result = await Self.call(ToolCatalog.conversationName, ["conversation_id": 1], store: store)
        #expect(result.text.contains("first line ⏎ second line ⏎ third"))
        #expect(!result.text.contains("clipped"))
    }

    @Test("The position of a page comes before the sentence about clipped text")
    func noticesKeepTheirOrder() async {
        let store = Self.threadStore(0)
        store.messagesValue = (0..<3).map {
            Self.wideMessage($0, text: Self.filled("message \(Self.padded($0)) ", to: Configuration.textWidth + 40))
        }
        let result = await Self.call(
            ToolCatalog.conversationName, ["conversation_id": 1, "limit": 2, "offset": -4], store: store)
        let range = Configuration.offsetRange
        #expect(
            result.text.hasPrefix(
                """
                offset=-4 is outside \(range.lowerBound)–\(range.upperBound); 0 was used.
                Showing 1–2 of 3 messages. Pass offset=2 for the next page.
                \(Format.clippedNotice)

                Invented thread
                """))
    }

    // MARK: A search that stops at its ceiling

    /// Ten messages a minute apart, newest first; the ones at 1, 3 and 8 mention bread.
    private static func scanStore(ceiling: Int) -> FakeMessageStore {
        let store = threadStore(0)
        store.messagesValue = (0..<10).map {
            wideMessage($0, text: [1, 3, 8].contains($0) ? "bread \(padded($0))" : "other \(padded($0))")
        }
        store.scanCeiling = ceiling
        return store
    }

    @Test("A scan that stops at its ceiling says so first, with the to_date that goes on from there")
    func scanCeilingIsAnnounced() async {
        let result = await Self.call(ToolCatalog.searchName, ["query": "bread"], store: Self.scanStore(ceiling: 5))
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                """
                The scan stopped after 5 messages; more may exist. Narrow by to_date=2026-08-09T11:56:00 \
                with offset=0 to go on from the oldest message scanned, or by participant or conversation_id.

                Messages: 2 shown
                """))
        #expect(result.text.contains("Scanned 5 messages back to 2026-08-09T11:56:00."))
        #expect(result.text.contains("bread 0001") && result.text.contains("bread 0003"))
        #expect(!result.text.contains("bread 0008"))
    }

    @Test("The to_date a stopped scan names reaches the messages it never looked at")
    func scanGoesOnFromTheOldestMessageRead() async {
        let result = await Self.call(
            ToolCatalog.searchName, ["query": "bread", "to_date": "2026-08-09T11:56:00"],
            store: Self.scanStore(ceiling: 5))
        #expect(result.text.contains("bread 0008"))
        #expect(!result.text.contains("bread 0003"))
        // Rows 4 to 8: the second the first scan ended on is read again, so nothing between
        // the two scans is skipped.
        #expect(result.text.contains("Scanned 5 messages back to 2026-08-09T11:52:00."))
    }

    @Test("After the ceiling, a later page counts only what the scan reached, and says so")
    func pagesOfAStoppedScan() async {
        let second = await Self.call(
            ToolCatalog.searchName, ["query": "bread", "limit": 1, "offset": 1], store: Self.scanStore(ceiling: 5))
        let lines = second.text.components(separatedBy: "\n")
        #expect(lines[0].hasPrefix("The scan stopped after 5 messages; more may exist. Narrow by to_date="))
        #expect(lines[1] == "Showing 2–2 of 2 messages found before the scan stopped. That is all.")
        #expect(second.text.contains("bread 0003") && !second.text.contains("bread 0001"))

        // The first page stopped on the second match, before the ceiling: nothing to announce
        // but the next page.
        let first = await Self.call(
            ToolCatalog.searchName, ["query": "bread", "limit": 1], store: Self.scanStore(ceiling: 5))
        #expect(first.text.hasPrefix("Showing 1–1 messages; more exist. Pass offset=1 for the next page.\n\n"))
    }

    @Test("A scan that reaches the end of the archive carries no notice")
    func wholeScanHasNoNotice() async {
        let result = await Self.call(ToolCatalog.searchName, ["query": "bread"], store: Self.scanStore(ceiling: 50))
        #expect(result.text.hasPrefix("Messages: 3 shown"))
        #expect(!result.text.contains("scan stopped"))
    }

    // MARK: Dates

    private func filter(_ arguments: [String: Value]) async -> (filter: MessageFilter?, outcome: Outcome) {
        let store = Self.threadStore(1)
        let outcome = await Self.call(ToolCatalog.searchName, arguments, store: store)
        return (store.lastFilter, outcome)
    }

    @Test("to_date is inclusive: it covers the whole day, minute or second it names")
    func toDateIsInclusive() async {
        let cases: [(String, Date)] = [
            ("2026-08-09", Fixtures.date(2026, 8, 10)),
            ("2026-08-09T09:00", Fixtures.date(2026, 8, 9, 9, 1)),
            ("2026-08-09T09:00:07", Fixtures.date(2026, 8, 9, 9, 0).addingTimeInterval(8)),
            ("2026-08-09T09:00:07+02:00", Fixtures.date(2026, 8, 9, 9, 0).addingTimeInterval(8)),
        ]
        for (written, end) in cases {
            let (filter, outcome) = await filter(["to_date": .string(written)])
            #expect(!outcome.isError, "\(written)")
            #expect(filter?.to == end, "\(written)")
            #expect(filter?.from == nil, "\(written)")
        }
    }

    @Test("from_date is inclusive and, alone, runs to the newest message")
    func fromDateAlone() async {
        let (filter, outcome) = await filter(["from_date": "2026-08-09T09:00"])
        #expect(!outcome.isError)
        #expect(filter?.from == Fixtures.date(2026, 8, 9, 9, 0))
        #expect(filter?.to == nil)
        #expect(outcome.text.contains("from 2026-08-09T09:00:00"))
    }

    @Test("A message on the last second of to_date is found, and one a second later is not")
    func toDateEdge() async {
        let store = Self.threadStore(0)
        let edge = Fixtures.date(2026, 8, 9, 9, 0)
        store.messagesValue = [
            Fixtures.message(id: 1, chatID: 1, text: "after the range", at: edge.addingTimeInterval(60)),
            Fixtures.message(id: 2, chatID: 1, text: "last moment of the range", at: edge.addingTimeInterval(59.5)),
            Fixtures.message(id: 3, chatID: 1, text: "first moment of the range", at: edge),
            Fixtures.message(id: 4, chatID: 1, text: "before the range", at: edge.addingTimeInterval(-0.5)),
        ]
        let result = await Self.call(
            ToolCatalog.searchName, ["from_date": "2026-08-09T09:00", "to_date": "2026-08-09T09:00"], store: store)
        #expect(result.text.contains("last moment of the range"))
        #expect(result.text.contains("first moment of the range"))
        #expect(!result.text.contains("after the range"))
        #expect(!result.text.contains("before the range"))
    }

    @Test("A date that does not exist is refused with the forms accepted")
    func impossibleDatesAreRefused() async {
        // 29 March 2026 has no 02:30 in the fixture's time zone: the clocks go from 02:00 to 03:00.
        for written in ["2026-02-30", "2026-13-01", "2026-03-29T02:30", "2026-08-09T25:00", "09/08/2026", "yesterday"] {
            let (_, outcome) = await filter(["from_date": .string(written)])
            #expect(outcome.isError, "\(written)")
            #expect(outcome.text.contains("Argument 'from_date' is not a date this server accepts"), "\(written)")
            #expect(outcome.text.contains("2026-08-12T09:00:00+02:00   explicit offset"), "\(written)")
        }
        let (_, valid) = await filter(["from_date": "2028-02-29"])
        #expect(!valid.isError)
    }

    @Test("A range that ends before it starts is refused with the forms accepted; one moment wide is not")
    func rangesAreChecked() async {
        let (_, inverted) = await filter(["from_date": "2026-08-09T10:00", "to_date": "2026-08-09T09:00"])
        #expect(inverted.isError)
        #expect(inverted.text.contains("'to_date' ends before 'from_date' begins"))
        #expect(inverted.text.contains("2026-08-12T09:00            local time"))

        for range: [String: Value] in [
            ["from_date": "2026-08-09", "to_date": "2026-08-09"],
            ["from_date": "2026-08-09T09:00:30", "to_date": "2026-08-09T09:00"],
        ] {
            let (_, outcome) = await filter(range)
            #expect(!outcome.isError, "\(range)")
        }
    }

    @Test("A filter value Messages never recorded matches nothing and says so, as the schema states")
    func unknownServiceMatchesNothing() async throws {
        let store = Self.threadStore(3)
        let result = await Self.call(ToolCatalog.searchName, ["service": "Telegraph"], store: store)
        #expect(store.lastFilter?.service == "Telegraph")
        #expect(!result.isError)
        let tool = try #require(ToolCatalog.all().first { $0.name == ToolCatalog.searchName })
        #expect(properties(of: tool)["service"]?["description"]?.stringValue?.contains("matches nothing") == true)
    }

    // MARK: Numbers moved, values refused

    @Test("A wrong type is refused with the form expected")
    func wrongTypesAreRefused() async {
        let cases: [(tool: String, arguments: [String: Value], expected: String)] = [
            (ToolCatalog.conversationsName, ["limit": "ten"], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.conversationsName, ["limit": 2.5], "Argument 'limit' is not valid: a whole number was expected"),
            (ToolCatalog.conversationsName, ["offset": true], "Argument 'offset' is not valid: a whole number was expected"),
            (ToolCatalog.conversationsName, ["query": 5], "Argument 'query' is not valid: text was expected"),
            (ToolCatalog.searchName, ["participant": ["+34600000001"]], "Argument 'participant' is not valid: text was expected"),
            (ToolCatalog.searchName, ["from_date": 20260809], "Argument 'from_date' is not valid: text was expected"),
            (ToolCatalog.searchName, ["has_attachment": "yes"], "Argument 'has_attachment' is not valid: true or false was expected"),
            (ToolCatalog.searchName, ["from_me": 1], "Argument 'from_me' is not valid: true or false was expected"),
            (ToolCatalog.searchName, ["conversation_id": "the first"], "Argument 'conversation_id' is not valid: an id, a whole number"),
            (ToolCatalog.conversationName, ["conversation_id": 1.5], "Argument 'conversation_id' is not valid: an id, a whole number"),
            (ToolCatalog.conversationName, ["conversation_id": "1"], "Argument 'conversation_id' is not valid: an id, a whole number"),
            (ToolCatalog.searchName, ["service": 5], "Argument 'service' is not valid: text was expected"),
            (ToolCatalog.attachmentsName, ["message_ids": [7, "seven"]], "Argument 'message_ids' is not valid: an id, a whole number"),
            (ToolCatalog.attachmentsName, ["message_ids": [7], "limit": [1]], "Argument 'limit' is not valid"),
            (ToolCatalog.sendName, ["recipient": 34_600_000_001, "text": "hello", "confirm": true], "Argument 'recipient' is not valid: text was expected"),
            (ToolCatalog.sendName, ["recipient": "+34600000001", "text": "hello", "confirm": "true"], "Argument 'confirm' is not valid: true or false was expected"),
        ]
        for (tool, arguments, expected) in cases {
            let store = Self.threadStore(1)
            let result = await Self.call(tool, arguments, store: store)
            #expect(result.isError, "\(tool) \(arguments)")
            #expect(result.text.contains(expected), "\(tool) \(arguments): \(result.text)")
            #expect(store.sent.isEmpty)
        }
    }

    @Test("A whole number sent as 20.0 is taken as 20, and a null as not given")
    func lenientForms() async {
        let result = await Self.conversations.call(30, ["limit": 20.0, "offset": .null, "query": .null])
        #expect(!result.isError)
        #expect(result.text.hasPrefix("Showing 1–20 of 30 conversations."))

        let thread = await Self.thread.call(1, ["conversation_id": 1.0])
        #expect(!thread.isError && thread.text.contains("message 0000 "))
    }

    @Test("An id outside its range is refused, never moved to another row")
    func identifiersAreRefused() async {
        let ids = Configuration.identifierRange
        let expected = "an id, a whole number from \(ids.lowerBound) to \(ids.upperBound), was expected"
        for id in [0, -1, ids.upperBound + 1] {
            let thread = await Self.thread.call(1, ["conversation_id": .int(id)])
            #expect(thread.isError && thread.text.contains("Argument 'conversation_id' is not valid: \(expected)"), "\(id)")
            let search = await Self.search.call(1, ["conversation_id": .int(id)])
            #expect(search.isError && search.text.contains(expected), "\(id)")
            let attachments = await Self.attachments.call(1, ["message_ids": [.int(id)]])
            #expect(attachments.isError && attachments.text.contains("Argument 'message_ids' is not valid: \(expected)"), "\(id)")
        }
        let edge = await Self.thread.call(1, ["conversation_id": .int(ids.upperBound)])
        #expect(edge.isError && edge.text.contains("No conversation exists with id \(ids.upperBound)"))
    }

    @Test("message_attachments takes its maximum number of ids and refuses one more, without shortening the list")
    func messageIDsAreBounded() async {
        let maximum = Configuration.maximumMessageIDs
        let atMaximum = await Self.attachments.call(1, ["message_ids": .array((1...maximum).map { .int($0) })])
        #expect(!atMaximum.isError)
        #expect(atMaximum.text.contains("on \(maximum) messages given"))

        let over = await Self.attachments.call(1, ["message_ids": .array((1...(maximum + 1)).map { .int($0) })])
        #expect(over.isError)
        #expect(
            over.text.contains(
                "Argument 'message_ids' is not valid: it holds \(maximum + 1) ids and one call takes at most \(maximum)"))

        let none = await Self.attachments.call(1, ["message_ids": []])
        #expect(none.isError && none.text.contains("Missing required argument 'message_ids'"))
        let single = await Self.attachments.call(1, ["message_ids": 7])
        #expect(!single.isError && single.text.contains("invented-0000.heic"))
    }

    // MARK: The send receipt

    private static let sendArguments: [String: Value] = [
        "recipient": "+34600000001", "text": "hello", "confirm": true,
    ]

    @Test("A receipt shows the start of what the shortcut printed and says the rest cannot be read")
    func shortcutOutputIsCut() async {
        let width = Configuration.shortcutOutputWidth
        let store = FakeMessageStore()
        store.shortcutOutput = String(repeating: "o", count: width) + "TAIL"
        let result = await Self.call(ToolCatalog.sendName, Self.sendArguments, store: store)
        #expect(!result.isError)
        #expect(
            result.text.hasPrefix(
                "Shortcut output: characters 1–\(width) of \(width + 4). The rest cannot be read: calling "
                    + "send_message again would send the message again.\n\nSent. This cannot be recalled."))
        #expect(result.text.contains(String(repeating: "o", count: width)))
        #expect(!result.text.contains("TAIL"))
        #expect(store.sent.count == 1)

        let fits = FakeMessageStore()
        fits.shortcutOutput = String(repeating: "o", count: width)
        let whole = await Self.call(ToolCatalog.sendName, Self.sendArguments, store: fits)
        #expect(whole.text.hasPrefix("Sent. This cannot be recalled."))
    }

    @Test("A receipt for the longest text of characters that take many UTF-16 units still fits a result")
    func receiptFitsAResult() async {
        let text = String(repeating: "👩‍👩‍👧", count: Configuration.maximumSendCharacters)
        #expect(text.utf16.count > ToolStandard.longestResult / 2)
        let store = FakeMessageStore()
        store.shortcutOutput = String(repeating: "👩‍👩‍👧", count: Configuration.shortcutOutputWidth + 1)
        let result = await Self.call(
            ToolCatalog.sendName, ["recipient": "+34600000001", "text": .string(text), "confirm": true], store: store)
        #expect(!result.isError)
        #expect(result.text.utf16.count <= ToolStandard.longestResult)
        #expect(result.text.hasPrefix("Text: characters 1–"))
        #expect(result.text.contains(" of \(Configuration.maximumSendCharacters). All of it was sent; the rest is the text given in the call.\n"))
        #expect(result.text.contains("Shortcut output: characters 1–"))
        // The receipt is shorter; what was handed to the shortcut is not.
        #expect(store.sent.first?.text == text)
    }

    @Test("A recipient longer than any address is refused before anything is sent")
    func longRecipientIsRefused() async {
        let maximum = Configuration.maximumRecipientCharacters
        let store = FakeMessageStore()
        let over = await Self.call(
            ToolCatalog.sendName,
            ["recipient": .string(String(repeating: "r", count: maximum + 1)), "text": "hello", "confirm": true],
            store: store)
        #expect(over.isError)
        #expect(over.text.contains("Argument 'recipient' is not valid: it is \(maximum + 1) characters"))
        #expect(over.text.utf16.count < 300)
        #expect(store.sent.isEmpty)

        let atMaximum = await Self.call(
            ToolCatalog.sendName,
            ["recipient": .string(String(repeating: "r", count: maximum)), "text": "hello", "confirm": true],
            store: store)
        #expect(!atMaximum.isError)
        #expect(store.sent.count == 1)
    }

    @Test("The longest text is sent and one character more is refused")
    func sendLengthBounds() async {
        let maximum = Configuration.maximumSendCharacters
        let store = FakeMessageStore()
        let atMaximum = await Self.call(
            ToolCatalog.sendName,
            ["recipient": "+34600000001", "text": .string(String(repeating: "a", count: maximum)), "confirm": true],
            store: store)
        #expect(!atMaximum.isError && store.sent.count == 1)
        let over = await Self.call(
            ToolCatalog.sendName,
            ["recipient": "+34600000001", "text": .string(String(repeating: "a", count: maximum + 1)), "confirm": true],
            store: store)
        #expect(over.isError && store.sent.count == 1)
        #expect(over.text.contains("The message is \(maximum + 1) characters; the maximum is \(maximum)."))
    }

    // MARK: Errors and time

    @Test("An error repeats at most a short piece of what the caller sent")
    func errorsClipWhatTheyEcho() async {
        let long = String(repeating: "n", count: 5000)
        let clipped = String(repeating: "n", count: ToolStandard.echoWidth) + "…"

        let tool = await Self.call(long, store: FakeMessageStore())
        #expect(tool.isError)
        #expect(tool.text == "'\(clipped)' is not a tool of this server.")

        let date = await Self.call(ToolCatalog.searchName, ["to_date": .string(long)], store: FakeMessageStore())
        #expect(date.isError)
        #expect(date.text.contains("'\(clipped)'") && !date.text.contains(long))
    }

    @Test("A search repeats only the start of a long query in its header")
    func headersClipWhatTheyEcho() async {
        let long = String(repeating: "q", count: 5000)
        let result = await Self.call(ToolCatalog.searchName, ["query": .string(long)], store: Self.threadStore(3))
        #expect(!result.isError)
        #expect(result.text.contains("text \"" + String(repeating: "q", count: ToolStandard.echoWidth) + "…\""))
        #expect(!result.text.contains(long))
        let conversations = await Self.conversations.call(0, ["query": .string(long)])
        #expect(!conversations.text.contains(long))
    }

    @Test("Every error this server words is inside the longest error, whatever it is given to repeat")
    func errorsAreBounded() {
        let long = String(repeating: "e", count: 50_000)
        let errors: [ToolError] = [
            .notAuthorized(.denied), .notAuthorized(.missing(path: "/Users/user/Library/Messages/chat.db")),
            .notAuthorized(.failed(long)), .missingArgument("conversation_id"),
            .badArgument(name: "limit", reason: "a whole number was expected"),
            .badDate(argument: "to_date", value: long), .endBeforeStart, .conversationNotFound(id: 7),
            .noMessageIDs, .confirmationRequired(action: "Sending a message"),
            .messageTooLong(characters: 50_000, maximum: Configuration.maximumSendCharacters),
            .sendShortcutMissing(name: Configuration.sendShortcutName),
            .sendFailed(shortcut: Configuration.sendShortcutName, detail: long),
            .schemaUnsupported(table: "message", missing: ["guid", "date", "is_from_me"]),
            .storeFailure(long), .unknownTool(long), .timedOut(seconds: 50, sending: true),
            .timedOut(seconds: 50, sending: false),
        ]
        for error in errors {
            #expect(error.message.utf16.count <= ToolStandard.longestError / 4, "\(Diagnostics.kind(of: error))")
        }
        let width = Configuration.errorDetailWidth
        #expect(
            ToolError.storeFailure(long).message.hasSuffix(
                String(repeating: "e", count: width) + "… (the first \(width) of 50000 characters)"))
        #expect(ToolError.detail("database is locked") == "database is locked")
    }

    @Test("A call that does not finish is answered at its deadline, and a send says it may have gone through")
    func deadlineAnswers() async {
        let store = Self.threadStore(1)
        store.delay = .seconds(20)
        let started = ContinuousClock.now

        let search = await Self.call(ToolCatalog.searchName, [:], store: store, timeout: .milliseconds(100))
        #expect(search.isError)
        #expect(search.text.contains("The call did not finish within 0 seconds and was abandoned."))
        #expect(search.text.contains("nothing was changed"))
        #expect(search.text.contains("narrowed by conversation_id, participant, from_date or to_date"))

        let send = await Self.call(ToolCatalog.sendName, Self.sendArguments, store: store, timeout: .milliseconds(100))
        #expect(send.isError)
        #expect(send.text.contains("THE MESSAGE MAY OR MAY NOT HAVE BEEN SENT"))
        #expect(ContinuousClock.now - started < .seconds(10))
    }

    @Test("The deadline of a call is within the standard's time limit, and the shortcut's own deadlines are inside it")
    func deadlineIsWithinTheTimeLimit() {
        #expect(MessageTools.defaultTimeout <= ToolStandard.timeLimit)
        #expect(
            Duration.seconds(Configuration.shortcutListSeconds + Configuration.shortcutRunSeconds)
                < MessageTools.defaultTimeout)
    }

    // MARK: What the model reads

    @Test("The instructions and every tool description are within the longest a client keeps")
    func textsAreWithinTheLimit() {
        #expect(ToolStandard.overlongTexts(instructions: MessagesMCPServer.instructions, catalog: ToolCatalog.all()).isEmpty)
        #expect(!MessagesMCPServer.instructions.isEmpty)
    }

    @Test("The instructions state the bounds the code enforces")
    func instructionsStateTheBounds() {
        let instructions = MessagesMCPServer.instructions
        #expect(instructions.contains("at most \(Configuration.textWidth) characters"))
        #expect(instructions.contains("stops after \(Configuration.scanLimit) of them"))
        #expect(instructions.contains("after \(MessageTools.defaultTimeout.components.seconds) seconds"))
    }

    @Test("messages_status reports the limits the code enforces")
    func statusStatesTheLimits() async {
        let result = await Self.call(ToolCatalog.statusName, store: FakeMessageStore())
        #expect(!result.isError)
        #expect(result.text.contains("\(Configuration.defaultMessageLimit) by default, \(Configuration.messageLimitRange.upperBound) at most"))
        #expect(result.text.contains("\(Configuration.scanLimit) messages per search"))
        #expect(result.text.contains("\(Configuration.textWidth) characters"))
        #expect(result.text.utf16.count <= ToolStandard.usualPage)
    }

    private func properties(of tool: Tool) -> [String: [String: Value]] {
        guard case .object(let schema) = tool.inputSchema,
            case .object(let properties)? = schema["properties"]
        else { return [:] }
        return properties.compactMapValues(\.objectValue)
    }

    @Test("Every listing's schema states the range and default of limit and offset that the code enforces", arguments: listings)
    private func schemaStatesThePage(_ listing: Listing) throws {
        let tool = try #require(ToolCatalog.all().first { $0.name == listing.tool })
        let limit = try #require(properties(of: tool)["limit"])
        #expect(limit["minimum"]?.intValue == listing.limits.lowerBound)
        #expect(limit["maximum"]?.intValue == listing.limits.upperBound)
        #expect(limit["default"]?.intValue == listing.defaultLimit)
        let offset = try #require(properties(of: tool)["offset"])
        #expect(offset["minimum"]?.intValue == Configuration.offsetRange.lowerBound)
        #expect(offset["maximum"]?.intValue == Configuration.offsetRange.upperBound)
        #expect(offset["default"]?.intValue == 0)
        // The description states the same maximum, taken from the same constant.
        #expect(tool.description?.contains("limit (up to \(listing.limits.upperBound))") == true)
        #expect(tool.description?.contains("\(listing.defaultLimit)") == true)
    }

    @Test("The descriptions state the widths, the ceiling and the maxima the code enforces")
    func descriptionsStateTheBounds() throws {
        func description(_ name: String) throws -> String {
            try #require(ToolCatalog.all().first { $0.name == name }?.description)
        }
        for name in [ToolCatalog.conversationName, ToolCatalog.searchName] {
            #expect(try description(name).contains("at most \(Configuration.textWidth) characters"))
            #expect(try description(name).contains("no tool of this server reads one message in full"))
        }
        #expect(try description(ToolCatalog.searchName).contains("stops after \(Configuration.scanLimit) of them"))
        #expect(try description(ToolCatalog.attachmentsName).contains("up to \(Configuration.maximumMessageIDs) message ids"))
        #expect(try description(ToolCatalog.sendName).contains("first \(Configuration.shortcutOutputWidth) characters"))

        let ids = try #require(properties(of: ToolCatalog.attachments)["message_ids"])
        #expect(ids["maxItems"]?.intValue == Configuration.maximumMessageIDs)
        #expect(ids["minItems"]?.intValue == 1)
    }

    @Test("Every number in a schema has a range, and every default lies inside it")
    func everyNumberHasARange() {
        for tool in ToolCatalog.all() {
            for (name, property) in properties(of: tool) where property["type"]?.stringValue == "integer" {
                guard let minimum = property["minimum"]?.intValue, let maximum = property["maximum"]?.intValue
                else {
                    Issue.record("\(tool.name).\(name) states no range")
                    continue
                }
                if let value = property["default"]?.intValue {
                    #expect((minimum...maximum).contains(value), "\(tool.name).\(name)")
                }
            }
        }
    }

    @Test("Only the standard names page a result and bound it by date")
    func standardArgumentNames() {
        let standard: Set = ["limit", "offset", "from_date", "to_date"]
        let lookalikes: Set = [
            "max", "count", "max_results", "page", "page_size", "skip", "start", "from", "to", "since",
            "until", "before", "after", "start_date", "end_date", "max_chars", "max_length",
            "char_offset", "cursor",
        ]
        var used: Set<String> = []
        for tool in ToolCatalog.all() {
            let names = Set(properties(of: tool).keys)
            #expect(names.isDisjoint(with: lookalikes), "\(tool.name)")
            used.formUnion(names.intersection(standard))
        }
        #expect(used == standard)
    }
}
