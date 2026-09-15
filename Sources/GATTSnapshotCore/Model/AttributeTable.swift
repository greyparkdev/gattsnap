import Foundation

/// A Bluetooth UUID, normalized to its canonical short form.
///
/// 128-bit UUIDs inside the Bluetooth base range are collapsed to their 16- or
/// 32-bit form so that a CoreBluetooth capture (which reports `"180A"`) and a
/// BlueZ capture (which reports the full `0000180a-0000-1000-8000-00805f9b34fb`)
/// produce byte-identical snapshots. Without this, every cross-adapter diff
/// would report every standard service as removed-and-added.
public struct BluetoothUUID: Hashable, Sendable, Comparable, Codable,
                             CustomStringConvertible {
    public let value: String

    private static let baseSuffix = "-0000-1000-8000-00805F9B34FB"

    public init(_ raw: String) {
        let upper = raw.uppercased()
        if upper.count == 36, upper.hasSuffix(Self.baseSuffix) {
            let head = String(upper.prefix(8))
            // 0000XXXX -> XXXX, otherwise the full 32-bit head.
            if head.hasPrefix("0000") {
                value = String(head.suffix(4))
            } else {
                value = head
            }
        } else {
            value = upper
        }
    }

    public init(from decoder: Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(value)
    }

    /// Sorts short UUIDs before long ones, then lexically. Keeps standard
    /// attributes grouped at the top of a snapshot where they are easy to read.
    public static func < (l: BluetoothUUID, r: BluetoothUUID) -> Bool {
        if l.value.count != r.value.count { return l.value.count < r.value.count }
        return l.value < r.value
    }

    public var description: String { value }

    /// True for the GAP (0x1800) and GATT (0x1801) services, which
    /// CoreBluetooth filters out of discovery entirely.
    public var isGAPOrGATTService: Bool { value == "1800" || value == "1801" }
}

/// A characteristic property, ordered by its bit position in the GATT
/// declaration rather than alphabetically, so serialized output reads the way a
/// firmware engineer expects.
public enum CharacteristicProperty: String, Codable, Sendable, CaseIterable, Comparable {
    case broadcast
    case read
    case writeWithoutResponse
    case write
    case notify
    case indicate
    case authenticatedSignedWrites
    case extendedProperties

    var canonicalIndex: Int { Self.allCases.firstIndex(of: self)! }

    public static func < (l: Self, r: Self) -> Bool { l.canonicalIndex < r.canonicalIndex }
}

/// Handles are optional platform-dependent detail. See docs/schema-decisions.md D1.
public struct ServiceHandles: Hashable, Sendable, Codable {
    public var start: UInt16
    public var end: UInt16
    public init(start: UInt16, end: UInt16) { self.start = start; self.end = end }
}

public struct CharacteristicHandles: Hashable, Sendable, Codable {
    public var declaration: UInt16
    public var value: UInt16
    public init(declaration: UInt16, value: UInt16) {
        self.declaration = declaration
        self.value = value
    }
}

public struct Descriptor: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    /// Ordinal among same-UUID siblings. See docs/schema-decisions.md.
    public var instance: Int
    public var handle: UInt16?
    /// Recorded for context but never diffed — CCCD value is per-connection state.
    public var valueHex: String?

    public init(uuid: BluetoothUUID, instance: Int = 0,
                handle: UInt16? = nil, valueHex: String? = nil) {
        self.uuid = uuid
        self.instance = instance
        self.handle = handle
        self.valueHex = valueHex
    }

    enum CodingKeys: String, CodingKey {
        case uuid, instance, handle
        case valueHex = "value_hex"
    }

    /// Client Characteristic Configuration Descriptor. Its disappearance is
    /// called out separately because it silently breaks every subscribed client.
    public var isCCCD: Bool { uuid.value == "2902" }
}

