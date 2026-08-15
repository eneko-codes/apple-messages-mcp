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

    /// Collapses a body onto one line for a list row.
    ///
    /// A message can be a paragraph. The one-line-per-result contract is what makes a
    /// page of results scannable, and the full text is one `conversation_get` away.
    static func oneLine(_ text: String, limit: Int = 120) -> String {
        let flattened = text.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ⏎ ")
        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit - 1)) + "…"
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
                ("opened", status.openedReadOnly ? "read-only, immutable (never writes, never locks)" : "READ-WRITE — this is a bug"),
                ("date unit", status.dateUnit?.rawValue),
                ("conversations", status.conversationCount.map(String.init)),
                ("messages", status.messageCount.map(String.init)),
                ("attachments", status.attachmentCount.map(String.init)),
                ("newest", status.newestMessageDate.map { timestampWithYear($0) }),
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
        lines.append(
            Self.block([
                ("search limit", String(Configuration.searchLimit)),
                ("scan ceiling", String(Configuration.scanLimit)),
                ("max send length", "\(Configuration.maximumSendCharacters) characters"),
            ]))

        lines.append("")
        lines.append("  binary  \(binaryPath)")

        if !status.access.isUsable {
            lines.append("")
            lines.append(ToolError.accessMessage(status.access))
        }
        return lines.joined(separator: "\n")
    }

    public func conversations(_ page: ConversationPage, offset: Int, query: String?) -> String {
        let scope = query.map { " · matching \"\($0)\"" } ?? ""
        let header = "\(page.total) conversation\(page.total == 1 ? "" : "s")\(scope)"
        guard !page.conversations.isEmpty else {
            return header + "\nNothing matched. conversations_list with no query lists them all."
        }

        let whenWidth = page.conversations.map { timestamp($0.lastMessageDate).count }.max() ?? 0
        let labelWidth = min(page.conversations.map(\.label.count).max() ?? 0, 44)

        var lines = [header]
        for conversation in page.conversations {
            var line = Self.pad(timestamp(conversation.lastMessageDate), to: whenWidth)
            line += "  " + Self.pad(Self.oneLine(conversation.label, limit: 44), to: labelWidth)
            line += "  " + (conversation.isGroup ? "group" : "1:1  ")
            line += "  " + Self.pad("\(conversation.messageCount) msg", to: 10)
            if conversation.unreadCount > 0 { line += "  \(conversation.unreadCount) unread" }
            if let service = conversation.serviceName, !service.isEmpty { line += "  \(service)" }
            lines.append(line + "  id=\(conversation.id)")
        }

        let shown = offset + page.conversations.count
        if shown < page.total {
            lines.append("…\(page.total - shown) more · call again with offset=\(shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// Newest first, and it says so — a transcript printed in the opposite order to the
    /// one a reader expects is read wrongly before anyone notices the header.
    public func conversationPage(
        _ page: MessagePage, conversationID: Int64, offset: Int, limit: Int
    ) -> String {
        let label = page.messages.first?.chatLabel ?? "conversation \(conversationID)"
        var header = "\(label) · id=\(conversationID)"
        if let total = page.total { header += " · \(total) messages" }
        header += " · newest first"

        guard !page.messages.isEmpty else {
            return header + "\n" + (offset > 0
                ? "Nothing at offset \(offset); the thread is shorter than that."
                : "This conversation has no messages.")
        }

        var lines = [header]
        let whenWidth = page.messages.map { timestamp($0.date).count }.max() ?? 0
        let whoWidth = page.messages.map { Self.who($0).count }.max() ?? 0

        for record in page.messages {
            var line = Self.pad(timestamp(record.date), to: whenWidth)
            line += "  " + Self.pad(Self.who(record), to: whoWidth)
            line += "  " + Self.oneLine(Self.body(of: record), limit: 160)
            if record.hasAttachments { line += "  📎" }
            if record.dateEdited != nil { line += "  (edited)" }
            lines.append(line + "  id=\(record.id)")
        }

        if let total = page.total {
            let shown = offset + page.messages.count
            if shown < total {
                lines.append(
                    "…\(total - shown) older · call again with offset=\(shown) (limit \(limit))")
            }
        }
        return lines.joined(separator: "\n")
    }

    static func who(_ record: MessageRecord) -> String {
        if record.isFromMe { return "me" }
        return record.handle ?? "them"
    }

    public func searchResults(
        _ page: MessagePage, filter: MessageFilter, offset: Int, scanLimit: Int
    ) -> String {
        var criteria: [String] = []
        if let query = filter.query { criteria.append("text \"\(query)\"") }
        if let participant = filter.participant { criteria.append("with \(participant)") }
        if let chatID = filter.chatID { criteria.append("in conversation \(chatID)") }
        if let from = filter.from {
            criteria.append("from \(DateParsing.roundTrip(from, calendar: calendar))")
        }
        if let to = filter.to {
            criteria.append("to \(DateParsing.roundTrip(to, calendar: calendar))")
        }
        if let hasAttachment = filter.hasAttachment {
            criteria.append(hasAttachment ? "with attachments" : "without attachments")
        }
        if let service = filter.service { criteria.append("service \(service)") }
        if let fromMe = filter.fromMe { criteria.append(fromMe ? "sent by me" : "received") }

        let header =
            "\(page.messages.count) match\(page.messages.count == 1 ? "" : "es") · "
            + (criteria.isEmpty ? "no filters" : criteria.joined(separator: " · "))
            + " · \(calendar.timeZone.identifier) · scanned \(page.scanned) rows"

        guard !page.messages.isEmpty else {
            var empty = [header, "No messages matched."]
            if page.hitScanCeiling {
                empty.append(
                    "The scan stopped at \(scanLimit) rows before reaching the end of the "
                        + "archive, so older matches may exist. Narrow it with participant, "
                        + "conversation_id or a date range.")
            }
            return empty.joined(separator: "\n")
        }

        var lines = [header]
        let whenWidth = page.messages.map { timestampWithYear($0.date).count }.max() ?? 0
        let whoWidth = page.messages.map { Self.who($0).count }.max() ?? 0

        for record in page.messages {
            var line = Self.pad(timestampWithYear(record.date), to: whenWidth)
            line += "  " + Self.pad(Self.who(record), to: whoWidth)
            if let label = record.chatLabel, !label.isEmpty {
                line += "  [" + Self.oneLine(label, limit: 28) + "]"
            }
            line += "  " + Self.oneLine(Self.body(of: record), limit: 140)
            if record.hasAttachments { line += "  📎" }
            lines.append(line + "  id=\(record.id)")
        }

        // A truncated answer that does not say it is truncated is a wrong answer.
        if page.hitScanCeiling {
            lines.append(
                "…the scan stopped at \(scanLimit) rows, so this is the newest slice of the "
                    + "archive and not all of it. Narrow the filters or page with offset.")
        } else if page.messages.count >= 1 {
            lines.append(
                "Page starts at offset \(offset). More may exist: call again with "
                    + "offset=\(offset + page.messages.count).")
        }
        return lines.joined(separator: "\n")
    }

    public func attachments(_ records: [AttachmentRecord], requested: [Int64]) -> String {
        guard !records.isEmpty else {
            return
                "No attachments on message\(requested.count == 1 ? "" : "s") "
                + requested.map(String.init).joined(separator: ", ") + "."
        }

        var lines = ["\(records.count) attachment\(records.count == 1 ? "" : "s")"]
        for record in records {
            let size = record.totalBytes > 0 ? Self.bytes(record.totalBytes) : "size unknown"
            var rows: [(String, String?)] = [
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
                rows.append(("on disk", "NO — the file is gone or offloaded to iCloud"))
            }
            lines.append("")
            lines.append(Self.block(rows))
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

    public func sent(_ receipt: SendReceipt) -> String {
        var lines = ["Sent. This cannot be recalled."]
        lines.append("")
        lines.append(
            Self.block([
                ("to", receipt.recipient),
                ("via", "shortcut \"\(receipt.shortcutName)\""),
                ("text", receipt.text),
                ("shortcut said", receipt.output),
            ]))
        lines.append("")
        lines.append(
            "Whether it arrived is Messages' business, not this server's — check the "
                + "conversation in Messages if delivery matters.")
        return lines.joined(separator: "\n")
    }
}
