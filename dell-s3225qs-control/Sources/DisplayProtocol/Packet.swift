import Foundation

public struct Brightness: Equatable, Sendable {
    public let current: Int
    public let maximum: Int
    public var percent: Int { Int((Double(current) / Double(maximum) * 100).rounded()) }
}

public enum Feature: UInt8 {
    case brightness = 0x10
    case volume = 0x62
}

public enum ControlError: LocalizedError {
    case unavailable, communication, invalidReply, rejected(Int)
    public var errorDescription: String? {
        switch self {
        case .unavailable: return "No controllable external display found. Reconnect the monitor and refresh."
        case .communication: return "The monitor did not respond. Enable DDC/CI in its menu, then refresh."
        case .invalidReply: return "The monitor returned an unsupported or invalid value. Check DDC/CI; for brightness, also turn off HDR."
        case .rejected(let value): return "The monitor kept the setting at \(value)%. Check its settings and try again."
        }
    }
}

// Wire format excludes the source byte, supplied separately to IOAVService.
public enum Packet {
    static func request(_ payload: [UInt8]) -> [UInt8] {
        let body = [UInt8(0x80 | payload.count)] + payload
        return body + [body.reduce(UInt8(0x6e ^ 0x51), ^)]
    }
    public static func read(_ feature: Feature = .brightness) -> [UInt8] { request([0x01, feature.rawValue]) }
    public static func write(_ value: UInt16, feature: Feature = .brightness) -> [UInt8] {
        request([0x03, feature.rawValue, UInt8(value >> 8), UInt8(value & 255)])
    }
    public static func parse(_ bytes: [UInt8], feature: Feature = .brightness) throws -> Brightness {
        guard bytes.count >= 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 2, bytes[3] == 0, bytes[4] == feature.rawValue,
              bytes.prefix(11).reduce(UInt8(0x50), ^) == 0 else { throw ControlError.invalidReply }
        let maximum = Int(bytes[6]) << 8 | Int(bytes[7])
        let current = Int(bytes[8]) << 8 | Int(bytes[9])
        guard maximum > 0, current <= maximum else { throw ControlError.invalidReply }
        return Brightness(current: current, maximum: maximum)
    }
}
