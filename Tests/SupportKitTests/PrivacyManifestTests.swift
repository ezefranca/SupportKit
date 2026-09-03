import Foundation
@testable import SupportKit
import Testing

@Suite("Privacy manifest")
struct PrivacyManifestTests {
    @Test
    func `the packaged manifest conservatively declares linked support data without tracking`() throws {
        // Arrange
        let manifestURL = try #require(Bundle.module.url(
            forResource: "PrivacyInfo",
            withExtension: "xcprivacy",
        ))
        let data = try Data(contentsOf: manifestURL)

        // Act
        let propertyList = try PropertyListSerialization.propertyList(from: data, format: nil)
        let root = try #require(propertyList as? [String: Any])
        let collectedData = try #require(root["NSPrivacyCollectedDataTypes"] as? [[String: Any]])
        let collectedTypes = Set(collectedData.compactMap {
            $0["NSPrivacyCollectedDataType"] as? String
        })

        // Assert
        #expect(root["NSPrivacyTracking"] as? Bool == false)
        #expect(collectedTypes == [
            "NSPrivacyCollectedDataTypeCustomerSupport",
            "NSPrivacyCollectedDataTypeOtherDiagnosticData",
            "NSPrivacyCollectedDataTypeEmailAddress",
        ])
        #expect(collectedData.allSatisfy { $0["NSPrivacyCollectedDataTypeTracking"] as? Bool == false })
        #expect(collectedData.allSatisfy { $0["NSPrivacyCollectedDataTypeLinked"] as? Bool == true })
        #expect(collectedData.allSatisfy {
            ($0["NSPrivacyCollectedDataTypePurposes"] as? [String])
                == ["NSPrivacyCollectedDataTypePurposeAppFunctionality"]
        })
    }
}
