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

    /// Default page size for the search tools. A tool's own `limit` still wins.
    public static let searchLimit = 50

    /// How many rows a single search may read before it stops and says so.
    ///
    /// A text query cannot be pushed into SQL: bodies now live in `attributedBody`, a
    /// binary archive SQL cannot look inside, so matching happens in Swift after decoding.
    /// The ceiling bounds that scan. Newest rows are read first, so hitting it means "the
    /// newest N matches", never "no matches".
    public static let scanLimit = 20_000

    public static let searchLimitRange = 1...200

    /// Paging ceiling. Declared here so the advertised schema and the enforced clamp
    /// cannot drift: both read this one value.
    public static let offsetRange = 0...100_000

    /// Longest body `send_message` will hand to Shortcuts. Not a protocol limit — a
    /// guard against a runaway generation being delivered to a real person's phone.
    public static let maximumSendCharacters = 4_000

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
