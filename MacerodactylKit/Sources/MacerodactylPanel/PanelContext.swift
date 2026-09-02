import Hummingbird
import HummingbirdAuth
import MacerodactylKit
import NIOCore

/// Request context carrying the authenticated identity and the client's real
/// socket address.
///
/// The identity is populated ONLY by `SessionAuthenticator` from the app's own
/// session cookie — never from a request header. Likewise the source IP for
/// audit and rate limiting comes from the actual TCP peer, not from
/// X-Forwarded-For or any proxy header, so nothing a client (or an upstream
/// like Cloudflare Access / Tailscale) sends can forge who they are.
public struct PanelRequestContext: AuthRequestContext, RemoteAddressRequestContext {
    public var coreContext: CoreRequestContextStorage
    public var identity: PanelUser?
    public let remoteAddress: SocketAddress?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.identity = nil
        self.remoteAddress = source.channel.remoteAddress
    }

    /// The peer IP as a string for audit/rate-limiting. Falls back to a
    /// sentinel rather than trusting any header.
    public var clientIP: String {
        remoteAddress?.ipAddress ?? "unknown"
    }
}
