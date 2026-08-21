import AVFoundation
import Foundation

enum AudioMixdownExporter {
    static func export(
        sourceURL: URL,
        outputURL: URL,
        completion: @escaping (Result<TrackWriterResult, Error>) -> Void
    ) {
        Task {
            do {
                let asset = AVURLAsset(url: sourceURL)
                let sourceTracks = try await asset.loadTracks(withMediaType: .audio)
                guard !sourceTracks.isEmpty else {
                    throw MixdownError.noAudioTrack
                }
                let ranges = try await sourceTracks.asyncMap { try await $0.load(.timeRange) }
                let earliestStart = ranges.map(\.start).min(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
                let composition = AVMutableComposition()
                var parameters: [AVMutableAudioMixInputParameters] = []
                let volume = Float(1 / sqrt(Double(sourceTracks.count)))

                for (index, sourceTrack) in sourceTracks.enumerated() {
                    guard let targetTrack = composition.addMutableTrack(
                        withMediaType: .audio,
                        preferredTrackID: kCMPersistentTrackID_Invalid
                    ) else { throw MixdownError.cannotCreateTrack }
                    let range = ranges[index]
                    let insertionTime = CMTimeSubtract(range.start, earliestStart)
                    try targetTrack.insertTimeRange(range, of: sourceTrack, at: insertionTime)
                    let input = AVMutableAudioMixInputParameters(track: targetTrack)
                    input.setVolume(volume, at: .zero)
                    parameters.append(input)
                }

                let mix = AVMutableAudioMix()
                mix.inputParameters = parameters
                let workingURL = outputURL.deletingPathExtension()
                    .appendingPathExtension("partial")
                    .appendingPathExtension(outputURL.pathExtension)
                try? FileManager.default.removeItem(at: workingURL)
                try? FileManager.default.removeItem(at: outputURL)
                guard let exporter = AVAssetExportSession(
                    asset: composition,
                    presetName: AVAssetExportPresetAppleM4A
                ) else { throw MixdownError.cannotCreateExporter }
                exporter.audioMix = mix
                exporter.outputURL = workingURL
                exporter.outputFileType = .m4a
                let exportBox = ExportSessionBox(
                    exporter: exporter,
                    duration: CMTimeGetSeconds(composition.duration)
                )
                exporter.exportAsynchronously {
                    DispatchQueue.main.async {
                        guard exportBox.exporter.status == .completed else {
                            completion(.failure(exportBox.exporter.error ?? MixdownError.exportFailed))
                            return
                        }
                        do {
                            try FileManager.default.moveItem(at: workingURL, to: outputURL)
                            let attributes = try FileManager.default.attributesOfItem(atPath: outputURL.path)
                            let fileSize = (attributes[.size] as? NSNumber)?.int64Value ?? 0
                            completion(.success(TrackWriterResult(
                                name: outputURL.lastPathComponent,
                                url: outputURL,
                                succeeded: fileSize > 0,
                                fileSize: fileSize,
                                videoFrames: 0,
                                audioSamples: 1,
                                failedAppends: 0,
                                duration: exportBox.duration,
                                effectiveFrameRate: 0,
                                errorText: fileSize > 0 ? nil : "混音文件为空"
                            )))
                        } catch {
                            completion(.failure(error))
                        }
                    }
                }
            } catch {
                await MainActor.run { completion(.failure(error)) }
            }
        }
    }
}

private final class ExportSessionBox: @unchecked Sendable {
    let exporter: AVAssetExportSession
    let duration: TimeInterval

    init(exporter: AVAssetExportSession, duration: TimeInterval) {
        self.exporter = exporter
        self.duration = duration
    }
}

private enum MixdownError: LocalizedError {
    case noAudioTrack
    case cannotCreateTrack
    case cannotCreateExporter
    case exportFailed

    var errorDescription: String? {
        switch self {
        case .noAudioTrack: return "成片没有可混合的音轨"
        case .cannotCreateTrack: return "无法创建混音轨"
        case .cannotCreateExporter: return "无法创建混音导出器"
        case .exportFailed: return "混音导出失败"
        }
    }
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var values: [T] = []
        values.reserveCapacity(count)
        for element in self { values.append(try await transform(element)) }
        return values
    }
}
