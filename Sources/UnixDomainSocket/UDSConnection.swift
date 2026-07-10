// UDSConnection.swift
// UnixDomainSocket – Production IPC module

import Foundation

// MARK: - UDSConnection

/// Manages a single established Unix Domain Socket connection.
///
/// **Thread safety:** All mutations happen on an internal serial queue.
/// `onReceive` and `onClose` callbacks are always dispatched to `callbackQueue`
/// (default `.main`).
///
/// **Ownership:** `UDSServer` and `UDSClient` own their connections.
/// External callers receive the object from the server/client delegate and
/// should only call `send(_:messageType:completion:)` and `close()`.
public final class UDSConnection: NSObject {

    // MARK: - Public identity

    /// Unique identifier assigned at creation.
    public let id: String

    // MARK: - Internal state

    private let fileDescriptor: Int32
    private let configuration: UDSConfiguration
    private let queue: DispatchQueue
    private let callbackQueue: DispatchQueue

    private var readSource: DispatchSourceRead?
    private var pendingWriteSource: DispatchSourceWrite?
    private var writeQueue: [(data: Data, completion: ((Error?) -> Void)?)] = []
    private var readBuffer = Data()
    private var isClosed = false
    private var fdClosed = false
    private var isDraining = false

    // MARK: - Callbacks (set by owning server / client)

    /// Invoked on `callbackQueue` for every received user envelope.
    /// Internal system messages (heartbeat, hello) are *not* forwarded here.
    var onReceive: ((UDSEnvelope) -> Void)?

    /// Invoked on `callbackQueue` when the connection is closed.
    var onClose: ((Error?) -> Void)?

    // MARK: - Coders

    private let encoder = UDSEnvelope.defaultEncoder
    private let decoder = UDSEnvelope.defaultDecoder

    // MARK: - Init / deinit

    init(
        fileDescriptor: Int32,
        id: String = UUID().uuidString,
        configuration: UDSConfiguration,
        callbackQueue: DispatchQueue = .main
    ) {
        self.fileDescriptor = fileDescriptor
        self.id             = id
        self.configuration  = configuration
        self.callbackQueue  = callbackQueue
        self.queue = DispatchQueue(
            label: "\(configuration.queueLabel).connection.\(id)",
            qos:   .userInteractive
        )
        super.init()
        configure()
    }

    deinit {
        // Synchronously close without firing callbacks (object is being destroyed).
        readSource?.cancel()
        pendingWriteSource?.cancel()
        if !fdClosed {
            fdClosed = true
            Darwin.close(fileDescriptor)
        }
    }

    // MARK: - Public API

    /// `true` when the underlying socket is open (thread-safe).
    public var isConnected: Bool {
        return queue.sync { !isClosed }
    }

    /// Encodes `message` and enqueues it for sending.
    ///
    /// Encoding is done synchronously on the caller's thread.
    /// Actual I/O is performed asynchronously on the internal queue.
    /// `completion` is called on the internal queue with `nil` on success
    /// or an `Error` on failure.
    ///
    /// - Throws: `UDSError.encodingFailed` if JSON encoding fails.
    ///           `UDSError.notConnected` if the connection is already closed.
    public func send<T: Encodable>(
        _ message: T,
        messageType: String? = nil,
        completion: ((Error?) -> Void)? = nil
    ) throws {
        let envelope = try UDSEnvelope(message, messageType: messageType, encoder: encoder)
        let frameData: Data
        do {
            let envData = try encoder.encode(envelope)
            frameData = UDSFrameCodec.frame(envData)
        } catch {
            throw UDSError.encodingFailed(error)
        }

        queue.async { [weak self] in
            guard let self = self, !self.isClosed else {
                completion?(UDSError.notConnected)
                return
            }
            self.enqueueWrite(data: frameData, completion: completion)
        }
    }

    /// Closes the connection gracefully.
    ///
    /// Idempotent – safe to call multiple times.
    public func close() {
        queue.async { [weak self] in
            self?.performClose(error: nil)
        }
    }

    // MARK: - Setup

    private func configure() {
        setNonBlocking(fileDescriptor)
        disableSIGPIPE(on: fileDescriptor)
        startReadSource()
    }

