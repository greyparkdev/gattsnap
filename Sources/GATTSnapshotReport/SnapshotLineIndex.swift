import Foundation
import GATTSnapshotCore

/// Maps a position in the attribute table onto a line number in the snapshot
/// file that produced it.
///
/// This exists so a finding can be annotated on the line of the characteristic
/// that actually changed rather than at the top of the file. An annotation that
/// always lands on line 1 is a footnote; one that lands on the characteristic is
/// a review comment, and that difference is most of what makes the pull-request
/// surface worth having at all.
///
/// It deliberately does **not** decode the file. `SnapshotCoding` already did
/// that, and the caller already holds the resulting `AttributeTable` — which is
/// what turns an `AttributePath` into array indices. All that is missing is
/// where each array element begins in the text, so this only skims structure and
/// counts newlines. Two small jobs beat one parser that has to do both.
public struct SnapshotLineIndex: Sendable {

    /// Keyed by a dotted path with numeric array indices, e.g.
    /// `table.services.1.characteristics.0`. The value is the 1-based line on
    /// which that value begins.
    private let linesByPath: [String: Int]

    public init(snapshotText: String) {
        var skimmer = Skimmer(bytes: Array(snapshotText.utf8))
        linesByPath = skimmer.skim()
    }

    /// The line of the deepest element of `path` that still exists in `table`.
    ///
    /// The fallback chain is the point of this method, not an edge case. Roughly
    /// half of all findings are *removals*, and a removed attribute by
    /// definition has no line in the head snapshot. Walking outward to the
    /// nearest surviving ancestor puts `characteristic_removed` on the service
    /// it was removed from, which is where a reviewer needs to look.
    ///
    /// Returns `nil` only when the file has no `table` key at all, which means
    /// it is not a snapshot.
    public func line(for path: AttributePath, in table: AttributeTable) -> Int? {
        let tableLine = linesByPath["table"]

        guard let serviceIndex = table.services.firstIndex(where: {
            $0.uuid == path.service && $0.instance == path.serviceInstance
        }) else { return tableLine }

        let servicePath = "table.services.\(serviceIndex)"
        let serviceLine = anchor(servicePath) ?? tableLine

        guard let characteristicUUID = path.characteristic else { return serviceLine }

        let characteristics = table.services[serviceIndex].characteristics
        guard let characteristicIndex = characteristics.firstIndex(where: {
            $0.uuid == characteristicUUID && $0.instance == (path.characteristicInstance ?? 0)
        }) else { return serviceLine }

        let characteristicPath = "\(servicePath).characteristics.\(characteristicIndex)"
        let characteristicLine = anchor(characteristicPath) ?? serviceLine

        guard let descriptorUUID = path.descriptor else { return characteristicLine }

        let descriptors = characteristics[characteristicIndex].descriptors
        guard let descriptorIndex = descriptors.firstIndex(where: {
            $0.uuid == descriptorUUID && $0.instance == (path.descriptorInstance ?? 0)
        }) else { return characteristicLine }

        return anchor("\(characteristicPath).descriptors.\(descriptorIndex)")
            ?? characteristicLine
    }

    /// Prefers an attribute's `uuid` line over its opening brace.
    ///
    /// GitHub shows the annotated line's text next to the message. `{` tells a
    /// reviewer nothing; `"uuid" : "A1A1…"` tells them which attribute this is
    /// about without leaving the annotation. The brace remains the fallback for
    /// a snapshot whose object has no `uuid` key.
    private func anchor(_ objectPath: String) -> Int? {
        linesByPath["\(objectPath).uuid"] ?? linesByPath[objectPath]
    }

    /// Exposed for tests and for callers that want to annotate a fixed key such
    /// as `adapter` or `structure_hash`.
    public func line(forKeyPath keyPath: String) -> Int? {
        linesByPath[keyPath]
    }
}

// MARK: - Structural skim

/// A JSON reader that extracts nothing but "where does each value begin".
///
/// It works on UTF-8 bytes. Multi-byte scalars only ever appear inside string
/// literals, which are skipped wholesale, and every continuation byte is `>=
/// 0x80` — so no multi-byte sequence can be mistaken for a structural character.
///
/// Malformed input cannot hang it: every branch consumes at least one byte and
/// every loop is bounded by the end of the buffer. A truncated or hand-mangled
/// file yields a partial index, and a partial index degrades to a coarser
/// annotation rather than to a crash.
private struct Skimmer {
    let bytes: [UInt8]
    var index = 0
    var line = 1
    var result: [String: Int] = [:]

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    mutating func skim() -> [String: Int] {
        skimValue(path: "")
        return result
    }

    private mutating func skimValue(path: String) {
        skipWhitespace()
        guard index < bytes.count else { return }
        result[path] = line

        switch bytes[index] {
        case UInt8(ascii: "{"): skimObject(path: path)
        case UInt8(ascii: "["): skimArray(path: path)
        case UInt8(ascii: "\""): skipString()
        default: skipLiteral()
        }
    }

    private mutating func skimObject(path: String) {
        index += 1 // '{'
        while index < bytes.count {
            skipWhitespace()
            guard index < bytes.count else { return }
            switch bytes[index] {
            case UInt8(ascii: "}"):
                index += 1
                return
            case UInt8(ascii: ","):
                index += 1
                continue
            case UInt8(ascii: "\""):
                let key = readString()
                skipWhitespace()
                guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { return }
                index += 1
                skimValue(path: path.isEmpty ? key : "\(path).\(key)")
            default:
                // Not valid JSON. Consume so the loop still terminates.
                index += 1
            }
        }
    }

    private mutating func skimArray(path: String) {
        index += 1 // '['
        var element = 0
        while index < bytes.count {
            skipWhitespace()
            guard index < bytes.count else { return }
            switch bytes[index] {
            case UInt8(ascii: "]"):
                index += 1
                return
            case UInt8(ascii: ","):
                index += 1
            default:
                skimValue(path: "\(path).\(element)")
                element += 1
            }
        }
    }

    /// Reads a string literal and returns its contents.
    ///
    /// Only `\"` and `\\` need real handling: any other escape cannot terminate
    /// the literal, and object keys in this schema are plain ASCII, so the
    /// returned text is used as-is rather than unescaped.
    private mutating func readString() -> String {
        index += 1 // opening quote
        let start = index
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if byte == UInt8(ascii: "\"") {
                let text = String(decoding: bytes[start..<index], as: UTF8.self)
                index += 1
                return text
            }
            if byte == UInt8(ascii: "\n") { line += 1 }
            index += 1
        }
        return String(decoding: bytes[start...], as: UTF8.self)
    }

    private mutating func skipString() {
        _ = readString()
    }

    /// Numbers, `true`, `false`, `null` — anything that ends at a delimiter.
    private mutating func skipLiteral() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"):
                return
            case UInt8(ascii: "\n"):
                return
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                return
            default:
                index += 1
            }
        }
    }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case UInt8(ascii: "\n"):
                line += 1
                index += 1
            case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\r"):
                index += 1
            default:
                return
            }
        }
    }
}
