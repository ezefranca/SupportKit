import Foundation
@testable import SupportKit
import Testing

@Suite("Gateway transport security metadata")
struct SupportGatewayTransportSecurityTests {
    @Test
    func `untrusted receipt destinations and metadata are rejected`() async throws {
        // Arrange
        let invalidReceipts = [
            SupportKitTestFixture.receipt(destinationURL: URL(string: "http://example.com/42")),
            SupportKitTestFixture.receipt(destinationURL: URL(string: "https://user@example.com/42")),
            SupportKitTestFixture.receipt(destinationReference: "ticket\u{202E}"),
            SupportKitTestFixture.receipt(acceptedAt: Date.now.addingTimeInterval(3600)),
        ]

        // Act / Assert
        for receipt in invalidReceipts {
            let httpClient = try SupportHTTPClientSpyingStub(outcome: .response(
                data: encode(receipt),
                statusCode: 202,
            ))
            let sut = try SupportGatewayTransport(
                configuration: .init(endpoint: gatewayURL()),
                authorizer: AnonymousSupportRequestAuthorizer(),
                httpClient: httpClient,
            )
            await expectTransportError(.invalidResponse) {
                try await sut.submit(SupportKitTestFixture.submission())
            }
        }
    }

    @Test
    func `remote error text is bounded redacted and stripped of spoofing controls`() async throws {
        // Arrange
        let body = try JSONEncoder().encode([
            "message": "  Attack\u{202E}\u{7F}\n person@example.com  ",
        ])
        let httpClient = SupportHTTPClientSpyingStub(outcome: .response(data: body, statusCode: 400))
        let sut = try SupportGatewayTransport(
            configuration: .init(endpoint: gatewayURL()),
            authorizer: AnonymousSupportRequestAuthorizer(),
            httpClient: httpClient,
        )

        // Act / Assert
        await expectTransportError(.permanent(code: 400, reason: "Attack <redacted-email>")) {
            try await sut.submit(SupportKitTestFixture.submission())
        }
    }

    private func encode(_ receipt: SupportDeliveryReceipt) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }

    private func gatewayURL() throws -> URL {
        try #require(URL(string: "https://support.example.com/reports"))
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
            Issue.record("Expected SupportTransportError")
        }
    }
}

@Suite("Bearer token authorizer")
struct SupportBearerTokenAuthorizerTests {
    @Test
    func `a fresh scoped token is added without changing the protected request`() async throws {
        // Arrange
        let endpoint = try #require(URL(string: "https://support.example.com/reports"))
        let request = URLRequest(url: endpoint)
        let sut = SupportBearerTokenAuthorizer { "header.payload.signature" }

        // Act
        let result = try await sut.authorize(request, body: Data())

        // Assert
        #expect(result.url == endpoint)
        #expect(result.value(forHTTPHeaderField: "Authorization") == "Bearer header.payload.signature")
    }

    @Test(arguments: ["", "contains space", "token\nheader", String(repeating: "a", count: 4097)])
    func `malformed token values are rejected`(token: String) async throws {
        // Arrange
        let request = try URLRequest(url: #require(URL(string: "https://support.example.com")))
        let sut = SupportBearerTokenAuthorizer { token }

        // Act / Assert
        do {
            _ = try await sut.authorize(request, body: Data())
            Issue.record("Expected malformed bearer token to fail")
        } catch let error as SupportAuthorizationError {
            #expect(error == .invalidBearerToken)
        } catch {
            Issue.record("Expected SupportAuthorizationError")
        }
    }
}

struct MutatingSupportRequestAuthorizer: SupportRequestAuthorizer {
    enum Mutation: Sendable {
        case url(URL)
        case method
        case body
        case bodyStream
        case timeout
        case header(String, String)
    }

    let mutation: Mutation

    func authorize(_ request: URLRequest, body _: Data) async throws -> URLRequest {
        var request = request
        switch mutation {
        case let .url(url): request.url = url
        case .method: request.httpMethod = "GET"
        case .body: request.httpBody = Data("different".utf8)
        case .bodyStream: request.httpBodyStream = InputStream(data: Data("different".utf8))
        case .timeout: request.timeoutInterval = 300
        case let .header(name, value): request.setValue(value, forHTTPHeaderField: name)
        }
        return request
    }
}
