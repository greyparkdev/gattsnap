import Foundation

/// Compares two attribute tables and classifies what changed.
///
/// `compare` takes an `AttributeTable` and capabilities, and has no parameter
/// through which `CaptureMetadata` could reach it. That is deliberate: the
/// exclusion of capture metadata from the diff is enforced by the type system
/// rather than by convention, so a later edit cannot quietly start diffing a
/// timestamp or an RSSI. See docs/schema-decisions.md D2.
public enum DiffEngine {

    // MARK: - Entry points

    /// Table-level comparison. This is the whole engine; the snapshot-level
    /// entry point below only adds profile-label warnings around it.
    public static func compare(
        base: AttributeTable,
        head: AttributeTable,
        baseCapabilities: AdapterCapabilities,
        headCapabilities: AdapterCapabilities,
        baseAdapterID: String = "base",
        headAdapterID: String = "head",
        options: DiffOptions = DiffOptions()
    ) -> (changes: [Change], unobservable: [Unobservable]) {
        let b = base.normalized()
        let h = head.normalized()

        // Persisted snapshots are rejected by SnapshotCoding when they claim
        // handles without recording every one. Keep the lower-level table API
        // fail-closed too: callers can construct tables directly without going
        // through the decoder.
        var effectiveBaseCapabilities = baseCapabilities
        var effectiveHeadCapabilities = headCapabilities
        var incompleteHandleAdapters: [String] = []
        if effectiveBaseCapabilities.canObserve(.handles), !b.hasCompleteHandleCoverage {
            effectiveBaseCapabilities.observed.remove(.handles)
            incompleteHandleAdapters.append(baseAdapterID)
        }
        if effectiveHeadCapabilities.canObserve(.handles), !h.hasCompleteHandleCoverage {
            effectiveHeadCapabilities.observed.remove(.handles)
            incompleteHandleAdapters.append(headAdapterID)
        }

        // Capabilities either side lacks. Anything in here must not be compared
        // — a skipped range is reported as `unobservable`, never as `removed`.
        var blind: Set<Capability> = []
        for capability in Capability.tableAffecting {
            if !effectiveBaseCapabilities.canObserve(capability)
                || !effectiveHeadCapabilities.canObserve(capability) {
                blind.insert(capability)
            }
        }

        // Recorded as the diff runs, so degradation reflects what was actually
        // dropped rather than what might theoretically have been.
        var suppressed: Set<Capability> = []
        var changes = diffServices(b, h, blind: blind, options: options, suppressed: &suppressed)
        changes.sort(by: changeOrder)

        // Being asked to compare handles and not having them is itself a
        // suppression: the comparison the user requested did not happen.
        if options.diffHandles && blind.contains(.handles) {
            suppressed.insert(.handles)
        }

        let unobservable = unobservableRanges(
            blind: blind, suppressed: suppressed,
            base: effectiveBaseCapabilities, head: effectiveHeadCapabilities,
            baseAdapterID: baseAdapterID, headAdapterID: headAdapterID,
            incompleteHandleAdapters: incompleteHandleAdapters,
            options: options)

        return (changes, unobservable)
    }

