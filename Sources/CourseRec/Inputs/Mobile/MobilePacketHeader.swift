import Foundation

/// AndroidScreenMonitor 每个 UDP 分片前的 24 字节大端头。
///
/// ```
///  0 magic  1 version  2 flags  3 reserved
///  4 frameSeq(i32)  8 fragCount(u16)  10 fragIndex(u16)
/// 12 payloadLen(u16)  14 ptsUs(i64)  22 reserved(u16)
/// ```
struct MobilePacketHeader: Equatable {
    let flags: Int
    let frameSeq: Int
    let fragCount: Int
    let fragIndex: Int
    let payloadLen: Int
    let ptsUs: Int64

    var isKeyframe: Bool { flags & MobileWire.flagKeyframe != 0 }
    var isConfig: Bool { flags & MobileWire.flagConfig != 0 }

    static func parse(_ bytes: [UInt8], offset: Int = 0, length: Int) -> Self? {
        guard offset >= 0,
              length >= MobileWire.headerSize,
              offset + length <= bytes.count,
              bytes[offset] == MobileWire.magic,
              bytes[offset + 1] == MobileWire.version
        else { return nil }

        return Self(
            flags: Int(bytes[offset + 2]),
            frameSeq: readI32(bytes, offset + 4),
            fragCount: readU16(bytes, offset + 8),
            fragIndex: readU16(bytes, offset + 10),
            payloadLen: readU16(bytes, offset + 12),
            ptsUs: readI64(bytes, offset + 14)
        )
    }

    func write(into bytes: inout [UInt8]) {
        precondition(bytes.count >= MobileWire.headerSize)
        bytes[0] = MobileWire.magic
        bytes[1] = MobileWire.version
        bytes[2] = UInt8(truncatingIfNeeded: flags)
        bytes[3] = 0
        Self.writeI32(&bytes, 4, frameSeq)
        Self.writeU16(&bytes, 8, fragCount)
        Self.writeU16(&bytes, 10, fragIndex)
        Self.writeU16(&bytes, 12, payloadLen)
        Self.writeI64(&bytes, 14, ptsUs)
        Self.writeU16(&bytes, 22, 0)
    }

    private static func readI32(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 24)
            | (Int(bytes[offset + 1]) << 16)
            | (Int(bytes[offset + 2]) << 8)
            | Int(bytes[offset + 3])
    }

    private static func readU16(_ bytes: [UInt8], _ offset: Int) -> Int {
        (Int(bytes[offset]) << 8) | Int(bytes[offset + 1])
    }

    private static func readI64(_ bytes: [UInt8], _ offset: Int) -> Int64 {
        var value: Int64 = 0
        for index in 0 ..< 8 {
            value = (value << 8) | Int64(bytes[offset + index])
        }
        return value
    }

    private static func writeI32(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 24)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeU16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func writeI64(_ bytes: inout [UInt8], _ offset: Int, _ value: Int64) {
        for index in 0 ..< 8 {
            bytes[offset + index] = UInt8(truncatingIfNeeded: value >> (56 - index * 8))
        }
    }
}
