import Darwin
import Foundation

/// 管理随 App 打包的 MediaMTX 子进程，只开放一个随机 RTMP 路径供局域网设备推流。
@MainActor
final class LocalRTMPReceiver {
    enum Phase: Equatable {
        case stopped
        case starting
        case ready
        case publishing
        case failed(String)
    }

    struct Snapshot: Equatable {
        let phase: Phase
        let streamName: String
        let publishURL: String
        let playbackURL: String
        let hasLANAddress: Bool

        var statusText: String {
            switch phase {
            case .stopped: return "接收服务已停止"
            case .starting: return "正在启动接收服务…"
            case .ready:
                return hasLANAddress ? "等待 RTMP 推流" : "未找到可用的局域网 IPv4"
            case .publishing: return "已检测到 RTMP 推流"
            case let .failed(message): return "接收服务失败：\(message)"
            }
        }

        var isReady: Bool {
            phase == .ready || phase == .publishing
        }
    }

    var onSnapshot: ((Snapshot) -> Void)?

    private static let streamNameDefaultsKey = "localRTMPStreamName"
    private static let port = 1935
    private var process: Process?
    private var outputPipe: Pipe?
    private var configURL: URL?
    private var generation = UUID()
    private var pendingLog = ""
    private var lastErrorLine = ""
    private var publisherConnectionMarker: String?
    private(set) var snapshot: Snapshot

    init() {
        let saved = UserDefaults.standard.string(forKey: Self.streamNameDefaultsKey)
        let streamName = Self.normalizedStreamName(saved)
        UserDefaults.standard.set(streamName, forKey: Self.streamNameDefaultsKey)
        snapshot = Self.makeSnapshot(streamName: streamName, phase: .stopped)
    }

    func start() {
        start(streamName: snapshot.streamName)
    }

    func regenerateStreamName() {
        let streamName = Self.makeStreamName()
        UserDefaults.standard.set(streamName, forKey: Self.streamNameDefaultsKey)
        start(streamName: streamName)
    }

    func stop() {
        generation = UUID()
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        if let process, process.isRunning { process.terminate() }
        self.process = nil
        if let configURL { try? FileManager.default.removeItem(at: configURL) }
        configURL = nil
        publish(Self.makeSnapshot(streamName: snapshot.streamName, phase: .stopped))
    }

    private func start(streamName: String) {
        stop()
        let token = UUID()
        generation = token
        pendingLog = ""
        lastErrorLine = ""
        publisherConnectionMarker = nil
        publish(Self.makeSnapshot(streamName: streamName, phase: .starting))

        guard let executable = Bundle.main.resourceURL?.appendingPathComponent("mediamtx"),
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            publish(Self.makeSnapshot(
                streamName: streamName,
                phase: .failed("应用包缺少 MediaMTX")
            ))
            return
        }

        do {
            let runtimeDirectory = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            )[0]
                .appendingPathComponent("CourseRec", isDirectory: true)
                .appendingPathComponent("Runtime", isDirectory: true)
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let config = runtimeDirectory.appendingPathComponent(
                "mediamtx-\(ProcessInfo.processInfo.processIdentifier).yml"
            )
            try Self.configuration(streamName: streamName).write(
                to: config,
                atomically: true,
                encoding: .utf8
            )
            configURL = config