public struct Characteristic: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var instance: Int
    public var properties: Set<CharacteristicProperty>
    public var handles: CharacteristicHandles?
    /// Populated only for the 0x180A allowlist; diffed as cosmetic.
    public var valueHex: String?
    public var descriptors: [Descriptor]

    public init(uuid: BluetoothUUID, instance: Int = 0,
                properties: Set<CharacteristicProperty> = [],
                handles: CharacteristicHandles? = nil,
                valueHex: String? = nil,
                descriptors: [Descriptor] = []) {
        self.uuid = uuid
        self.instance = instance
        self.properties = properties
        self.handles = handles
        self.valueHex = valueHex
        self.descriptors = descriptors
    }

    enum CodingKeys: String, CodingKey {
        case uuid, instance, properties, handles, descriptors
        case valueHex = "value_hex"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(BluetoothUUID.self, forKey: .uuid)
        instance = try c.decodeIfPresent(Int.self, forKey: .instance) ?? 0
        properties = Set(try c.decodeIfPresent([CharacteristicProperty].self, forKey: .properties) ?? [])
        handles = try c.decodeIfPresent(CharacteristicHandles.self, forKey: .handles)
        valueHex = try c.decodeIfPresent(String.self, forKey: .valueHex)
        descriptors = try c.decodeIfPresent([Descriptor].self, forKey: .descriptors) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(uuid, forKey: .uuid)
        try c.encode(instance, forKey: .instance)
        try c.encode(properties.sorted(), forKey: .properties)
        try c.encodeIfPresent(handles, forKey: .handles)
        try c.encodeIfPresent(valueHex, forKey: .valueHex)
        try c.encode(descriptors, forKey: .descriptors)
    }
}

public struct Service: Hashable, Sendable, Codable {
    public var uuid: BluetoothUUID
    public var instance: Int
    public var isPrimary: Bool
    public var handles: ServiceHandles?
    public var includedServices: [BluetoothUUID]
    public var characteristics: [Characteristic]

    public init(uuid: BluetoothUUID, instance: Int = 0, isPrimary: Bool = true,
                handles: ServiceHandles? = nil,
                includedServices: [BluetoothUUID] = [],
                characteristics: [Characteristic] = []) {
        self.uuid = uuid
        self.instance = instance
        self.isPrimary = isPrimary
        self.handles = handles
        self.includedServices = includedServices
        self.characteristics = characteristics
    }

    enum CodingKeys: String, CodingKey {
        case uuid, instance, handles, characteristics
        case isPrimary = "primary"
        case includedServices = "included_services"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        uuid = try c.decode(BluetoothUUID.self, forKey: .uuid)
        instance = try c.decodeIfPresent(Int.self, forKey: .instance) ?? 0
        isPrimary = try c.decodeIfPresent(Bool.self, forKey: .isPrimary) ?? true
        handles = try c.decodeIfPresent(ServiceHandles.self, forKey: .handles)
        includedServices = try c.decodeIfPresent([BluetoothUUID].self, forKey: .includedServices) ?? []
        characteristics = try c.decodeIfPresent([Characteristic].self, forKey: .characteristics) ?? []
    }
}

/// The diffable payload of a snapshot. Deliberately contains nothing about the
/// capture session — see docs/schema-decisions.md D2.
public struct AttributeTable: Hashable, Sendable, Codable {
    public var services: [Service]

    public init(services: [Service] = []) {
        self.services = services
    }

    /// Whether any attribute in the table carries a handle. Used to tell a
    /// reader that `--diff-handles` would explain a hash difference the default
    /// diff could not.
    public var containsHandles: Bool {
        services.contains { service in
            service.handles != nil
                || service.characteristics.contains { ch in
                    ch.handles != nil || ch.descriptors.contains { $0.handle != nil }
                }
        }
    }

