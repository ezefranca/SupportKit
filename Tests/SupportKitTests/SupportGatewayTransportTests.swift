import CryptoKit
import Foundation
@testable import SupportKit
import Testing

@Suite("Gateway transport")
struct SupportGatewayTransportTests {
    enum Classification: Sendable {
        case retryable
        case permanent
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        let statusCode: Int
        let classification: Classification

        var testDescription: String {
            "HTTP \(statusCode)"
        }
    }

    static let statusCases: [StatusCase] = [
        .init(statusCode: 400, classification: .permanent),
        .init(statusCode: 401, classification: .permanent),
        .init(statusCode: 403, classification: .permanent),
        .init(statusCode: 404, classification: .permanent),
        .init(statusCode: 409, classification: .permanent),
        .init(statusCode: 422, classification: .permanent),
        .init(statusCode: 408, classification: .retryable),
        .init(statusCode: 425, classification: .retryable),
        .init(statusCode: 429, classification: .retryable),
        .init(statusCode: 500, classification: .retryable),
        .init(statusCode: 503, classification: .retryable),
        .init(statusCode: 599, classification: .retryable),
    ]

    @Test
    func `requests contain the idempotency, integrity, content, and authorization headers`() async throws {
        // Arrange
        let submission = SupportKitTestFixture.submission()
        let responseData = try encode(SupportKitTestFixture.receipt())
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(data: responseData, statusCode: 202))
        let authorizer = SupportRequestAuthorizerSpy()
        let endpoint = try gatewayURL(path: "v1/reports")
        let configuration = try SupportGatewayTransport.Configuration(endpoint: endpoint)
        let sut = SupportGatewayTransport(
            configuration: configuration,
            authorizer: authorizer,
            httpClient: httpClient,
        )

        // Act
        let receipt = try await sut.submit(submission)
        let request = try #require(await httpClient.requests().first)
        let requestBeforeAuthorization = try #require(await authorizer.requests().first)
        let authorizedBody = try #require(await authorizer.bodies().first)
        let decodedBody = try decodeSubmission(authorizedBody)

