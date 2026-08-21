import Darwin
import Foundation

/// 监听 UDP 6061，仅接收当前控制连接对应 IP 的媒体包。
final class MobileMediaReceiver: @unchecked Sendable {
    enum ReceiverError: LocalizedError {
        case socketCreationFailed
        case bindFailed(UInt16)

        var errorDescription: String? {
            switch self {
            case .socketCreationFailed: return "无法创建移动端 UDP 接收 socket"
            case let .bindFailed(port): return "无法监听移动端媒体端口 UDP \(port)"
            }
        }
    }

    var onFrame: (@Sendable (MobileFrame) -> Void)? {
        get { stateLock.withLock { frameHandler } }
        set { stateLock.withLock { frameHandler = newValue } }
    }
    var onVideoLoss: (@Sendable () -> Void)? {
        get { stateLock.withLock { videoLossHandler } }
        set { stateLock.withLock { videoLossHandler = newValue } }
    }

    private let requestedPort: UInt16
    private let stateLock = NSLock()
    private var descriptor: Int32 = -1
    private var expectedHost: String?
    private var frameHandler: (@Sendable (MobileFrame) -> Void)?
    private var videoLossHandler: (@Sendable () -> Void)?
    private var running = false
    private var boundPort: UInt16 = 0
    // Audio/video share one UDP socket but complete out of order; independent windows
    // prevent a small AAC packet from making an older multi-fragment 4K frame look stale.
    private let videoReassembler = MobileReassembler()
    private let audioReassembler = MobileReassembler()

    /// Port 0 lets the OS allocate a unique socket, allowing screen and camera phones concurrently.
    init(port: UInt16 = 0) {
        requestedPort = port
    }

    var listeningPort: UInt16 { stateLock.withLock { boundPort } }

    func setExpectedHost(_ host: String) {
        stateLock.withLock { expectedHost = Self.normalized(host) }
    }

    func start() throws {
        if stateLock.withLock({ running }) { return }
        let socket = Darwin.socket(AF_INET6, SOCK_DGRAM, 0)
        guard socket >= 0 else { throw ReceiverError.socketCreationFailed }

        var one: Int32 = 1
        var zero: Int32 = 0
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(socket, IPPROTO_IPV6, IPV6_V6ONLY, &zero, socklen_t(MemoryLayout.size(ofValue: zero)))
        var receiveBuffer: Int32 = 4 << 20
        setsockopt(socket, SOL_SOCKET, SO_RCVBUF, &receiveBuffer, socklen_t(MemoryLayout.size(ofValue: receiveBuffer)))

        var address = sockaddr_in6()
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_port = requestedPort.bigEndian
        address.sin6_addr = in6addr_any
        let bindStatus = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bindStatus == 0 else {
            Darwin.close(socket)
            throw ReceiverError.bindFailed(requestedPort)
        }

        var bound = sockaddr_in6()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let nameStatus = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &boundLength)
            }
        }
        guard nameStatus == 0 else {
            Darwin.close(socket)
            throw ReceiverError.bindFailed(requestedPort)
        }

        stateLock.withLock {
            descriptor = socket
            running = true
            boundPort = UInt16(bigEndian: bound.sin6_port)
        }
        Thread.detachNewThread { [weak self] in self?.receiveLoop(socket: socket) }
    }

    func stop() {
        let socket = stateLock.withLock { () -> Int32 in
            running = false
            let current = descriptor
            descriptor = -1
            boundPort = 0
            return current
        }
        guard socket >= 0 else { return }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func receiveLoop(socket: Int32) {
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while stateLock.withLock({ running && descriptor == socket }) {
            var sender = sockaddr_storage()
            var senderLength = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = buffer.withUnsafeMutableBytes { rawBuffer in
                withUnsafeMutablePointer(to: &sender) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(
                            socket,
                            rawBuffer.baseAddress,
                            rawBuffer.count,
                            0,
                            $0,
                            &senderLength
                        )
                    }
                }
            }
            guard count > 0 else { break }
            guard let host = Self.numericHost(sender, length: senderLength) else { continue }
            let expected = stateLock.withLock { expectedHost }
            guard expected == nil || Self.normalized(host) == expected else { continue }
            guard let header = MobilePacketHeader.parse(buffer, length: Int(count)),
                  MobileWire.headerSize + header.payloadLen <= count
            else { continue }
            let reassembler = header.flags & MobileWire.flagAudio != 0
                ? audioReassembler
                : videoReassembler
            let droppedBefore = reassembler.droppedFrames
            let frame = reassembler.onFragment(
                header,
                datagram: buffer,
                payloadOffset: MobileWire.headerSize
            )
            if reassembler === videoReassembler, reassembler.droppedFrames > droppedBefore {
                let lossHandler = stateLock.withLock { videoLossHandler }
                lossHandler?()
            }
            if let frame {
                let handler = stateLock.withLock { frameHandler }
                handler?(frame)
            }
        }
    }

    private static func numericHost(_ address: sockaddr_storage, length: socklen_t) -> String? {
        var address = address
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return status == 0 ? String(cString: host) : nil
    }

    private static func normalized(_ host: String) -> String {
        host.hasPrefix("::ffff:") ? String(host.dropFirst(7)) : host
    }
}