    /// The first attribute whose handle is absent.
    ///
    /// A snapshot may claim the `handles` capability only when this returns
    /// `nil`. One missing value makes a handle comparison incomplete, and
    /// treating that as "unchanged" would be a false pass.
    public var firstMissingHandlePath: String? {
        for service in services {
            let servicePath = "\(service.uuid)\(service.instance == 0 ? "" : "#\(service.instance)")"
            guard service.handles != nil else { return servicePath }
            for characteristic in service.characteristics {
                let characteristicPath = servicePath + "/\(characteristic.uuid)"
                    + (characteristic.instance == 0 ? "" : "#\(characteristic.instance)")
                guard characteristic.handles != nil else { return characteristicPath }
                for descriptor in characteristic.descriptors {
                    let descriptorPath = characteristicPath + "/\(descriptor.uuid)"
                        + (descriptor.instance == 0 ? "" : "#\(descriptor.instance)")
                    guard descriptor.handle != nil else { return descriptorPath }
                }
            }
        }
        return nil
    }

    public var hasCompleteHandleCoverage: Bool { firstMissingHandlePath == nil }

    /// Sorts every level and assigns `instance` ordinals to same-UUID siblings.
    /// New snapshots and comparisons use this ordering. Discovery
    /// order is eliminated wherever UUIDs (and handles for repeated UUIDs)
    /// establish identity; unresolved repeated UUIDs are warned about by the
    /// diff engine. Existing schema-1 hashes use their original ordering below.
    public func normalized() -> AttributeTable {
        normalized(useHandleOrdering: true)
    }

    /// Schema 1 hashes preserve discovery order among equal UUID siblings
    /// (and equal primary status for services). These rules must not change
    /// when comparison matching improves: existing files retain their hashes.
    func normalizedForSchemaV1Hash() -> AttributeTable {
        normalized(useHandleOrdering: false)
    }

    private func normalized(useHandleOrdering: Bool) -> AttributeTable {
        var out = self
        out.services = assignInstances(services.sorted { serviceOrder($0, $1, useHandles: useHandleOrdering) },
                                       key: \.uuid) { svc, idx in
            var svc = svc
            svc.instance = idx
            svc.includedServices = svc.includedServices.sorted()
            svc.characteristics = assignInstances(svc.characteristics.sorted { characteristicOrder($0, $1, useHandles: useHandleOrdering) },
                                                  key: \.uuid) { ch, cidx in
                var ch = ch
                ch.instance = cidx
                ch.descriptors = assignInstances(ch.descriptors.sorted { descriptorOrder($0, $1, useHandles: useHandleOrdering) },
                                                 key: \.uuid) { d, didx in
                    var d = d
                    d.instance = didx
                    return d
                }
                return ch
            }
            return svc
        }
        return out
    }
}

/// Handles are the only stable tie-breaker available for repeated UUIDs. When
/// they are absent, normalization deliberately preserves discovery order and
/// the diff reports the resulting identity ambiguity instead of sorting by
/// mutable properties and potentially hiding a real change.
private func serviceOrder(_ lhs: Service, _ rhs: Service, useHandles: Bool) -> Bool {
    if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
    if lhs.isPrimary != rhs.isPrimary { return lhs.isPrimary && !rhs.isPrimary }
    if useHandles, let l = lhs.handles, let r = rhs.handles, l.start != r.start { return l.start < r.start }
    return false
}

private func characteristicOrder(_ lhs: Characteristic, _ rhs: Characteristic, useHandles: Bool) -> Bool {
    if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
    if useHandles, let l = lhs.handles, let r = rhs.handles, l.declaration != r.declaration {
        return l.declaration < r.declaration
    }
    return false
}

private func descriptorOrder(_ lhs: Descriptor, _ rhs: Descriptor, useHandles: Bool) -> Bool {
    if lhs.uuid != rhs.uuid { return lhs.uuid < rhs.uuid }
    if useHandles, let l = lhs.handle, let r = rhs.handle, l != r { return l < r }
    return false
}

/// Walks a sorted array and hands each element its ordinal among elements
/// sharing the same key.
private func assignInstances<T, K: Hashable>(
    _ items: [T], key: KeyPath<T, K>, _ transform: (T, Int) -> T
) -> [T] {
    var counts: [K: Int] = [:]
    return items.map { item in
        let k = item[keyPath: key]
        let idx = counts[k, default: 0]
        counts[k] = idx + 1
        return transform(item, idx)
    }
}
