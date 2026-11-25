import Foundation

/// Plain-text rendering of every tool result.
public struct Format: Sendable {
    let calendar: Calendar

    public init(calendar: Calendar) {
        self.calendar = calendar
    }

    // MARK: Helpers

    static func pad(_ text: String, to width: Int) -> String {
        let shortfall = width - text.count
        return shortfall > 0 ? text + String(repeating: " ", count: shortfall) : text
    }

    static func block(_ rows: [(String, String?)]) -> String {
        let present = rows.compactMap { label, value -> (String, String)? in
            guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return (label, value)
        }
        guard let width = present.map(\.0.count).max() else { return "" }
        let indent = String(repeating: " ", count: width + 3)
        return present.map { label, value in
            let wrapped = value.split(separator: "\n", omittingEmptySubsequences: false)
                .joined(separator: "\n" + indent)
            return "  \(pad(label, to: width)) \(wrapped)"
        }.joined(separator: "\n")
    }

    /// A body on one line, however many it was written on.
    static func flattened(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
    }

    /// Collapses a text onto one line of at most `width` characters for a list row.
    ///
    /// A message can be a paragraph. The one-line-per-result contract is what makes a
    /// page of results scannable, and what keeps a page of rows inside a result.
    static func oneLine(_ text: String, width: Int) -> String {
        let flattened = flattened(text)
        guard flattened.count > width else { return flattened }
        return String(flattened.prefix(width - 1)) + "…"
    }

    /// Whether a row shows less than the whole text of this message.
    static func isClipped(_ record: MessageRecord) -> Bool {
        flattened(body(of: record)).count > Configuration.textWidth
    }

    /// Goes before the rows when one of them shows less than its whole text.
    ///
    /// Its own wording, not `Notice.clipped`: that form names the tool that reads one item
    /// in full, and this server has none. Until it does, the sentence says so, because a
    /// reader told only that text was clipped would go looking for the rest.
    static let clippedNotice = """
        Text is clipped to \(Configuration.textWidth) characters in each row. No tool of \
        this server reads one message in full.
        """

    /// What a listing shows in place of rows, so that "nothing matched" is never taken
    /// for "nothing at this offset".
    static func nothing(_ none: String, matching: Int) -> String {
        matching == 0 ? none : "(nothing at this offset)"
    }

    static func plural(_ count: Int, _ noun: String) -> String {
        "\(count) \(noun)\(count == 1 ? "" : "s")"
    }

    func timestamp(_ date: Date?) -> String {
        guard let date else { return "(no date)" }
        return DateParsing.day(date, calendar: calendar) + " "
            + DateParsing.time(date, calendar: calendar)
    }

    func timestampWithYear(_ date: Date?) -> String {
        guard let date else { return "(no date)" }
        return DateParsing.dayWithYear(date, calendar: calendar) + " "
            + DateParsing.time(date, calendar: calendar)
    }

    /// What a row without text actually is, so a blank line is never mistaken for a bug.
    static func placeholder(for record: MessageRecord) -> String {
        if record.hasAttachments { return "(attachment only)" }
        if record.associatedMessageType != 0 {
            return "(reaction or edit marker, type \(record.associatedMessageType))"
        }
        return "(no text — rich payload, sticker or app message)"
    }

    static func body(of record: MessageRecord) -> String {
        guard let text = record.text, !text.isEmpty else { return placeholder(for: record) }
        return text
    }

    // MARK: Tools

    public func status(_ status: StoreStatus, binaryPath: String) -> String {
        var lines = ["apple-messages-mcp \(MessagesMCPServer.version)"]

        lines.append("")
        lines.append("READ · local Messages database")
        lines.append(
            Self.block([
                ("access", ToolError.accessMessage(status.access).split(separator: "\n").first.map(String.init)),
                ("database", status.databasePath),
                ("opened", status.openedReadOnly ? "read-only, through the write-ahead log (never writes)" : "READ-WRITE — this is a bug"),
                ("date unit", status.dateUnit?.rawValue),
                ("conversations", status.conversationCount.map(String.init)),
                ("messages", status.messageCount.map(String.init)),
                ("attachments", status.attachmentCount.map(String.init)),
                ("newest", status.newestMessageDate.map { timestampWithYear($0) }),
                ("write-ahead log", status.walBytes.map { "\($0) bytes, read on every call" }),
            ]))

        lines.append("")
        lines.append("SEND · Shortcuts")
        let installed: String =
            switch status.sendShortcutInstalled {
            case true: "installed"
            case false: "NOT INSTALLED — send_message will refuse"
            case nil: "could not be checked (is /usr/bin/shortcuts present?)"
            }
        lines.append(
            Self.block([
                ("shortcut required", "\(Configuration.sendShortcutName) · \(installed)"),
                ("gated by", "this tool's permission switch in Claude Desktop"),
            ]))

        lines.append("")
        lines.append("LIMITS")
        func page(_ fallback: Int, _ range: ClosedRange<Int>) -> String {
            "\(fallback) by default, \(range.upperBound) at most"
        }
        lines.append(
            Self.block([
                ("conversations per page", page(Configuration.defaultConversationLimit, Configuration.conversationLimitRange)),
                ("messages per page", page(Configuration.defaultMessageLimit, Configuration.messageLimitRange)),
                ("attachments per page", page(Configuration.defaultAttachmentLimit, Configuration.attachmentLimitRange)),
                ("text shown per message", "\(Configuration.textWidth) characters"),
                ("scan ceiling", "\(Configuration.scanLimit) messages per search"),
                ("max send length", "\(Configuration.maximumSendCharacters) characters"),
                ("call deadline", "\(MessageTools.defaultTimeout.components.seconds) seconds"),
            ]))

        lines.append("")
        lines.append("  binary  \(binaryPath)")

        if !status.access.isUsable {
            lines.append("")
            lines.append(ToolError.accessMessage(status.access))
        }
        return lines.joined(separator: "\n")
    }

