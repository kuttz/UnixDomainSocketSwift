# UnixDomainSocket - Swift

A pure Swift Unix Domain Socket library for high-performance, bidirectional interprocess communication (IPC) between iOS and macOS apps and their extensions. Built for App Group-enabled environments, it provides a reliable and efficient channel for exchanging data across process boundaries.

## Features

| Feature | Detail |
|---------|--------|
| **Object messages** | Wrap any `Codable` type, including structs, classes, and enums, in a `UDSEnvelope` |
| **Length-prefixed framing** | 4-byte big-endian header prevents partial/merged TCP-style reads |
| **Automatic reconnection** | Configurable: `.none`, `.immediate`, `.fixed`, `.exponential` (with jitter) |
| **Server heartbeats** | Optional keep-alive pings; auto-ACKed by the client layer |
| **Thread safety** | Every object has a dedicated serial `DispatchQueue`; delegates are dispatched on `.main` (configurable) |
| **Structured logging** | `os.Logger` (iOS 14+) with fallback to `os_log` |


## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/kuttz/UnixDomainSocketSwift.git", from: "1.0.0")
]
```

Add `UnixDomainSocket` to both the **app target** and the **extension target** dependencies.

### Drag-and-drop (no SPM)

Copy the `Sources/UnixDomainSocket/*.swift` files directly into both targets in Xcode.

## Quick Start

### 1. App Group

Enable the **App Groups** capability in both targets with the **same** identifier, e.g. `group.com.yourcompany.yourapp`.

### 2. App side (Server)

```swift
import UnixDomainSocket

class AppDelegate: UIResponder, UIApplicationDelegate, UDSServerDelegate {

    let server: UDSServer = {
        let config = UDSConfiguration.appGroup("group.com.yourcompany.yourapp")!
        return UDSServer(configuration: config)
    }()

    func application(_ app: UIApplication,
                     didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        server.delegate = self
        try? server.start()
        return true
    }

    // MARK: UDSServerDelegate

    func server(_ server: UDSServer, didAcceptConnection connection: UDSConnection) {
        print("Extension connected: \(connection.id)")
    }

    func server(_ server: UDSServer,
                didReceiveEnvelope envelope: UDSEnvelope,
                from connection: UDSConnection) {
        guard envelope.messageType == "StatusUpdate",
              let update = try? envelope.decode(as: StatusUpdate.self) else { return }
        print("Status \(update.code): \(update.message)")
    }

    func server(_ server: UDSServer,
                connectionDidClose connection: UDSConnection, error: Error?) {
        print("Extension disconnected: \(error?.localizedDescription ?? "clean")")
    }
}
```

### 3. Extension side (Client)

```swift
import UnixDomainSocket

struct StatusUpdate: Codable {
    let code: Int
    let message: String
}

class ExtensionController: UDSClientDelegate {

    private var client: UDSClient?

    func start() {
        guard let config = UDSConfiguration.appGroup("group.com.yourcompany.yourapp") else { return }
        let c = UDSClient(configuration: config)
        c.delegate = self
        c.connect()
        client = c
    }

    func stop() {
        client?.stop()
        client = nil
    }

    func reportStatus(code: Int, message: String) {
        let update = StatusUpdate(code: code, message: message)
        try? client?.send(update, messageType: "StatusUpdate")
    }

    // MARK: UDSClientDelegate

    func clientDidConnect(_ client: UDSClient) {
        print("Connected to host app")
    }

    func clientDidDisconnect(_ client: UDSClient, error: Error?) {
        print("Disconnected: \(error?.localizedDescription ?? "clean")")
    }

    func client(_ client: UDSClient, didReceiveEnvelope envelope: UDSEnvelope) {
        // Handle messages sent back from the server (host app)
    }

    func client(_ client: UDSClient, willReconnectAfter delay: TimeInterval, attempt: Int) {
        print("Reconnect attempt \(attempt) in \(delay)s")
    }
}
```

## Sending Typed Objects

Any `Codable` type works out of the box:

```swift
struct StatusUpdate: Codable {
    let code: Int
    let message: String
}

// Sender (extension side)
let update = StatusUpdate(code: 200, message: "Ready")
try client.send(update, messageType: "StatusUpdate")

// Receiver (in delegate — app/server side)
func server(_ server: UDSServer,
            didReceiveEnvelope envelope: UDSEnvelope,
            from connection: UDSConnection) {
    guard envelope.messageType == "StatusUpdate",
          let update = try? envelope.decode(as: StatusUpdate.self) else { return }
    print("Status \(update.code): \(update.message)")
}
```

## Reconnection Strategies

```swift
// Never reconnect (default for testing)
UDSReconnectStrategy.none

// Retry immediately, up to 10 times
UDSReconnectStrategy.immediate(maxAttempts: 10)

// Retry every 2 seconds, forever
UDSReconnectStrategy.fixed(interval: 2.0)

// Exponential back-off: 0.5 s → 1 s → 2 s … capped at 30 s, with jitter
UDSReconnectStrategy.exponential()   // all defaults

// Custom exponential
UDSReconnectStrategy.exponential(
    baseInterval: 0.25,
    maxInterval:  10.0,
    multiplier:   2.0,
    jitter:       true,
    maxAttempts:  15
)
```

## Configuration Reference

```swift
UDSConfiguration(
    socketPath:        "/path/to/socket.sock",  // or use .appGroup(...)
    listenBacklog:     5,                        // kernel accept queue depth
    readBufferSize:    65_536,                   // per-read byte budget (64 KiB)
    maxMessageSize:    64 * 1_024 * 1_024,       // 64 MiB hard cap
    reconnectStrategy: .exponential(),
    heartbeatInterval: 5.0,                      // 0 = disabled
    queueLabel:        "com.uds"                 // DispatchQueue name prefix
)
```

## Requirements

- iOS 14+ / macOS 11+
- Swift 5.9+
- Xcode 15+