    /// Snapshot-level comparison. Unwraps the tables, resolves capabilities and
    /// adds the profile-mismatch warning.
    public static func compare(
        base: Snapshot,
        head: Snapshot,
        options: DiffOptions = DiffOptions()
    ) -> DiffReport {
        let (changes, unobservable) = compare(
            base: base.table, head: head.table,
            baseCapabilities: base.adapter.capabilities,
            headCapabilities: head.adapter.capabilities,
            baseAdapterID: base.adapter.id,
            headAdapterID: head.adapter.id,
            options: options)

        var warnings: [DiffWarning] = []
        // Warns, never fails: the label is a sanity check, not the diff key.
        if base.profile != head.profile {
            warnings.append(DiffWarning(kind: .profileMismatch,
                "profile labels differ: base is '\(base.profile)', head is '\(head.profile)'. "
                + "These may be snapshots of different products — check you are diffing the right two files."))
        }

        let ambiguousPaths = ambiguousIdentityPaths(base.table, side: "base")
            + ambiguousIdentityPaths(head.table, side: "head")
        if !ambiguousPaths.isEmpty {
            warnings.append(DiffWarning(kind: .ambiguousIdentity,
                "repeated UUID siblings lack complete handles at "
                + ambiguousPaths.joined(separator: ", ")
                + ". Instance matching may follow discovery order, so verify findings in these ranges."))
        }

        // structure_hash is sold as CI's cheap "did anything change at all"
        // check. If it fires while the diff reports nothing, the two signals
        // contradict each other and the reader is left with an unexplained
        // mismatch. Say why instead.
        if base.structureHash != head.structureHash, changes.isEmpty {
            var causes: [QuietHashCause] = []
            var explanations: [String] = []

            let sameNormalizedHash = StructureHash.compute(base.table.normalized())
                == StructureHash.compute(head.table.normalized())
            if sameNormalizedHash {
                causes.append(.storedOrderDiffers)
                explanations.append("schema-1 snapshots preserve different stored orders for repeated UUIDs; "
                                    + "their attribute tables match after handle-based ordering")
            }

            // Only worth suggesting when both sides actually carry handles —
            // otherwise --diff-handles would just degrade the run rather than
            // explain anything, and the suppression below is the real cause.
            if !sameNormalizedHash, !options.diffHandles,
               base.table.containsHandles, head.table.containsHandles {
                causes.append(.handlesNotDiffed)
                explanations.append("both snapshots record attribute handles and --diff-handles "
                                    + "is off — re-run with --diff-handles to compare them")
            }
            if unobservable.contains(where: { $0.category == .suppressedComparison }) {
                causes.append(.adapterCapabilityGap)
                explanations.append("findings were dropped from ranges these adapters cannot "
                                    + "both observe (see the degraded section)")
            }
            // One capture recorded something the other never collected — e.g.
            // one run used --include-handles and the other did not. The tables
            // genuinely differ, so the hash differs, but there is nothing to
            // compare on the side that never captured it.
            // Same adapter, different recorded capabilities means the flags
            // differed. Across *different* adapters the difference is inherent,
            // and "re-capture the same way" would be nonsense advice — that is
            // an adapter capability gap, reported above.
            let baseObserved = base.adapter.capabilities.observed
            let headObserved = head.adapter.capabilities.observed
            if base.adapter.id == head.adapter.id, baseObserved != headObserved {
                causes.append(.captureOptionsDiffer)
                let describe: (Set<Capability>) -> String = { set in
                    set.isEmpty ? "none" : set.map(\.rawValue).sorted().joined(separator: ", ")
                }
                explanations.append("the two snapshots were captured with different options "
                                    + "(base recorded \(describe(baseObserved)); head recorded "
                                    + "\(describe(headObserved))) — re-capture both the same way "
                                    + "to compare them")
            }
            if causes.isEmpty {
                causes.append(.undetermined)
                explanations.append("no cause could be determined — structure_hash covers "
                                    + "something the diff cannot explain, which is a bug in "
                                    + "gattsnap rather than a fact about your firmware. "
                                    + "Please report it")
            }

            warnings.append(DiffWarning(
                kind: .quietHashDifference, causes: causes,
                "structure_hash differs between these snapshots, but no changes are reported "
                + "at this diff level: \(explanations.joined(separator: "; and "))."))
        }

        return DiffReport(
            changes: changes,
            unobservable: unobservable,
            warnings: warnings,
            baseProfile: base.profile,
            headProfile: head.profile,
            baseStructureHash: base.structureHash,
            headStructureHash: head.structureHash,
            failOnWarning: options.failOnWarning)
    }

    // MARK: - Capability intersection

    private static func unobservableRanges(
        blind: Set<Capability>, suppressed: Set<Capability>,
        base: AdapterCapabilities, head: AdapterCapabilities,
        baseAdapterID: String, headAdapterID: String,
        incompleteHandleAdapters: [String],
        options: DiffOptions
    ) -> [Unobservable] {
        var out: [Unobservable] = []
        for capability in Capability.tableAffecting.sorted() where blind.contains(capability) {
            // Handles are only part of the comparison when asked for. Listing
            // them otherwise would put a limitation in every report that the
            // user explicitly opted out of caring about.
            if capability == .handles && !options.diffHandles { continue }

            var blindIDs: [String] = []
            if !base.canObserve(capability) { blindIDs.append(baseAdapterID) }
            if !head.canObserve(capability) { blindIDs.append(headAdapterID) }
            let unique = Array(Set(blindIDs)).sorted()
            let bothBlind = unique.count == 1 && blindIDs.count == 2

            let who = bothBlind
                ? "neither adapter can observe"
                : (unique.count == 1
                    ? "the \(unique[0]) adapter cannot observe"
                    : "neither adapter can observe")

            let isSuppression = suppressed.contains(capability)
            let incomplete = capability == .handles
                ? Array(Set(incompleteHandleAdapters)).sorted()
                : []
            let reason = incomplete.isEmpty
                ? "\(who) it"
                : "snapshot(s) from \(incomplete.joined(separator: ", ")) have incomplete coverage"
            let detail = "\(capability.unobservableDescription) not comparable: \(reason)"
                + (isSuppression
                    ? " — findings in this range were dropped from the comparison"
                    : " — nothing was dropped, but the comparison does not cover it")

            out.append(Unobservable(
                capability: capability,
                category: isSuppression ? .suppressedComparison : .standingLimitation,
                blindAdapters: unique,
                detail: detail))
        }
        return out
    }

