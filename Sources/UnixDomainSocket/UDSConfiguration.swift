// UDSConfiguration.swift
// UnixDomainSocket – Production IPC module

import Foundation

/// Immutable configuration for a Unix Domain Socket server or client.
public struct UDSConfiguration {

    // MARK: - Properties

    /// Absolute path to the socket file.
    /// For App ↔ Extension IPC this **must** be inside a shared App Group container.
    public let socketPath: String

    /// Maximum number of pending (not yet accepted) connections in the kernel queue.
    public let listenBacklog: Int32

    /// Size of each read buffer in bytes (default 64 KiB).
    public let readBufferSize: Int

    /// Maximum allowed encoded message size in bytes (default 64 MiB).
    /// Messages larger than this cause the connection to be terminated with
    /// `UDSError.messageTooLarge`.
    public let maxMessageSize: Int

    /// Reconnection strategy used by `UDSClient` (default: exponential back-off).
    public let reconnectStrategy: UDSReconnectStrategy

    /// Interval at which the server sends keepalive heartbeats to connected clients.
    /// Set to `0` to disable heartbeats.
    public let heartbeatInterval: TimeInterval

    /// Label prefix used to name internal `DispatchQueue` instances.
    /// Useful when inspecting queues in Instruments.
    public let queueLabel: String

    // MARK: - Initialisers

    public init(
        socketPath:       String,
        listenBacklog:    Int32           = 5,
        readBufferSize:   Int             = 65_536,
        maxMessageSize:   Int             = 64 * 1_024 * 1_024,
        reconnectStrategy: UDSReconnectStrategy = .exponential(),
        heartbeatInterval: TimeInterval   = 5.0,
        queueLabel:       String          = "com.uds"
    ) {
        self.socketPath        = socketPath
        self.listenBacklog     = listenBacklog
        self.readBufferSize    = readBufferSize
        self.maxMessageSize    = maxMessageSize
        self.reconnectStrategy = reconnectStrategy
        self.heartbeatInterval = heartbeatInterval
        self.queueLabel        = queueLabel
    }

    // MARK: - App Group convenience

    /// Creates a configuration whose socket file lives inside an App Group container.
    ///
    /// - Parameters:
    ///   - groupIdentifier: The App Group identifier (e.g. `"group.com.company.app"`).
    ///   - socketName:      File name for the socket inside the container.
    ///   - reconnectStrategy: Strategy used by the client peer.
    /// - Returns: `nil` when the App Group container URL cannot be resolved.
    public static func appGroup(
        _ groupIdentifier: String,
        socketName: String = "uds.sock",
        reconnectStrategy: UDSReconnectStrategy = .exponential()
    ) -> UDSConfiguration? {
        guard let containerURL = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier
        ) else {
            return nil
        }
        let path = containerURL.appendingPathComponent(socketName).path
        return UDSConfiguration(socketPath: path, reconnectStrategy: reconnectStrategy)
    }
}
