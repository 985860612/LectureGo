import AppKit
import Foundation
import OSLog

enum DiagnosticLogLevel: String {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case critical = "CRITICAL"

    fileprivate var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warning: return .default
        case .error: return .error
        case .critical: return .fault
        }
    }
}

/// 同时写入系统 Console 和用户日志目录的轻量诊断日志器。
/// 文件写入是同步且低频的，保证异常发生后尽量留下最后一条上下文。
final class DiagnosticLogger: @unchecked Sendable {
    static let shared = DiagnosticLogger()

    let directoryURL: URL
    let currentLogURL: URL

    private let lock = NSLock()
    private let systemLogger: Logger
    private let markerURL: URL
    private let formatter = ISO8601DateFormatter()
    private let maximumLogSize: UInt64
    private let archiveCount: Int
    private var sessionID = String(UUID().uuidString.prefix(8))
    private var sessionStarted = false

    init(
        directoryURL overrideDirectoryURL: URL? = nil,
        maximumLogSize: UInt64 = 5 * 1_024 * 1_024,
        archiveCount: Int = 3
    ) {
        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library", isDirectory: true)
        directoryURL = overrideDirectoryURL ?? library
            .appendingPathComponent("Logs", isDirectory: true)
            .appendingPathComponent("LectureGo", isDirectory: true)
        currentLogURL = directoryURL.appendingPathComponent("LectureGo.log")
        markerURL = directoryURL.appendingPathComponent(".running-session")
        self.maximumLogSize = maximumLogSize
        self.archiveCount = max(1, archiveCount)
        systemLogger = Logger(
            subsystem: Bundle.main.bundleIdentifier ?? "com.xjstudio.lecturego",
            category: "diagnostics"
        )
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    func beginSession() {
        lock.lock()
        guard !sessionStarted else {
            lock.unlock()
            return
        }
        sessionStarted = true
        let previousSession = try? String(contentsOf: markerURL, encoding: .utf8)
        let marker = "\(sessionID) \(formatter.string(from: Date()))"
        try? marker.write(to: markerURL, atomically: true, encoding: .utf8)
        lock.unlock()

        if let previousSession, !previousSession.isEmpty {
            var metadata = ["previous_session": previousSession]
            if let report = Self.latestSystemCrashReport() {
                metadata["system_crash_report"] = report.path
            }
            log(
                .warning,
                category: "lifecycle",
                "检测到上一次运行未正常退出",
                metadata: metadata
            )
        }
        let info = ProcessInfo.processInfo
        log(
            .info,
            category: "lifecycle",
            "应用启动",
            metadata: [
                "app_version": Self.appVersion,
                "os_version": info.operatingSystemVersionString,
                "process": String(info.processIdentifier)
            ]
        )
    }

    func endSession(reason: String = "normal") {
        log(.info, category: "lifecycle", "应用退出", metadata: ["reason": reason])
        lock.lock()
        try? FileManager.default.removeItem(at: markerURL)
        sessionStarted = false
        lock.unlock()
    }

    func log(
        _ level: DiagnosticLogLevel,
        category: String,
        _ message: String,
        metadata: [String: String] = [:]
    ) {
        let safeMessage = Self.singleLine(message)
        let safeMetadata = metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(Self.singleLine($0.value))" }
            .joined(separator: " ")
        let context = safeMetadata.isEmpty ? "" : " \(safeMetadata)"

        systemLogger.log(
            level: level.osLogType,
            "[\(category, privacy: .public)] \(safeMessage, privacy: .public)\(context, privacy: .public)"
        )

        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] [\(category)] [session:\(sessionID)] \(safeMessage)\(context)\n"
        appendLocked(Data(line.utf8))
    }

    func error(
        _ error: Error,
        category: String,
        operation: String,
        metadata: [String: String] = [:]
    ) {
        let value = error as NSError
        var context = metadata
        context["operation"] = operation
        context["error_domain"] = value.domain
        context["error_code"] = String(value.code)
        log(.error, category: category, value.localizedDescription, metadata: context)
    }

    func openLogDirectory() {
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directoryURL)
    }

    private func appendLocked(_ data: Data) {
        rotateIfNeededLocked(additionalBytes: UInt64(data.count))
        if !FileManager.default.fileExists(atPath: currentLogURL.path) {
            FileManager.default.createFile(atPath: currentLogURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: currentLogURL) else { return }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
    }

    private func rotateIfNeededLocked(additionalBytes: UInt64) {
        let attributes = try? FileManager.default.attributesOfItem(atPath: currentLogURL.path)
        let size = (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
        guard size + additionalBytes > maximumLogSize else { return }
        for index in stride(from: archiveCount, through: 1, by: -1) {
            let target = archiveURL(index)
            let source = index == 1 ? currentLogURL : archiveURL(index - 1)
            if FileManager.default.fileExists(atPath: target.path) {
                try? FileManager.default.removeItem(at: target)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try? FileManager.default.moveItem(at: source, to: target)
            }
        }
    }

    private func archiveURL(_ index: Int) -> URL {
        directoryURL.appendingPathComponent("LectureGo.\(index).log")
    }

    private static func singleLine(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\r", with: "\\r")
            .replacingOccurrences(of: "\n", with: "\\n")
    }

    private static var appVersion: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev"
        return "\(short) (\(build))"
    }

    private static func latestSystemCrashReport() -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        guard let reports = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return reports.filter { url in
            let name = url.lastPathComponent.lowercased()
            let supportedExtension = url.pathExtension == "ips" || url.pathExtension == "crash"
            return supportedExtension && (name.contains("courserec") || name.contains("lecturego"))
        }.max { lhs, rhs in
            let left = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let right = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return left < right
        }
    }
}

/// 仅记录未捕获的 Objective-C 异常；Swift fatal error 和信号崩溃由下次启动的
/// 异常退出标记关联 macOS DiagnosticReports，当前进程不做不安全的崩溃恢复。
func recordUncaughtException(_ exception: NSException) {
    DiagnosticLogger.shared.log(
        .critical,
        category: "uncaught-exception",
        exception.reason ?? exception.name.rawValue,
        metadata: [
            "name": exception.name.rawValue,
            "stack": exception.callStackSymbols.joined(separator: " | ")
        ]
    )
}
