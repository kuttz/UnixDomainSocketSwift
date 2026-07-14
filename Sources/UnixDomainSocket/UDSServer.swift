// UDSServer.swift
// UnixDomainSocket – Production IPC module

import Foundation

// MARK: - Delegate

/// Receive server lifecycle and message events.
public protocol UDSServerDelegate: AnyObject {
    /// A new client has connected. The `connection` object can be used to
    /// send replies directly with `connection.send(...)`.
    func server(_ server: UDSServer, didAcceptConnection connection: UDSConnection)

    /// A user-level envelope arrived from `connection`.
    /// Internal heartbeat / hello messages are **not** forwarded.
    func server(_ server: UDSServer, didReceiveEnvelope envelope: UDSEnvelope,
                from connection: UDSConnection)

    /// A client connection was closed. `error` is `nil` for an orderly shutdown.
    func server(_ server: UDSServer, connectionDidClose connection: UDSConnection,
                error: Error?)

    /// The server encountered a non-recoverable error and stopped.
    func server(_ server: UDSServer, didFailWithError error: Error)
}

// Default no-op implementations so conformers only implement what they need.
public extension UDSServerDelegate {
    func server(_ server: UDSServer, didAcceptConnection connection: UDSConnection) {}
    func server(_ server: UDSServer, connectionDidClose connection: UDSConnection, error: Error?) {}
    func server(_ server: UDSServer, didFailWithError error: Error) {}
}

// MARK: - UDSServer

/// Listens on a Unix Domain Socket and manages inbound client connections.
///
/// **Typical usage (main app):**
/// ```swift
/// let config = UDSConfiguration.appGroup("group.com.example.app")!
/// let server = UDSServer(configuration: config)
/// server.delegate = self
/// try server.start()
/// ```
///
/// **Thread safety:** All public methods are safe to call from any thread.
public final class UDSServer: NSObject {

    // MARK: - Properties

    public weak var delegate: UDSServerDelegate?

    private let configuration: UDSConfiguration
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var serverFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var heartbeatTimer: DispatchSourceTimer?
    private var heartbeatSeq: UInt64 = 0

    /// Active connections keyed by connection ID.
    private var connections: [String: UDSConnection] = [:]

