import Foundation
@testable import SupportKit
import Testing

@Suite("Resource limit normalization")
struct SupportResourceLimitTests {
    @Test
    func `astronomical delivery values are clamped before date and duration arithmetic`() {
        // Act
        let sut = DeliveryConfiguration(
            duplicateSuppressionInterval: .greatestFiniteMagnitude,
            initialRetryDelay: .greatestFiniteMagnitude,
            maximumRetryDelay: .greatestFiniteMagnitude,
            maximumStoredSubmissions: .max,
            deliveryBatchSize: .max,
            receiptRetentionInterval: .greatestFiniteMagnitude,
            maximumSubmissionBytes: .max,
            deliveryLeaseDuration: .greatestFiniteMagnitude,
        )

        // Assert
        #expect(sut.duplicateSuppressionInterval == 365 * 24 * 60 * 60)
        #expect(sut.initialRetryDelay == 7 * 24 * 60 * 60)
        #expect(sut.maximumRetryDelay == 7 * 24 * 60 * 60)
        #expect(sut.maximumStoredSubmissions == 1000)
        #expect(sut.deliveryBatchSize == 100)
        #expect(sut.receiptRetentionInterval == 365 * 24 * 60 * 60)
        #expect(sut.maximumSubmissionBytes == 256 * 1024)
        #expect(sut.deliveryLeaseDuration == 24 * 60 * 60)
    }

    @Test
    func `astronomical gateway byte limits are clamped to bounded allocations`() throws {
        // Arrange
        let endpoint = try #require(URL(string: "https://support.example.com/reports"))

        // Act
        let sut = try SupportGatewayTransport.Configuration(
            endpoint: endpoint,
            maximumRequestBytes: .max,
            maximumResponseBytes: .max,
        )

        // Assert
        #expect(sut.maximumRequestBytes == 256 * 1024)
        #expect(sut.maximumResponseBytes == 1024 * 1024)
    }

    @Test
    func `astronomical diagnostic limits are clamped to bounded work`() {
        // Act
        let sut = DiagnosticsConfiguration(
            maximumLogEntries: .max,
            maximumLogMessageLength: .max,
            maximumDiagnosticCount: .max,
            maximumDiagnosticValueLength: .max,
        )

        // Assert
        #expect(sut.maximumLogEntries == 500)
        #expect(sut.maximumLogMessageLength == 10000)
        #expect(sut.maximumDiagnosticCount == 100)
        #expect(sut.maximumDiagnosticValueLength == 20000)
    }
}