    // MARK: - Structural diff

    private static func diffServices(
        _ base: AttributeTable, _ head: AttributeTable,
        blind: Set<Capability>, options: DiffOptions,
        suppressed: inout Set<Capability>
    ) -> [Change] {
        var changes: [Change] = []

        let baseByKey = Dictionary(uniqueKeysWithValues: base.services.map { (ServiceKey($0), $0) })
        let headByKey = Dictionary(uniqueKeysWithValues: head.services.map { (ServiceKey($0), $0) })

        for (key, service) in baseByKey where headByKey[key] == nil {
            // A service the other adapter is blind to is not "removed" — but
            // dropping the finding is a real suppression and must be recorded.
            if service.uuid.isGAPOrGATTService && blind.contains(.gapGattServices) {
                suppressed.insert(.gapGattServices)
                continue
            }
            changes.append(Change(
                kind: .serviceRemoved, severity: .breaking,
                path: AttributePath(service: service.uuid, serviceInstance: service.instance),
                detail: "service \(service.uuid) removed "
                    + "(\(service.characteristics.count) characteristic(s) went with it)"))
        }

        for (key, service) in headByKey where baseByKey[key] == nil {
            if service.uuid.isGAPOrGATTService && blind.contains(.gapGattServices) {
                suppressed.insert(.gapGattServices)
                continue
            }
            changes.append(Change(
                kind: .serviceAdded, severity: .additive,
                path: AttributePath(service: service.uuid, serviceInstance: service.instance),
                detail: "service \(service.uuid) added "
                    + "with \(service.characteristics.count) characteristic(s)"))
        }

        for (key, baseService) in baseByKey {
            guard let headService = headByKey[key] else { continue }
            changes += diffService(baseService, headService, blind: blind, options: options)
        }

        return changes
    }

    private static func diffService(
        _ base: Service, _ head: Service,
        blind: Set<Capability>, options: DiffOptions
    ) -> [Change] {
        var changes: [Change] = []
        let servicePath = AttributePath(service: base.uuid, serviceInstance: base.instance)

        if base.isPrimary != head.isPrimary {
            // A secondary service is only reachable through an include, so
            // demoting one detaches every client that discovered it directly.
            changes.append(Change(
                kind: .servicePrimaryChanged,
                severity: head.isPrimary ? .additive : .breaking,
                path: servicePath,
                detail: "service \(base.uuid) changed from "
                    + "\(base.isPrimary ? "primary" : "secondary") to "
                    + "\(head.isPrimary ? "primary" : "secondary")"))
        }

        for removed in Set(base.includedServices).subtracting(head.includedServices).sorted() {
            changes.append(Change(
                kind: .includedServiceRemoved, severity: .breaking, path: servicePath,
                detail: "service \(base.uuid) no longer includes \(removed)"))
        }
        for added in Set(head.includedServices).subtracting(base.includedServices).sorted() {
            changes.append(Change(
                kind: .includedServiceAdded, severity: .additive, path: servicePath,
                detail: "service \(base.uuid) now includes \(added)"))
        }

        if options.diffHandles, !blind.contains(.handles),
           let bh = base.handles, let hh = head.handles, bh != hh {
            changes.append(Change(
                kind: .handleShift, severity: .breaking, path: servicePath,
                detail: "service \(base.uuid) handle range moved from "
                    + "0x\(hex(bh.start))–0x\(hex(bh.end)) to 0x\(hex(hh.start))–0x\(hex(hh.end))",
                note: bondedClientNote))
        }

        let baseChars = Dictionary(uniqueKeysWithValues: base.characteristics.map { (CharKey($0), $0) })
        let headChars = Dictionary(uniqueKeysWithValues: head.characteristics.map { (CharKey($0), $0) })

        for (key, ch) in baseChars where headChars[key] == nil {
            changes.append(Change(
                kind: .characteristicRemoved, severity: .breaking,
                path: AttributePath(service: base.uuid, serviceInstance: base.instance,
                                    characteristic: ch.uuid, characteristicInstance: ch.instance),
                detail: "characteristic \(ch.uuid) removed from service \(base.uuid)"))
        }
        for (key, ch) in headChars where baseChars[key] == nil {
            changes.append(Change(
                kind: .characteristicAdded, severity: .additive,
                path: AttributePath(service: base.uuid, serviceInstance: base.instance,
                                    characteristic: ch.uuid, characteristicInstance: ch.instance),
                detail: "characteristic \(ch.uuid) added to service \(base.uuid) "
                    + "[\(ch.properties.sorted().map(\.rawValue).joined(separator: "|"))]"))
        }
        for (key, baseChar) in baseChars {
            guard let headChar = headChars[key] else { continue }
            changes += diffCharacteristic(baseChar, headChar, in: base,
                                          blind: blind, options: options)
        }

        return changes
    }

