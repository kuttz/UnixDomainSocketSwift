// UDSClient.swift
// UnixDomainSocket – Production IPC module

import Foundation

// MARK: - Delegate

/// Receive client lifecycle and message events.
public protocol UDSClientDelegate: AnyObject {
    /// The client successfully established a connection to the server.
    func clientDidConnect(_ client: UDSClient)

    /// The connection was lost. `error` is `nil` for an explicit `stop()` call.
    func clientDidDisconnect(_ client: UDSClient, error: Error?)

    /// A user-level envelope was received from the server.
    /// Internal heartbeat / hello messages are **not** forwarded.
    func client(_ client: UDSClient, didReceiveEnvelope envelope: UDSEnvelope)

    /// Notifies the delegate just before a reconnect attempt is scheduled.
    /// Useful for UI updates.
    func client(_ client: UDSClient, willReconnectAfter delay: TimeInterval, attempt: Int)
}

// Default no-op implementations.
public extension UDSClientDelegate {
    func clientDidDisconnect(_ client: UDSClient, error: Error?) {}
    func client(_ client: UDSClient, willReconnectAfter delay: TimeInterval, attempt: Int) {}
}

// MARK: - State

public extension UDSClient {
    /// Observable connection state.
    enum State: Equatable {
        case disconnected
        case connecting
        case connected
        /// Waiting before the next reconnect attempt.
        case reconnecting(attempt: Int, delay: TimeInterval)

        public static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.disconnected, .disconnected): return true
            case (.connecting,   .connecting):   return true
            case (.connected,    .connected):    return true
            case (.reconnecting(let a, _), .reconnecting(let b, _)): return a == b
            default: return false
            }
        }
    }
}

// MARK: - UDSClient

/// Connects to a `UDSServer` on a Unix Domain Socket with automatic reconnection.
///
/// **Typical usage (Broadcast Extension):**
/// ```swift
/// let config = UDSConfiguration.appGroup("group.com.example.app")!
/// let client = UDSClient(configuration: config)
/// client.delegate = self
/// client.connect()
/// ```
///
/// **Thread safety:** All public methods are safe to call from any thread.
public final class UDSClient: NSObject {

    // MARK: - Properties

    public weak var delegate: UDSClientDelegate?

    private let configuration: UDSConfiguration
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var connection: UDSConnection?
    private var _state: State = .disconnected
    private var reconnectAttempt = 0
    private var pendingReconnect: DispatchWorkItem?
    private var isStopped = false

    // MARK: - Init

    /// - Parameters:
    ///   - configuration: Socket and behaviour configuration.
    ///   - callbackQueue: Queue on which delegate methods are called (default `.main`).
    public init(
        configuration: UDSConfiguration,
        callbackQueue: DispatchQueue = .main
    ) {
        self.configuration = configuration
        self.callbackQueue = callbackQueue
        self.queue = DispatchQueue(
            label:          "\(configuration.queueLabel).client",
            qos:            .userInteractive,
            autoreleaseFrequency: .workItem
        )
        super.init()
    }

    deinit { stop() }

    // MARK: - Public API

    /// Current connection state (thread-safe snapshot).
    public var state: State {
        return queue.sync { _state }
    }

    /// `true` when an active connection is established.
    public var isConnected: Bool {
        return queue.sync { _state == .connected }
    }

    // MARK: Connect / Stop

    /// Initiates a connection attempt (with automatic reconnection on failure).
    ///
    /// Calling `connect()` while already connected or reconnecting is a no-op.
    public func connect() {
        queue.async { [weak self] in
            guard let self else { return }
            guard case .disconnected = self._state else { return }
            self.isStopped      = false
            self.reconnectAttempt = 0
            self.performConnect()
        }
    }

    /// Disconnects permanently and cancels any pending reconnect timers.
    public func stop() {
        queue.async { [weak self] in
            self?._stop()
        }
    }

    private func _stop() {
        isStopped = true
        cancelPendingReconnect()
        connection?.close()
        connection = nil
        _state = .disconnected
    }