    private var _isRunning = false

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
            label:          "\(configuration.queueLabel).server",
            qos:            .userInteractive,
            autoreleaseFrequency: .workItem
        )
        super.init()
    }

    deinit { _stop() }

    // MARK: - Public API

    /// `true` after `start()` returns successfully.
    public var isRunning: Bool {
        return queue.sync { _isRunning }
    }

    /// Snapshot of currently connected clients.
    public var activeConnections: [UDSConnection] {
        return queue.sync { Array(connections.values) }
    }

    /// Number of currently connected clients.
    public var connectionCount: Int {
        return queue.sync { connections.count }
    }

    // MARK: Start

    /// Binds the socket, begins listening, and starts accepting connections.
    ///
    /// - Throws: `UDSError.alreadyRunning` if called while the server is active.
    ///           Various `UDSError` cases for POSIX failures.
    public func start() throws {
        try queue.sync { try _start() }
    }

    private func _start() throws {
        guard !_isRunning else { throw UDSError.alreadyRunning }

        let path = configuration.socketPath

        // Remove stale socket file.
        unlink(path)

        // Create socket.
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UDSError.socketCreationFailed(errno: errno) }

        disableSIGPIPE(on: fd)

        var reuseAddr: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuseAddr, socklen_t(MemoryLayout<Int32>.size))

        // Bind.
        var addr = try makeSockAddr(path: path)
        let bindResult = withSockAddr(&addr) { ptr, len in
            Darwin.bind(fd, ptr, len)
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw UDSError.bindFailed(errno: errno)
        }

        // Listen.
        guard Darwin.listen(fd, configuration.listenBacklog) == 0 else {
            Darwin.close(fd)
            throw UDSError.listenFailed(errno: errno)
        }

        serverFD  = fd
        _isRunning = true

        log.info("UDS Server listening at: \(path)")

        startAcceptSource()

        if configuration.heartbeatInterval > 0 {
            startHeartbeat()
        }
    }

    // MARK: Stop

    /// Stops the server, closes all connections, and removes the socket file.
    ///
    /// Safe to call multiple times.
    public func stop() {
        queue.async { [weak self] in self?._stop() }
    }

    private func _stop() {
        guard _isRunning else { return }
        _isRunning = false

        heartbeatTimer?.cancel()
        heartbeatTimer = nil

        acceptSource?.cancel()
        acceptSource = nil

        let all = connections
        connections.removeAll()
        all.values.forEach { $0.close() }

        if serverFD >= 0 {
            Darwin.close(serverFD)
            serverFD = -1
        }
        unlink(configuration.socketPath)

        log.info("UDS Server stopped")
    }

    // MARK: Send / Broadcast

    /// Sends a message to a specific client.
    ///
    /// - Parameters:
    ///   - message:      `Encodable` payload.
    ///   - connectionID: Target connection ID (from `UDSConnection.id`).
    ///   - messageType:  Optional type tag; defaults to the Swift type name.
    ///   - completion:   Called with `nil` on success or an `Error` on failure.
    public func send<T: Encodable>(
        _ message: T,
        to connectionID: String,
        messageType: String? = nil,
        completion: ((Error?) -> Void)? = nil
    ) {
        queue.async { [weak self] in
            guard let conn = self?.connections[connectionID] else {
                completion?(UDSError.notConnected)
                return
            }
            try? conn.send(message, messageType: messageType, completion: completion)
        }
    }

    /// Broadcasts a message to **all** connected clients.
    public func broadcast<T: Encodable>(
        _ message: T,
        messageType: String? = nil
    ) {
        queue.async { [weak self] in
            self?.connections.values.forEach {
                try? $0.send(message, messageType: messageType)
            }
        }
    }

    // MARK: - Accept source

    private func startAcceptSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: serverFD, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptConnection() }
        source.setCancelHandler { }
        acceptSource = source
        source.resume()
    }

    private func acceptConnection() {
        var clientAddr = sockaddr_un()
        let clientFD: Int32 = withMutableSockAddr(&clientAddr) { ptr, lenPtr in
            Darwin.accept(serverFD, ptr, lenPtr)
        }

        guard clientFD >= 0 else {
            let err = errno
            if err != EAGAIN && err != EWOULDBLOCK {
                log.error("accept() failed: \(String(cString: strerror(err)))")
            }
            return
        }

        let conn = UDSConnection(
            fileDescriptor: clientFD,
            configuration: configuration,
            callbackQueue: callbackQueue
        )

        conn.onReceive = { [weak self, weak conn] envelope in
            guard let self, let conn else { return }
            self.delegate?.server(self, didReceiveEnvelope: envelope, from: conn)
        }

        conn.onClose = { [weak self, weak conn] error in
            guard let self, let conn else { return }
            self.queue.async {
                self.connections.removeValue(forKey: conn.id)
            }
            self.callbackQueue.async {
                self.delegate?.server(self, connectionDidClose: conn, error: error)
            }
        }

        connections[conn.id] = conn

        // Send greeting.
        try? conn.send(
            UDSHello(connectionID: conn.id),
            messageType: UDSInternalType.hello
        )

        log.info("UDS Server accepted connection: \(conn.id) (total: \(connections.count))")

        let snapshot = conn
        callbackQueue.async { [weak self] in
            guard let self else { return }
            self.delegate?.server(self, didAcceptConnection: snapshot)
        }
    }

    // MARK: - Heartbeat

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = configuration.heartbeatInterval
        timer.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.sendHeartbeats() }
        heartbeatTimer = timer
        timer.resume()
    }

    private func sendHeartbeats() {
        heartbeatSeq += 1
        let beat = UDSHeartbeat(sequence: heartbeatSeq)
        connections.values.forEach {
            try? $0.send(beat, messageType: UDSInternalType.heartbeat)
        }
    }
}