    private static func diffCharacteristic(
        _ base: Characteristic, _ head: Characteristic, in service: Service,
        blind: Set<Capability>, options: DiffOptions
    ) -> [Change] {
        var changes: [Change] = []
        let path = AttributePath(service: service.uuid, serviceInstance: service.instance,
                                 characteristic: base.uuid, characteristicInstance: base.instance)

        for removed in base.properties.subtracting(head.properties).sorted() {
            changes.append(Change(
                kind: .propertyRemoved, severity: .breaking, path: path,
                detail: "characteristic \(base.uuid) lost the '\(removed.rawValue)' property"))
        }
        for added in head.properties.subtracting(base.properties).sorted() {
            changes.append(Change(
                kind: .propertyAdded, severity: .additive, path: path,
                detail: "characteristic \(base.uuid) gained the '\(added.rawValue)' property"))
        }

        if options.diffHandles, !blind.contains(.handles),
           let bh = base.handles, let hh = head.handles, bh != hh {
            changes.append(Change(
                kind: .handleShift, severity: .breaking, path: path,
                detail: "characteristic \(base.uuid) handles moved from "
                    + "declaration 0x\(hex(bh.declaration))/value 0x\(hex(bh.value)) to "
                    + "declaration 0x\(hex(hh.declaration))/value 0x\(hex(hh.value))",
                note: bondedClientNote))
        }

        // Only the Device Information allowlist; everything else is runtime
        // state and would make every capture diff dirty.
        if DeviceInformation.isDiffableValue(service: service.uuid, characteristic: base.uuid),
           base.valueHex != head.valueHex {
            let label = DeviceInformation.label(for: base.uuid)
            changes.append(Change(
                kind: .deviceInformationChanged, severity: .cosmetic, path: path,
                detail: "\(label) changed from \(describe(base.valueHex)) to \(describe(head.valueHex))"))
        }

        let baseDescs = Dictionary(uniqueKeysWithValues: base.descriptors.map { (DescKey($0), $0) })
        let headDescs = Dictionary(uniqueKeysWithValues: head.descriptors.map { (DescKey($0), $0) })

        for (key, d) in baseDescs where headDescs[key] == nil {
            let descPath = AttributePath(
                service: service.uuid, serviceInstance: service.instance,
                characteristic: base.uuid, characteristicInstance: base.instance,
                descriptor: d.uuid, descriptorInstance: d.instance)
            changes.append(Change(
                kind: .descriptorRemoved, severity: .breaking, path: descPath,
                detail: d.isCCCD
                    ? "CCCD (0x2902) removed from characteristic \(base.uuid) — "
                      + "clients can no longer subscribe to notifications or indications"
                    : "descriptor \(d.uuid) removed from characteristic \(base.uuid)"))
        }
        for (key, d) in headDescs where baseDescs[key] == nil {
            let descPath = AttributePath(
                service: service.uuid, serviceInstance: service.instance,
                characteristic: base.uuid, characteristicInstance: base.instance,
                descriptor: d.uuid, descriptorInstance: d.instance)
            changes.append(Change(
                kind: .descriptorAdded, severity: .additive, path: descPath,
                detail: "descriptor \(d.uuid) added to characteristic \(base.uuid)"))
        }
        if options.diffHandles, !blind.contains(.handles) {
            for (key, baseDescriptor) in baseDescs {
                guard let headDescriptor = headDescs[key],
                      let baseHandle = baseDescriptor.handle,
                      let headHandle = headDescriptor.handle,
                      baseHandle != headHandle else { continue }
                let descriptorPath = AttributePath(
                    service: service.uuid, serviceInstance: service.instance,
                    characteristic: base.uuid, characteristicInstance: base.instance,
                    descriptor: baseDescriptor.uuid, descriptorInstance: baseDescriptor.instance)
                changes.append(Change(
                    kind: .handleShift, severity: .breaking, path: descriptorPath,
                    detail: "descriptor \(baseDescriptor.uuid) handle moved from "
                        + "0x\(hex(baseHandle)) to 0x\(hex(headHandle))",
                    note: bondedClientNote))
            }
        }
        // Descriptor *values* are deliberately not diffed — CCCD value is
        // per-connection state, not table structure.

        return changes
    }

