import type {
  DeliveryReceipt,
  PublicStatus,
  ReportStatusResponse,
  StoredReport,
} from "./domain";

/**
 * Maps internal state to the public receipt without exposing an internal tracker
 * reference or repository URL to an untrusted app client.
 */
export function receiptFromReport(report: StoredReport, duplicate: boolean): DeliveryReceipt {
  const status = duplicate ? "duplicate" : report.status === "delivered" ? "delivered" : "accepted";
  return {
    reportID: report.reportID,
    status,
    acceptedAt: report.acceptedAt,
    destinationReference: null,
    destinationURL: null,
  };
}

export function publicStatusFromReport(report: StoredReport): ReportStatusResponse {
  let status: PublicStatus;
  if (report.status === "delivered") {
    status = "delivered";
  } else if (report.status === "permanent_failure" || report.status === "manual_review") {
    status = "needsAttention";
  } else {
    status = "accepted";
  }
  return {
    reportID: report.reportID,
    projectID: report.projectID,
    status,
    acceptedAt: report.acceptedAt,
    updatedAt: report.updatedAt,
    destinationReference: null,
    destinationURL: null,
  };
}
