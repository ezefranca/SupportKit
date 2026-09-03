import Foundation

/// Adds short-lived first-party or attestation authorization to a receiver request.
public protocol SupportRequestAuthorizer: Sendable {
    /// Adds short-lived authorization headers to an otherwise immutable request.
    ///
    /// Implementations may add authentication or attestation headers. They must not
    /// change the URL, HTTP method, body, body stream, timeout, or transport-owned
    /// idempotency, payload-digest, content-type, accept, and user-agent headers.
    /// ``SupportGatewayTransport`` rejects a request when an authorizer changes any
    /// protected property. Static app-wide credentials are unsafe.
    ///
    /// - Parameters:
    ///   - request: The complete request whose protected properties must remain unchanged.
    ///   - body: The exact encoded payload, provided for short-lived signing schemes.
    /// - Returns: The request with authorization headers added.
    /// - Throws: An authorization or attestation failure.
    func authorize(_ request: URLRequest, body: Data) async throws -> URLRequest
}
