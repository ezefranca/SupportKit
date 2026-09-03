import SwiftUI

struct SupportAdditionalFieldsSection: View {
    @Binding var states: [SupportFormFieldState]
    let title: String
    let theme: SupportFormTheme

    var body: some View {
        if !states.isEmpty {
            Section(title) {
                ForEach($states) { $state in
                    SupportAdditionalFieldRow(state: $state, theme: theme)
                }
            }
            .listRowBackground(theme.rowBackground)
        }
    }
}
