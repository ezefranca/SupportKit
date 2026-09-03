import CryptoKit
import Foundation

/// Sends reports to a credential-free HTTPS receiver.
///
/// The receiver maps `projectID` to an allowlisted destination. It can use the
/// included server core or any implementation of the documented wire contract.
public struct SupportGatewayTransport: SupportTransport {
    /// Security and size limits for ``SupportGatewayTransport``.
    public struct Configuration: Sendable {
        private static let maximumAllowedRequestBytes = 256 * 1024
        private static let maximumAllowedResponseBytes = 1024 * 1024

        /// The fixed ingestion endpoint used for every request.
        public let endpoint: URL
        /// The largest encoded report the transport accepts.
        public let maximumRequestBytes: Int
        /// The largest response the transport reads before rejecting it.
        public let maximumResponseBytes: Int
        /// Whether debug builds may use plain HTTP on a loopback host.
        public let allowsInsecureLocalhost: Bool

        /// Creates validated receiver limits.
        ///
        /// Byte limits are clamped to safe implementation bounds. Plain HTTP is
        /// accepted only for loopback hosts in debug builds.
        ///
        /// - Parameters:
        ///   - endpoint: A fixed HTTPS ingestion URL without credentials, a query, or a fragment.
        ///   - maximumRequestBytes: The maximum encoded request size.
        ///   - maximumResponseBytes: The maximum response size to read.
        ///   - allowsInsecureLocalhost: Whether debug builds may use HTTP on a loopback host.
        /// - Throws: ``SupportConfigurationError/invalidEndpoint`` when `endpoint` violates the policy.
        public init(
            endpoint: URL,
            maximumRequestBytes: Int = 256 * 1024,
            maximumResponseBytes: Int = 64 * 1024,
            allowsInsecureLocalhost: Bool = false,
        ) throws {
            guard Self.isAllowed(endpoint, allowsInsecureLocalhost: allowsInsecureLocalhost) else {
                throw SupportConfigurationError.invalidEndpoint
            }
            self.endpoint = endpoint
            self.maximumRequestBytes = min(max(1024, maximumRequestBytes), Self.maximumAllowedRequestBytes)
            self.maximumResponseBytes = min(max(1024, maximumResponseBytes), Self.maximumAllowedResponseBytes)
            #if DEBUG
                self.allowsInsecureLocalhost = allowsInsecureLocalhost
            #else
                self.allowsInsecureLocalhost = false
            #endif
        }

        fileprivate static func isAllowed(_ url: URL, allowsInsecureLocalhost: Bool) -> Bool {
            guard url.host != nil,
                  url.user == nil,
                  url.password == nil,
                  url.query == nil,
                  url.fragment == nil
            else { return false }
            if url.scheme?.lowercased() == "https" {
                return true
            }
            #if DEBUG
                let localHosts = Set(["localhost", "127.0.0.1", "::1"])
                return allowsInsecureLocalhost
                    && url.scheme?.lowercased() == "http"
                    && url.host.map(localHosts.contains) == true
            #else
                return false
            #endif
        }
    }

    private struct ErrorResponse: Decodable {
        let code: String?
        let message: String?
    }

    private let configuration: Configuration
    private let authorizer: any SupportRequestAuthorizer
    private let httpClient: any SupportHTTPClient

    /// Creates a transport that posts reports to a credential-free receiver.
    ///
    /// - Parameters:
    ///   - configuration: The validated endpoint and request limits.
    ///   - authorizer: A request signer or attestation provider. Pass
    ///     ``AnonymousSupportRequestAuthorizer`` only to a receiver intentionally
    ///     configured for anonymous, rate-limited ingestion.
    ///   - httpClient: The HTTP execution boundary.
    public init(
        configuration: Configuration,
        authorizer: any SupportRequestAuthorizer,
        httpClient: any SupportHTTPClient = URLSessionSupportHTTPClient(),
    ) {
        self.configuration = configuration
        self.authorizer = authorizer
        self.httpClient = httpClient
    }

    /// Sends one frozen report and validates the receiver's receipt.
    ///
    /// - Parameter submission: The immutable report to deliver.
    /// - Returns: The receiver's matching durable receipt.
    /// - Throws: ``SupportTransportError`` when the request is too large, the network
    ///   fails, or the response violates the receiver contract.
    public func submit(_ submission: SupportSubmission) async throws -> SupportDeliveryReceipt {
        let body = try SupportSubmissionWireCodec.encode(submission)
        guard body.count <= configuration.maximumRequestBytes else {
            throw SupportTransportError.payloadTooLarge
        }

        let request = try await authorizedRequest(for: submission, body: body)
        let (data, response) = try await response(for: request)
        guard data.count <= configuration.maximumResponseBytes else {
            throw SupportTransportError.invalidResponse
        }
        return try Self.deliveryReceipt(from: data, response: response, submission: submission)
    }