            let pipe = Pipe()
            outputPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                Task { @MainActor in self?.consumeLog(text, token: token) }
            }

            let process = Process()
            process.executableURL = executable
            process.arguments = [config.path]
            process.standardOutput = pipe
            process.standardError = pipe
            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    self?.handleTermination(process, token: token)
                }
            }
            self.process = process
            try process.run()

            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(1))
                guard let self,
                      self.generation == token,
                      self.process?.isRunning == true,
                      self.snapshot.phase == .starting
                else { return }
                self.publish(Self.makeSnapshot(streamName: streamName, phase: .ready))
            }
        } catch {
            process = nil
            publish(Self.makeSnapshot(
                streamName: streamName,
                phase: .failed(error.localizedDescription)
            ))
        }
    }

    private func consumeLog(_ text: String, token: UUID) {
        guard generation == token else { return }
        pendingLog += text
        let lines = pendingLog.split(separator: "\n", omittingEmptySubsequences: false)
        pendingLog = lines.last.map(String.init) ?? ""
        for rawLine in lines.dropLast() {
            let line = String(rawLine)
            if line.localizedCaseInsensitiveContains("ERR") {
                lastErrorLine = Self.cleanLogLine(line)
            }
            if line.contains("[RTMP] listener opened on") {
                publish(Self.makeSnapshot(streamName: snapshot.streamName, phase: .ready))
            }
            if line.contains("is publishing to path 'live/\(snapshot.streamName)'") {
                publisherConnectionMarker = Self.connectionMarker(in: line)
                publish(Self.makeSnapshot(streamName: snapshot.streamName, phase: .publishing))
            } else if line.contains("closed:"),
                      let publisherConnectionMarker,
                      line.contains(publisherConnectionMarker) {
                self.publisherConnectionMarker = nil
                publish(Self.makeSnapshot(streamName: snapshot.streamName, phase: .ready))
            }
        }
    }

    private func handleTermination(_ terminated: Process, token: UUID) {
        guard generation == token, process === terminated else { return }
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        outputPipe = nil
        process = nil
        let reason = lastErrorLine.isEmpty
            ? "MediaMTX 已退出（代码 \(terminated.terminationStatus)）"
            : lastErrorLine
        publish(Self.makeSnapshot(streamName: snapshot.streamName, phase: .failed(reason)))
    }

    private func publish(_ value: Snapshot) {
        snapshot = value
        onSnapshot?(value)
    }

    private static func makeSnapshot(streamName: String, phase: Phase) -> Snapshot {
        let address = localIPv4Address()
        let externalHost = address ?? "127.0.0.1"
        return Snapshot(
            phase: phase,
            streamName: streamName,
            publishURL: "rtmp://\(externalHost):\(port)/live/\(streamName)",
            playbackURL: "rtmp://127.0.0.1:\(port)/live/\(streamName)",
            hasLANAddress: address != nil
        )
    }

    private static func configuration(streamName: String) -> String {
        """
        logLevel: info
        logDestinations: [stdout]
        writeQueueSize: 64
        api: false
        metrics: false
        pprof: false
        playback: false
        rtsp: false
        rtmp: true
        rtmpAddress: :\(port)
        rtmpEncryption: "no"
        hls: false
        webrtc: false
        srt: false
        paths:
          live/\(streamName):
            source: publisher
        """
    }

    private static func makeStreamName() -> String {
        let alphabet = Array("abcdefghjkmnpqrstuvwxyz23456789")
        return "stream-" + String((0 ..< 10).map { _ in alphabet.randomElement()! })
    }

    private static func isValidStreamName(_ value: String?) -> Bool {
        guard let value, value.hasPrefix("stream-"), value.count == 17 else { return false }
        return value.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
    }

    private static func normalizedStreamName(_ value: String?) -> String {
        if isValidStreamName(value), let value { return value }
        if let value, value.hasPrefix("dji-"), value.count == 14 {
            return "stream-" + value.dropFirst(4)
        }
        return makeStreamName()
    }

    private static func cleanLogLine(_ line: String) -> String {
        guard let range = line.range(of: "ERR:") else { return line }
        return line[range.upperBound...].trimmingCharacters(in: .whitespaces)
    }

    private static func connectionMarker(in line: String) -> String? {
        guard let start = line.range(of: "[conn "),
              let end = line[start.lowerBound...].firstIndex(of: "]")
        else { return nil }
        return String(line[start.lowerBound ... end])
    }

    private static func localIPv4Address() -> String? {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else { return nil }
        defer { freeifaddrs(pointer) }

        var candidates: [(score: Int, address: String)] = []
        for interface in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let address = interface.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET)
            else { continue }
            let flags = Int32(interface.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let name = String(cString: interface.pointee.ifa_name)
            let excludedPrefixes = ["utun", "awdl", "llw", "bridge", "vmenet", "vmnet", "docker", "pdp_ip"]
            guard !excludedPrefixes.contains(where: name.hasPrefix) else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                address,
                socklen_t(address.pointee.sa_len),
                &host,
                socklen_t(host.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let value = String(cString: host)
            guard !value.hasPrefix("169.254.") else { continue }
            let score = name == "en0" ? 0 : (name.hasPrefix("en") ? 1 : 2)
            candidates.append((score, value))
        }
        return candidates.sorted { $0.score < $1.score }.first?.address
    }
}
