import Foundation

/// Content hash over the attribute table alone.
///
/// Uses its own explicit text encoding rather than hashing the JSON, so that a
/// future change to the JSON encoder (key order, whitespace, a new metadata
/// field) cannot silently change every committed snapshot's hash. The hash
/// covers exactly the structure the diff engine looks at, and nothing else.
public enum StructureHash {
    /// Uses the original schema-1 ordering, independently of the ordering used
    /// to match attributes in a diff. New Snapshot instances first normalize
    /// their stored table, but existing files must hash in their original order
    /// among repeated UUIDs. Changing this contract requires a schema version.
    public static func compute(_ table: AttributeTable) -> String {
        "sha256:" + SHA256.hexDigest(canonicalText(table))
    }

    /// Stable, greppable line-oriented encoding. Deliberately human-readable so
    /// a hash mismatch can be debugged by eye.
    static func canonicalText(_ table: AttributeTable) -> String {
        var lines: [String] = []
        for service in table.normalizedForSchemaV1Hash().services {
            lines.append("S\t\(service.uuid)\t\(service.instance)\t\(service.isPrimary ? "primary" : "secondary")")
            // Handles are part of the attribute table, not capture metadata, so
            // they participate. This is what lets CI's cheap structure_hash
            // check catch a handle shift — the case D1 exists for. A snapshot
            // taken with --include-handles therefore hashes differently from one
            // taken without, which is correct: they recorded different data.
            if let h = service.handles {
                lines.append("SH\t\(service.uuid)\t\(service.instance)\t\(h.start)\t\(h.end)")
            }
            for included in service.includedServices {
                lines.append("I\t\(service.uuid)\t\(service.instance)\t\(included)")
            }
            for ch in service.characteristics {
                let props = ch.properties.sorted().map(\.rawValue).joined(separator: ",")
                lines.append("C\t\(service.uuid)\t\(service.instance)\t\(ch.uuid)\t\(ch.instance)\t\(props)")
                if let h = ch.handles {
                    lines.append("CH\t\(service.uuid)\t\(service.instance)\t\(ch.uuid)\t\(ch.instance)\t\(h.declaration)\t\(h.value)")
                }
                // Only allowlisted values participate; see schema-decisions.
                if DeviceInformation.isDiffableValue(service: service.uuid, characteristic: ch.uuid),
                   let v = ch.valueHex {
                    lines.append("V\t\(service.uuid)\t\(service.instance)\t\(ch.uuid)\t\(ch.instance)\t\(v)")
                }
                for d in ch.descriptors {
                    lines.append("D\t\(service.uuid)\t\(service.instance)\t\(ch.uuid)\t\(ch.instance)\t\(d.uuid)\t\(d.instance)")
                    if let h = d.handle {
                        lines.append("DH\t\(service.uuid)\t\(service.instance)\t\(ch.uuid)\t\(ch.instance)\t\(d.uuid)\t\(d.instance)\t\(h)")
                    }
                }
            }
        }
        return lines.joined(separator: "\n")
    }
}

/// The Device Information Service (0x180A).
///
/// Its characteristic values are the only ones the diff looks at: they are
/// stable read-only identification strings, which is what makes "manufacturer
/// string changed" detectable as a cosmetic change. Every other characteristic
/// value is runtime state and would make each capture diff dirty.
public enum DeviceInformation {
    public static let serviceUUID = BluetoothUUID("180A")

    public static let characteristicNames: [String: String] = [
        "2A23": "system_id",
        "2A24": "model_number",
        "2A25": "serial_number",
        "2A26": "firmware_revision",
        "2A27": "hardware_revision",
        "2A28": "software_revision",
        "2A29": "manufacturer_name",
        "2A2A": "ieee_regulatory_certification",
        "2A50": "pnp_id",
    ]

    public static func isDiffableValue(service: BluetoothUUID, characteristic: BluetoothUUID) -> Bool {
        service == serviceUUID && characteristicNames[characteristic.value] != nil
    }

    public static func label(for characteristic: BluetoothUUID) -> String {
        characteristicNames[characteristic.value] ?? characteristic.value
    }
}
