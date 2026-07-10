// UDSFrameCodec.swift
// UnixDomainSocket – Production IPC module

import Foundation

/// Encodes and decodes the length-prefixed framing protocol.
///
/// Wire format:
/// ```
/// ┌──────────────────────┬────────────────────────────────────┐
/// │  4 bytes (big-endian)│        N bytes                     │
/// │  UInt32 payload len  │  JSON-encoded UDSEnvelope payload  │
/// └──────────────────────┴────────────────────────────────────┘
/// ```
enum UDSFrameCodec {

    /// Number of bytes occupied by the length header.
    static let headerSize = MemoryLayout<UInt32>.size   // 4

    // MARK: Encoding

    /// Wraps `data` in a length-prefixed frame ready for transmission.
    static func frame(_ data: Data) -> Data {
        var bigEndianLength = UInt32(data.count).bigEndian
        var packet = Data(bytes: &bigEndianLength, count: headerSize)
        packet.append(data)
        return packet
    }

    // MARK: Decoding

    /// Extracts complete frames from `buffer`.
    ///
    /// Frames are removed from `buffer` as they are parsed. Partial trailing
    /// data is left untouched. The caller owns the mutation of `buffer`.
    ///
    /// - Parameters:
    ///   - buffer:  Accumulated receive buffer (mutated in place).
    ///   - maxSize: Maximum permitted payload length in bytes.
    /// - Returns: Array of decoded payload `Data` objects (may be empty).
    /// - Throws: `UDSError.messageTooLarge` if a frame header announces a
    ///           payload that exceeds `maxSize`.
    static func unframe(buffer: inout Data, maxSize: Int) throws -> [Data] {
        var frames: [Data] = []

        while buffer.count >= headerSize {
            // --- Read length header (unaligned – Data slices may not be 4-byte aligned) ---
            let rawLength: UInt32 = buffer.withUnsafeBytes { ptr in
                ptr.loadUnaligned(as: UInt32.self)
            }
            let payloadLength = Int(UInt32(bigEndian: rawLength))

            guard payloadLength > 0 else {
                // Malformed zero-length frame – skip header and keep going.
                buffer.removeFirst(headerSize)
                continue
            }
            guard payloadLength <= maxSize else {
                throw UDSError.messageTooLarge(size: payloadLength, max: maxSize)
            }

            let totalSize = headerSize + payloadLength
            guard buffer.count >= totalSize else {
                break   // Incomplete frame – wait for more data.
            }

            // --- Extract payload -------------------------------------------
            let payload = buffer[buffer.startIndex + headerSize ..< buffer.startIndex + totalSize]
            frames.append(Data(payload))
            buffer.removeFirst(totalSize)
        }

        return frames
    }
}
