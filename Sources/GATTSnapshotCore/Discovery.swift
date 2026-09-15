import Foundation

/// One advertiser seen during a scan.
///
/// Exists because you cannot capture a device whose name you do not know, and
/// the advertised name is not something a user can look up anywhere else. This
/// is the first thing anyone runs, so it belongs in the tool rather than in a
/// throwaway spike binary.
public struct DiscoveredPeripheral: Hashable, Sendable, Codable {
    /// Adapter-scoped identifier: a host-scoped UUID on CoreBluetooth, a device
    /// address on BlueZ. Usable with `capture --id` on the same machine.
    public var identifier: String
    /// What the device put on the air. This is what `capture --name` matches.
    public var advertisedLocalName: String?
    /// What the OS remembers. Shown only when it differs from the advertised
    /// name, because a stale cached name is exactly the trap that makes people
    /// search for a device they cannot match (platform-notes §4).
    public var cachedName: String?
    public var rssi: Int?
    /// `nil` when the advertisement did not say. Absence is not "no".
    public var isConnectable: Bool?
    public var serviceUUIDs: [BluetoothUUID]
    public var manufacturerDataHex: String?

    public init(identifier: String,
                advertisedLocalName: String? = nil,
                cachedName: String? = nil,
                rssi: Int? = nil,
                isConnectable: Bool? = nil,
                serviceUUIDs: [BluetoothUUID] = [],
                manufacturerDataHex: String? = nil) {
        self.identifier = identifier
        self.advertisedLocalName = advertisedLocalName
        self.cachedName = cachedName
        self.rssi = rssi
        self.isConnectable = isConnectable
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerDataHex = manufacturerDataHex
    }

    enum CodingKeys: String, CodingKey {
        case identifier, rssi
        case advertisedLocalName = "advertised_local_name"
        case cachedName = "cached_name"
        case isConnectable = "is_connectable"
        case serviceUUIDs = "service_uuids"
        case manufacturerDataHex = "manufacturer_data_hex"
    }

    /// The name `capture --name` would match, if any.
    public var matchableName: String? { advertisedLocalName ?? cachedName }

    /// Only connectable devices can be captured, so an unnamed non-connectable
    /// beacon is noise when you are hunting for a board.
    public var isCapturable: Bool { isConnectable != false }

    /// Strongest first, unnamed last, so the device on your desk is at the top.
    public static func displayOrder(_ l: Self, _ r: Self) -> Bool {
        switch (l.rssi, r.rssi) {
        case let (a?, b?) where a != b: return a > b
        case (nil, _?): return false
        case (_?, nil): return true
        default: return l.identifier < r.identifier
        }
    }
}

public struct ScanOptions: Hashable, Sendable {
    public var duration: Duration

    public init(duration: Duration = .seconds(8)) {
        self.duration = duration
    }
}

// An adapter reports everything it saw; deciding what is worth showing is a
// presentation concern. Keeping the filter out of the adapter is also what lets
// the CLI say how many entries it withheld, instead of leaving the user
// wondering why their beacon is missing.
