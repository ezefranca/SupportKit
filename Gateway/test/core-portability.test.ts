import { describe, expect, it } from "vitest";
import {
  IssueTrackerError,
  dispatchOutbox,
  ingestSubmission,
  processDelivery,
  receiptFromReport,
  sha256Hex,
} from "../src/ServerCore/index";
import type {
  DeliveryDependencies,
  IssueTracker,
  ReportStore,
  StoredPayload,
  StoredReport,
} from "../src/ServerCore/index";
import { submission } from "./fixtures";

type FakeTarget = { inbox: string };

describe("portable ServerCore", () => {
  it("delivers through a fake IssueTracker and reconciles ambiguity without another create", async () => {
    const state = { report: pendingReport() };
    const reports = fakeReportStore(state);
    let createCalls = 0;
    let findCalls = 0;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => {
          createCalls += 1;
          return Promise.reject(new IssueTrackerError("ambiguous", "fake_create_unknown"));
        },
        findByMarker: () => {
          findCalls += 1;
          return Promise.resolve({
            reference: "fake-42",
            url: "https://tracker.example.test/items/42",
          });
        },
      }),
    };
    let now = new Date("2026-09-03T12:00:00Z");
    const dependencies = fakeDependencies(reports, tracker, { now: () => now });

    const first = await processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      1,
      dependencies,
    );
    expect(first).toEqual({ action: "retry", delaySeconds: 600 });
    expect(state.report.status).toBe("reconciling");

    now = new Date("2026-09-03T12:10:00Z");
    const second = await processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      2,
      dependencies,
    );
    expect(second).toEqual({ action: "ack" });
    expect(state.report.status).toBe("delivered");
    expect(state.report.destinationReference).toBe("fake-42");
    expect(createCalls).toBe(1);
    expect(findCalls).toBe(1);
  });

  it("validates an immutable target before both create and reconciliation", async () => {
    let validationCalls = 0;
    let createCalls = 0;
    let findCalls = 0;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => {
          validationCalls += 1;
          return Promise.reject(new IssueTrackerError(
            "permanent",
            "github_repository_visibility_mismatch",
          ));
        },
        create: () => {
          createCalls += 1;
          return Promise.reject(new Error("must not create"));
        },
        findByMarker: () => {
          findCalls += 1;
          return Promise.reject(new Error("must not reconcile"));
        },
      }),
    };

    const createState = { report: pendingReport() };
    await expect(processDelivery(
      {
        schemaVersion: 1,
        projectID: "test.project",
        reportID: createState.report.reportID,
      },
      1,
      fakeDependencies(fakeReportStore(createState), tracker),
    )).resolves.toEqual({ action: "ack" });
    expect(createState.report.status).toBe("permanent_failure");
    expect(createState.report.lastErrorCode).toBe("github_repository_visibility_mismatch");

    const reconciliationState = {
      report: {
        ...pendingReport(),
        status: "reconciling" as const,
        reconciliationNotBefore: "2026-09-03T12:00:00Z",
      },
    };
    await expect(processDelivery(
      {
        schemaVersion: 1,
        projectID: "test.project",
        reportID: reconciliationState.report.reportID,
      },
      1,
      fakeDependencies(fakeReportStore(reconciliationState), tracker),
    )).resolves.toEqual({ action: "ack" });
    expect(reconciliationState.report.status).toBe("manual_review");
    expect(reconciliationState.report.lastErrorCode)
      .toBe("github_repository_visibility_mismatch");
    expect(validationCalls).toBe(2);
    expect(createCalls).toBe(0);
    expect(findCalls).toBe(0);
  });

  it("leases one reconciliation search across eight rapid duplicate messages", async () => {
    const state = {
      report: {
        ...pendingReport(),
        status: "reconciling" as const,
        reconciliationNotBefore: "2026-09-03T12:00:00Z",
      },
    };
    const reports = fakeReportStore(state);
    let findCalls = 0;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => Promise.reject(new Error("must not create")),
        findByMarker: () => {
          findCalls += 1;
          return Promise.resolve(null);
        },
      }),
    };
    const dependencies = fakeDependencies(reports, tracker);
    const message = {
      schemaVersion: 1 as const,
      projectID: "test.project",
      reportID: state.report.reportID,
    };

    const decisions = await Promise.all(
      Array.from({ length: 8 }, (_, index) => processDelivery(message, index + 1, dependencies)),
    );

    expect(findCalls).toBe(1);
    expect(state.report.reconciliationAttemptCount).toBe(1);
    expect(state.report.status).toBe("reconciling");
    expect(state.report.reconciliationNotBefore).toBe("2026-09-03T12:10:00.000Z");
    expect(decisions.filter((decision) => decision.action === "retry")).toHaveLength(8);

    await expect(processDelivery(message, 9, dependencies)).resolves.toEqual({
      action: "retry",
      delaySeconds: 600,
    });
    expect(findCalls).toBe(1);
    expect(state.report.reconciliationAttemptCount).toBe(1);
  });

  it("prevents an expired reconciliation worker from overriding a newer delivery", async () => {
    const state = {
      report: {
        ...pendingReport(),
        status: "reconciling" as const,
        reconciliationAttemptCount: 7,
        reconciliationNotBefore: "2026-09-03T12:00:00Z",
      },
    };
    const reports = fakeReportStore(state);
    const staleSearch = { resolve: null as ((result: null) => void) | null };
    let findCalls = 0;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => Promise.reject(new Error("must not create")),
        findByMarker: () => {
          findCalls += 1;
          if (findCalls === 1) {
            return new Promise<null>((resolve) => {
              staleSearch.resolve = resolve;
            });
          }
          return Promise.resolve({
            reference: "newer-42",
            url: "https://tracker.example.test/items/42",
          });
        },
      }),
    };
    let now = new Date("2026-09-03T12:00:00Z");
    const dependencies = fakeDependencies(reports, tracker, { now: () => now });
    const message = {
      schemaVersion: 1 as const,
      projectID: "test.project",
      reportID: state.report.reportID,
    };

    const stale = processDelivery(message, 1, dependencies);
    await waitUntil(() => staleSearch.resolve !== null);
    now = new Date("2026-09-03T12:02:00Z");
    await expect(processDelivery(message, 2, dependencies)).resolves.toEqual({ action: "ack" });
    if (staleSearch.resolve === null) {
      throw new Error("stale search did not start");
    }
    staleSearch.resolve(null);
    await expect(stale).resolves.toEqual({ action: "retry", delaySeconds: 30 });

    expect(findCalls).toBe(2);
    expect(state.report.status).toBe("delivered");
    expect(state.report.destinationReference).toBe("newer-42");
    expect(state.report.reconciliationAttemptCount).toBe(7);
    expect(state.report.lastErrorCode).not.toBe("destination_create_not_reconciled");
  });

  it("delivers through the immutable accepted route and marker version after rotation", async () => {
    const state = { report: { ...pendingReport(), routingRevision: 1, markerVersion: 4 } };
    const reports = fakeReportStore(state);
    let openedInbox: string | null = null;
    let usedMarkerVersion: number | null = null;
    let createdLabels: readonly string[] = [];
    const tracker: IssueTracker<FakeTarget> = {
      open: (target) => {
        openedInbox = target.inbox;
        return Promise.resolve({
          validateTarget: () => Promise.resolve(),
          create: (_document, labels) => {
            createdLabels = labels;
            return Promise.resolve({
              reference: "old-route-42",
              url: "https://tracker.example.test/items/42",
            });
          },
          findByMarker: () => Promise.resolve(null),
        });
      },
    };
    const dependencies = fakeDependencies(reports, tracker);
    dependencies.projects = {
      findEnabledProject: () => Promise.resolve({
        projectID: "test.project",
        routingRevision: 2,
        destination: { inbox: "new-route" },
        allowedLabels: new Set(["new-label"]),
        defaultLabels: ["new-label"],
        payloadRetentionDays: 365,
      }),
      findEnabledProjectRevision: (_projectID, revision) => Promise.resolve(
        revision === 1
          ? {
              projectID: "test.project",
              routingRevision: 1,
              destination: { inbox: "accepted-route" },
              allowedLabels: new Set(["bug", "support"]),
              defaultLabels: ["support"],
              payloadRetentionDays: 365,
            }
          : null,
      ),
    };
    dependencies.markerFactory = {
      activeVersion: 9,
      make: (_projectID, _reportID, version) => {
        usedMarkerVersion = version;
        return Promise.resolve("supportkit-report-accepted-marker");
      },
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      1,
      dependencies,
    )).resolves.toEqual({ action: "ack" });
    expect(openedInbox).toBe("accepted-route");
    expect(usedMarkerVersion).toBe(4);
    expect(createdLabels).toEqual(["support", "bug"]);
  });

  it("fails to manual review when the exact accepted route revision is unavailable", async () => {
    const state = { report: { ...pendingReport(), routingRevision: 7 } };
    const reports = fakeReportStore(state);
    let trackerOpened = false;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => {
        trackerOpened = true;
        return Promise.reject(new Error("must not open"));
      },
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      1,
      fakeDependencies(reports, tracker),
    )).resolves.toEqual({ action: "ack" });
    expect(state.report.status).toBe("manual_review");
    expect(state.report.lastErrorCode).toBe("accepted_route_unavailable");
    expect(trackerOpened).toBe(false);
  });

  it("does not expose a private adapter destination in the public receipt", () => {
    const report = {
      ...pendingReport(),
      status: "delivered" as const,
      destinationReference: "private-42",
      destinationURL: "https://private.example.test/items/42",
    };
    expect(receiptFromReport(report, false)).toMatchObject({
      status: "delivered",
      destinationReference: null,
      destinationURL: null,
    });
  });

  it("rejects an unsafe marker from a custom adapter before document rendering", async () => {
    const state = { report: pendingReport() };
    const reports = fakeReportStore(state);
    let createCalled = false;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => {
          createCalled = true;
          return Promise.reject(new Error("must not create"));
        },
        findByMarker: () => Promise.resolve(null),
      }),
    };
    const dependencies = {
      ...fakeDependencies(reports, tracker),
      markerFactory: {
        activeVersion: 1,
        make: () => Promise.resolve("safe-prefix-->unsafe-comment-close"),
      },
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      1,
      dependencies,
    )).resolves.toEqual({ action: "ack" });
    expect(state.report.status).toBe("manual_review");
    expect(state.report.lastErrorCode).toBe("destination_marker_invalid");
    expect(createCalled).toBe(false);
  });

  it("rejects unsafe destination metadata returned by a custom tracker", async () => {
    const state = { report: pendingReport() };
    const reports = fakeReportStore(state);
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => Promise.resolve({
          reference: "fake-42",
          url: [
            "https://",
            "diagnostic-user",
            ":diagnostic-password",
            "@tracker.example.test/items/42",
          ].join(""),
        }),
        findByMarker: () => Promise.resolve(null),
      }),
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      1,
      fakeDependencies(reports, tracker),
    )).resolves.toEqual({ action: "retry", delaySeconds: 600 });
    expect(state.report.status).toBe("reconciling");
    expect(state.report.destinationReference).toBeNull();
    expect(state.report.destinationURL).toBeNull();
  });

  it("treats a corrupt creating lease timestamp as expired and reconciles", async () => {
    const state = {
      report: {
        ...pendingReport(),
        status: "creating" as const,
        leaseExpiresAt: "not-a-timestamp",
      },
    };
    const reports = fakeReportStore(state);
    let createCalled = false;
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.resolve({
        validateTarget: () => Promise.resolve(),
        create: () => {
          createCalled = true;
          return Promise.reject(new Error("must reconcile"));
        },
        findByMarker: () => Promise.resolve({
          reference: "fake-42",
          url: "https://tracker.example.test/items/42",
        }),
      }),
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      Number.NaN,
      fakeDependencies(reports, tracker),
    )).resolves.toEqual({ action: "ack" });
    expect(state.report.status).toBe("delivered");
    expect(createCalled).toBe(false);
  });

  it("normalizes corrupt outbox retry counts to a finite delay", async () => {
    let availableAt: string | null = null;
    const result = await dispatchOutbox({
      outbox: {
        listPending: () => Promise.resolve([{
          projectID: "test.project",
          reportID: pendingReport().reportID,
          publishAttemptCount: Number.NaN,
        }]),
        markPublished: () => Promise.reject(new Error("must not publish")),
        markRetry: (_projectID, _reportID, nextAvailableAt) => {
          availableAt = nextAvailableAt;
          return Promise.resolve();
        },
        recoverStale: () => Promise.resolve(),
        purgeExpiredPayloads: () => Promise.resolve(),
      },
      publisher: {
        publish: () => Promise.reject(new Error("transport unavailable")),
      },
      clock: {
        now: () => new Date("2026-09-03T12:00:00Z"),
      },
    });

    expect(result).toEqual({ published: 0, failed: true });
    expect(availableAt).toBe("2026-09-03T12:00:15.000Z");
  });

  it("normalizes a corrupt queue attempt count to a finite retry delay", async () => {
    const state = { report: pendingReport() };
    const reports = fakeReportStore(state);
    const tracker: IssueTracker<FakeTarget> = {
      open: () => Promise.reject(new Error("transport unavailable")),
    };

    await expect(processDelivery(
      { schemaVersion: 1, projectID: "test.project", reportID: state.report.reportID },
      Number.NaN,
      fakeDependencies(reports, tracker),
    )).resolves.toEqual({ action: "retry", delaySeconds: 30 });
    expect(state.report.status).toBe("retrying");
  });

  it("denies a cross-project principal before storage admission", async () => {
    const rawBody = new TextEncoder().encode(JSON.stringify(submission()));
    let admissionCalled = false;
    let storeCalled = false;
    const operation = ingestSubmission(
      {
        rawBody,
        claimedRawPayloadSha256: await sha256Hex(rawBody),
        idempotencyKey: submission().idempotencyKey,
        principal: {
          actorID: "first-party:user",
          allowedProjectIDs: new Set(["another.project"]),
        },
      },
      {
        projects: {
          findEnabledProject: () => Promise.resolve(null),
          findEnabledProjectRevision: () => Promise.resolve(null),
        },
        reports: {
          ...fakeReportStore({ report: pendingReport() }),
          acceptWithOutbox: () => {
            storeCalled = true;
            return Promise.reject(new Error("must not store"));
          },
        },
        payloadCipher: {
          encrypt: () => Promise.reject(new Error("must not encrypt")),
          decrypt: () => Promise.reject(new Error("unused")),
        },
        markerFactory: {
          activeVersion: 1,
          make: () => Promise.reject(new Error("unused")),
        },
        admission: {
          allow: () => {
            admissionCalled = true;
            return Promise.resolve(true);
          },
        },
        now: () => new Date("2026-09-03T12:00:00Z"),
      },
    );
    await expect(operation).rejects.toMatchObject({
      kind: "forbidden",
      code: "project_not_authorized",
    });
    expect(admissionCalled).toBe(false);
    expect(storeCalled).toBe(false);
  });
});

