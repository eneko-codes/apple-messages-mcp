import Foundation

/// Recovers the plain text of a message from `message.attributedBody`.
///
/// Messages stopped filling the `text` column reliably around macOS 11: the body now
/// arrives as an `NSMutableAttributedString` archived with `NSArchiver`, in the old
/// NeXT *typedstream* format. That format has no public Swift reader — `NSUnarchiver`
/// is `NS_SWIFT_UNAVAILABLE`, and `NSKeyedUnarchiver` cannot read it because it is not a
/// keyed archive — so the string is lifted out of the bytes directly.
///
/// This is a deliberately small reader for one shape, not a typedstream parser. It reads
/// the first C-string the archive declares, which is the attributed string's backing
/// store; everything after it is the attribute run table.
///
/// The layout below was read off archives produced by `NSArchiver` on macOS 26.5:
///
/// ```text
/// 04 0b "streamtyped" 81 e8 03 …           header
/// … 08 "NSString" 01 95                    class chain, ending at NSString
/// 84 01 2b                                 type descriptor: one char, '+' = C string
/// 1e                                       length, 30 bytes
/// 48 6f 6c 61 2c 20 c2 bf …                the UTF-8 body
/// ```
///
/// Integers are variable width and self-describing, which the header proves: `81 e8 03`
/// is the marker `0x81` followed by the little-endian 16-bit 1000, the system version.
/// A 300-character body encodes its length the same way — `2b 81 2c 01`.
public enum AttributedBody {

    /// `0x84 0x01 0x2b` — a one-character type descriptor holding `+`.
    ///
    /// Anchoring on the descriptor rather than on the literal `NSString` is what keeps
    /// this correct: the class chain names `NSMutableString` *and* `NSString`, and the
    /// attribute dictionary that follows the text names both again. The descriptor is
    /// emitted once per encoded value, and the body is the first value encoded.
    private static let cStringMarker: [UInt8] = [0x84, 0x01, 0x2b]

    /// Refuses anything larger than a plausible message body. A blob that decodes to a
    /// megabyte is a misread length, not a text message, and shipping it would put
    /// arbitrary binary into a JSON-RPC response.
    static let maximumTextBytes = 1 << 20

    public static func text(from blob: Data) -> String? {
        let bytes = [UInt8](blob)
        guard let markerEnd = indexAfterMarker(in: bytes) else { return nil }
        guard let (length, textStart) = readLength(bytes, at: markerEnd) else { return nil }
        guard length > 0, length <= maximumTextBytes, textStart + length <= bytes.count
        else { return nil }

        let slice = Data(bytes[textStart..<(textStart + length)])
        // A misread length lands mid-sequence and fails to decode, which is the check
        // that keeps a wrong guess from becoming mojibake in the transcript.
        return String(data: slice, encoding: .utf8)
    }

    private static func indexAfterMarker(in bytes: [UInt8]) -> Int? {
        guard bytes.count > cStringMarker.count else { return nil }
        for index in 0...(bytes.count - cStringMarker.count - 1) {
            if bytes[index] == cStringMarker[0], bytes[index + 1] == cStringMarker[1],
                bytes[index + 2] == cStringMarker[2]
            {
                return index + cStringMarker.count
            }
        }
        return nil
    }

    /// Typedstream's variable-width integer, restricted to the widths a length can use.
    ///
    /// `0x80` is a reference tag and `0x83`/`0x84` introduce floating point, none of
    /// which can be a byte count — reading one means the marker matched something that
    /// is not a string, and returning `nil` is the honest answer.
    private static func readLength(_ bytes: [UInt8], at index: Int) -> (Int, Int)? {
        guard index < bytes.count else { return nil }
        switch bytes[index] {
        case let single where single < 0x80:
            return (Int(single), index + 1)

        case 0x81:
            guard index + 2 < bytes.count else { return nil }
            let value = UInt16(bytes[index + 1]) | UInt16(bytes[index + 2]) << 8
            return (Int(value), index + 3)

        case 0x82:
            guard index + 4 < bytes.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 { value |= UInt32(bytes[index + 1 + offset]) << (8 * offset) }
            return (Int(value), index + 5)

        default:
            return nil
        }
    }
}
