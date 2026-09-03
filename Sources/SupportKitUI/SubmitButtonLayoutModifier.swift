import SwiftUI

private struct SubmitButtonLayoutModifier: ViewModifier {
    let theme: SupportFormTheme
    let isDisabled: Bool

    func body(content: Content) -> some View {
        content
            .font(theme.buttonFont)
            .frame(maxWidth: .infinity, minHeight: theme.minimumControlHeight)
            .contentShape(.rect(cornerRadius: theme.cornerRadius))
            .disabled(isDisabled)
    }
}

extension View {
    func submitButtonLayout(theme: SupportFormTheme, isDisabled: Bool) -> some View {
        modifier(SubmitButtonLayoutModifier(theme: theme, isDisabled: isDisabled))
    }
}
