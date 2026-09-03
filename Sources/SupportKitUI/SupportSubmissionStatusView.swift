import SupportKit
import SwiftUI

struct SupportSubmissionStatusView: View {
    let phase: SupportFormPhase
    let configuration: SupportFormConfiguration
    let theme: SupportFormTheme

    var body: some View {
        switch phase {
        case let .queued(reportID):
            Label(configuration.queuedMessage, systemImage: "clock.badge.checkmark")
                .foregroundStyle(theme.success)
                .accessibilityHint(
                    "\(configuration.reportIdentifierAccessibilityLabel) \(reportID.uuidString)",
                )
        case let .accepted(_, destinationURL):
            VStack(alignment: .leading, spacing: theme.verticalSpacing / 2) {
                Label(configuration.deliveredMessage, systemImage: "checkmark.circle.fill")
                    .foregroundStyle(theme.success)
                if let destinationURL, destinationURL.scheme?.lowercased() == "https" {
                    Link(configuration.viewDestinationTitle, destination: destinationURL)
                }
            }
        case let .failed(message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.error)
                .accessibilityAddTraits(.isStaticText)
        default:
            EmptyView()
        }
    }
}
