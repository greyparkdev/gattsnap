import Foundation

/// Everything about *this capture session* rather than about the peripheral's
/// attribute table.
///
/// Nothing in here is diffable, and the diff engine has no parameter through
/// which it could reach this type. See docs/schema-decisions.md D2.
public struct CaptureMetadata: Hashable, Sendable, Codable {
    public var capturedAt: String
    public var toolVersion: String
    public var host: String?
    /// What the peripheral put on the air. Prefer this over any OS-cached name:
    /// `CBPeripheral.name` is remembered by the system and will not change when
    /// the device is renamed (platform-notes §4).
    public var advertisedLocalName: String?
    /// Host-scoped UUID on Apple platforms — differs per machine for the same
    /// peripheral, which is exactly why it cannot be an identity key.
    public var peripheralIdentifier: String?
    public var macAddress: String?
    public var rssi: Int?
    public var mtu: Int?
    /// A capture that completes implausibly fast is the signature of a cached
    /// service table rather than a real read (platform-notes §3).
    public var discoveryDurationMs: Double?
    public var deviceInformation: [String: String]?

    public init(capturedAt: String, toolVersion: String, host: String? = nil,
                advertisedLocalName: String? = nil, peripheralIdentifier: String? = nil,
                macAddress: String? = nil, rssi: Int? = nil, mtu: Int? = nil,
                discoveryDurationMs: Double? = nil,
                deviceInformation: [String: String]? = nil) {
        self.capturedAt = capturedAt
        self.toolVersion = toolVersion
        self.host = host
        self.advertisedLocalName = advertisedLocalName
        self.peripheralIdentifier = peripheralIdentifier
        self.macAddress = macAddress
        self.rssi = rssi
        self.mtu = mtu
        self.discoveryDurationMs = discoveryDurationMs
        self.deviceInformation = deviceInformation
    }

    enum CodingKeys: String, CodingKey {
        case host, rssi, mtu
        case capturedAt = "captured_at"
        case toolVersion = "tool_version"
        case advertisedLocalName = "advertised_local_name"
        case peripheralIdentifier = "peripheral_identifier"
        case macAddress = "mac_address"
        case discoveryDurationMs = "discovery_duration_ms"
        case deviceInformation = "device_information"
    }
}

public enum SchemaVersion {
    /// Version-tagged from day one. Bump on any change that an older reader
    /// could misinterpret; readers refuse versions they do not know.
    public static let current = 1
}

public struct Snapshot: Hashable, Sendable, Codable {
    public var schemaVersion: Int
    /// Human-assigned product label. Required so the field is never empty, but
    /// deliberately not the diff key — a mismatch warns, it does not fail.
    public var profile: String
    public var adapter: AdapterIdentity
    /// SHA-256 over the canonically-sorted attribute table only. Lets CI ask
    /// "did anything change at all" without running a diff.
    public var structureHash: String
    public var captureMetadata: CaptureMetadata
    public var table: AttributeTable

    enum CodingKeys: String, CodingKey {
        case profile, adapter, table
        case schemaVersion = "schema_version"
        case structureHash = "structure_hash"
        case captureMetadata = "capture_metadata"
    }

    /// Builds a snapshot with a normalized table and a freshly computed hash.
    public init(profile: String, adapter: AdapterIdentity,
                captureMetadata: CaptureMetadata, table: AttributeTable) {
        let normalized = table.normalized()
        self.schemaVersion = SchemaVersion.current
        self.profile = profile
        self.adapter = adapter
        self.captureMetadata = captureMetadata
        self.table = normalized
        self.structureHash = StructureHash.compute(normalized)
    }
}
