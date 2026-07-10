// UnixDomainSocketTests.swift
// UnixDomainSocket – Unit & Integration Tests

import XCTest
@testable import UnixDomainSocket

final class UnixDomainSocketTests: XCTestCase {

    // MARK: - Helpers

    private var tmpSocketPath: String {
        return "/tmp/uds_test_\(ProcessInfo.processInfo.processIdentifier).sock"
    }

    private func makeConfig(reconnect: UDSReconnectStrategy = .none) -> UDSConfiguration {
        return UDSConfiguration(
            socketPath:        tmpSocketPath,
            reconnectStrategy: reconnect,
            heartbeatInterval: 0            // disable heartbeats in tests
        )
    }

    override func tearDown() {
        super.tearDown()
        unlink(tmpSocketPath)
    }

    // MARK: - Frame Codec

    func testFrameRoundTrip() throws {
        let original = "Hello, World!".data(using: .utf8)!
        let framed   = UDSFrameCodec.frame(original)

        XCTAssertEqual(framed.count, UDSFrameCodec.headerSize + original.count)

        var buffer = framed
        let decoded = try UDSFrameCodec.unframe(buffer: &buffer, maxSize: 1024)

        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0], original)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testFrameMultipleMessages() throws {
        var combined = Data()
        let messages: [Data] = [
            "first".data(using: .utf8)!,
            "second".data(using: .utf8)!,
            "third".data(using: .utf8)!
        ]
        messages.forEach { combined.append(UDSFrameCodec.frame($0)) }

        var buffer = combined
        let decoded = try UDSFrameCodec.unframe(buffer: &buffer, maxSize: 1024)

        XCTAssertEqual(decoded.count, 3)
        XCTAssertEqual(decoded[0], messages[0])
        XCTAssertEqual(decoded[1], messages[1])
        XCTAssertEqual(decoded[2], messages[2])
    }

    func testFramePartialMessage() throws {
        let data   = "incomplete".data(using: .utf8)!
        let cut    = UDSFrameCodec.frame(data).dropLast(3)   // cut off last 3 bytes

        var mutableBuffer = Data(cut)
        let decoded = try UDSFrameCodec.unframe(buffer: &mutableBuffer, maxSize: 1024)

        XCTAssertTrue(decoded.isEmpty)
        XCTAssertFalse(mutableBuffer.isEmpty)   // partial data retained
    }

    func testFrameTooLarge() {
        let data   = Data(repeating: 0, count: 100)
        var buffer = UDSFrameCodec.frame(data)

        XCTAssertThrowsError(try UDSFrameCodec.unframe(buffer: &buffer, maxSize: 10)) { error in
            XCTAssertEqual(error as? UDSError, UDSError.messageTooLarge(size: 100, max: 10))
        }
    }

    // MARK: - Envelope

    func testEnvelopeRoundTrip() throws {
        struct Payload: Codable, Equatable { let value: Int; let name: String }
        let original = Payload(value: 42, name: "test")
        let envelope = try UDSEnvelope(original)

        XCTAssertEqual(envelope.messageType, "Payload")
        XCTAssertFalse(envelope.messageID.isEmpty)

        let decoded = try envelope.decode(as: Payload.self)
        XCTAssertEqual(decoded, original)
    }

    func testEnvelopeCustomTypeTag() throws {
        let envelope = try UDSEnvelope("hello", messageType: "MyCustomTag")
        XCTAssertEqual(envelope.messageType, "MyCustomTag")
    }

    // MARK: - Reconnect Strategy

    func testExponentialBackoff() {
        let strategy = UDSReconnectStrategy.exponential(
            baseInterval: 1.0,
            maxInterval:  16.0,
            multiplier:   2.0,
            jitter:       false,
            maxAttempts:  5
        )
        XCTAssertNotNil(strategy.delay(for: 0))   // ~1 s
        XCTAssertNotNil(strategy.delay(for: 4))   // ~16 s (capped)
        XCTAssertNil(strategy.delay(for: 5))      // exhausted
    }

    func testFixedStrategy() {
        let strategy = UDSReconnectStrategy.fixed(interval: 2.0, maxAttempts: 3)
        XCTAssertEqual(strategy.delay(for: 0), 2.0)
        XCTAssertEqual(strategy.delay(for: 2), 2.0)
        XCTAssertNil(strategy.delay(for: 3))
    }

    func testNoneStrategy() {
        let strategy = UDSReconnectStrategy.none
        XCTAssertNil(strategy.delay(for: 0))
    }

    // MARK: - Integration: server start / stop

    func testServerStartStop() throws {
        let config = makeConfig()
        let server = UDSServer(configuration: config)
        XCTAssertFalse(server.isRunning)
        try server.start()
        XCTAssertTrue(server.isRunning)
        server.stop()

        let expectation = expectation(description: "server stopped")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)
        XCTAssertFalse(server.isRunning)
    }

    func testServerDoubleStartThrows() throws {
        let config = makeConfig()
        let server = UDSServer(configuration: config)
        try server.start()
        XCTAssertThrowsError(try server.start()) { err in
            XCTAssertEqual(err as? UDSError, .alreadyRunning)
        }
        server.stop()
    }

    // MARK: - Integration: connect and send message

    func testClientConnectsAndSendsMessage() throws {
        struct Greeting: Codable, Equatable { let text: String }

        let config           = makeConfig()
        let server           = UDSServer(configuration: config)
        let receivedExpect   = expectation(description: "message received")
        let connectedExpect  = expectation(description: "client connected")
        var receivedGreeting: Greeting?

        let serverDelegate = MockServerDelegate()
        serverDelegate.onMessage = { env, _ in
            receivedGreeting = try? env.decode(as: Greeting.self)
            receivedExpect.fulfill()
        }
        server.delegate = serverDelegate

        try server.start()

        let client  = UDSClient(configuration: config)
        let clientD = MockClientDelegate()
        clientD.onConnect = { connectedExpect.fulfill() }
        client.delegate  = clientD

        client.connect()

        wait(for: [connectedExpect], timeout: 2)
        try client.send(Greeting(text: "hi server"), messageType: "Greeting")
        wait(for: [receivedExpect], timeout: 2)

        XCTAssertEqual(receivedGreeting, Greeting(text: "hi server"))

        client.stop()
        server.stop()
    }

    // MARK: - Integration: reconnect

    func testClientReconnects() throws {
        let config          = makeConfig(reconnect: .fixed(interval: 0.1, maxAttempts: 5))
        let server          = UDSServer(configuration: config)
        let reconnectExpect = expectation(description: "client reconnected")
        var reconnectCount  = 0

        try server.start()

        let client  = UDSClient(configuration: config)
        let clientD = MockClientDelegate()
        clientD.onConnect = {
            reconnectCount += 1
            if reconnectCount == 2 { reconnectExpect.fulfill() }
        }
        client.delegate = clientD
        client.connect()

        // Let first connection establish, then kill server briefly.
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            server.stop()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                try? server.start()
            }
        }

        wait(for: [reconnectExpect], timeout: 5)
        XCTAssertEqual(reconnectCount, 2)

        client.stop()
        server.stop()
    }
}

