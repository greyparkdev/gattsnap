import Foundation
import GATTSnapshotCore

/// Renders scan results.
///
/// The job is not "list Bluetooth devices" — plenty of tools do that. It is
/// "tell me the exact `capture` command for the thing on my desk", so the
/// output leads with signal strength and ends with a copy-pasteable command.
public enum ScanRenderer {

    public static func render(_ results: [DiscoveredPeripheral],
                              format: OutputFormat,
                              hiddenCount: Int,
                              useColor: Bool) throws -> String {
        switch format {
        case .human, .junit, .github, .markdown:
            // Only human and json mean anything for a scan; the diff-report
            // formats fall back rather than fail, since a user passing a global
            // --format should still get something useful. `scan` rejects them at
            // the argument level, so this is a backstop, not the primary guard.
            human(results, hiddenCount: hiddenCount, useColor: useColor)
        case .json:
            try json(results, hiddenCount: hiddenCount)
        }
    }

    // MARK: - Human

    static func human(_ results: [DiscoveredPeripheral],
                      hiddenCount: Int,
                      useColor: Bool) -> String {
        func paint(_ text: String, _ code: String) -> String {
            useColor ? "\u{001B}[\(code)m\(text)\u{001B}[0m" : text
        }

        guard !results.isEmpty else {
            var out = "No connectable peripherals found.\n"
            if hiddenCount > 0 {
                out += "\(hiddenCount) non-connectable advertiser(s) hidden — pass --all to show them.\n"
            }
            out += "\nIf your device should be here: check it is powered, in range, "
                 + "and not already connected to something else.\n"
            return out
        }

        let nameWidth = max(4, min(32, results.compactMap { $0.matchableName?.count }.max() ?? 4))
        var lines: [String] = []
        lines.append(paint(
            "\("RSSI".padding(toLength: 5, withPad: " ", startingAt: 0))  "
            + "\("NAME".padding(toLength: nameWidth, withPad: " ", startingAt: 0))  "
            + "IDENTIFIER", "1"))

        for entry in results {
            let rssi = entry.rssi.map { "\($0)" } ?? "?"
            let name = sanitizedForTerminal(entry.matchableName ?? "<no name>")
            let truncated = name.count > nameWidth
                ? String(name.prefix(nameWidth - 1)) + "…"
                : name.padding(toLength: nameWidth, withPad: " ", startingAt: 0)

            // Signal is the whole point of the ordering, so make it scannable.
            let signalColor = switch entry.rssi {
            case .some(let value) where value >= -60: "32"  // green: on your desk
            case .some(let value) where value >= -80: "33"  // yellow: same room
            default: "2"                                     // dim: far or unknown
            }

            var line = paint(rssi.padding(toLength: 5, withPad: " ", startingAt: 0), signalColor)
                + "  " + (entry.matchableName == nil ? paint(truncated, "2") : truncated)
                + "  " + paint(sanitizedForTerminal(entry.identifier), "2")
            if entry.isConnectable == false { line += paint("  [not connectable]", "31") }
            lines.append(line)

            // A cached name that differs is the trap from platform-notes §4:
            // the OS remembers an old name, so searching for it fails.
            if let cached = entry.cachedName,
               let advertised = entry.advertisedLocalName,
               cached != advertised {
                lines.append(paint("       OS-cached name differs: '\(sanitizedForTerminal(cached))' — "
                                   + "match on the advertised name above", "2"))
            }
            if !entry.serviceUUIDs.isEmpty {
                lines.append(paint("       services: "
                                   + entry.serviceUUIDs.map(\.value).joined(separator: ", "), "2"))
            }
        }

        var out = lines.joined(separator: "\n") + "\n"
        if hiddenCount > 0 {
            out += "\n" + paint("\(hiddenCount) non-connectable advertiser(s) hidden "
                                + "— pass --all to show them.", "2") + "\n"
        }

        // The whole reason this command exists.
        if let best = results.first, best.matchableName != nil {
            out += "\nTo capture the strongest match:\n"
            out += paint("  gattsnap capture --id \(shellQuote(best.identifier)) "
                         + "--profile 'replace-with-profile-label' --out 'snapshot.json'",
                         "36") + "\n"
        } else if let best = results.first {
            out += "\nThe strongest match advertises no name; capture it by identifier:\n"
            out += paint("  gattsnap capture --id \(shellQuote(best.identifier)) "
                         + "--profile 'replace-with-profile-label' --out 'snapshot.json'",
                         "36") + "\n"
        }
        return out
    }

    /// Prevent terminal-control characters from advertisements from changing
    /// the surrounding output. Printable Unicode remains readable.
    static func sanitizedForTerminal(_ value: String) -> String {
        value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar)
                ? String(format: "\\u{%04X}", scalar.value)
                : String(scalar)
        }.joined()
    }

    /// POSIX-shell single quoting. The current identifier is UUID-shaped, but
    /// keeping the renderer correct for future adapters avoids recreating the
    /// advertised-name injection bug with device addresses or paths.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - JSON

    struct Envelope: Encodable {
        let tool: String
        let count: Int
        let hiddenNonConnectable: Int
        let peripherals: [DiscoveredPeripheral]

        enum CodingKeys: String, CodingKey {
            case tool, count, peripherals
            case hiddenNonConnectable = "hidden_non_connectable"
        }
    }

    static func json(_ results: [DiscoveredPeripheral], hiddenCount: Int = 0) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let envelope = Envelope(tool: "gattsnap", count: results.count,
                                hiddenNonConnectable: hiddenCount, peripherals: results)
        return String(decoding: try encoder.encode(envelope), as: UTF8.self) + "\n"
    }
}
