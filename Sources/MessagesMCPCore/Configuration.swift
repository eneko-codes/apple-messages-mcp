import Foundation

/// What used to be settings the person installing the extension could change, before the
/// owner's plug-and-play rule removed "Who Claude may message", "Shortcut that sends the
/// message" and "Default results" from the connector's settings entirely: only the
/// per-tool allow/ask/prohibit switch in Claude Desktop controls this server now.
public enum Configuration {

    /// The shortcut `send_message` runs. Fixed, not configurable: a shortcut cannot be
    /// installed programmatically — macOS has no import API — so whoever wants sending
    /// has to build one by exactly this name. Documented in the README.
    public static let sendShortcutName = "Claude Send Message"

    // MARK: Pages
    //
    // Each maximum is a number of rows of ordinary width that fits
    // `ToolStandard.longestResult` with room to spare, and each default makes a call with
    // no optional argument about `ToolStandard.usualPage` or less. `BoundsTests` renders a
    // full page of the widest ordinary rows of every listing to hold both to that.

    /// Rows a listing may skip. One range for every tool that pages, so the advertised
    /// schema and the value the code uses cannot drift: both read this.
    public static let offsetRange = 0...10_000_000

    public static let conversationLimitRange = 1...200
    public static let defaultConversationLimit = 50

    /// For `conversation_get` and `messages_search`, whose rows carry a message's text.
    public static let messageLimitRange = 1...100
    public static let defaultMessageLimit = 30

    public static let attachmentLimitRange = 1...50
    public static let defaultAttachmentLimit = 20

    /// The most message ids `message_attachments` takes in one call: two full pages of
    /// messages. A longer list is refused, never shortened, because the ids left out would
    /// be messages the caller believes were looked at.
    public static let maximumMessageIDs = 2 * messageLimitRange.upperBound

    /// A row id. The upper end is the largest whole number every JSON client carries
    /// exactly; a value outside the range is refused, never moved to a neighbouring row.
    public static let identifierRange = 1...9_007_199_254_740_991

    // MARK: Widths

    /// How much of a message's text a row shows. The only field a row clips, and a result
    /// says so when it did.
    public static let textWidth = 160

    /// The widest the name and the sender columns are padded to. A longer value is shown
    /// whole and pushes the rest of its row to the right: a name or an address is never
    /// cut, because no other tool would return the rest of it.
    public static let labelColumnWidth = 44
    public static let senderColumnWidth = 40

    /// How much of what the shortcut printed a send receipt shows. The rest cannot be
    /// asked for again: a second call would send a second message.
    public static let shortcutOutputWidth = 2_000

    /// How much of another program's error text (SQLite, the `shortcuts` tool) an error
    /// repeats.
    public static let errorDetailWidth = 1_000

    // MARK: Scan and time

    /// How many rows a single search may read before it stops and says so.
    ///
    /// A text query cannot be pushed into SQL: bodies now live in `attributedBody`, a
    /// binary archive SQL cannot look inside, so matching happens in Swift after decoding.
    /// The ceiling bounds that scan. Newest rows are read first, so hitting it means "the
    /// newest N matches", never "no matches".
    public static let scanLimit = 20_000

    /// How long `shortcuts list` and `shortcuts run` may take before they are stopped. A
    /// send does both, so their sum has to stay inside `MessageTools.defaultTimeout`.
    public static let shortcutListSeconds = 10
    public static let shortcutRunSeconds = 30

    // MARK: Sending

    /// Longest body `send_message` will hand to Shortcuts. Not a protocol limit — a
    /// guard against a runaway generation being delivered to a real person's phone.
    public static let maximumSendCharacters = 4_000

    /// Longest recipient `send_message` accepts, well past any phone number or email
    /// address. Anything longer is a mistake, and the receipt repeats the recipient.
    public static let maximumRecipientCharacters = 320

    /// Normalises a phone-shaped address for comparison, used by the `participant` search
    /// filter to match a handle however Messages happens to have stored it. Case is
    /// ignored, and a value written like a phone number is compared on its digits so that
    /// `+34 600 111 222` and `+34600111222` are the same handle. `600111222` is *not* the
    /// same as `+34600111222` — inferring a country code is a guess this server does not
    /// make.
    static func normalizeRecipient(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let telephoneCharacters = CharacterSet(charactersIn: "+0123456789 -()./")
        if !trimmed.isEmpty,
            trimmed.unicodeScalars.allSatisfy({ telephoneCharacters.contains($0) })
        {
            let digits = trimmed.filter { $0.isNumber }
            let leadingPlus = trimmed.hasPrefix("+") ? "+" : ""
            return leadingPlus + digits
        }
        return trimmed.lowercased()
    }
}
