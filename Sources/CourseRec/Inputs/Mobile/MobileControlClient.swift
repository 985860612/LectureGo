import Darwin
import Foundation

/// AndroidScreenMonitor 局域网控制通道：TCP `HELLO` / `OK` / `KEYFRAME` / `BYE`。
final class MobileControlClient: @unchecked Sendable {
    struct StreamInfo: Sendable {
        let width: Int
        let height: Int
        let codec: String
        let peerHost: String
        let sourceKind: MobileSourceKind
        let audioCodec: String?
        let audioSampleRate: Int?
        let audioChannels: Int?
    }

    enum ClientError: LocalizedError {
        case resolveFailed(String)
        case connectFailed(String, UInt16)
        case invalidHandshake(String)

        var errorDescription: String? {
            switch self {
            case let .resolveFailed(host): return "无法解析移动端地址：\(host)"
            case let .connectFailed(host, port): return "无法连接移动端：\(host):\(port)"
            case let .invalidHandshake(line): return "移动端握手响应无效：\(line)"
            }
        }
    }

    private let stateLock = NSLock()
    private var descriptor: Int32 = -1

    func connect(host: String, controlPort: UInt16, mediaPort: UInt16) throws -> StreamInfo {
        close(sendBye: false)
        let socket = try Self.connectSocket(host: host, port: controlPort, timeoutMs: 3_000)
        var one: Int32 = 1
        setsockopt(socket, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(
            socket,
            SOL_SOCKET,
            SO_RCVTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        setsockopt(
            socket,
            SOL_SOCKET,
            SO_SNDTIMEO,
            &timeout,
            socklen_t(MemoryLayout.size(ofValue: timeout))
        )
        stateLock.withLock { descriptor = socket }

        sendLine("HELLO \(mediaPort)")
        guard let line = readLine() else {
            close(sendBye: false)
            throw ClientError.invalidHandshake("无响应")
        }
        let parts = line.split(separator: " ")
        guard parts.first?.uppercased() == "OK",
              parts.count >= 3,
              let width = Int(parts[1]), width > 0,
              let height = Int(parts[2]), height > 0
        else {
            close(sendBye: false)
            throw ClientError.invalidHandshake(line)
        }
        let codec = parts.count >= 4 ? String(parts[3]).lowercased() : MobileWire.codecH264
        guard codec == MobileWire.codecH264 || codec == MobileWire.codecH265 else {
            close(sendBye: false)
            throw ClientError.invalidHandshake("不支持的编码 \(codec)")
        }
        let sourceKind = parts.count >= 5
            ? MobileSourceKind(rawValue: String(parts[4]).lowercased()) ?? .unknown
            : .unknown
        let audioCodec = parts.count >= 6 ? String(parts[5]).lowercased() : nil
        let audioSampleRate = parts.count >= 7 ? Int(parts[6]) : nil
        let audioChannels = parts.count >= 8 ? Int(parts[7]) : nil
        if let audioCodec, audioCodec != MobileWire.audioCodecAAC {
            close(sendBye: false)
            throw ClientError.invalidHandshake("不支持的音频编码 \(audioCodec)")
        }
        return StreamInfo(
            width: width,
            height: height,
            codec: codec,
            peerHost: Self.peerHost(of: socket) ?? host,
            sourceKind: sourceKind,
            audioCodec: audioCodec,
            audioSampleRate: audioSampleRate,
            audioChannels: audioChannels
        )
    }

    func keepAlive() {
        sendLine("NOP")
    }

    func requestKeyframe() {
        sendLine("KEYFRAME")
    }

    func close() {
        close(sendBye: true)
    }

    private func close(sendBye: Bool) {
        let socket = stateLock.withLock { () -> Int32 in
            let current = descriptor
            descriptor = -1
            return current
        }
        guard socket >= 0 else { return }
        if sendBye {
            Self.send("BYE\n", to: socket)
        }
        Darwin.shutdown(socket, SHUT_RDWR)
        Darwin.close(socket)
    }

    private func sendLine(_ line: String) {
        let socket = stateLock.withLock { descriptor }
        guard socket >= 0 else { return }
        Self.send(line + "\n", to: socket)
    }

    private static func send(_ text: String, to socket: Int32) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { raw in
            Darwin.send(socket, raw.baseAddress, raw.count, 0)
        }
    }

    private func readLine() -> String? {
        let socket = stateLock.withLock { descriptor }
        guard socket >= 0 else { return nil }
        var output: [UInt8] = []
        output.reserveCapacity(64)
        var byte: UInt8 = 0
        while output.count < 1_024 {
            let count = Darwin.recv(socket, &byte, 1, 0)
            guard count > 0 else { return nil }
            if byte == 0x0A { return String(decoding: output, as: UTF8.self) }
            if byte != 0x0D { output.append(byte) }
        }
        return nil
    }

    private static func connectSocket(host: String, port: UInt16, timeoutMs: Int32) throws -> Int32 {
        var hints = addrinfo(
            ai_flags: AI_ADDRCONFIG,
            ai_family: AF_UNSPEC,
            ai_socktype: SOCK_STREAM,
            ai_protocol: IPPROTO_TCP,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &result)
        guard status == 0, let first = result else { throw ClientError.resolveFailed(host) }
        defer { freeaddrinfo(result) }

        var candidate: UnsafeMutablePointer<addrinfo>? = first
        while let info = candidate?.pointee {
            let socket = Darwin.socket(info.ai_family, info.ai_socktype, info.ai_protocol)
            if socket >= 0 {
                let originalFlags = fcntl(socket, F_GETFL, 0)
                _ = fcntl(socket, F_SETFL, originalFlags | O_NONBLOCK)
                let connectStatus = Darwin.connect(socket, info.ai_addr, info.ai_addrlen)
                var connected = connectStatus == 0
                if !connected, errno == EINPROGRESS {
                    var descriptor = pollfd(fd: socket, events: Int16(POLLOUT), revents: 0)
                    if poll(&descriptor, 1, timeoutMs) > 0 {
                        var socketError: Int32 = 0
                        var length = socklen_t(MemoryLayout.size(ofValue: socketError))
                        getsockopt(socket, SOL_SOCKET, SO_ERROR, &socketError, &length)
                        connected = socketError == 0
                    }
                }
                _ = fcntl(socket, F_SETFL, originalFlags)
                if connected { return socket }
                Darwin.close(socket)
            }
            candidate = info.ai_next
        }
        throw ClientError.connectFailed(host, port)
    }

    private static func peerHost(of socket: Int32) -> String? {
        var address = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        guard withUnsafeMutablePointer(to: &address, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getpeername(socket, $0, &length)
            }
        }) == 0 else { return nil }

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            }
        }
        return status == 0 ? String(cString: host) : nil
    }
}
