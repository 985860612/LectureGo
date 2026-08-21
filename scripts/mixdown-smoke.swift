import Foundation

@main
struct MixdownSmokeTest {
    static func main() {
        let input = URL(fileURLWithPath: "/tmp/courserec-mixdown-input.mov")
        let output = URL(fileURLWithPath: "/tmp/courserec-mixdown-output.m4a")
        try? FileManager.default.removeItem(at: output)
        let semaphore = DispatchSemaphore(value: 0)
        var exitCode = 1
        AudioMixdownExporter.export(sourceURL: input, outputURL: output) { result in
            switch result {
            case let .success(file):
                print("mixdown-smoke: PASS \(file.fileSize) bytes")
                exitCode = file.succeeded ? 0 : 1
            case let .failure(error):
                fputs("mixdown-smoke: FAIL \(error.localizedDescription)\n", stderr)
            }
            semaphore.signal()
        }
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(Int32(exitCode))
    }
}
