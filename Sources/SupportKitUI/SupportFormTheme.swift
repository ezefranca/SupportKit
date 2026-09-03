import SwiftUI

/// Visual tokens for the ready-made form. Apps can replace every color, font,
/// spacing value, and corner radius while retaining SupportKit behavior.
@MainActor
public struct SupportFormTheme {
    /// The standard submit-button treatment.
    public enum SubmitButtonAppearance {
        /// A filled, high-emphasis bordered button.
        case prominent
        /// A lower-emphasis bordered button.
        case bordered
        /// A button without a border or fill.
        case plain
    }

    /// The accent used by controls and links.
    public let tint: Color
    /// The background behind the form's scrolling content.
    public let background: Color
    /// The background applied to each form row.
    public let rowBackground: Color
    /// The foreground style for primary copy.
    public let primaryText: Color
    /// The foreground style for supporting copy.
    public let secondaryText: Color
    /// The foreground style for submission errors.
    public let error: Color
    /// The foreground style for accepted or queued states.
    public let success: Color
    /// The form-title font.
    public let titleFont: Font
    /// The introductory-copy font.
    public let introductionFont: Font
    /// The font used by input controls.
    public let fieldFont: Font
    /// The font used by help and sensitivity copy.
    public let helpFont: Font
    /// The submission-status font.
    public let statusFont: Font
    /// The submit-button label font.
    public let buttonFont: Font
    /// The nonnegative corner radius used by interactive shapes.
    public let cornerRadius: Double
    /// The control height, clamped to at least 44 points.
    public let minimumControlHeight: Double
    /// The nonnegative spacing between vertically arranged elements.
    public let verticalSpacing: Double
    /// The submit-button treatment.
    public let submitButtonAppearance: SubmitButtonAppearance

    /// Creates a complete visual theme for ``SupportForm``.
    ///
    /// Dynamic Type behavior comes from the supplied SwiftUI fonts. Dimensions are normalized to safe values:
    /// `cornerRadius` and `verticalSpacing` cannot be negative, `minimumControlHeight` is at least 44 points, and a
    /// non-finite dimension uses its initializer default.
    ///
    /// - Parameters:
    ///   - tint: The accent used by controls and links.
    ///   - background: The background behind the form's scrolling content.
    ///   - rowBackground: The background applied to each form row.
    ///   - primaryText: The foreground style for primary copy.
    ///   - secondaryText: The foreground style for supporting copy.
    ///   - error: The foreground style for submission errors.
    ///   - success: The foreground style for queued and accepted states.
    ///   - titleFont: The form-title font.
    ///   - introductionFont: The introductory-copy font.
    ///   - fieldFont: The font used by input controls.
    ///   - helpFont: The font used by help and sensitivity copy.
    ///   - statusFont: The submission-status font.
    ///   - buttonFont: The submit-button label font.
    ///   - cornerRadius: The corner radius used by interactive shapes.
    ///   - minimumControlHeight: The minimum height of interactive controls, in points.
    ///   - verticalSpacing: The spacing between vertically arranged elements, in points.
    ///   - submitButtonAppearance: The submit-button treatment.
    public init(
        tint: Color = .accentColor,
        background: Color = .clear,
        rowBackground: Color = Color.secondary.opacity(0.08),
        primaryText: Color = .primary,
        secondaryText: Color = .secondary,
        error: Color = .red,
        success: Color = .green,
        titleFont: Font = .title.bold(),
        introductionFont: Font = .body,
        fieldFont: Font = .body,
        helpFont: Font = .footnote,
        statusFont: Font = .callout,
        buttonFont: Font = .headline,
        cornerRadius: Double = 12,
        minimumControlHeight: Double = 44,
        verticalSpacing: Double = 12,
        submitButtonAppearance: SubmitButtonAppearance = .prominent,
    ) {
        self.tint = tint
        self.background = background
        self.rowBackground = rowBackground
        self.primaryText = primaryText
        self.secondaryText = secondaryText
        self.error = error
        self.success = success
        self.titleFont = titleFont
        self.introductionFont = introductionFont
        self.fieldFont = fieldFont
        self.helpFont = helpFont
        self.statusFont = statusFont
        self.buttonFont = buttonFont
        self.cornerRadius = cornerRadius.isFinite ? max(0, cornerRadius) : 12
        self.minimumControlHeight = minimumControlHeight.isFinite ? max(44, minimumControlHeight) : 44
        self.verticalSpacing = verticalSpacing.isFinite ? max(0, verticalSpacing) : 12
        self.submitButtonAppearance = submitButtonAppearance
    }

    /// The adaptive, Dynamic Type-friendly standard theme.
    public static var `default`: Self {
        .init()
    }
}
