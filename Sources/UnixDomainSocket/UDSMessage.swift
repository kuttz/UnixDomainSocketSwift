// UDSMessage.swift
// UnixDomainSocket – Production IPC module

import Foundation

// MARK: - Envelope

/// A type-erased transport envelope that wraps any `Codable` message.
///
/// The payload is JSON-encoded so the receiver can decode it into the
/// concrete type by calling `decode(as:)`.
public struct UDSEnvelope: Codable, Sendable {

    /// Unique message identifier (UUID string).
    public let messageID: String

    /// Type tag used to route and decode the payload.
    /// Defaults to the bare type name of the encoded value.
    public let messageType: String

    /// Unix timestamp of when the envelope was created.
    public let timestamp: TimeInterval

    /// JSON-encoded representation of the wrapped message.
    public let payload: Data

    // MARK: Encoding

    /// Creates an envelope by JSON-encoding `message`.
    ///
    /// - Parameters:
    ///   - message:     The `Encodable` value to wrap.
    ///   - messageType: Explicit type tag; defaults to `String(describing: T.self)`.
    ///   - encoder:     Custom `JSONEncoder`; the default instance is used otherwise.
    /// - Throws: `UDSError.encodingFailed` if serialisation fails.
    public init<T: Encodable>(
        _ message: T,
        messageType: String? = nil,
        encoder: JSONEncoder = UDSEnvelope.defaultEncoder
    ) throws {
        do {
            self.messageID   = UUID().uuidString
            self.messageType = messageType ?? String(describing: T.self)
            self.timestamp   = Date().timeIntervalSince1970
            self.payload     = try encoder.encode(message)
        } catch {
            throw UDSError.encodingFailed(error)
        }
    }

    // MARK: Decoding

    /// Decodes the payload into the requested concrete type.
    ///
    /// - Parameters:
    ///   - type:    Target `Decodable` type.
    ///   - decoder: Custom `JSONDecoder`; the default instance is used otherwise.
    /// - Throws: `UDSError.decodingFailed` if deserialisation fails.
    public func decode<T: Decodable>(
        as type: T.Type,
        decoder: JSONDecoder = UDSEnvelope.defaultDecoder
    ) throws -> T {
        do {
            return try decoder.decode(type, from: payload)
        } catch {
            throw UDSError.decodingFailed(error)
        }
    }

    // MARK: Shared coders

    @usableFromInline
    static let defaultEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }()

    @usableFromInline
    static let defaultDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }()
}

// MARK: - Built-in system messages

/// Keepalive ping sent by the server.
struct UDSHeartbeat: Codable {
    let sequence: UInt64
}

/// Acknowledgement sent back by the client.
struct UDSHeartbeatAck: Codable {
    let sequence: UInt64
}

/// Greeting sent by the server immediately after accepting a new connection.
public struct UDSHello: Codable {
    public let serverVersion: String
    public let connectionID: String
    public init(serverVersion: String = "1.0", connectionID: String) {
        self.serverVersion = serverVersion
        self.connectionID  = connectionID
    }
}

// MARK: - Reserved type tags

/// Namespace for internal message type tags.
/// These are filtered out before user delegates see them.
enum UDSInternalType {
    static let heartbeat    = "__uds.heartbeat__"
    static let heartbeatAck = "__uds.heartbeat_ack__"
    static let hello        = "__uds.hello__"

    static var all: Set<String> { [heartbeat, heartbeatAck, hello] }
}
