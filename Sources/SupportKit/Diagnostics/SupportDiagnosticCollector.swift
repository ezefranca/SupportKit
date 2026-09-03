import Foundation

struct SupportDiagnosticCollector: Sendable {
    let configuration: DiagnosticsConfiguration
    let systemProvider: SystemDiagnosticsProvider

    func collect(ifRequested: Bool) async -> [SupportDiagnostic] {
        let limit = configuration.maximumDiagnosticCount
        guard ifRequested, limit > 0 else { return [] }

        var collected: [SupportDiagnostic] = []
        func appendBounded(_ values: [SupportDiagnostic]) {
            for value in values where collected.count < limit {
                if let safe = bounded(value) {
                    collected.append(safe)
                }
            }
        }

        await appendBounded(systemProvider.collectDiagnostics())
        for provider in configuration.customProviders where collected.count < limit {
            await appendBounded(provider.collectDiagnostics())
        }
        return collected
    }

    private func bounded(_ diagnostic: SupportDiagnostic) -> SupportDiagnostic? {
        guard diagnostic.key.utf8.count <= 800,
              diagnostic.value.utf8.count <= 80 * 1024
        else { return nil }

        let key = SupportTextSafety.removingUnsafeScalars(from: diagnostic.key)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let value = SupportTextSafety.removingUnsafeScalars(from: diagnostic.value)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !value.isEmpty else { return nil }
        return SupportDiagnostic(
            key: String(key.prefix(200)),
            value: String(value.prefix(configuration.maximumDiagnosticValueLength)),
            sensitivity: diagnostic.sensitivity,
        )
    }
}
