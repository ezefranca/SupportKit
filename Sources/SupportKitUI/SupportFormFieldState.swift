import Foundation
import SupportKit

/// Editable presentation state for one configured additional field.
public struct SupportFormFieldState: Identifiable {
    /// The stable configured field identifier.
    public var id: String {
        field.id
    }

    /// The immutable definition rendered by this state.
    public let field: SupportFormField
    /// The value used by text, email, multiline, and picker controls.
    public var textValue: String
    /// The value used by toggle controls.
    public var toggleValue: Bool

    /// Creates editable state initialized from a configured field's default value.
    ///
    /// - Parameter field: The field definition represented by this state.
    public init(field: SupportFormField) {
        self.field = field
        textValue = field.defaultValue
        toggleValue = field.defaultValue == "true"
    }

    var responseValue: String {
        if case .toggle = field.kind {
            toggleValue ? "true" : "false"
        } else {
            textValue
        }
    }
}
