import Foundation

/// Performs no authorization. Use only with gateways that explicitly support
/// anonymous, rate-limited report ingestion.
public struct AnonymousSupportRequestAuthorizer: SupportRequestAuthorizer {
    /// Creates an authorizer that leaves requests unchanged.
    public init() {}

    /// Returns `request` without adding authorization material.
    ///
    /// - Parameters:
    ///   - request: The protected request assembled by the transport.
    ///   - body: The exact request body.
    /// - Returns: `request` unchanged.
    public func authorize(_ request: URLRequest, body _: Data) -> URLRequest {
        request
    }
}
