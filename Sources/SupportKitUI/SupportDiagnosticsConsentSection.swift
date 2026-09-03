import SupportKit
import SwiftUI

struct SupportDiagnosticsConsentSection: View {
    let configuration: SupportFormConfiguration
    let theme: SupportFormTheme
    @Binding var isIncluded: Bool

    var body: some View {
        Section(configuration.privacySectionTitle) {
            Toggle(configuration.diagnosticsOptInLabel, isOn: $isIncluded)
                .font(theme.fieldFont)
            Text(configuration.diagnosticsOptInHelp)
                .font(theme.helpFont)
                .foregroundStyle(theme.secondaryText)
        }
        .listRowBackground(theme.rowBackground)
    }
}
