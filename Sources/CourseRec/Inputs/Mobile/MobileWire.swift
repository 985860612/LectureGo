import Foundation

/// AndroidScreenMonitor 局域网直连协议常量。此处故意不包含中转协议。
enum MobileWire {
    static let magic: UInt8 = 0xAB
    static let version: UInt8 = 1
    static let headerSize = 24
    static let maxPayload = 1200
    static let maxFragments = 4096

    static let flagKeyframe = 0x01
    static let flagConfig = 0x02
    static let flagAudio = 0x04

    static let defaultControlPort: UInt16 = 6060
    static let bonjourServiceType = "_screenmon._tcp."
    static let bonjourDomain = "local."

    static let codecH264 = "h264"
    static let codecH265 = "h265"
    static let audioCodecAAC = "aac"
}
