import AVFoundation
import AudioToolbox
import Darwin
import Foundation

private final class MockStreamer: @unchecked Sendable {
    let port: UInt16

    private let codec: String
    private let encodedFrame: [UInt8]
    private let listener: Int32
    private var client: Int32 = -1

    init(codec: String, encodedFrame: [UInt8]) throws {
        self.codec = codec
        self.encodedFrame = encodedFrame

        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { throw SmokeError.socketFailure }
        var one: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0, Darwin.listen(socket, 1) == 0 else {
            Darwin.close(socket)
            throw SmokeError.socketFailure
        }
        var bound = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bound, { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }) == 0 else {
            Darwin.close(socket)
            throw SmokeError.socketFailure
        }
        listener = socket
        port = UInt16(bigEndian: bound.sin_port)
    }

    func start() {
        Thread.detachNewThread { [weak self] in self?.serve() }
    }

    func stop() {
        if client >= 0 {
            Darwin.shutdown(client, SHUT_RDWR)
            Darwin.close(client)
            client = -1
        }
        Darwin.shutdown(listener, SHUT_RDWR)
        Darwin.close(listener)
    }

    private func serve() {
        let accepted = Darwin.accept(listener, nil, nil)
        guard accepted >= 0 else { return }
        client = accepted
        guard let hello = readLine(from: accepted),
              hello.hasPrefix("HELLO "),
              let mediaPort = UInt16(hello.dropFirst(6))
        else { return }
        sendLine("OK 64 64 \(codec) screen aac 48000 2", to: accepted)

        while let line = readLine(from: accepted) {
            if line == "KEYFRAME" {
                sendFrame([0x11, 0x90], flags: MobileWire.flagAudio | MobileWire.flagConfig, sequence: 1, to: mediaPort)
                sendFrame([0x21, 0x10, 0x04, 0x60], flags: MobileWire.flagAudio, sequence: 2, to: mediaPort)
                sendFrame(encodedFrame, flags: MobileWire.flagKeyframe | MobileWire.flagConfig, sequence: 3, to: mediaPort)
            } else if line == "BYE" {
                return
            }
        }
    }

    private func sendFrame(
        _ frame: [UInt8],
        flags: Int,
        sequence: Int,
        to mediaPort: UInt16
    ) {
        let socket = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard socket >= 0 else { return }
        defer { Darwin.close(socket) }
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = mediaPort.bigEndian
        target.sin_addr.s_addr = inet_addr("127.0.0.1")

        let fragmentCount = max(1, Int(ceil(Double(frame.count) / Double(MobileWire.maxPayload))))
        for index in 0 ..< fragmentCount {
            let start = index * MobileWire.maxPayload
            let end = min(frame.count, start + MobileWire.maxPayload)
            let payload = Array(frame[start ..< end])
            let header = MobilePacketHeader(
                flags: flags,
                frameSeq: sequence,
                fragCount: fragmentCount,
                fragIndex: index,
                payloadLen: payload.count,
                ptsUs: Int64(Date().timeIntervalSince1970 * 1_000_000)
            )
            var datagram = [UInt8](repeating: 0, count: MobileWire.headerSize)
            header.write(into: &datagram)
            datagram.append(contentsOf: payload)
            _ = datagram.withUnsafeBytes { bytes in
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(socket, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            usleep(200)
        }
    }

    private func sendLine(_ line: String, to socket: Int32) {
        let bytes = Array((line + "\n").utf8)
        _ = bytes.withUnsafeBytes { Darwin.send(socket, $0.baseAddress, $0.count, 0) }
    }

    private func readLine(from socket: Int32) -> String? {
        var bytes: [UInt8] = []
        var byte: UInt8 = 0
        while bytes.count < 1_024 {
            guard Darwin.recv(socket, &byte, 1, 0) > 0 else { return nil }
            if byte == 0x0A { return String(decoding: bytes, as: UTF8.self) }
            if byte != 0x0D { bytes.append(byte) }
        }
        return nil
    }
}

private enum SmokeError: Error {
    case invalidArguments
    case socketFailure
    case decodeTimeout
}

@main
private enum MobileInputSmoke {
    static func main() throws {
        guard CommandLine.arguments.count == 4 else { throw SmokeError.invalidArguments }
        let codec = CommandLine.arguments[1]
        let data = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2]))
        try checkAACPassthrough(URL(fileURLWithPath: CommandLine.arguments[3]))
        let server = try MockStreamer(codec: codec, encodedFrame: [UInt8](data))
        server.start()

        let decoded = DispatchSemaphore(value: 0)
        let receivedAudio = DispatchSemaphore(value: 0)
        let input = MobileInputClient()
        input.onStatus = { print("status: \($0)") }
        input.onVideo = { sample in
            guard let image = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetWidth(image) == 64,
                  CVPixelBufferGetHeight(image) == 64
            else { return }
            decoded.signal()
        }
        input.onAudio = { sample in
            guard CMSampleBufferGetNumSamples(sample) == 1 else { return }
            receivedAudio.signal()
        }
        input.start(
            streamer: MobileStreamer(
                name: "mock",
                host: "127.0.0.1",
                controlPort: server.port,
                sourceKind: .screen
            ),
            expectedKind: .screen
        )
        let result = decoded.wait(timeout: .now() + 8)
        let audioResult = receivedAudio.wait(timeout: .now() + 2)
        input.stop()
        server.stop()
        guard result == .success, audioResult == .success else { throw SmokeError.decodeTimeout }
        print("PASS: \(codec) + AAC TCP/UDP ingest")
    }

    private static func checkAACPassthrough(_ adtsURL: URL) throws {
        let adts = [UInt8](try Data(contentsOf: adtsURL))
        guard adts.count >= 9,
              adts[0] == 0xFF,
              adts[1] & 0xF0 == 0xF0
        else { throw SmokeError.socketFailure }
        let headerLength = adts[1] & 0x01 == 1 ? 7 : 9
        let frameLength = (Int(adts[3] & 0x03) << 11)
            | (Int(adts[4]) << 3)
            | (Int(adts[5]) >> 5)
        guard frameLength > headerLength, frameLength <= adts.count else {
            throw SmokeError.socketFailure
        }
        let profile = Int((adts[2] >> 6) & 0x03) + 1
        let frequencyIndex = Int((adts[2] >> 2) & 0x0F)
        let channelConfig = (Int(adts[2] & 0x01) << 2) | Int((adts[3] >> 6) & 0x03)
        let audioSpecificConfig = [
            UInt8((profile << 3) | (frequencyIndex >> 1)),
            UInt8(((frequencyIndex & 1) << 7) | (channelConfig << 3))
        ]
        let payload = Array(adts[headerLength ..< frameLength])
        let builder = MobileAudioSampleBuilder(
            sampleRate: 48_000,
            channels: 2,
            timeline: MobileTimeline()
        )
        let config = MobileFrame(
            sequence: 1,
            flags: MobileWire.flagAudio | MobileWire.flagConfig,
            ptsUs: 1_000_000,
            data: audioSpecificConfig
        )
        guard builder.consume(config) == nil else { throw SmokeError.socketFailure }
        let accessUnit = MobileFrame(
            sequence: 2,
            flags: MobileWire.flagAudio,
            ptsUs: 1_021_333,
            data: payload
        )
        guard let sample = builder.consume(accessUnit),
              let format = CMSampleBufferGetFormatDescription(sample),
              CMFormatDescriptionGetMediaSubType(format) == kAudioFormatMPEG4AAC
        else { throw SmokeError.socketFailure }

        try checkMismatchedWriterRejects(sample)

        let output = temporaryM4A("hinted")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try TrackWriter(
            url: output,
            audioTracks: ["audio"],
            audioFormatHints: ["audio": format]
        )
        writer.startIfNeeded(t0: CMSampleBufferGetPresentationTimeStamp(sample))
        guard writer.appendAudio(sample, track: "audio") else { throw SmokeError.socketFailure }
        let finished = DispatchSemaphore(value: 0)
        writer.finish { finished.signal() }
        guard finished.wait(timeout: .now() + 5) == .success,
              let size = try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0
        else { throw SmokeError.socketFailure }
        guard isReadableAACAsset(output) else { throw SmokeError.socketFailure }
        print("PASS: AAC config + CMSampleBuffer + M4A passthrough")
    }

    private static func checkMismatchedWriterRejects(_ sample: CMSampleBuffer) throws {
        let output = temporaryM4A("mismatch")
        defer { try? FileManager.default.removeItem(at: output) }
        let writer = try TrackWriter(url: output, audioTracks: ["audio"])
        writer.startIfNeeded(t0: CMSampleBufferGetPresentationTimeStamp(sample))
        guard !writer.appendAudio(sample, track: "audio"), writer.snapshot.state == .failed else {
            throw SmokeError.socketFailure
        }
        writer.cancel()
        print("PASS: compressed AAC is rejected from a PCM writer without crashing")
    }

    private static func temporaryM4A(_ suffix: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("courserec-aac-\(suffix)-\(UUID().uuidString).m4a")
    }

    private static func isReadableAACAsset(_ url: URL) -> Bool {
        var audioFile: AudioFileID?
        guard AudioFileOpenURL(url as CFURL, .readPermission, 0, &audioFile) == noErr,
              let audioFile
        else { return false }
        defer { AudioFileClose(audioFile) }

        var format = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var packetCount: UInt64 = 0
        var packetCountSize = UInt32(MemoryLayout<UInt64>.size)
        return AudioFileGetProperty(
            audioFile,
            kAudioFilePropertyDataFormat,
            &formatSize,
            &format
        ) == noErr
            && AudioFileGetProperty(
                audioFile,
                kAudioFilePropertyAudioDataPacketCount,
                &packetCountSize,
                &packetCount
            ) == noErr
            && format.mFormatID == kAudioFormatMPEG4AAC
            && packetCount > 0
    }
}
