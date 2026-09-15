import Foundation
import ObjectiveC.runtime

// Reads attribute handles off CoreBluetooth's model objects.
//
// CBService/CBCharacteristic/CBDescriptor declare handles as real ObjC
// properties — see docs/platform-notes.md §2 — but none of them appear in a
// public header, so this is private API.
//
// This lives in its own target for a reason. It is linked *only* on macOS, via
// a platform condition in Package.swift, so an iOS build of GATTCapture does not
// contain these selectors at all. A runtime guard would have left them present
// but dormant in a shipped app binary; App Review scans for the symbol, not for
// whether it executes. See docs/schema-decisions.md D1.
//
// Deliberately takes NSObject rather than CoreBluetooth types: this target does
// not import CoreBluetooth, which keeps it trivially testable and makes the
// dependency direction obvious.

public enum HandleProbe {

    public static func serviceHandles(_ object: NSObject) -> (start: UInt16, end: UInt16)? {
        guard let start = uint16(object, "startHandle"),
              let end = uint16(object, "endHandle") else { return nil }
        return (start, end)
    }

    public static func characteristicHandles(_ object: NSObject) -> (declaration: UInt16, value: UInt16)? {
        guard let declaration = uint16(object, "handle"),
              let value = uint16(object, "valueHandle") else { return nil }
        return (declaration, value)
    }

    public static func descriptorHandle(_ object: NSObject) -> UInt16? {
        uint16(object, "handle")
    }

    /// True when the running OS still exposes the properties this relies on.
    /// Lets a caller report "handles unavailable on this macOS" rather than
    /// silently recording a table without them.
    public static func isAvailable(onServiceClass cls: AnyClass) -> Bool {
        let names = inheritedPropertyNames(cls)
        return names.contains("startHandle") && names.contains("endHandle")
    }

    public static func isAvailable(onServiceClass serviceClass: AnyClass,
                                   characteristicClass: AnyClass,
                                   descriptorClass: AnyClass) -> Bool {
        let serviceNames = inheritedPropertyNames(serviceClass)
        let characteristicNames = inheritedPropertyNames(characteristicClass)
        let descriptorNames = inheritedPropertyNames(descriptorClass)
        return serviceNames.isSuperset(of: ["startHandle", "endHandle"])
            && characteristicNames.isSuperset(of: ["handle", "valueHandle"])
            && descriptorNames.contains("handle")
    }

    // MARK: - Safe KVC

    /// Reads a key only when the ObjC runtime confirms a property backs it.
    ///
    /// `-valueForKey:` raises on an unknown key, and Swift cannot catch an ObjC
    /// exception — so a future macOS that drops these properties would crash the
    /// tool rather than degrade. Checking first turns that into a `nil`, which
    /// the caller records as "handles absent".
    private static func uint16(_ object: NSObject, _ key: String) -> UInt16? {
        var current: AnyClass? = type(of: object)
        var found = false
        while let cls = current, NSStringFromClass(cls) != "NSObject" {
            if propertyNames(cls).contains(key) { found = true; break }
            current = class_getSuperclass(cls)
        }
        guard found, let value = object.value(forKey: key) as? NSNumber else { return nil }
        let raw = value.intValue
        // ATT handle 0x0000 is reserved and never identifies an attribute.
        guard raw > 0, raw <= Int(UInt16.max) else { return nil }
        return UInt16(raw)
    }

    private static func inheritedPropertyNames(_ cls: AnyClass) -> Set<String> {
        var names: Set<String> = []
        var current: AnyClass? = cls
        while let candidate = current, NSStringFromClass(candidate) != "NSObject" {
            names.formUnion(propertyNames(candidate))
            current = class_getSuperclass(candidate)
        }
        return names
    }

    private static func propertyNames(_ cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { i in String(cString: property_getName(list[i])) }
    }
}
