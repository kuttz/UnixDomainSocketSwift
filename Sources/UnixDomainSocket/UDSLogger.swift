// UDSLogger.swift
// UnixDomainSocket – Production IPC module

import Foundation
import os.log

/// Internal structured logger. Uses `os.Logger` (unified logging) on iOS 14+ / macOS 11+.
/// Falls back to `os_log` on older runtimes.
final class UDSLogger: @unchecked Sendable {

    // MARK: Singleton

    static let shared = UDSLogger()
    private init() {}

    // MARK: Private

    private let subsystem = "com.UnixDomainSocket"
    private let category  = "UDS"

    @available(iOS 14.0, macOS 11.0, *)
    private lazy var osLogger = Logger(subsystem: subsystem, category: category)

    private lazy var legacyLog = OSLog(subsystem: subsystem, category: category)

    // MARK: - Logging methods

    func debug(_ msg: String,
               file: String = #fileID, line: Int = #line) {
        let m = "[\(file):\(line)] \(msg)"
        if #available(iOS 14.0, macOS 11.0, *) {
            osLogger.debug("\(m, privacy: .public)")
        } else {
            os_log(.debug, log: legacyLog, "%{public}@", m)
        }
    }

    func info(_ msg: String) {
        if #available(iOS 14.0, macOS 11.0, *) {
            osLogger.info("\(msg, privacy: .public)")
        } else {
            os_log(.info, log: legacyLog, "%{public}@", msg)
        }
    }

    func warning(_ msg: String,
                 file: String = #fileID, line: Int = #line) {
        let m = "[\(file):\(line)] \(msg)"
        if #available(iOS 14.0, macOS 11.0, *) {
            osLogger.warning("\(m, privacy: .public)")
        } else {
            os_log(.error, log: legacyLog, "%{public}@", m)
        }
    }

    func error(_ msg: String,
               file: String = #fileID, line: Int = #line) {
        let m = "[\(file):\(line)] \(msg)"
        if #available(iOS 14.0, macOS 11.0, *) {
            osLogger.error("\(m, privacy: .public)")
        } else {
            os_log(.error, log: legacyLog, "%{public}@", m)
        }
    }

    func fault(_ msg: String,
               file: String = #fileID, line: Int = #line) {
        let m = "[\(file):\(line)] \(msg)"
        if #available(iOS 14.0, macOS 11.0, *) {
            osLogger.fault("\(m, privacy: .public)")
        } else {
            os_log(.fault, log: legacyLog, "%{public}@", m)
        }
    }
}

// Convenience shorthand used inside the module.
let log = UDSLogger.shared