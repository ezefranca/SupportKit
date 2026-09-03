import SupportKit
import SwiftUI

/// A customizable SwiftUI support form.
@MainActor
public struct SupportForm: View {
    private let client: SupportClient
    private let theme: SupportFormTheme
    private let onSubmission: @MainActor (SupportSubmissionResult) -> Void
    let stateIdentity: ObjectIdentifier

    /// Creates the standard support experience with the client's validated form configuration.
    ///
    /// The form keys its editable state to the client's object identity. Replacing `client` at the same position in
    /// a SwiftUI hierarchy therefore starts a fresh form and cannot submit through the previous client.
    ///
    /// - Parameters:
    ///   - client: The long-lived client that prepares and queues reports.
    ///   - theme: Visual tokens for the form.
    ///   - onSubmission: Called for a queued, duplicate, or rejected result.
    public init(
        client: SupportClient,
        theme: SupportFormTheme = .default,
        onSubmission: @escaping @MainActor (SupportSubmissionResult) -> Void = { _ in },
    ) {
        self.client = client
        self.theme = theme
        self.onSubmission = onSubmission
        stateIdentity = ObjectIdentifier(client)
    }

    /// The configured support form and its optional payload-review sheet.
    public var body: some View {
        SupportFormContent(
            client: client,
            configuration: client.formConfiguration,
            theme: theme,
            onSubmission: onSubmission,
        )
        .id(stateIdentity)
    }
}

@MainActor
struct SupportFormContent: View {
    @State var model: SupportFormModel

    private let configuration: SupportFormConfiguration
    private let theme: SupportFormTheme
    private let onSubmission: @MainActor (SupportSubmissionResult) -> Void

    init(
        client: SupportClient,
        configuration: SupportFormConfiguration,
        theme: SupportFormTheme,
        onSubmission: @escaping @MainActor (SupportSubmissionResult) -> Void,
    ) {
        _model = State(initialValue: SupportFormModel(client: client, configuration: configuration))
        self.configuration = configuration
        self.theme = theme
        self.onSubmission = onSubmission
    }

    var body: some View {
        @Bindable var model = model

        Form {
            SupportFormHeader(
                title: configuration.title,
                introduction: configuration.introduction,
                theme: theme,
            )

            SupportCoreFieldsSection(
                configuration: configuration,
                theme: theme,
                subject: $model.subject,
                message: $model.message,
            )

            SupportAdditionalFieldsSection(
                states: $model.fieldStates,
                title: configuration.detailsSectionTitle,
                theme: theme,
            )

            SupportDiagnosticsConsentSection(
                configuration: configuration,
                theme: theme,
                isIncluded: $model.includesDiagnostics,
            )

            Section {
                SupportSubmissionStatusView(
                    phase: model.phase,
                    configuration: configuration,
                    theme: theme,
                )
                .font(theme.statusFont)

                SupportSubmitButton(
                    title: configuration.submitButtonTitle,
                    theme: theme,
                    isBusy: model.isBusy,
                    action: prepareSubmission,
                )
            }
            .listRowBackground(theme.rowBackground)
        }
        .scrollContentBackground(.hidden)
        .background(theme.background)
        .tint(theme.tint)
        .sheet(isPresented: $model.isShowingPreview, onDismiss: model.cancelPreview) {
            if let prepared = model.preparedSubmission {
                SupportPayloadPreviewView(
                    preview: prepared.preview,
                    configuration: configuration,
                    theme: theme,
                    confirm: confirmSubmission,
                    cancel: model.cancelPreview,
                )
            }
        }
    }

    private func prepareSubmission() {
        Task {
            if let result = await model.prepareForSubmission() {
                onSubmission(result)
            }
        }
    }

    private func confirmSubmission() {
        Task {
            if let result = await model.submitPrepared() {
                onSubmission(result)
            }
        }
    }
}
