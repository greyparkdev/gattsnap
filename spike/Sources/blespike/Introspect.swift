import Foundation
import ObjectiveC.runtime

// Safe, non-throwing introspection of CoreBluetooth's ObjC classes.
// We enumerate ivars/properties via the runtime rather than blind-KVC'ing
// guessed key names, because -valueForKey: on a missing key raises an ObjC
// exception that Swift cannot catch.

enum Introspect {
    static func ivarNames(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyIvarList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).compactMap { i in
            ivar_getName(list[i]).map { String(cString: $0) }
        }
    }

    static func propertyNames(of cls: AnyClass) -> [String] {
        var count: UInt32 = 0
        guard let list = class_copyPropertyList(cls, &count) else { return [] }
        defer { free(list) }
        return (0..<Int(count)).map { i in String(cString: property_getName(list[i])) }
    }

    /// Full ivar + property surface, walking the superclass chain up to NSObject.
    static func surface(of cls: AnyClass) -> [String: [String]] {
        var out: [String: [String]] = [:]
        var current: AnyClass? = cls
        while let c = current, NSStringFromClass(c) != "NSObject" {
            let name = NSStringFromClass(c)
            let ivars = ivarNames(of: c)
            let props = propertyNames(of: c)
            if !ivars.isEmpty || !props.isEmpty {
                out[name] = (ivars.map { "ivar \($0)" } + props.map { "prop \($0)" }).sorted()
            }
            current = class_getSuperclass(c)
        }
        return out
    }

    /// KVC-read a key only if the runtime says an ivar or property backs it.
    /// Returns nil rather than raising when the key is absent.
    static func safeValue(_ object: NSObject, forKey key: String) -> Any? {
        let cls: AnyClass = type(of: object)
        var current: AnyClass? = cls
        var known = Set<String>()
        while let c = current, NSStringFromClass(c) != "NSObject" {
            for n in ivarNames(of: c) { known.insert(n); known.insert(n.hasPrefix("_") ? String(n.dropFirst()) : "_" + n) }
            for n in propertyNames(of: c) { known.insert(n) }
            current = class_getSuperclass(c)
        }
        guard known.contains(key) else { return nil }
        return object.value(forKey: key)
    }

    /// Try a list of candidate key names, return the first that yields a value.
    static func firstValue(_ object: NSObject, keys: [String]) -> (String, Any)? {
        for k in keys {
            if let v = safeValue(object, forKey: k), !(v is NSNull) {
                return (k, v)
            }
        }
        return nil
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