    /// `rows` is the page, `total` every conversation that matched.
    public func conversations(_ rows: [Conversation], total: Int, query: String?) -> String {
        let scope = query.map { " matching \"\(ToolStandard.echo($0))\"" } ?? ""
        let header = "Conversations\(scope): \(total), ordered by latest message (newest first), then highest id."
        guard !rows.isEmpty else {
            let none =
                query == nil
                ? "Messages holds no conversations."
                : "Nothing matched. conversations_list with no query lists them all."
            return header + "\n" + Self.nothing(none, matching: total)
        }

        let whenWidth = rows.map { timestamp($0.lastMessageDate).count }.max() ?? 0
        // Never cut: this list is the only place a conversation's name and participants
        // are shown, so a clipped one could not be read anywhere else.
        let labels = rows.map { Self.flattened($0.label) }
        let labelWidth = min(labels.map(\.count).max() ?? 0, Configuration.labelColumnWidth)

        var lines = [header]
        for (conversation, label) in zip(rows, labels) {
            var line = Self.pad(timestamp(conversation.lastMessageDate), to: whenWidth)
            line += "  " + Self.pad(label, to: labelWidth)
            line += "  " + (conversation.isGroup ? "group" : "1:1  ")
            line += "  " + Self.pad("\(conversation.messageCount) msg", to: 10)
            if conversation.unreadCount > 0 { line += "  \(conversation.unreadCount) unread" }
            if let service = conversation.serviceName, !service.isEmpty { line += "  \(service)" }
            line += "  id=\(conversation.id)"
            // A named conversation's label is its name, so who is in it goes last.
            if let name = conversation.displayName, !name.isEmpty, !conversation.participants.isEmpty {
                line += "  with " + conversation.participants.joined(separator: ", ")
            }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    /// Newest first, and it says so — a transcript printed in the opposite order to the
    /// one a reader expects is read wrongly before anyone notices the header. `rows` is
    /// the page, `total` every message of the thread.
    public func conversationPage(_ rows: [MessageRecord], conversationID: Int64, total: Int) -> String {
        let label = rows.first?.chatLabel.map { Self.flattened($0) }
        let header =
            "\(label ?? "conversation \(conversationID)") · id=\(conversationID) · "
            + "\(Self.plural(total, "message")), ordered newest first, then highest id."

        guard !rows.isEmpty else {
            return header + "\n" + Self.nothing("This conversation has no messages.", matching: total)
        }

        var lines = [header]
        let whenWidth = rows.map { timestamp($0.date).count }.max() ?? 0
        let whoWidth = Self.senderColumn(rows)

        for record in rows {
            var line = Self.pad(timestamp(record.date), to: whenWidth)
            line += "  " + Self.pad(Self.who(record), to: whoWidth)
            line += "  " + Self.oneLine(Self.body(of: record), width: Configuration.textWidth)
            if record.hasAttachments { line += "  📎" }
            if record.dateEdited != nil { line += "  (edited)" }
            lines.append(line + "  id=\(record.id)")
        }
        return lines.joined(separator: "\n")
    }

    /// The sender's address whole, however long: it is what `participant` takes.
    static func who(_ record: MessageRecord) -> String {
        if record.isFromMe { return "me" }
        return record.handle.map { flattened($0) } ?? "them"
    }

    static func senderColumn(_ rows: [MessageRecord]) -> Int {
        min(rows.map { who($0).count }.max() ?? 0, Configuration.senderColumnWidth)
    }

    /// `rows` is the page; `page` says how the scan that found it went.
    public func searchResults(_ rows: [MessageRecord], page: MessagePage, filter: MessageFilter) -> String {
        var criteria: [String] = []
        if let query = filter.query { criteria.append("text \"\(ToolStandard.echo(query))\"") }
        if let participant = filter.participant {
            criteria.append("with \(ToolStandard.echo(participant))")
        }
        if let chatID = filter.chatID { criteria.append("in conversation \(chatID)") }
        if let from = filter.from {
            criteria.append("from \(DateParsing.roundTrip(from, calendar: calendar))")
        }
        if let to = filter.to {
            criteria.append("before \(DateParsing.roundTrip(to, calendar: calendar))")
        }
        if let hasAttachment = filter.hasAttachment {
            criteria.append(hasAttachment ? "with attachments" : "without attachments")
        }
        if let service = filter.service { criteria.append("service \(ToolStandard.echo(service))") }
        if let fromMe = filter.fromMe { criteria.append(fromMe ? "sent by me" : "received") }

        var scan = "Scanned \(Self.plural(page.scanned, "message"))"
        if let oldest = page.oldestScanned {
            scan += " back to \(DateParsing.roundTrip(oldest, calendar: calendar))"
        }
        var lines = [
            "Messages: \(rows.count) shown · "
                + (criteria.isEmpty ? "no filters" : criteria.joined(separator: " · "))
                + " · times in \(calendar.timeZone.identifier)",
            "\(scan). Ordered newest first, then highest id.",
        ]

        guard !rows.isEmpty else {
            // With no total the scan stopped on a match past this page, so some matched.
            lines.append(Self.nothing("No messages matched.", matching: page.total ?? 1))
            return lines.joined(separator: "\n")
        }

        let whenWidth = rows.map { timestampWithYear($0.date).count }.max() ?? 0
        let whoWidth = Self.senderColumn(rows)

        for record in rows {
            var line = Self.pad(timestampWithYear(record.date), to: whenWidth)
            line += "  " + Self.pad(Self.who(record), to: whoWidth)
            if let label = record.chatLabel, !label.isEmpty {
                line += "  [" + Self.flattened(label) + "]"
            }
            line += "  " + Self.oneLine(Self.body(of: record), width: Configuration.textWidth)
            if record.hasAttachments { line += "  📎" }
            lines.append(line + "  id=\(record.id)")
        }
        return lines.joined(separator: "\n")
    }

    /// `rows` is the page, `total` every attachment on the `requested` messages.
    public func attachments(_ rows: [AttachmentRecord], total: Int, requested: Int) -> String {
        let header =
            "Attachments: \(total) on \(Self.plural(requested, "message")) given, "
            + "ordered by message id, then attachment id."
        guard !rows.isEmpty else {
            let none = requested == 1
                ? "That message has no attachment." : "None of those messages has an attachment."
            return header + "\n" + Self.nothing(none, matching: total)
        }

        var lines = [header]
        for record in rows {
            let size = record.totalBytes > 0 ? Self.bytes(record.totalBytes) : "size unknown"
            var fields: [(String, String?)] = [
                ("message", String(record.messageID)),
                ("name", record.transferName),
                ("type", [record.mimeType, record.uti].compactMap { $0 }.joined(separator: " · ")),
                ("size", size),
                ("direction", record.isOutgoing ? "sent" : "received"),
                ("created", record.createdDate.map { timestampWithYear($0) }),
                ("path", record.path),
            ]
            if !record.existsOnDisk {
                // Common: iCloud offloads old attachments and leaves the row behind.
                fields.append(("on disk", "NO — the file is gone or offloaded to iCloud"))
            }
            lines.append("")
            lines.append(Self.block(fields))
        }
        lines.append("")
        lines.append(
            "Reading an attachment needs the same Full Disk Access the database does; this "
                + "server lists them and never copies one.")
        return lines.joined(separator: "\n")
    }

    static func bytes(_ count: Int64) -> String {
        let units = ["B", "KB", "MB", "GB"]
        var value = Double(count)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0
            ? "\(count) B" : String(format: "%.1f %@", value, units[index])
    }

    /// The receipt repeats the text that was sent and what the shortcut printed. Both are
    /// windows from the start, shrunk together when the receipt would not fit a result:
    /// characters that take many UTF-16 units each can make even a short text long.
    ///
    /// Neither window can be continued, so each says why in its own words, where
    /// `Notice.window` would name an argument to pass: this tool has none, and a second
    /// call would send a second message.
    public func sent(_ receipt: SendReceipt) -> String {
        let outputTotal = receipt.output?.count ?? 0
        let widest = max(receipt.text.count, min(outputTotal, Configuration.shortcutOutputWidth), 1)
        return ToolStandard.fitting(widest) { size in
            let text = String(receipt.text.prefix(size))
            let output = receipt.output.map {
                String($0.prefix(min(size, Configuration.shortcutOutputWidth)))
            }
            var notices: [String] = []
            if text.count < receipt.text.count {
                notices.append(
                    "Text: characters 1–\(text.count) of \(receipt.text.count). All of it was "
                        + "sent; the rest is the text given in the call.")
            }
            if let output, output.count < outputTotal {
                notices.append(
                    "Shortcut output: characters 1–\(output.count) of \(outputTotal). The rest "
                        + "cannot be read: calling send_message again would send the message again.")
            }

            var lines = ["Sent. This cannot be recalled."]
            lines.append("")
            lines.append(
                Self.block([
                    ("to", receipt.recipient),
                    ("via", "shortcut \"\(receipt.shortcutName)\""),
                    ("text", text),
                    ("shortcut said", output),
                ]))
            lines.append("")
            lines.append(
                "Whether it arrived is Messages' business, not this server's — check the "
                    + "conversation in Messages if delivery matters.")
            return ToolStandard.withNotices(notices, lines.joined(separator: "\n"))
        }
    }
}
