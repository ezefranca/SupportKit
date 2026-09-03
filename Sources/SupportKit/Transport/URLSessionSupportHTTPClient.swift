import Foundation

/// An ephemeral, redirect-blocking HTTP client safe to share across tasks.
public actor URLSessionSupportHTTPClient: SupportHTTPClient {
    private static let maximumAllowedResponseBytes = 1024 * 1024

    private let session: URLSession

    /// Creates an ephemeral session that disables caches, cookies, and redirects.
    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        Self.harden(configuration)
        session = URLSession(
            configuration: configuration,
            delegate: SupportRedirectBlockingDelegate.shared,
            delegateQueue: nil,
        )
    }

    init(configuration: URLSessionConfiguration) {
        Self.harden(configuration)
        session = URLSession(
            configuration: configuration,
            delegate: SupportRedirectBlockingDelegate.shared,
            delegateQueue: nil,
        )
    }

    /// Executes a request while enforcing a streaming response-size cap.
    ///
    /// - Parameters:
    ///   - request: The fully authorized request to execute.
    ///   - maximumResponseBytes: The maximum number of response-body bytes to read.
    /// - Returns: The bounded response body and HTTP metadata.
    /// - Throws: ``SupportTransportError/invalidResponse`` for a non-HTTP or oversized
    ///   response, or the underlying networking or cancellation error.
    public func data(
        for request: URLRequest,
        maximumResponseBytes: Int,
    ) async throws -> (Data, HTTPURLResponse) {
        guard maximumResponseBytes >= 0 else {
            throw SupportTransportError.invalidResponse
        }
        let byteLimit = min(maximumResponseBytes, Self.maximumAllowedResponseBytes)

        do {
            try Task.checkCancellation()
            let (bytes, urlResponse) = try await session.bytes(for: request)
            return try await withTaskCancellationHandler {
                guard let response = urlResponse as? HTTPURLResponse else {
                    bytes.task.cancel()
                    throw SupportTransportError.invalidResponse
                }

                let expectedLength = response.expectedContentLength
                guard expectedLength < 0 || expectedLength <= Int64(byteLimit) else {
                    bytes.task.cancel()
                    throw SupportTransportError.invalidResponse
                }

                var data = Data()
                if expectedLength > 0 {
                    data.reserveCapacity(Int(expectedLength))
                }
                for try await byte in bytes {
                    try Task.checkCancellation()
                    guard data.count < byteLimit else {
                        bytes.task.cancel()
                        throw SupportTransportError.invalidResponse
                    }
                    data.append(byte)
                }
                try Task.checkCancellation()
                return (data, response)
            } onCancel: {
                bytes.task.cancel()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            if Task.isCancelled {
                throw CancellationError()
            }
            throw error
        }
    }

    private static func harden(_ configuration: URLSessionConfiguration) {
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
    }
}

/// `URLSession` retains its delegate and may invoke it concurrently. This
/// singleton has no mutable state, so its unchecked conformance is structural.
private final class SupportRedirectBlockingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    static let shared = SupportRedirectBlockingDelegate()

    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
    ) async -> URLRequest? {
        nil
    }
}
