// UDSError.swift
// UnixDomainSocket – Production IPC module
// Copyright © 2024. All rights reserved.

import Foundation

/// All errors surfaced by the UnixDomainSocket module.
public enum UDSError: Error {
    // MARK: Socket lifecycle
    case socketCreationFailed(errno: Int32)
    case bindFailed(errno: Int32)
    case listenFailed(errno: Int32)
    case connectFailed(errno: Int32)
    case acceptFailed(errno: Int32)

    // MARK: I/O
    case sendFailed(errno: Int32)
    case receiveFailed(errno: Int32)

    // MARK: Validation
    case invalidSocketPath(String)
    case messageTooLarge(size: Int, max: Int)

    // MARK: Serialisation
    case encodingFailed(Error)
    case decodingFailed(Error)

    // MARK: Connection state
    case connectionClosed
    case timeout
    case notConnected
    case alreadyRunning
}

// MARK: - LocalizedError

extension UDSError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let code):
            return "Socket creation failed: \(posixString(code))"
        case .bindFailed(let code):
            return "Bind failed: \(posixString(code))"
        case .listenFailed(let code):
            return "Listen failed: \(posixString(code))"
        case .connectFailed(let code):
            return "Connect failed: \(posixString(code))"
        case .acceptFailed(let code):
            return "Accept failed: \(posixString(code))"
        case .sendFailed(let code):
            return "Send failed: \(posixString(code))"
        case .receiveFailed(let code):
            return "Receive failed: \(posixString(code))"
        case .invalidSocketPath(let path):
            return "Socket path invalid or too long: '\(path)'"
        case .messageTooLarge(let size, let max):
            return "Message (\(size) B) exceeds maximum allowed size (\(max) B)"
        case .encodingFailed(let err):
            return "Message encoding failed: \(err.localizedDescription)"
        case .decodingFailed(let err):
            return "Message decoding failed: \(err.localizedDescription)"
        case .connectionClosed:
            return "Connection closed by remote peer"
        case .timeout:
            return "Operation timed out"
        case .notConnected:
            return "Not connected"
        case .alreadyRunning:
            return "Server is already running"
        }
    }

    private func posixString(_ code: Int32) -> String {
        return String(cString: strerror(code))
    }
}

// MARK: - Equatable (for testing)

extension UDSError: Equatable {
    public static func == (lhs: UDSError, rhs: UDSError) -> Bool {
        switch (lhs, rhs) {
        case (.socketCreationFailed(let a), .socketCreationFailed(let b)): return a == b
        case (.bindFailed(let a), .bindFailed(let b)):                     return a == b
        case (.listenFailed(let a), .listenFailed(let b)):                 return a == b
        case (.connectFailed(let a), .connectFailed(let b)):               return a == b
        case (.acceptFailed(let a), .acceptFailed(let b)):                 return a == b
        case (.sendFailed(let a), .sendFailed(let b)):                     return a == b
        case (.receiveFailed(let a), .receiveFailed(let b)):               return a == b
        case (.invalidSocketPath(let a), .invalidSocketPath(let b)):       return a == b
        case (.messageTooLarge(let a1, let a2), .messageTooLarge(let b1, let b2)): return a1 == b1 && a2 == b2
        case (.connectionClosed, .connectionClosed):                       return true
        case (.timeout, .timeout):                                         return true
        case (.notConnected, .notConnected):                               return true
        case (.alreadyRunning, .alreadyRunning):                           return true
        default: return false
        }
    }
}