// MARK: - Mock delegates

private final class MockServerDelegate: UDSServerDelegate {
    var onConnect: ((UDSConnection) -> Void)?
    var onMessage: ((UDSEnvelope, UDSConnection) -> Void)?
    var onClose:   ((UDSConnection, Error?) -> Void)?

    func server(_ s: UDSServer, didAcceptConnection c: UDSConnection)    { onConnect?(c) }
    func server(_ s: UDSServer, didReceiveEnvelope e: UDSEnvelope, from c: UDSConnection) { onMessage?(e, c) }
    func server(_ s: UDSServer, connectionDidClose c: UDSConnection, error: Error?) { onClose?(c, error) }
    func server(_ s: UDSServer, didFailWithError e: Error)                {}
}

private final class MockClientDelegate: UDSClientDelegate {
    var onConnect:    (() -> Void)?
    var onDisconnect: ((Error?) -> Void)?
    var onMessage:    ((UDSEnvelope) -> Void)?

    func clientDidConnect(_ c: UDSClient)                                        { onConnect?() }
    func clientDidDisconnect(_ c: UDSClient, error: Error?)                      { onDisconnect?(error) }
    func client(_ c: UDSClient, didReceiveEnvelope e: UDSEnvelope)               { onMessage?(e) }
    func client(_ c: UDSClient, willReconnectAfter d: TimeInterval, attempt: Int) {}
}
