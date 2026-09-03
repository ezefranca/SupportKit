import SupportKit
import SwiftUI

struct SupportAdditionalFieldRow: View {
    @Binding var state: SupportFormFieldState
    let theme: SupportFormTheme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.verticalSpacing / 2) {
            fieldControl
            if let help = state.field.help {
                Text(help)
                    .font(theme.helpFont)
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    @ViewBuilder private var fieldControl: some View {
        switch state.field.kind {
        case .text, .email:
            TextField(state.field.prompt ?? state.field.label, text: $state.textValue)
                .font(theme.fieldFont)
                .accessibilityLabel(state.field.label)
        case .multiline:
            TextField(
                state.field.prompt ?? state.field.label,
                text: $state.textValue,
                axis: .vertical,
            )
            .font(theme.fieldFont)
            .lineLimit(3 ... 10)
            .accessibilityLabel(state.field.label)
        case .toggle:
            Toggle(state.field.label, isOn: $state.toggleValue)
                .font(theme.fieldFont)
        case let .picker(options):
            Picker(state.field.label, selection: $state.textValue) {
                ForEach(options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .font(theme.fieldFont)
        }
    }
}
