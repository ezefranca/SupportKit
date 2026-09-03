import SwiftUI

struct SupportFormHeader: View {
    let title: String
    let introduction: String
    let theme: SupportFormTheme

    var body: some View {
        VStack(alignment: .leading, spacing: theme.verticalSpacing) {
            Text(title)
                .font(theme.titleFont)
                .foregroundStyle(theme.primaryText)
                .accessibilityAddTraits(.isHeader)
            Text(introduction)
                .font(theme.introductionFont)
                .foregroundStyle(theme.secondaryText)
        }
        .listRowBackground(theme.rowBackground)
    }
}
