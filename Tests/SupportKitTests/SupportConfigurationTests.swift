import Foundation
@testable import SupportKit
import Testing

@Suite("Support configuration")
struct SupportConfigurationTests {
    @Test
    func `form and project configuration rejects ambiguous identifiers`() {
        // Arrange
        let duplicateForm = SupportFormConfiguration(additionalFields: [
            .init(id: "account", label: "First"),
            .init(id: "account", label: "Second"),
        ])
        let reservedForm = SupportFormConfiguration(additionalFields: [
            .init(id: "message", label: "Reserved"),
        ])

        // Act / Assert
        #expect(throws: SupportConfigurationError.duplicateFieldIdentifier("account")) {
            try duplicateForm.validate()
        }
        #expect(throws: SupportConfigurationError.reservedFieldIdentifier("message")) {
            try reservedForm.validate()
        }
        #expect(throws: SupportConfigurationError.invalidProjectIdentifier) {
            _ = try SupportConfiguration(projectID: "owner/repository")
        }
        #expect(throws: SupportConfigurationError.invalidProjectIdentifier) {
            _ = try SupportConfiguration(projectID: "café")
        }
        #expect(throws: SupportConfigurationError.invalidFieldIdentifier("café")) {
            try SupportFormConfiguration(additionalFields: [
                .init(id: "café", label: "Field"),
            ]).validate()
        }
    }

    @Test
    func `queue namespace spelling is preserved and outbound developer text is validated`() throws {
        // Act
        let configuration = try SupportConfiguration(projectID: "Project.ID", queueIdentifier: "Shared.Queue")

        // Assert
        #expect(configuration.queueIdentifier == "Shared.Queue")
        #expect(throws: SupportConfigurationError.invalidReportTitlePrefix) {
            _ = try SupportConfiguration(projectID: "project", reportTitlePrefix: "Support\u{202E}")
        }
        #expect(throws: SupportConfigurationError.invalidLabel(" bad")) {
            _ = try SupportConfiguration(projectID: "project", labels: [" bad"])
        }
        #expect(throws: SupportConfigurationError.invalidLabel("bad\u{7F}")) {
            _ = try SupportConfiguration(projectID: "project", labels: ["bad\u{7F}"])
        }
    }

    @Test
    func `field defaults and rendered labels are bounded and receiver-safe`() {
        // Arrange
        let tooManyFields = (0 ... 24).map {
            SupportFormField(id: "field\($0)", label: "Field \($0)")
        }
        let unsafePicker = SupportFormField(
            id: "kind",
            label: "Kind",
            kind: .picker(options: [.init(id: "one", label: " one")]),
            defaultValue: "one",
        )
        let unsafeToggle = SupportFormField(
            id: "consent",
            label: "Consent",
            kind: .toggle,
            toggleTrueLabel: "",
        )
        let oversizedDefault = SupportFormField(
            id: "context",
            label: "Context",
            maximumLength: nil,
            defaultValue: String(repeating: "x", count: 256 * 1024 + 1),
        )

        // Act / Assert
        #expect(throws: SupportConfigurationError.tooManyFormFields(maximum: 24)) {
            try SupportFormConfiguration(additionalFields: tooManyFields).validate()
        }
        #expect(throws: SupportConfigurationError.invalidPickerOptionLabel(field: "kind", option: "one")) {
            try SupportFormConfiguration(additionalFields: [unsafePicker]).validate()
        }
        #expect(throws: SupportConfigurationError.invalidFieldLabel("consent")) {
            try SupportFormConfiguration(additionalFields: [unsafeToggle]).validate()
        }
        #expect(throws: SupportConfigurationError.invalidFieldDefaultValue("context")) {
            try SupportFormConfiguration(additionalFields: [oversizedDefault]).validate()
        }
        #expect(throws: SupportConfigurationError.invalidFormCopy("queuedMessage")) {
            try SupportFormConfiguration(
                additionalFields: [],
                queuedMessage: "Queued\u{202E}",
            ).validate()
        }
        #expect(throws: SupportConfigurationError.invalidFieldSupportingText("notes")) {
            try SupportFormConfiguration(additionalFields: [
                .init(id: "notes", label: "Notes", help: String(repeating: "x", count: 16 * 1024 + 1)),
            ]).validate()
        }
    }
}