    private func startReadSource() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: queue)

        source.setEventHandler { [weak self] in
            self?.handleReadAvailable()
        }

        source.setCancelHandler { [weak self] in
            guard let self else { return }
            if !self.fdClosed {
                self.fdClosed = true
                Darwin.close(self.fileDescriptor)
            }
        }

        readSource = source
        source.resume()
    }

    // MARK: - Reading

    private func handleReadAvailable() {
        // Drain all available bytes in a tight loop (non-blocking socket).
        var buf = [UInt8](repeating: 0, count: configuration.readBufferSize)
        var totalRead = 0

        while true {
            let n = recv(fileDescriptor, &buf, buf.count, 0)
            if n > 0 {
                readBuffer.append(contentsOf: buf.prefix(n))
                totalRead += n
                if n < buf.count { break }  // likely no more data buffered
            } else if n == 0 {
                // Orderly shutdown by the remote peer.
                performClose(error: UDSError.connectionClosed)
                return
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    break
                }
                performClose(error: UDSError.receiveFailed(errno: err))
                return
            }
        }

        guard totalRead > 0 else { return }
        processReadBuffer()
    }

    private func processReadBuffer() {
        do {
            let frames = try UDSFrameCodec.unframe(buffer: &readBuffer,
                                                    maxSize: configuration.maxMessageSize)
            for frameData in frames {
                dispatchFrame(frameData)
            }
        } catch {
            log.error("Frame decode error on connection \(id): \(error.localizedDescription)")
            performClose(error: error)
        }
    }

    private func dispatchFrame(_ data: Data) {
        let envelope: UDSEnvelope
        do {
            envelope = try decoder.decode(UDSEnvelope.self, from: data)
        } catch {
            log.warning("Envelope decode failed on connection \(id): \(error.localizedDescription)")
            return
        }

        // Handle internal system messages transparently.
        switch envelope.messageType {
        case UDSInternalType.heartbeat:
            handleHeartbeat(envelope)
        case UDSInternalType.heartbeatAck:
            // Server may track RTT here in future – currently a no-op on the connection level.
            break
        default:
            // Forward user messages to the owning object's callback.
            let cb = onReceive
            callbackQueue.async { cb?(envelope) }
        }
    }

    private func handleHeartbeat(_ envelope: UDSEnvelope) {
        guard let beat = try? envelope.decode(as: UDSHeartbeat.self) else { return }
        let ack = UDSHeartbeatAck(sequence: beat.sequence)
        try? send(ack, messageType: UDSInternalType.heartbeatAck)
    }

    // MARK: - Writing

    private func enqueueWrite(data: Data, completion: ((Error?) -> Void)?) {
        writeQueue.append((data: data, completion: completion))
        if !isDraining {
            drainWriteQueue()
        }
    }

    private func drainWriteQueue() {
        guard !writeQueue.isEmpty, !isClosed else {
            isDraining = false
            return
        }

        isDraining = true
        let item = writeQueue.removeFirst()

        performWrite(data: item.data, offset: 0) { [weak self] error in
            item.completion?(error)
            if let error = error {
                self?.performClose(error: error)
            } else {
                self?.drainWriteQueue()
            }
        }
    }

    private func performWrite(data: Data, offset: Int, completion: @escaping (Error?) -> Void) {
        var currentOffset = offset

        while currentOffset < data.count {
            guard !isClosed else {
                completion(UDSError.connectionClosed)
                return
            }

            let result = data.withUnsafeBytes { ptr in
                Darwin.send(
                    fileDescriptor,
                    ptr.baseAddress!.advanced(by: currentOffset),
                    data.count - currentOffset,
                    0
                )
            }

            if result > 0 {
                currentOffset += result
            } else if result == 0 {
                completion(UDSError.connectionClosed)
                return
            } else {
                let err = errno
                if err == EAGAIN || err == EWOULDBLOCK {
                    // Socket send buffer full – wait until writable.
                    scheduleWrite(data: data, offset: currentOffset, completion: completion)
                    return
                }
                completion(UDSError.sendFailed(errno: err))
                return
            }
        }

        completion(nil)
    }

    /// Registers a one-shot `DispatchSourceWrite` to resume writing when the
    /// socket send buffer drains.
    private func scheduleWrite(data: Data, offset: Int, completion: @escaping (Error?) -> Void) {
        pendingWriteSource?.cancel()
        let source = DispatchSource.makeWriteSource(fileDescriptor: fileDescriptor, queue: queue)
        pendingWriteSource = source

        source.setEventHandler { [weak self] in
            source.cancel()
            self?.pendingWriteSource = nil
            guard let self, !self.isClosed else {
                completion(UDSError.connectionClosed)
                return
            }
            self.performWrite(data: data, offset: offset, completion: completion)
        }

        source.resume()
    }

    // MARK: - Close

    private func performClose(error: Error?) {
        guard !isClosed else { return }
        isClosed = true
        isDraining = false

        // Cancel I/O sources (cancel handler closes the fd).
        pendingWriteSource?.cancel()
        pendingWriteSource = nil

        if let rs = readSource {
            readSource = nil
            rs.cancel()   // → cancel handler closes fd
        } else if !fdClosed {
            fdClosed = true
            Darwin.close(fileDescriptor)
        }

        // Fail any queued writes.
        let pending = writeQueue
        writeQueue.removeAll()
        let closeError = error ?? UDSError.connectionClosed
        for item in pending {
            item.completion?(closeError)
        }

        // Notify owner.
        let cb = onClose
        let err = error
        callbackQueue.async { cb?(err) }

        log.info("Connection \(id) closed – \(error?.localizedDescription ?? "clean")")
    }
}