    // MARK: Send

    /// Encodes `message` into an envelope and sends it to the server.
    ///
    /// - Throws: `UDSError.notConnected` if the client is not currently connected.
    ///           `UDSError.encodingFailed` if JSON encoding fails.
    public func send<T: Encodable>(
        _ message: T,
        messageType: String? = nil,
        completion: ((Error?) -> Void)? = nil
    ) throws {
        // Capture connection reference safely.
        let conn: UDSConnection? = queue.sync { connection }
        guard let conn, conn.isConnected else {
            throw UDSError.notConnected
        }
        try conn.send(message, messageType: messageType, completion: completion)
    }

    // MARK: - Internal: Connection

    private func performConnect() {
        _state = .connecting
        log.info("UDS Client connecting to: \(configuration.socketPath) (attempt \(reconnectAttempt))")

        let path = configuration.socketPath

        // Create socket.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            scheduleReconnect(error: UDSError.socketCreationFailed(errno: errno))
            return
        }

        disableSIGPIPE(on: fd)

        // Build address.
        var addr: sockaddr_un
        do {
            addr = try makeSockAddr(path: path)
        } catch {
            Darwin.close(fd)
            log.error("Invalid socket path: \(error.localizedDescription)")
            _state = .disconnected
            return
        }

        // Connect.
        let result = withSockAddr(&addr) { ptr, len in
            Darwin.connect(fd, ptr, len)
        }

        guard result == 0 else {
            let err = errno
            Darwin.close(fd)
            scheduleReconnect(error: UDSError.connectFailed(errno: err))
            return
        }

        // ── Connected ──────────────────────────────────────────────────────
        reconnectAttempt = 0
        _state = .connected

        let conn = UDSConnection(
            fileDescriptor: fd,
            configuration:  configuration,
            callbackQueue:  callbackQueue
        )

        conn.onReceive = { [weak self] envelope in
            guard let self else { return }
            // Internal hello message: extract server greeting.
            if envelope.messageType == UDSInternalType.hello {
                if let hello = try? envelope.decode(as: UDSHello.self) {
                    log.info("Server greeting: v\(hello.serverVersion), conn=\(hello.connectionID)")
                }
                return
            }
            self.delegate?.client(self, didReceiveEnvelope: envelope)
        }

        conn.onClose = { [weak self] error in
            guard let self else { return }
            self.queue.async {
                self.connection = nil
                if self.isStopped {
                    self._state = .disconnected
                    self.callbackQueue.async {
                        self.delegate?.clientDidDisconnect(self, error: nil)
                    }
                } else {
                    self.scheduleReconnect(error: error ?? UDSError.connectionClosed)
                }
            }
        }

        connection = conn

        log.info("UDS Client connected to: \(path)")

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.clientDidConnect(self)
        }
    }

    // MARK: - Reconnect

    private func scheduleReconnect(error: Error) {
        guard !isStopped else { return }

        let attempt = reconnectAttempt
        guard let delay = configuration.reconnectStrategy.delay(for: attempt) else {
            log.warning("UDS Client: max reconnect attempts reached")
            _state = .disconnected
            callbackQueue.async { [weak self] in
                guard let self else { return }
                self.delegate?.clientDidDisconnect(self, error: error)
            }
            return
        }

        reconnectAttempt += 1
        _state = .reconnecting(attempt: reconnectAttempt, delay: delay)

        log.info("UDS Client reconnecting in \(String(format: "%.2f", delay))s (attempt \(reconnectAttempt))")

        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.client(self, willReconnectAfter: delay, attempt: self.reconnectAttempt)
        }

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, !self.isStopped else { return }
            self.performConnect()
        }

        pendingReconnect = workItem
        if delay <= 0 {
            queue.async(execute: workItem)
        } else {
            queue.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func cancelPendingReconnect() {
        pendingReconnect?.cancel()
        pendingReconnect = nil
    }
}
