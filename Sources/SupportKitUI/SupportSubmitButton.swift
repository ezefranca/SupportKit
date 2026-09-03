import SwiftUI

struct SupportSubmitButton: View {
    let title: String
    let theme: SupportFormTheme
    let isBusy: Bool
    let action: @MainActor () -> Void

    var body: some View {
        styledButton
            .submitButtonLayout(theme: theme, isDisabled: isBusy)
    }

    @ViewBuilder private var styledButton: some View {
        switch theme.submitButtonAppearance {
        case .prominent:
            button.buttonStyle(.borderedProminent)
        case .bordered:
            button.buttonStyle(.bordered)
        case .plain:
            button.buttonStyle(.plain)
        }
    }

    private var button: some View {
        Button(action: action) {
            HStack {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityHidden(true)
                }
                Text(title)
            }
        }
    }
}