function fakeDependencies(
  reports: ReportStore,
  issueTracker: IssueTracker<FakeTarget>,
  options: {
    now?: () => Date;
    project?: { revision: number; inbox: string };
  } = {},
): DeliveryDependencies<FakeTarget> {
  const storedPayload: StoredPayload = {
    submission: submission(),
    serverRedactionCount: 0,
  };
  let identifier = 90;
  const project = {
    projectID: "test.project",
    routingRevision: options.project?.revision ?? 1,
    destination: { inbox: options.project?.inbox ?? "support" },
    allowedLabels: new Set(["bug", "support"]),
    defaultLabels: ["support"],
    payloadRetentionDays: 30,
  };
  return {
    reports,
    projects: {
      findEnabledProject: () => Promise.resolve(project),
      findEnabledProjectRevision: (_projectID, revision) => Promise.resolve(
        revision === project.routingRevision ? project : null,
      ),
    },
    issueTracker,
    payloadCipher: {
      encrypt: () => Promise.resolve({ ciphertext: "unused", iv: "unused", keyVersion: 1 }),
      decrypt: () => Promise.resolve(storedPayload),
    },
    markerFactory: {
      activeVersion: 1,
      make: () => Promise.resolve("supportkit-report-fake-marker"),
    },
    clock: {
      now: options.now ?? (() => new Date("2026-09-03T12:00:00Z")),
    },
    identifiers: {
      randomUUID: () => `lease-${String(identifier++)}`,
    },
  };
}

