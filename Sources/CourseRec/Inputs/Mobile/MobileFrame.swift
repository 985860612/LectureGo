import Foundation

struct MobileFrame: Sendable {
    let sequence: Int
    let flags: Int
    let ptsUs: Int64
    let data: [UInt8]

    var isKeyframe: Bool { flags & MobileWire.flagKeyframe != 0 }
    var isConfig: Bool { flags & MobileWire.flagConfig != 0 }
    var isAudio: Bool { flags & MobileWire.flagAudio != 0 }
}