    // MARK: - Helpers

    private static let bondedClientNote =
        "Handles shifted. A bonded client that cached this attribute table by handle will "
        + "read or write the wrong attribute until it re-discovers. Unless the firmware sends a "
        + "Service Changed indication (0x2A05), those clients break in the field — and a fresh "
        + "re-discovery test will not reproduce it."

    private static func hex(_ v: UInt16) -> String { String(format: "%04X", v) }

    private static func describe(_ hexString: String?) -> String {
        guard let hexString, !hexString.isEmpty else { return "<absent>" }
        // DIS values are UTF-8 strings in practice; show them readably when they
        // decode, and fall back to hex when they do not.
        var bytes: [UInt8] = []
        var idx = hexString.startIndex
        while idx < hexString.endIndex,
              let next = hexString.index(idx, offsetBy: 2, limitedBy: hexString.endIndex),
              let byte = UInt8(hexString[idx..<next], radix: 16) {
            bytes.append(byte)
            idx = next
        }
        if bytes.count * 2 == hexString.count,
           let s = String(bytes: bytes, encoding: .utf8),
           !s.isEmpty,
           s.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F }) {
            return "\"\(s)\""
        }
        return "<\(hexString)>"
    }

    private static func ambiguousIdentityPaths(_ table: AttributeTable, side: String) -> [String] {
        let table = table.normalized()
        var paths: [String] = []

        for group in Dictionary(grouping: table.services, by: \.uuid).values
        where group.count > 1 && group.contains(where: { $0.handles == nil }) {
            paths.append("\(side):services/\(group[0].uuid)")
        }

        for service in table.services {
            for group in Dictionary(grouping: service.characteristics, by: \.uuid).values
            where group.count > 1 && group.contains(where: { $0.handles == nil }) {
                paths.append("\(side):\(AttributePath(service: service.uuid, serviceInstance: service.instance))/\(group[0].uuid)")
            }
            for characteristic in service.characteristics {
                for group in Dictionary(grouping: characteristic.descriptors, by: \.uuid).values
                where group.count > 1 && group.contains(where: { $0.handle == nil }) {
                    let path = AttributePath(
                        service: service.uuid, serviceInstance: service.instance,
                        characteristic: characteristic.uuid,
                        characteristicInstance: characteristic.instance)
                    paths.append("\(side):\(path)/\(group[0].uuid)")
                }
            }
        }
        return paths.sorted()
    }

    /// Stable output order: most severe first, then by path, then by kind, so
    /// two runs over the same inputs always print identically.
    private static func changeOrder(_ l: Change, _ r: Change) -> Bool {
        if l.severity != r.severity { return l.severity > r.severity }
        if l.path.description != r.path.description {
            return l.path.description < r.path.description
        }
        return l.kind.rawValue < r.kind.rawValue
    }
}

// Matching keys. Without handles there is no stronger identity than
// (uuid, instance) — see the known limitation in docs/schema-decisions.md.
private struct ServiceKey: Hashable {
    let uuid: BluetoothUUID, instance: Int
    init(_ s: Service) { uuid = s.uuid; instance = s.instance }
}

private struct CharKey: Hashable {
    let uuid: BluetoothUUID, instance: Int
    init(_ c: Characteristic) { uuid = c.uuid; instance = c.instance }
}

private struct DescKey: Hashable {
    let uuid: BluetoothUUID, instance: Int
    init(_ d: Descriptor) { uuid = d.uuid; instance = d.instance }
}
