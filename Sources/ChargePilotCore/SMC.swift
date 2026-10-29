import CSMC
import Foundation
import IOKit

/// A four-character SMC key such as "CHIE", packed big-endian.
public struct FourCC: Hashable, CustomStringConvertible, Sendable {
    public let rawValue: UInt32

    public init(_ string: String) {
        var value: UInt32 = 0
        for byte in string.utf8.prefix(4) { value = value << 8 | UInt32(byte) }
        rawValue = value
    }

    public init(rawValue: UInt32) { self.rawValue = rawValue }

    public var description: String {
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: rawValue >> $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    public static func isValid(_ string: String) -> Bool {
        string.utf8.count == 4 && string.allSatisfy { $0.isASCII && !$0.isNewline }
    }
}

public struct SMCValue: Sendable {
    public let key: FourCC
    public let type: FourCC
    public let bytes: [UInt8]
    /// Attribute bits reported by the SMC; 0x40 means the key accepts writes.
    public let attributes: UInt8

    public var isWritable: Bool { attributes & 0x40 != 0 }
    public var hex: String { bytes.map { String(format: "%02x", $0) }.joined() }

    /// Apple Silicon SMCs store integers and floats little-endian; Intel ones big-endian.
    #if arch(arm64)
    static let littleEndian = true
    #else
    static let littleEndian = false
    #endif

    private func unsigned(_ count: Int) -> UInt64? {
        guard bytes.count >= count else { return nil }
        let ordered = Self.littleEndian ? bytes[0..<count].reversed() : Array(bytes[0..<count])
        return ordered.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
    }

    /// Interprets the value according to its SMC type, when that type is numeric.
    public var number: Double? {
        switch type.description {
        case "ui8 ", "flag": return bytes.first.map(Double.init)
        case "ui16": return unsigned(2).map { Double($0) }
        case "ui32": return unsigned(4).map { Double($0) }
        case "si8 ": return bytes.first.map { Double(Int8(bitPattern: $0)) }
        case "si16": return unsigned(2).map { Double(Int16(truncatingIfNeeded: $0)) }
        case "flt ":
            // Apple Silicon SMCs store floats little-endian.
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256
        default: return nil
        }
    }
}

public enum SMCError: Error, CustomStringConvertible {
    case unavailable(kern_return_t)
    case keyNotFound(String)
    case failed(String, kern_return_t)
    case badSize(String, expected: Int)

    public var description: String {
        switch self {
        case .unavailable(let code): return "AppleSMC inaccessible (0x\(String(code, radix: 16)))"
        case .keyNotFound(let key): return "Clé SMC \(key) absente"
        case .failed(let key, let code): return "Échec SMC sur \(key) (0x\(String(UInt32(bitPattern: code), radix: 16)))"
        case .badSize(let key, let expected): return "La clé \(key) attend \(expected) octet(s)"
        }
    }
}

/// Connection to the System Management Controller. Reading works for any user; writing needs root.
public final class SMC {
    private var connection: io_connect_t = 0
    private let lock = NSLock()

    public init() throws {
        let result = smc_open(&connection)
        guard result == KERN_SUCCESS else { throw SMCError.unavailable(result) }
    }

    deinit { smc_close(connection) }

    public func read(_ key: String) -> SMCValue? {
        try? readThrowing(key)
    }

    public func readThrowing(_ key: String) throws -> SMCValue {
        lock.lock(); defer { lock.unlock() }
        var info = SMCKeyInfo()
        var raw = [UInt8](repeating: 0, count: 32)
        let code = FourCC(key)
        let result = raw.withUnsafeMutableBufferPointer { smc_read(connection, code.rawValue, &info, $0.baseAddress) }
        if result == 0x84 { throw SMCError.keyNotFound(key) }
        guard result == KERN_SUCCESS else { throw SMCError.failed(key, result) }
        let size = min(Int(info.dataSize), 32)
        return SMCValue(key: code, type: FourCC(rawValue: info.dataType), bytes: Array(raw[0..<size]), attributes: info.dataAttributes)
    }

    public func exists(_ key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        var info = SMCKeyInfo()
        return smc_key_info(connection, FourCC(key).rawValue, &info) == KERN_SUCCESS
    }

    public func write(_ key: String, _ bytes: [UInt8]) throws {
        let current = try readThrowing(key)
        guard current.bytes.count == bytes.count else { throw SMCError.badSize(key, expected: current.bytes.count) }
        lock.lock(); defer { lock.unlock() }
        let result = bytes.withUnsafeBufferPointer { smc_write(connection, FourCC(key).rawValue, $0.baseAddress, UInt32(bytes.count)) }
        guard result == KERN_SUCCESS else { throw SMCError.failed(key, result) }
    }

    /// Every key the SMC lists, in index order.
    public func allKeys() -> [String] {
        lock.lock(); defer { lock.unlock() }
        var count: UInt32 = 0
        guard smc_key_count(connection, &count) == KERN_SUCCESS else { return [] }
        var keys: [String] = []
        for index in 0..<count {
            var key: UInt32 = 0
            if smc_key_at_index(connection, index, &key) == KERN_SUCCESS { keys.append(FourCC(rawValue: key).description) }
        }
        return keys
    }
}

public extension Array where Element == UInt8 {
    init?(hex: String) {
        let clean = hex.lowercased().replacingOccurrences(of: "0x", with: "").filter { !$0.isWhitespace }
        guard clean.count.isMultiple(of: 2), !clean.isEmpty else { return nil }
        var bytes: [UInt8] = []
        var index = clean.startIndex
        while index < clean.endIndex {
            let next = clean.index(index, offsetBy: 2)
            guard let byte = UInt8(clean[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self = bytes
    }
}
