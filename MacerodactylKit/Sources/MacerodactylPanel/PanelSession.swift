import Foundation
import MacerodactylKit

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif

/// Server-side session tokens. The raw token lives only in the client's cookie;
/// the database stores only its SHA-256 hash, so a leaked database can't be
/// used to mint sessions.
public enum PanelSession {
    public static let cookieName = "mcd_session"
    public static let lifetimeDays = 14

    /// A fresh 128-bit random token, URL-safe base64 (no padding).
    public static func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        return Data(bytes).base64URLEncodedString()
    }

    /// The stored form of a token: hex SHA-256. Constant-length, so lookups
    /// don't leak length, and the raw token is never persisted.
    public static func hashToken(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // ISO8601DateFormatter's formatting methods are thread-safe; the options
    // are set once and never mutated, so sharing one instance is safe.
    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    public static func timestamp(_ date: Date = Date()) -> String {
        isoFormatter.string(from: date)
    }

    public static func expiry(from now: Date = Date()) -> String {
        timestamp(now.addingTimeInterval(Double(lifetimeDays) * 86_400))
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
