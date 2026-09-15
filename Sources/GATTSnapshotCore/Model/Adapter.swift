import Foundation

/// A thing an adapter may or may not be able to see.
///
/// Capabilities are how the diff engine tells "this platform cannot observe X"
/// apart from "X is unchanged" — the distinction that keeps a cross-adapter
/// comparison from silently printing a clean result. See schema-decisions D3.
public enum Capability: String, Codable, Sendable, CaseIterable, Comparable {
    /// Attribute handles. CoreBluetooth can read these, but only under
    /// `--include-handles`; BlueZ always can.
    case handles

    /// The peripheral's Bluetooth device address. Never available on Apple
    /// platforms — `CBPeripheral.BDAddress` exists but returns nil.
    case macAddress = "mac_address"

    /// The GAP (0x1800) and GATT (0x1801) services. CoreBluetooth consumes
    /// these internally and omits them from discovery, which also makes the
    /// Device Name characteristic (0x2A00) unreachable there.
    case gapGattServices = "gap_gatt_services"

    /// Advertising interval and other PDU-level parameters. Requires the raw
    /// advertising PDU, which CoreBluetooth does not expose.
    case advertisingParameters = "advertising_parameters"

    public static func < (l: Self, r: Self) -> Bool { l.rawValue < r.rawValue }

    /// Capabilities that can affect an attribute-table comparison.
    ///
    /// `macAddress` is excluded: it lives in capture metadata, which the diff
    /// cannot see by contract (D2), so it can never suppress a finding.
    /// Reporting it as unobservable on every diff would be pure noise.
    public static var tableAffecting: [Capability] {
        [.handles, .gapGattServices, .advertisingParameters]
    }

    /// Human-readable reason a comparison was degraded, used verbatim in output.
    public var unobservableDescription: String {
        switch self {
        case .handles: "attribute handles"
        case .macAddress: "device address"
        case .gapGattServices: "GAP/GATT services (0x1800/0x1801), including device name (0x2A00)"
        case .advertisingParameters: "advertising parameters, including advertising interval"
        }
    }
}

/// What a capture actually observed: the adapter's declared abilities
/// intersected with the options the capture ran under.
public struct AdapterCapabilities: Hashable, Sendable, Codable {
    public var observed: Set<Capability>

    public init(_ observed: Set<Capability>) { self.observed = observed }

    public func canObserve(_ c: Capability) -> Bool { observed.contains(c) }

    public init(from decoder: Decoder) throws {
        // Encoded as an object of flags so a snapshot is self-describing when
        // read by a human: {"handles": true, "mac_address": false, ...}
        let c = try decoder.container(keyedBy: DynamicKey.self)
        var set: Set<Capability> = []
        for cap in Capability.allCases {
            let key = DynamicKey(stringValue: cap.rawValue)!
            if try c.decodeIfPresent(Bool.self, forKey: key) == true { set.insert(cap) }
        }
        observed = set
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: DynamicKey.self)
        for cap in Capability.allCases.sorted() {
            try c.encode(observed.contains(cap), forKey: DynamicKey(stringValue: cap.rawValue)!)
        }
    }
}

struct DynamicKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

/// Which adapter produced a snapshot, and at what capability version.
public struct AdapterIdentity: Hashable, Sendable, Codable {
    public var id: String
    /// Bumped whenever the adapter's declared abilities change, so old
    /// snapshots stay honest about what they were captured with.
    public var capabilityVersion: Int
    public var capabilities: AdapterCapabilities

    public init(id: String, capabilityVersion: Int, capabilities: AdapterCapabilities) {
        self.id = id
        self.capabilityVersion = capabilityVersion
        self.capabilities = capabilities
    }

    enum CodingKeys: String, CodingKey {
        case id, capabilities
        case capabilityVersion = "capability_version"
    }
}

/// The declared maximum abilities of each known adapter, keyed by id and
/// capability version.
///
/// A snapshot's recorded capabilities must be a *subset* of the declaration —
/// equal when every option was enabled, smaller when the user opted out (for
/// example capturing without `--include-handles`). Validation catches a
/// hand-edited or forged snapshot claiming to have seen something its adapter
/// cannot.
public enum AdapterRegistry {
    public static let coreBluetooth = "corebluetooth"
    public static let bluez = "bluez"

    private static let declarations: [String: [Int: Set<Capability>]] = [
        // Empirically established in M1; see docs/platform-notes.md §2.
        coreBluetooth: [
            1: [.handles],
        ],
        // Not implemented yet. Declared so the diff engine's cross-adapter path
        // is exercised by tests before the adapter exists.
        bluez: [
            1: [.handles, .macAddress, .gapGattServices, .advertisingParameters],
        ],
    ]

    public static func declaredCapabilities(id: String, version: Int) -> Set<Capability>? {
        declarations[id]?[version]
    }

    public static func isKnown(id: String, version: Int) -> Bool {
        declaredCapabilities(id: id, version: version) != nil
    }
}
