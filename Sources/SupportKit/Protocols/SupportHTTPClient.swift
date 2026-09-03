import Foundation

/// Executes one receiver request behind a testable network boundary.
public protocol SupportHTTPClient: Sendable {
    /// Streams a bounded response into memory.
    ///
    /// - Parameters:
    ///   - request: The request to execute without following redirects.
    ///   - maximumResponseBytes: The maximum response-body size to read.
    /// - Returns: The bounded body and HTTP response metadata.
    /// - Throws: A transport, networking, or cancellation error.
    func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
    ) async throws -> (Data, HTTPURLResponse)
}
