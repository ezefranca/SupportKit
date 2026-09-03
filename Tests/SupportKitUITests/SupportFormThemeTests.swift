@testable import SupportKitUI
import Testing

@MainActor
@Suite("Support form theme")
struct SupportFormThemeTests {
    @Test
    func `nonfinite dimensions fall back to documented defaults`() {
        // Arrange / Act
        let sut = SupportFormTheme(
            cornerRadius: .infinity,
            minimumControlHeight: -.infinity,
            verticalSpacing: .nan,
        )

        // Assert
        #expect(sut.cornerRadius == 12)
        #expect(sut.minimumControlHeight == 44)
        #expect(sut.verticalSpacing == 12)
    }

    @Test
    func `finite dimensions retain their lower bounds`() {
        // Arrange / Act
        let sut = SupportFormTheme(
            cornerRadius: -1,
            minimumControlHeight: 10,
            verticalSpacing: -1,
        )

        // Assert
        #expect(sut.cornerRadius == 0)
        #expect(sut.minimumControlHeight == 44)
        #expect(sut.verticalSpacing == 0)
    }
}
