import Foundation

enum SupportDraftPreparationBudget {
    /// Bounds work before diagnostics collection and regular-expression redaction. Subtracting each UTF-8 count from
    /// the remaining budget avoids overflowing even when a hostile draft contains many independently large values.
    static func fits(
        _ draft: SupportDraft,
        form: SupportFormConfiguration,
        maximumBytes: Int,
    ) -> Bool {
        var remainingBytes = maximumBytes
        guard consumeUTF8(draft.subject, from: &remainingBytes),
              consumeUTF8(draft.message, from: &remainingBytes)
        else { return false }
        for (key, value) in draft.responses {
            guard consumeUTF8(key, from: &remainingBytes),
                  consumeUTF8(value, from: &remainingBytes)
            else { return false }
        }
        for field in form.additionalFields where draft.responses[field.id] == nil {
            guard consumeUTF8(field.id, from: &remainingBytes),
                  consumeUTF8(field.defaultValue, from: &remainingBytes)
            else { return false }
        }
        return true
    }

    private static func consumeUTF8(_ value: String, from remainingBytes: inout Int) -> Bool {
        let count = value.utf8.count
        guard count <= remainingBytes else { return false }
        remainingBytes -= count
        return true
    }
}