function fakeReportStore(state: { report: StoredReport }): ReportStore {
  const update = (changes: Partial<StoredReport>): void => {
    state.report = { ...state.report, ...changes };
  };
  return {
    acceptWithOutbox: () => Promise.reject(new Error("unused")),
    find: () => Promise.resolve({ ...state.report }),
    claimForAuthorization: (_projectID, _reportID, leaseToken, now, leaseExpiresAt) => {
      const claimable = ["pending", "retrying"].includes(state.report.status)
        || (state.report.status === "authorizing"
          && !isFutureTimestamp(state.report.leaseExpiresAt, now));
      if (!claimable) {
        return Promise.resolve(false);
      }
      update({
        status: "authorizing",
        leaseToken,
        leaseExpiresAt,
        updatedAt: now,
        attemptCount: state.report.attemptCount + 1,
      });
      return Promise.resolve(true);
    },
    markCreating: (_projectID, _reportID, leaseToken, now, leaseExpiresAt) => {
      update({ status: "creating", leaseToken, leaseExpiresAt, updatedAt: now });
      return Promise.resolve(true);
    },
    markRetrying: (_projectID, _reportID, leaseToken, lastErrorCode, updatedAt) => {
      if (
        !["authorizing", "creating"].includes(state.report.status)
        || state.report.leaseToken !== leaseToken
      ) {
        return Promise.resolve(false);
      }
      update({
        status: "retrying",
        lastErrorCode,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
    scheduleReconciliationFromCreating: (
      _projectID,
      _reportID,
      creatingLeaseToken,
      lastErrorCode,
      updatedAt,
      reconciliationNotBefore,
    ) => {
      if (state.report.status !== "creating" || state.report.leaseToken !== creatingLeaseToken) {
        return Promise.resolve(false);
      }
      update({
        status: "reconciling",
        lastErrorCode,
        updatedAt,
        reconciliationNotBefore,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
    claimCreatingForReconciliation: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      now,
      leaseExpiresAt,
    ) => {
      if (
        state.report.status !== "creating"
        || isFutureTimestamp(state.report.leaseExpiresAt, now)
      ) {
        return Promise.resolve(null);
      }
      update({
        status: "reconciling",
        leaseToken: reconciliationLeaseToken,
        leaseExpiresAt,
        reconciliationNotBefore: null,
        updatedAt: now,
      });
      return Promise.resolve({ completedAttemptCount: state.report.reconciliationAttemptCount });
    },
    claimForReconciliation: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      now,
      leaseExpiresAt,
    ) => {
      if (
        state.report.status !== "reconciling"
        || isFutureTimestamp(state.report.reconciliationNotBefore, now)
        || isFutureTimestamp(state.report.leaseExpiresAt, now)
      ) {
        return Promise.resolve(null);
      }
      update({ leaseToken: reconciliationLeaseToken, leaseExpiresAt, updatedAt: now });
      return Promise.resolve({ completedAttemptCount: state.report.reconciliationAttemptCount });
    },
    rescheduleReconciliation: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      lastErrorCode,
      updatedAt,
      reconciliationNotBefore,
    ) => {
      if (state.report.status !== "reconciling" || state.report.leaseToken !== reconciliationLeaseToken) {
        return Promise.resolve(false);
      }
      update({
        lastErrorCode,
        updatedAt,
        reconciliationNotBefore,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
    completeReconciliationMiss: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      updatedAt,
      reconciliationNotBefore,
      maximumAttempts,
    ) => {
      if (state.report.status !== "reconciling" || state.report.leaseToken !== reconciliationLeaseToken) {
        return Promise.resolve("stale");
      }
      const attempts = state.report.reconciliationAttemptCount + 1;
      const terminal = attempts >= maximumAttempts;
      update({
        status: terminal ? "manual_review" : "reconciling",
        reconciliationAttemptCount: attempts,
        reconciliationNotBefore: terminal ? null : reconciliationNotBefore,
        leaseToken: null,
        leaseExpiresAt: null,
        lastErrorCode: terminal
          ? "destination_create_not_reconciled"
          : "destination_create_not_found_yet",
        updatedAt,
      });
      return Promise.resolve(terminal ? "manual_review" : "scheduled");
    },
    markReconciliationDelivered: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      destinationReference,
      destinationURL,
      updatedAt,
    ) => {
      if (state.report.status !== "reconciling" || state.report.leaseToken !== reconciliationLeaseToken) {
        return Promise.resolve(false);
      }
      update({
        status: "delivered",
        destinationReference,
        destinationURL,
        deliveredAt: updatedAt,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
        reconciliationNotBefore: null,
      });
      return Promise.resolve(true);
    },
    markReconciliationManualReview: (
      _projectID,
      _reportID,
      reconciliationLeaseToken,
      lastErrorCode,
      updatedAt,
    ) => {
      if (state.report.status !== "reconciling" || state.report.leaseToken !== reconciliationLeaseToken) {
        return Promise.resolve(false);
      }
      update({
        status: "manual_review",
        lastErrorCode,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
        reconciliationNotBefore: null,
      });
      return Promise.resolve(true);
    },
    markDelivered: (
      _projectID,
      _reportID,
      leaseToken,
      destinationReference,
      destinationURL,
      updatedAt,
    ) => {
      if (state.report.status !== "creating" || state.report.leaseToken !== leaseToken) {
        return Promise.resolve(false);
      }
      update({
        status: "delivered",
        destinationReference,
        destinationURL,
        deliveredAt: updatedAt,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
    markPermanentFailure: (_projectID, _reportID, leaseToken, lastErrorCode, updatedAt) => {
      if (
        !["authorizing", "creating"].includes(state.report.status)
        || state.report.leaseToken !== leaseToken
      ) {
        return Promise.resolve(false);
      }
      update({
        status: "permanent_failure",
        lastErrorCode,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
    markManualReview: (_projectID, _reportID, leaseToken, lastErrorCode, updatedAt) => {
      if (
        !["authorizing", "creating"].includes(state.report.status)
        || state.report.leaseToken !== leaseToken
      ) {
        return Promise.resolve(false);
      }
      update({
        status: "manual_review",
        lastErrorCode,
        updatedAt,
        leaseToken: null,
        leaseExpiresAt: null,
      });
      return Promise.resolve(true);
    },
  };
}

function pendingReport(): StoredReport {
  return {
    projectID: "test.project",
    reportID: "00000000-0000-4000-8000-000000000001",
    idempotencyKeyHash: "a".repeat(64),
    rawPayloadSha256: "b".repeat(64),
    contentFingerprint: "c".repeat(64),
    payloadCiphertext: "ciphertext",
    payloadIV: "iv",
    encryptionVersion: 1,
    markerVersion: 1,
    routingRevision: 1,
    status: "pending",
    attemptCount: 0,
    reconciliationAttemptCount: 0,
    leaseToken: null,
    leaseExpiresAt: null,
    reconciliationNotBefore: null,
    destinationReference: null,
    destinationURL: null,
    lastErrorCode: null,
    acceptedAt: "2026-09-03T12:00:00Z",
    payloadPurgeAt: "2026-10-03T12:00:00Z",
    updatedAt: "2026-09-03T12:00:00Z",
    deliveredAt: null,
    payloadPurgedAt: null,
  };
}

function isFutureTimestamp(value: string | null, now: string): boolean {
  if (value === null) {
    return false;
  }
  const timestamp = Date.parse(value);
  return Number.isFinite(timestamp) && timestamp > Date.parse(now);
}

async function waitUntil(predicate: () => boolean): Promise<void> {
  for (let attempt = 0; attempt < 50; attempt += 1) {
    if (predicate()) {
      return;
    }
    await Promise.resolve();
  }
  throw new Error("condition_not_reached");
}