        // Assert
        #expect(receipt == SupportKitTestFixture.receipt())
        #expect(request.url == endpoint)
        #expect(request.httpMethod == "POST")
        #expect(request.timeoutInterval == 30)
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == submission.idempotencyKey)
        #expect(request.value(forHTTPHeaderField: "X-SupportKit-Payload-SHA256") == sha256(authorizedBody))
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "SupportKit/1.0")
        #expect(request.value(forHTTPHeaderField: "X-Test-Authorization") == "ephemeral-test-proof")
        #expect(requestBeforeAuthorization.value(forHTTPHeaderField: "X-Test-Authorization") == nil)
        #expect(request.httpBody == authorizedBody)
        #expect(decodedBody == submission)
        #expect(await httpClient.maximumResponseByteLimits() == [configuration.maximumResponseBytes])
    }

    @Test(arguments: statusCases)
    func `HTTP failures are classified without exposing the response body`(testCase: StatusCase) async throws {
        // Arrange
        let body = try JSONEncoder().encode(["message": "Try again for person@example.com"])
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(
            data: body,
            statusCode: testCase.statusCode,
            headers: ["Retry-After": "12"],
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act
        do {
            _ = try await sut.submit(SupportKitTestFixture.submission())
            Issue.record("Expected HTTP \(testCase.statusCode) to throw")
        } catch let error as SupportTransportError {
            // Assert
            switch (testCase.classification, error) {
            case let (.retryable, .retryable(code, retryAfter, reason)):
                #expect(code == testCase.statusCode)
                #expect(retryAfter == 12)
                #expect(reason == "Try again for <redacted-email>")
            case let (.permanent, .permanent(code, reason)):
                #expect(code == testCase.statusCode)
                #expect(reason == "Try again for <redacted-email>")
            default:
                Issue.record("Unexpected classification \(error)")
            }
        } catch {
            Issue.record("Expected SupportTransportError, received \(type(of: error))")
        }
    }

    @Test(arguments: [200, 201, 202])
    func `successful status codes decode gateway receipts`(statusCode: Int) async throws {
        // Arrange
        let expected = SupportKitTestFixture.receipt(status: .delivered)
        let httpClient = try SupportHTTPClientSpyingStub(outcome: .response(
            data: encode(expected),
            statusCode: statusCode,
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act
        let receipt = try await sut.submit(SupportKitTestFixture.submission())

        // Assert
        #expect(receipt == expected)
    }

    @Test
    func `gateway JavaScript timestamps with fractional seconds decode`() async throws {
        // Arrange
        let submission = SupportKitTestFixture.submission()
        let responseData = Data(
            """
            {
              "reportID": "\(submission.id.uuidString)",
              "status": "accepted",
              "acceptedAt": "2023-11-14T22:13:20.000Z",
              "destinationURL": null,
              "destinationReference": null
            }
            """.utf8,
        )
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(data: responseData, statusCode: 202))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act
        let receipt = try await sut.submit(submission)

        // Assert
        #expect(receipt.acceptedAt == SupportKitTestFixture.date)
    }

    @Test
    func `a receipt for a different report is rejected`() async throws {
        // Arrange
        let response = SupportKitTestFixture.receipt(reportID: SupportKitTestFixture.secondReportID)
        let httpClient = try SupportHTTPClientSpyingStub(outcome: .response(
            data: encode(response),
            statusCode: 201,
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(.invalidResponse) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }

    @Test
    func `a malformed successful response is classified as invalid instead of leaking decoder details`() async throws {
        // Arrange
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(
            data: Data("not-json".utf8),
            statusCode: 200,
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(.invalidResponse) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }

    @Test
    func `an oversized request is rejected before authorization or network I/O`() async throws {
        // Arrange
        let httpClient = SupportHTTPClientSpyingStub(outcome: .connectivityError)
        let authorizer = SupportRequestAuthorizerSpy()
        let sut = try SupportGatewayTransport(
            configuration: .init(
                endpoint: gatewayURL(),
                maximumRequestBytes: 1024,
            ),
            authorizer: authorizer,
            httpClient: httpClient,
        )
        let submission = SupportKitTestFixture.submission(message: String(repeating: "x", count: 2000))

        // Act / Assert
        await expectTransportError(.payloadTooLarge) {
            try await sut.submit(submission)
        }
        #expect(await authorizer.bodies().isEmpty)
        #expect(await httpClient.requests().isEmpty)
    }

    @Test
    func `an oversized response is rejected before status or JSON processing`() async throws {
        // Arrange
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(
            data: Data(repeating: 0x41, count: 1025),
            statusCode: 503,
            headers: ["Retry-After": "20"],
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(
                endpoint: gatewayURL(),
                maximumResponseBytes: 1024,
            ),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(.invalidResponse) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }

    @Test
    func `ordinary connectivity errors become safe retryable failures`() async throws {
        // Arrange
        let httpClient = SupportHTTPClientSpyingStub(outcome: .connectivityError)
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(
            .retryable(
                code: nil,
                retryAfter: nil,
                reason: "The support receiver is temporarily unreachable.",
            ),
        ) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }

    @Test
    func `preclassified HTTP client errors pass through unchanged`() async throws {
        // Arrange
        let expected = SupportTransportError.retryable(code: 429, retryAfter: 90, reason: "Back off.")
        let httpClient = SupportHTTPClientSpyingStub(outcome: .supportError(expected))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(expected) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }
}

extension SupportGatewayTransportTests {
    @Test(arguments: ["NaN", "Infinity", "-1"])
    func `invalid retry-after seconds are ignored`(value: String) async throws {
        // Arrange
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(
            data: Data(),
            statusCode: 429,
            headers: ["Retry-After": value],
        ))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        do {
            _ = try await sut.submit(SupportKitTestFixture.submission())
            Issue.record("Expected a retryable response")
        } catch let error as SupportTransportError {
            guard case let .retryable(code, retryAfter, _) = error else {
                Issue.record("Expected a retryable transport error")
                return
            }
            #expect(code == 429)
            #expect(retryAfter == nil)
        } catch {
            Issue.record("Expected SupportTransportError, received \(type(of: error))")
        }
    }

    @Test
    func `only HTTPS endpoints are accepted for non-local gateways`() throws {
        // Arrange
        let secure = try #require(URL(string: "https://support.example.com/reports"))
        let insecure = try #require(URL(string: "http://support.example.com/reports"))
        let file = URL(fileURLWithPath: "/tmp/reports")
        let credentialed = try #require(URL(string: "https://user:password@support.example.com/reports"))
        let queried = try #require(URL(string: "https://support.example.com/reports?tenant=private"))
        let fragmented = try #require(URL(string: "https://support.example.com/reports#internal"))

        // Act / Assert
        _ = try SupportGatewayTransport.Configuration(endpoint: secure)
        #expect(throws: SupportConfigurationError.invalidEndpoint) {
            _ = try SupportGatewayTransport.Configuration(endpoint: insecure)
        }
        #expect(throws: SupportConfigurationError.invalidEndpoint) {
            _ = try SupportGatewayTransport.Configuration(endpoint: file)
        }
        #expect(throws: SupportConfigurationError.invalidEndpoint) {
            _ = try SupportGatewayTransport.Configuration(endpoint: credentialed)
        }
        #expect(throws: SupportConfigurationError.invalidEndpoint) {
            _ = try SupportGatewayTransport.Configuration(endpoint: queried)
        }
        #expect(throws: SupportConfigurationError.invalidEndpoint) {
            _ = try SupportGatewayTransport.Configuration(endpoint: fragmented)
        }
    }

    @Test
    func `authorizers cannot mutate protected request properties`() async throws {
        // Arrange
        let cases: [(String, MutatingSupportRequestAuthorizer.Mutation)] = try [
            ("URL", .url(gatewayURL(path: "other"))),
            ("method", .method),
            ("body", .body),
            ("body stream", .bodyStream),
            ("timeout", .timeout),
            ("idempotency", .header("Idempotency-Key", "different")),
            ("digest", .header("X-SupportKit-Payload-SHA256", "different")),
            ("content type", .header("Content-Type", "text/plain")),
            ("accept", .header("Accept", "text/plain")),
            ("user agent", .header("User-Agent", "different")),
            ("content encoding", .header("Content-Encoding", "gzip")),
            ("content length", .header("Content-Length", "1")),
            ("content range", .header("Content-Range", "bytes 0-0/1")),
            ("transfer encoding", .header("Transfer-Encoding", "chunked")),
            ("host", .header("Host", "other.example.com")),
        ]

        for (name, mutation) in cases {
            let httpClient = SupportHTTPClientSpyingStub(outcome: .connectivityError)
            let sut = try SupportGatewayTransport(
                configuration: .init(endpoint: gatewayURL()),
                authorizer: MutatingSupportRequestAuthorizer(mutation: mutation),
                httpClient: httpClient,
            )

            // Act / Assert
            do {
                _ = try await sut.submit(SupportKitTestFixture.submission())
                Issue.record("Expected protected \(name) mutation to fail")
            } catch let error as SupportTransportError {
                #expect(error == .permanent(
                    code: nil,
                    reason: "Support request authorization changed protected request properties.",
                ))
            } catch {
                Issue.record("Expected SupportTransportError for \(name), received \(type(of: error))")
            }
            #expect(await httpClient.requests().isEmpty)
        }
    }

    private func encode(_ receipt: SupportDeliveryReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    private func gatewayURL(path: String = "reports") throws -> URL {
        try #require(URL(string: "https://support.example.com/\(path)"))
    }

    private func decodeSubmission(_ data: Data) throws -> SupportSubmission {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SupportSubmission.self, from: data)
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map {
            let hex = String($0, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }

    private func expectTransportError(
        _ expected: SupportTransportError,
        operation: () async throws -> SupportDeliveryReceipt,
    ) async {
        do {
            _ = try await operation()
            Issue.record("Expected \(expected)")
        } catch let error as SupportTransportError {
            #expect(error == expected)
        } catch {
            Issue.record("Expected SupportTransportError, received \(type(of: error))")
        }
    }
}
