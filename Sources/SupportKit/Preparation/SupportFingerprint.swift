import CryptoKit
import Foundation

enum SupportFingerprint {
    struct Input {
        let projectID: String
        let title: String
        let message: String
        let responses: [SupportFieldResponse]
        let diagnostics: [SupportDiagnostic]
        let labels: [String]
    }

    static func make(_ input: Input) -> String {
        let orderedResponses = input.responses.sorted {
            ($0.id, $0.label, $0.value) < ($1.id, $1.label, $1.value)
        }
        let orderedDiagnostics = input.diagnostics.sorted {
            ($0.key, $0.value, $0.sensitivity.rawValue) < ($1.key, $1.value, $1.sensitivity.rawValue)
        }
        let orderedLabels = input.labels.sorted()
        let responseValues = orderedResponses.flatMap { ["response", $0.id, $0.label, $0.value] }
        let diagnosticValues = orderedDiagnostics.flatMap {
            ["diagnostic", $0.key, $0.value, $0.sensitivity.rawValue]
        }
        let labelValues = orderedLabels.flatMap { ["label", $0] }
        let components = [
            "project", input.projectID,
            "title", input.title,
            "message", input.message,
            "response-count", String(input.responses.count),
        ] + responseValues + [
            "diagnostic-count", String(input.diagnostics.count),
        ] + diagnosticValues + [
            "label-count", String(input.labels.count),
        ] + labelValues
        let canonical = components.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map {
            let hex = String($0, radix: 16)
            return hex.count == 1 ? "0\(hex)" : hex
        }.joined()
    }
}
