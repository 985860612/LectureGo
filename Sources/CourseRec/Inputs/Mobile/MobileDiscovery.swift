import Darwin
import Foundation

/// 通过 Bonjour 浏览 AndroidScreenMonitor 注册的 `_screenmon._tcp` 服务。
final class MobileDiscovery: NSObject {
    var onStreamersChanged: (([MobileStreamer]) -> Void)?

    private let browser = NetServiceBrowser()
    private var resolving: [String: NetService] = [:]
    private var streamers: [String: MobileStreamer] = [:]

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(
            ofType: MobileWire.bonjourServiceType,
            inDomain: MobileWire.bonjourDomain
        )
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        browser.stop()
        resolving.values.forEach { $0.stop() }
        resolving.removeAll()
        streamers.removeAll()
        publish()
    }

    private func publish() {
        onStreamersChanged?(streamers.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        })
    }

    private static func serviceKey(_ service: NetService) -> String {
        "\(service.name)|\(service.type)|\(service.domain)"
    }

    private static func numericHosts(from service: NetService) -> [String] {
        guard let addresses = service.addresses else { return [] }
        return addresses.compactMap { data -> (String, Int32)? in
            data.withUnsafeBytes { raw -> (String, Int32)? in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: sockaddr.self) else {
                    return nil
                }
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = getnameinfo(
                    base,
                    socklen_t(data.count),
                    &host,
                    socklen_t(host.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                )
                guard status == 0 else { return nil }
                return (String(cString: host), Int32(base.pointee.sa_family))
            }
        }
        .sorted { $0.1 == AF_INET && $1.1 != AF_INET }
        .map(\.0)
    }

    private static func sourceKind(from service: NetService) -> MobileSourceKind {
        guard let data = service.txtRecordData() else { return .unknown }
        let values = NetService.dictionary(fromTXTRecord: data)
        guard let raw = values["source"].map({ String(decoding: $0, as: UTF8.self) })
        else { return .unknown }
        return MobileSourceKind(rawValue: raw) ?? .unknown
    }
}

extension MobileDiscovery: NetServiceBrowserDelegate {
    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didFind service: NetService,
        moreComing: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Self.serviceKey(service)
        resolving[key] = service
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceBrowser(
        _ browser: NetServiceBrowser,
        didRemove service: NetService,
        moreComing: Bool
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Self.serviceKey(service)
        resolving.removeValue(forKey: key)
        streamers.removeValue(forKey: key)
        publish()
    }
}

extension MobileDiscovery: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        dispatchPrecondition(condition: .onQueue(.main))
        let key = Self.serviceKey(sender)
        resolving[key] = sender
        guard sender.port > 0,
              sender.port <= Int(UInt16.max),
              let host = Self.numericHosts(from: sender).first
        else { return }
        streamers[key] = MobileStreamer(
            name: sender.name,
            host: host,
            controlPort: UInt16(sender.port),
            sourceKind: Self.sourceKind(from: sender)
        )
        publish()
    }

    func netService(
        _ sender: NetService,
        didNotResolve errorDict: [String: NSNumber]
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        resolving.removeValue(forKey: Self.serviceKey(sender))
    }
}
