import SupportKit
import SwiftUI

struct SupportPayloadPreviewView: View {
    let preview: SupportPayloadPreview
    let configuration: SupportFormConfiguration
    let theme: SupportFormTheme
    let confirm: @MainActor () -> Void
    let cancel: @MainActor () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section(configuration.previewReportSectionTitle) {
                    LabeledContent(configuration.previewSubjectLabel, value: preview.title)
                    Text(preview.message)
                }

                if !preview.responses.isEmpty {
                    Section(configuration.previewResponsesSectionTitle) {
                        ForEach(preview.responses, id: \.id) { response in
                            LabeledContent(response.label, value: response.value)
                        }
                    }
                }

                if !preview.diagnostics.isEmpty {
                    Section(configuration.previewDiagnosticsSectionTitle) {
                        ForEach(Array(preview.diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                            VStack(alignment: .leading, spacing: theme.verticalSpacing / 2) {
                                Text(diagnostic.key).bold()
                                diagnosticValue(diagnostic.value)
                                if diagnostic.sensitivity == .potentiallyIdentifying {
                                    Label(
                                        configuration.potentiallyIdentifyingValueLabel,
                                        systemImage: "person.crop.circle.badge.exclamationmark",
                                    )
                                    .font(theme.helpFont)
                                    .foregroundStyle(theme.secondaryText)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle(configuration.previewTitle)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(configuration.previewCancellationTitle, action: cancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(configuration.previewConfirmationTitle, action: confirm)
                }
            }
            .tint(theme.tint)
        }
    }

    @ViewBuilder
    private func diagnosticValue(_ value: String) -> some View {
        #if os(watchOS)
            Text(value)
        #else
            Text(value)
                .textSelection(.enabled)
        #endif
    }
}
