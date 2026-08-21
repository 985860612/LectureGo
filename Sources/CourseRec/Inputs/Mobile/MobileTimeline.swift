import CoreMedia
import Foundation

/// Maps the sender's wall-clock microseconds onto one local host-clock timeline.
final class MobileTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var remoteBaseUs: Int64?
    private var localBase = CMTime.invalid

    func time(forRemoteUs remoteUs: Int64) -> CMTime {
        lock.withLock {
            if remoteBaseUs == nil {
                remoteBaseUs = remoteUs
                localBase = CMClockGetTime(CMClockGetHostTimeClock())
            }
            let delta = CMTime(value: remoteUs - remoteBaseUs!, timescale: 1_000_000)
            return CMTimeAdd(localBase, delta)
        }
    }
}
