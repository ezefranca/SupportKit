import Foundation

struct SupportRetryPolicy: Sendable {
    let configuration: DeliveryConfiguration

    func delay(afterAttempt attempt: Int, serverDelay: TimeInterval?, reportID: UUID) -> TimeInterval {
        if let serverDelay, serverDelay.isFinite, serverDelay >= 0 {
            return min(
                max(serverDelay, configuration.initialRetryDelay),
                configuration.maximumRetryDelay,
            )
        }

        let safeAttempt = max(attempt, 1)
        let exponent = min(safeAttempt - 1, 20)
        let base = min(
            configuration.initialRetryDelay * pow(2, Double(exponent)),
            configuration.maximumRetryDelay,
        )
        let byte = reportID.uuid.0
        let jitter = 0.8 + (Double(byte) / 255 * 0.4)
        return min(base * jitter, configuration.maximumRetryDelay)
    }
}
