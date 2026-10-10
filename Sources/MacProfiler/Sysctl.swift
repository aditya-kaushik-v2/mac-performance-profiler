import Foundation
import Darwin

enum Sysctl {
    static func integer(_ name: String) -> Int64? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        if size == MemoryLayout<Int64>.stride {
            var value: Int64 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return value
        }
        if size == MemoryLayout<Int32>.stride {
            var value: Int32 = 0
            guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
            return Int64(value)
        }
        return nil
    }

    static func unsigned(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.stride
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size + 1)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    static func bootDate() -> Date? {
        var boot = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(boot.tv_sec) + TimeInterval(boot.tv_usec) / 1_000_000)
    }
}

enum CString {
    static func fromTuple<T>(_ value: T) -> String {
        withUnsafePointer(to: value) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) {
                String(cString: $0)
            }
        }
    }
}

func signedRegistryInteger(_ any: Any?) -> Int64? {
    guard let number = any as? NSNumber else { return nil }
    let magnitude = number.doubleValue
    if magnitude < 0 { return number.int64Value }
    if magnitude > Double(Int64.max) {
        return Int64(bitPattern: number.uint64Value)
    }
    return number.int64Value
}

func registryDouble(_ any: Any?) -> Double? {
    switch any {
    case let number as NSNumber:
        return number.doubleValue
    case let value as Double:
        return value
    case let value as Int:
        return Double(value)
    default:
        return nil
    }
}
