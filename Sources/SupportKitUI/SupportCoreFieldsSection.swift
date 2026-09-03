import SupportKit
import SwiftUI

struct SupportCoreFieldsSection: View {
    let configuration: SupportFormConfiguration
    let theme: SupportFormTheme
    @Binding var subject: String
    @Binding var message: String

    var body: some View {
        Section {
            TextField(configuration.subjectPrompt, text: $subject)
                .font(theme.fieldFont)
                .accessibilityLabel(configuration.subjectLabel)

            VStack(alignment: .leading, spacing: theme.verticalSpacing) {
                Text(configuration.messageLabel)
                    .font(theme.helpFont)
                    .foregroundStyle(theme.secondaryText)
                TextField(configuration.messagePrompt, text: $message, axis: .vertical)
                    .font(theme.fieldFont)
                    .lineLimit(5 ... 12)
                    .accessibilityLabel(configuration.messageLabel)
            }
        } header: {
            Text(configuration.subjectLabel)
        }
        .listRowBackground(theme.rowBackground)
    }
}
