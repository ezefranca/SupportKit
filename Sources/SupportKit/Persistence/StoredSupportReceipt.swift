import Foundation

struct StoredSupportReceipt: Codable, Sendable {
    let queueScope: SupportQueueScope
    let receipt: SupportDeliveryReceipt
    let contentFingerprint: String
    let recordedAt: Date

    init(
        queueScope: SupportQueueScope,
        receipt: SupportDeliveryReceipt,
        contentFingerprint: String,
        recordedAt: Date,
    ) {
        self.queueScope = queueScope
        self.receipt = receipt
        self.contentFingerprint = contentFingerprint
        self.recordedAt = recordedAt
    }

    private enum CodingKeys: String, CodingKey {
        case queueScope
        case receipt
        case contentFingerprint
        case recordedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        queueScope = try container.decode(SupportQueueScope.self, forKey: .queueScope)
        receipt = try container.decode(SupportDeliveryReceipt.self, forKey: .receipt)
        contentFingerprint = try container.decode(String.self, forKey: .contentFingerprint)
        // A pre-release record without this field is conservatively treated as
        // observed now so an old receiver timestamp cannot defeat deduplication.
        recordedAt = try container.decodeIfPresent(Date.self, forKey: .recordedAt) ?? .now
    }
}
