import Foundation

/// An authorization failure detected before a request leaves the device.
public enum SupportAuthorizationError: Error, Equatable, LocalizedError, Sendable {
    /// The token provider returned an empty, oversized, or malformed bearer token.
    case invalidBearerToken

    /// A localized explanation suitable for configuration diagnostics.
    public var errorDescription: String? {
        switch self {
        case .invalidBearerToken: "The support authorization provider returned an invalid bearer token."
        }
    }
}

/// Adds a freshly supplied bearer token without storing a long-lived credential.
public struct SupportBearerTokenAuthorizer: SupportRequestAuthorizer {
    /// An asynchronous provider of scoped, short-lived bearer tokens.
    public typealias TokenProvider = @Sendable () async throws -> String

    private let tokenProvider: TokenProvider

    /// Creates an authorizer backed by a short-lived token provider.
    ///
    /// - Parameter tokenProvider: Called immediately before every delivery attempt.
    ///   Do not capture an app-wide repository or receiver secret in this closure.
    public init(tokenProvider: @escaping TokenProvider) {
        self.tokenProvider = tokenProvider
    }

    /// Adds an RFC 6750-compatible `Authorization: Bearer` header.
    ///
    /// - Parameters:
    ///   - request: The transport-built request whose protected properties remain unchanged.
    ///   - body: The exact request body, which this authorizer does not modify.
    /// - Returns: A copy of `request` with a validated bearer authorization header.
    /// - Throws: ``SupportAuthorizationError/invalidBearerToken`` or the token provider's error.
    public func authorize(_ request: URLRequest, body _: Data) async throws -> URLRequest {
        let token = try await tokenProvider()
        guard Self.isValid(token) else {
            throw SupportAuthorizationError.invalidBearerToken
        }
        var authorized = request
        authorized.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return authorized
    }

    private static func isValid(_ token: String) -> Bool {
        guard !token.isEmpty, token.utf8.count <= 4096 else { return false }
        var reachedPadding = false
        for byte in token.utf8 {
            if byte == 0x3D { // `=` padding is allowed only as a suffix.
                reachedPadding = true
                continue
            }
            guard !reachedPadding, isBearerTokenByte(byte) else { return false }
        }
        return true
    }

    private static func isBearerTokenByte(_ byte: UInt8) -> Bool {
        (0x30 ... 0x39).contains(byte)
            || (0x41 ... 0x5A).contains(byte)
            || (0x61 ... 0x7A).contains(byte)
            || [0x2D, 0x2E, 0x5F, 0x7E, 0x2B, 0x2F].contains(byte)
    }
}
