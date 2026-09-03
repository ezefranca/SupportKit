import Foundation

struct SupportSubmissionPreparer: Sendable {
    struct ValidatedDraft: Sendable {
        let subject: String
        let message: String
        let responses: [SupportFieldResponse]
    }

    let configuration: SupportConfiguration
    let redactor: SupportRedactor

    func prepare(
        draft: SupportDraft,
        id: UUID,
        now: Date,
        diagnostics: [SupportDiagnostic],
    ) -> Result<SupportSubmission, SupportSubmissionFailure> {
        switch validate(draft) {
        case let .success(validatedDraft):
            .success(prepare(
                validatedDraft: validatedDraft,
                id: id,
                now: now,
                diagnostics: diagnostics,
            ))
        case let .failure(failure):
            .failure(failure)
        }
    }

    func validate(_ draft: SupportDraft) -> Result<ValidatedDraft, SupportSubmissionFailure> {
        guard SupportTextSafety.isWireSafe(draft.subject) else {
            return .failure(.unsupportedCharacters(configuration.form.subjectLabel))
        }
        guard SupportTextSafety.isWireSafe(draft.message) else {
            return .failure(.unsupportedCharacters(configuration.form.messageLabel))
        }
        let subject = draft.subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = draft.message.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !subject.isEmpty else { return .failure(.emptySubject) }
        guard !message.isEmpty else { return .failure(.emptyMessage) }
        guard subject.count <= configuration.form.subjectMaximumLength else {
            return .failure(.subjectTooLong(maximum: configuration.form.subjectMaximumLength))
        }
        guard message.count <= configuration.form.messageMaximumLength else {
            return .failure(.messageTooLong(maximum: configuration.form.messageMaximumLength))
        }

        let responseResult = makeResponses(for: draft)
        guard case let .success(responses) = responseResult else {
            guard case let .failure(failure) = responseResult else {
                return .failure(.queueUnavailable)
            }
            return .failure(failure)
        }

        return .success(ValidatedDraft(
            subject: redactor.redact(subject),
            message: redactor.redact(message),
            responses: responses,
        ))
    }

    func prepare(
        validatedDraft: ValidatedDraft,
        id: UUID,
        now: Date,
        diagnostics: [SupportDiagnostic],
    ) -> SupportSubmission {
        let title = redactor.redact(
            [configuration.reportTitlePrefix, validatedDraft.subject]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
        )
        let safeDiagnostics = diagnostics.map {
            SupportDiagnostic(
                key: redactor.redact($0.key),
                value: redactor.redact($0.value),
                sensitivity: $0.sensitivity,
            )
        }
        let fingerprint = SupportFingerprint.make(.init(
            projectID: configuration.projectID,
            title: title,
            message: validatedDraft.message,
            responses: validatedDraft.responses,
            diagnostics: safeDiagnostics,
            labels: configuration.labels,
        ))

        return SupportSubmission(
            id: id,
            projectID: configuration.projectID,
            createdAt: now,
            title: title,
            message: validatedDraft.message,
            responses: validatedDraft.responses,
            diagnostics: safeDiagnostics,
            labels: configuration.labels,
            contentFingerprint: fingerprint,
        )
    }

    private func makeResponses(
        for draft: SupportDraft,
    ) -> Result<[SupportFieldResponse], SupportSubmissionFailure> {
        do {
            let responses = try configuration.form.additionalFields.compactMap { field in
                try makeResponse(for: field, value: draft.responses[field.id] ?? field.defaultValue)
            }
            return .success(responses)
        } catch let failure as SupportSubmissionFailure {
            return .failure(failure)
        } catch {
            return .failure(.queueUnavailable)
        }
    }

    private func makeResponse(
        for field: SupportFormField,
        value rawValue: String,
    ) throws -> SupportFieldResponse? {
        guard SupportTextSafety.isWireSafe(rawValue) else {
            throw SupportSubmissionFailure.unsupportedCharacters(field.label)
        }
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if field.isRequired, value.isEmpty || (Self.isToggle(field.kind) && value != "true") {
            throw SupportSubmissionFailure.requiredField(field.label)
        }
        if let maximumLength = field.maximumLength, value.count > maximumLength {
            throw SupportSubmissionFailure.fieldTooLong(label: field.label, maximum: maximumLength)
        }
        if case .email = field.kind, !value.isEmpty, !Self.looksLikeEmail(value) {
            throw SupportSubmissionFailure.invalidEmail(field.label)
        }

        let renderedValue = try Self.renderedValue(value, for: field)
        guard !renderedValue.isEmpty else { return nil }
        return SupportFieldResponse(
            id: field.id,
            label: redactor.redactSecrets(in: field.label),
            value: redacted(renderedValue, policy: field.redactionPolicy),
        )
    }

    private func redacted(_ value: String, policy: SupportFormField.RedactionPolicy) -> String {
        switch policy {
        case .standard:
            redactor.redact(value)
        case .secretsOnly:
            redactor.redactSecrets(in: value)
        }
    }

    private static func renderedValue(
        _ value: String,
        for field: SupportFormField,
    ) throws -> String {
        switch field.kind {
        case let .picker(options):
            guard let option = options.first(where: { $0.id == value }) else {
                throw SupportSubmissionFailure.invalidSelection(field.label)
            }
            return option.label
        case .toggle:
            return value == "true" ? field.toggleTrueLabel : field.toggleFalseLabel
        case .text, .multiline, .email:
            return value
        }
    }

    private static func isToggle(_ kind: SupportFormField.Kind) -> Bool {
        if case .toggle = kind {
            true
        } else {
            false
        }
    }

    private static func looksLikeEmail(_ value: String) -> Bool {
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}
