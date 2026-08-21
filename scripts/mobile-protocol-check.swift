import Foundation

@main
enum MobileProtocolCheck {
    static func main() {
        run("header round-trip", headerRoundTrip)
        run("audio flags round-trip", audioFlagsRoundTrip)
        run("invalid header rejected", invalidHeaderRejected)
        run("single fragment", singleFragment)
        run("out-of-order fragments", outOfOrderFragments)
        run("duplicate fragment ignored", duplicateFragmentIgnored)
        run("lost frame dropped", lostFrameDropped)
        run("stale fragment ignored", staleFragmentIgnored)
        run("truncated payload rejected", truncatedPayloadRejected)
        print("ALL PASS")
    }

    private static func run(_ name: String, _ check: () -> Bool) {
        guard check() else {
            FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8))
            exit(1)
        }
        print("ok: \(name)")
    }

    private static func headerRoundTrip() -> Bool {
        let header = MobilePacketHeader(
            flags: MobileWire.flagKeyframe,
            frameSeq: 0x1234_5678,
            fragCount: 3,
            fragIndex: 2,
            payloadLen: 1199,
            ptsUs: 1_777_000_123_456
        )
        var bytes = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &bytes)
        return MobilePacketHeader.parse(bytes, length: bytes.count) == header
    }

    private static func invalidHeaderRejected() -> Bool {
        var bytes = [UInt8](repeating: 0, count: MobileWire.headerSize)
        bytes[0] = 0xFF
        return MobilePacketHeader.parse([], length: 0) == nil
            && MobilePacketHeader.parse(bytes, length: bytes.count) == nil
    }

    private static func audioFlagsRoundTrip() -> Bool {
        let payload = [UInt8](repeating: 0x5A, count: 8)
        let header = MobilePacketHeader(
            flags: MobileWire.flagAudio | MobileWire.flagConfig,
            frameSeq: 2,
            fragCount: 1,
            fragIndex: 0,
            payloadLen: payload.count,
            ptsUs: 42
        )
        var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &datagram)
        datagram.append(contentsOf: payload)
        guard let frame = MobileReassembler().onFragment(
            header,
            datagram: datagram,
            payloadOffset: MobileWire.headerSize
        ) else { return false }
        return frame.isAudio && frame.isConfig && !frame.isKeyframe
    }

    private static func outOfOrderFragments() -> Bool {
        let reassembler = MobileReassembler()
        let fragments = [Array("abc".utf8), Array("def".utf8), Array("ghi".utf8)]
        guard feed(fragments[2], index: 2, sequence: 9, into: reassembler) == nil,
              feed(fragments[0], index: 0, sequence: 9, into: reassembler) == nil,
              let frame = feed(fragments[1], index: 1, sequence: 9, into: reassembler)
        else { return false }
        return frame.sequence == 9 && frame.data == Array("abcdefghi".utf8)
    }

    private static func singleFragment() -> Bool {
        let reassembler = MobileReassembler()
        let payload = Array("frame".utf8)
        let header = MobilePacketHeader(
            flags: MobileWire.flagKeyframe,
            frameSeq: 1,
            fragCount: 1,
            fragIndex: 0,
            payloadLen: payload.count,
            ptsUs: 456
        )
        var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &datagram)
        datagram.append(contentsOf: payload)
        let frame = reassembler.onFragment(
            header,
            datagram: datagram,
            payloadOffset: MobileWire.headerSize
        )
        return frame?.data == payload && frame?.isKeyframe == true
    }

    private static func duplicateFragmentIgnored() -> Bool {
        let reassembler = MobileReassembler()
        let first = Array("abc".utf8)
        let second = Array("def".utf8)
        guard feed(first, index: 0, sequence: 12, into: reassembler) == nil,
              feed(first, index: 0, sequence: 12, into: reassembler) == nil,
              feed(second, index: 1, sequence: 12, into: reassembler) == nil
        else { return false }
        return true
    }

    private static func lostFrameDropped() -> Bool {
        let reassembler = MobileReassembler()
        _ = feed(Array("old".utf8), index: 0, sequence: 20, into: reassembler)
        let payload = Array("new".utf8)
        let header = MobilePacketHeader(
            flags: 0,
            frameSeq: 21,
            fragCount: 1,
            fragIndex: 0,
            payloadLen: payload.count,
            ptsUs: 500
        )
        var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &datagram)
        datagram.append(contentsOf: payload)
        let frame = reassembler.onFragment(
            header,
            datagram: datagram,
            payloadOffset: MobileWire.headerSize
        )
        return frame?.sequence == 21 && reassembler.droppedFrames == 1
    }

    private static func staleFragmentIgnored() -> Bool {
        let reassembler = MobileReassembler()
        let payload = Array("new".utf8)
        let header = MobilePacketHeader(
            flags: 0,
            frameSeq: 31,
            fragCount: 1,
            fragIndex: 0,
            payloadLen: payload.count,
            ptsUs: 600
        )
        var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &datagram)
        datagram.append(contentsOf: payload)
        guard reassembler.onFragment(
            header,
            datagram: datagram,
            payloadOffset: MobileWire.headerSize
        ) != nil else { return false }
        return feed(Array("old".utf8), index: 0, sequence: 30, into: reassembler) == nil
    }

    private static func truncatedPayloadRejected() -> Bool {
        let reassembler = MobileReassembler()
        let header = MobilePacketHeader(
            flags: 0,
            frameSeq: 1,
            fragCount: 1,
            fragIndex: 0,
            payloadLen: 10,
            ptsUs: 0
        )
        return reassembler.onFragment(
            header,
            datagram: [UInt8](repeating: 0, count: MobileWire.headerSize + 2),
            payloadOffset: MobileWire.headerSize
        ) == nil
    }

    private static func feed(
        _ payload: [UInt8],
        index: Int,
        sequence: Int,
        into reassembler: MobileReassembler
    ) -> MobileFrame? {
        let header = MobilePacketHeader(
            flags: MobileWire.flagKeyframe,
            frameSeq: sequence,
            fragCount: 3,
            fragIndex: index,
            payloadLen: payload.count,
            ptsUs: 123
        )
        var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
        header.write(into: &datagram)
        datagram.append(contentsOf: payload)
        return reassembler.onFragment(
            header,
            datagram: datagram,
            payloadOffset: MobileWire.headerSize
        )
    }
}
