// UDSSocketUtils.swift
// UnixDomainSocket – Production IPC module

import Foundation

// MARK: - sockaddr_un helpers (internal)

/// Builds a `sockaddr_un` from `path` and validates the path length.
///
/// - Throws: `UDSError.invalidSocketPath` when the path (plus null-terminator)
///           exceeds the 104-byte `sun_path` buffer on Darwin.
func makeSockAddr(path: String) throws -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)

    let maxLen = MemoryLayout.size(ofValue: addr.sun_path)   // 104 on Darwin
    guard !path.isEmpty, path.utf8.count + 1 <= maxLen else {
        throw UDSError.invalidSocketPath(path)
    }

    withUnsafeMutableBytes(of: &addr.sun_path) { dst in
        path.withCString { src in
            dst.baseAddress!.copyMemory(from: src, byteCount: path.utf8.count + 1)
        }
    }

    return addr
}

/// Calls `body` with a typed `UnsafePointer<sockaddr>` and the appropriate size.
@discardableResult
func withSockAddr<T>(
    _ addr: inout sockaddr_un,
    _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T
) rethrows -> T {
    return try withUnsafePointer(to: &addr) { ptr in
        try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
}

/// Calls `body` with a mutable pointer to `sockaddr` and a mutable length.
@discardableResult
func withMutableSockAddr<T>(
    _ addr: inout sockaddr_un,
    _ body: (UnsafeMutablePointer<sockaddr>, UnsafeMutablePointer<socklen_t>) throws -> T
) rethrows -> T {
    return try withUnsafeMutablePointer(to: &addr) { ptr in
        try ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            var len = socklen_t(MemoryLayout<sockaddr_un>.size)
            return try body(sockPtr, &len)
        }
    }
}

// MARK: - Socket option helpers

/// Sets `SO_NOSIGPIPE` on `fd` so broken-pipe signals do not kill the process.
func disableSIGPIPE(on fd: Int32) {
    var flag: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &flag, socklen_t(MemoryLayout<Int32>.size))
}

/// Sets `O_NONBLOCK` on `fd`.
func setNonBlocking(_ fd: Int32) {
    let flags = fcntl(fd, F_GETFL, 0)
    _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
}