    private func authorizedRequest(for submission: SupportSubmission, body: Data) async throws -> URLRequest {
        let digest = Self.sha256(body)
        var request = URLRequest(url: configuration.endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(submission.idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        request.setValue(digest, forHTTPHeaderField: "X-SupportKit-Payload-SHA256")
        request.setValue("SupportKit/1.0", forHTTPHeaderField: "User-Agent")
        request = try await authorizer.authorize(request, body: body)
        guard let authorizedURL = request.url,
              authorizedURL == configuration.endpoint,
              Configuration.isAllowed(
                  authorizedURL,
                  allowsInsecureLocalhost: configuration.allowsInsecureLocalhost,
              ),
              request.httpMethod == "POST",
              request.httpBody == body,
              request.httpBodyStream == nil,
              request.timeoutInterval == 30,
              request.value(forHTTPHeaderField: "Idempotency-Key") == submission.idempotencyKey,
              request.value(forHTTPHeaderField: "X-SupportKit-Payload-SHA256") == digest,
              request.value(forHTTPHeaderField: "Content-Type") == "application/json",
              request.value(forHTTPHeaderField: "Accept") == "application/json",
              request.value(forHTTPHeaderField: "User-Agent") == "SupportKit/1.0",
              request.value(forHTTPHeaderField: "Content-Encoding") == nil,
              request.value(forHTTPHeaderField: "Content-Length") == nil,
              request.value(forHTTPHeaderField: "Content-Range") == nil,
              request.value(forHTTPHeaderField: "Transfer-Encoding") == nil,
              request.value(forHTTPHeaderField: "Host") == nil
        else {
            throw SupportTransportError.permanent(
                code: nil,
                reason: "Support request authorization changed protected request properties.",
            )
        }
        return request
    }

    private func response(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            return try await httpClient.data(
                for: request,
                maximumResponseBytes: configuration.maximumResponseBytes,
            )
        } catch let error as SupportTransportError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw SupportTransportError.retryable(
                code: nil,
                retryAfter: nil,
                reason: "The support receiver is temporarily unreachable.",
            )
        }
    }

    private static func deliveryReceipt(
        from data: Data,
        response: HTTPURLResponse,
        submission: SupportSubmission,
    ) throws -> SupportDeliveryReceipt {
        switch response.statusCode {
        case 200, 201, 202:
            let receipt: SupportDeliveryReceipt
            do {
                receipt = try decoder().decode(SupportDeliveryReceipt.self, from: data)
            } catch {
                throw SupportTransportError.invalidResponse
            }
            guard receipt.reportID == submission.id else {
                throw SupportTransportError.invalidResponse
            }
            guard Self.isValid(receipt: receipt) else {
                throw SupportTransportError.invalidResponse
            }
            return receipt
        case 408, 425, 429, 500 ... 599:
            throw SupportTransportError.retryable(
                code: response.statusCode,
                retryAfter: retryAfter(from: response),
                reason: safeMessage(from: data) ?? "The support receiver asked us to retry later.",
            )
        default:
            throw SupportTransportError.permanent(
                code: response.statusCode,
                reason: safeMessage(from: data) ?? "The support receiver rejected this report.",
            )
        }
    }

    private static func safeMessage(from data: Data) -> String? {
        guard let response = try? decoder().decode(ErrorResponse.self, from: data),
              let message = response.message,
              let bounded = SupportTextSafety.boundedSingleLine(message, maximumBytes: 4096)
        else { return nil }
        return SupportTextSafety.boundedFailureReason(SupportRedactor().redact(bounded))
    }

    private static func isValid(receipt: SupportDeliveryReceipt) -> Bool {
        guard receipt.acceptedAt.timeIntervalSinceReferenceDate.isFinite,
              receipt.acceptedAt <= Date.now.addingTimeInterval(5 * 60)
        else { return false }

        if let url = receipt.destinationURL {
            guard url.scheme?.lowercased() == "https",
                  url.host != nil,
                  url.user == nil,
                  url.password == nil
            else { return false }
        }
        if let reference = receipt.destinationReference {
            guard reference.utf8.count <= 1024,
                  reference.count <= 200,
                  reference == reference.trimmingCharacters(in: .whitespacesAndNewlines),
                  !reference.isEmpty,
                  SupportTextSafety.isWireSafe(reference)
            else { return false }
        }
        return true
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            let hex = String($0, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }

    private static func retryAfter(from response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = TimeInterval(value), seconds.isFinite, seconds >= 0 {
            return seconds
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        guard let date = formatter.date(from: value) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)
            guard !value.isEmpty, value.utf8.count <= 64 else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Expected a bounded ISO-8601 timestamp.",
                )
            }

            let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            if let date = try? fractional.parse(value) {
                return date
            }
            let wholeSeconds = Date.ISO8601FormatStyle(includingFractionalSeconds: false)
            if let date = try? wholeSeconds.parse(value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Expected an ISO-8601 timestamp.",
            )
        }
        return decoder
    }
}
