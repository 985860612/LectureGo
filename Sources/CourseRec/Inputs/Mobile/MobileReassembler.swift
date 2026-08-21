import Foundation

/// 单路移动端媒体分片重组。缺片帧直接丢弃，不跨帧等待，优先保证低延迟。
final class MobileReassembler {
    private final class Pending {
        let flags: Int
        let ptsUs: Int64
        var parts: [[UInt8]?]
        var received = 0
        var totalLength = 0

        init(fragmentCount: Int, flags: Int, ptsUs: Int64) {
            self.flags = flags
            self.ptsUs = ptsUs
            parts = Array(repeating: nil, count: fragmentCount)
        }
    }

    private let window: Int
    private var pending: [Int: Pending] = [:]
    private var lastEmitted = -1
    private(set) var droppedFrames = 0

    init(window: Int = 8) {
        self.window = window
    }

    func onFragment(
        _ header: MobilePacketHeader,
        datagram: [UInt8],
        payloadOffset: Int
    ) -> MobileFrame? {
        guard header.frameSeq > lastEmitted,
              header.fragCount > 0,
              header.fragCount <= MobileWire.maxFragments,
              header.fragIndex >= 0,
              header.fragIndex < header.fragCount,
              header.payloadLen >= 0,
              header.payloadLen <= MobileWire.maxPayload,
              payloadOffset >= 0,
              payloadOffset + header.payloadLen <= datagram.count
        else { return nil }

        var frame = pending[header.frameSeq]
        if frame == nil {
            frame = Pending(
                fragmentCount: header.fragCount,
                flags: header.flags,
                ptsUs: header.ptsUs
            )
            pending[header.frameSeq] = frame
            evictStale(newestSequence: header.frameSeq)
        }
        guard let frame, frame.parts.count == header.fragCount else { return nil }

        if frame.parts[header.fragIndex] == nil {
            let end = payloadOffset + header.payloadLen
            frame.parts[header.fragIndex] = Array(datagram[payloadOffset ..< end])
            frame.received += 1
            frame.totalLength += header.payloadLen
        }

        guard frame.received == frame.parts.count else { return nil }
        pending.removeValue(forKey: header.frameSeq)
        lastEmitted = header.frameSeq
        for sequence in Array(pending.keys) where sequence <= lastEmitted {
            pending.removeValue(forKey: sequence)
            droppedFrames += 1
        }

        var data: [UInt8] = []
        data.reserveCapacity(frame.totalLength)
        for part in frame.parts {
            guard let part else { return nil }
            data.append(contentsOf: part)
        }
        return MobileFrame(
            sequence: header.frameSeq,
            flags: frame.flags,
            ptsUs: frame.ptsUs,
            data: data
        )
    }

    private func evictStale(newestSequence: Int) {
        guard pending.count > window else { return }
        let threshold = newestSequence - window
        for sequence in Array(pending.keys) where sequence < threshold {
            pending.removeValue(forKey: sequence)
            droppedFrames += 1
        }
    }
}
