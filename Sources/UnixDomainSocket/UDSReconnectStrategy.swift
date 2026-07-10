// UDSReconnectStrategy.swift
// UnixDomainSocket – Production IPC module

import Foundation

/// Defines how a client behaves when a connection is lost.
public enum UDSReconnectStrategy {

    /// Never attempt to reconnect.
    case none

    /// Reconnect immediately, up to `maxAttempts` times.
    case immediate(maxAttempts: Int = .max)

    /// Reconnect with a constant `interval` between attempts.
    case fixed(interval: TimeInterval, maxAttempts: Int = .max)

    /// Reconnect with exponential back-off.
    ///
    /// - Parameters:
    ///   - baseInterval: Initial delay before the first retry (default 0.5 s).
    ///   - maxInterval:  Upper cap for the delay (default 30 s).
    ///   - multiplier:   Factor by which the delay grows each attempt (default 2.0).
    ///   - jitter:       When `true`, applies ±25 % random jitter to avoid thundering-herd (default `true`).
    ///   - maxAttempts:  Hard limit on the total number of retries. `Int.max` means retry forever.
    case exponential(
        baseInterval: TimeInterval = 0.5,
        maxInterval:  TimeInterval = 30.0,
        multiplier:   Double       = 2.0,
        jitter:       Bool         = true,
        maxAttempts:  Int          = .max
    )

    // MARK: - Computed delay

    /// Returns the delay (in seconds) before the nth retry, or `nil` if no more retries should occur.
    ///
    /// - Parameter attempt: Zero-based index of the reconnect attempt.
    func delay(for attempt: Int) -> TimeInterval? {
        switch self {
        case .none:
            return nil

        case .immediate(let max):
            return attempt < max ? 0 : nil

        case .fixed(let interval, let max):
            return attempt < max ? interval : nil

        case .exponential(let base, let maxInterval, let multiplier, let jitter, let maxAttempts):
            guard attempt < maxAttempts else { return nil }
            let raw   = base * pow(multiplier, Double(attempt))
            var delay = Swift.min(raw, maxInterval)
            if jitter {
                delay *= Double.random(in: 0.75...1.25)
                delay  = Swift.min(delay, maxInterval)
            }
            return Swift.max(0, delay)
        }
    }

    /// Maximum number of attempts encoded in the strategy.
    var maxAttempts: Int {
        switch self {
        case .none:                                         return 0
        case .immediate(let m):                             return m
        case .fixed(_, let m):                              return m
        case .exponential(_, _, _, _, let maxAttempts):     return maxAttempts
        }
    }
}
