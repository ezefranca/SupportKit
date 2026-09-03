import Foundation
@testable import SupportKit
import Testing

@Suite("Retry policy")
struct SupportRetryPolicyTests {
    @Test
    func `server delays are honored and capped`() {
        // Arrange
        let configuration = DeliveryConfiguration(initialRetryDelay: 10, maximumRetryDelay: 100)
        let sut = SupportRetryPolicy(configuration: configuration)

        // Act
        let ordinary = sut.delay(afterAttempt: 5, serverDelay: 42, reportID: SupportKitTestFixture.reportID)
        let capped = sut.delay(afterAttempt: 5, serverDelay: 500, reportID: SupportKitTestFixture.reportID)

        // Assert
        #expect(ordinary == 42)
        #expect(capped == 100)
    }

    @Test
    func `invalid or immediate server delays cannot create a retry hot loop`() {
        // Arrange
        let configuration = DeliveryConfiguration(initialRetryDelay: 10, maximumRetryDelay: 100)
        let sut = SupportRetryPolicy(configuration: configuration)

        // Act / Assert
        #expect(sut.delay(afterAttempt: 1, serverDelay: 0, reportID: SupportKitTestFixture.reportID) == 10)
        #expect(sut.delay(afterAttempt: 1, serverDelay: -1, reportID: SupportKitTestFixture.reportID) == 8)
        #expect(sut.delay(afterAttempt: 1, serverDelay: .infinity, reportID: SupportKitTestFixture.reportID) == 8)
        #expect(sut.delay(afterAttempt: 1, serverDelay: .nan, reportID: SupportKitTestFixture.reportID) == 8)
    }

    @Test
    func `exponential backoff has stable report-specific jitter`() {
        // Arrange
        let configuration = DeliveryConfiguration(initialRetryDelay: 10, maximumRetryDelay: 100)
        let sut = SupportRetryPolicy(configuration: configuration)
        let lowJitterID = UUID(uuid: (
            0x00, 0x00, 0x00, 0x00,
            0x00, 0x00,
            0x40, 0x00,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ))
        let highJitterID = UUID(uuid: (
            0xFF, 0x00, 0x00, 0x00,
            0x00, 0x00,
            0x40, 0x00,
            0x80, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        ))

        // Act
        let firstAttempt = sut.delay(afterAttempt: 1, serverDelay: nil, reportID: lowJitterID)
        let secondAttempt = sut.delay(afterAttempt: 2, serverDelay: nil, reportID: lowJitterID)
        let cappedAttempt = sut.delay(afterAttempt: 20, serverDelay: nil, reportID: highJitterID)

        // Assert
        #expect(firstAttempt == 8)
        #expect(secondAttempt == 16)
        #expect(cappedAttempt == 100)
    }

    @Test
    func `corrupt extreme attempt counts cannot overflow backoff arithmetic`() {
        // Arrange
        let configuration = DeliveryConfiguration(initialRetryDelay: 10, maximumRetryDelay: 100)
        let sut = SupportRetryPolicy(configuration: configuration)

        // Act
        let negative = sut.delay(
            afterAttempt: .min,
            serverDelay: nil,
            reportID: SupportKitTestFixture.reportID,
        )
        let positive = sut.delay(
            afterAttempt: .max,
            serverDelay: nil,
            reportID: SupportKitTestFixture.reportID,
        )

        // Assert
        #expect(negative == 8)
        #expect(positive == 80)
        #expect(positive.isFinite)
    }
}
