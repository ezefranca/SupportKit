PRAGMA foreign_keys = ON;

CREATE TABLE projects (
    project_id TEXT PRIMARY KEY NOT NULL,
    enabled INTEGER NOT NULL DEFAULT 1 CHECK (enabled IN (0, 1)),
    current_routing_revision INTEGER NOT NULL DEFAULT 1
        CHECK (current_routing_revision BETWEEN 1 AND 999999999),
    payload_retention_days INTEGER NOT NULL DEFAULT 30 CHECK (payload_retention_days BETWEEN 1 AND 365),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE TABLE project_routes (
    project_id TEXT NOT NULL,
    routing_revision INTEGER NOT NULL CHECK (routing_revision BETWEEN 1 AND 999999999),
    destination_adapter TEXT NOT NULL,
    destination_config_json TEXT NOT NULL CHECK (json_valid(destination_config_json)),
    allowed_labels_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(allowed_labels_json)),
    default_labels_json TEXT NOT NULL DEFAULT '[]' CHECK (json_valid(default_labels_json)),
    created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (project_id, routing_revision),
    FOREIGN KEY (project_id) REFERENCES projects(project_id) ON DELETE RESTRICT
);

CREATE TABLE reports (
    project_id TEXT NOT NULL,
    report_id TEXT NOT NULL,
    idempotency_key_hash TEXT NOT NULL CHECK (length(idempotency_key_hash) = 64),
    raw_payload_sha256 TEXT NOT NULL CHECK (length(raw_payload_sha256) = 64),
    content_fingerprint TEXT NOT NULL CHECK (length(content_fingerprint) = 64),
    payload_ciphertext TEXT,
    payload_iv TEXT,
    encryption_version INTEGER NOT NULL CHECK (encryption_version BETWEEN 1 AND 999999999),
    marker_version INTEGER NOT NULL CHECK (marker_version BETWEEN 1 AND 999999999),
    routing_revision INTEGER NOT NULL CHECK (routing_revision BETWEEN 1 AND 999999999),
    status TEXT NOT NULL DEFAULT 'pending' CHECK (
        status IN (
            'pending',
            'authorizing',
            'creating',
            'retrying',
            'reconciling',
            'delivered',
            'permanent_failure',
            'manual_review'
        )
    ),
    attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (attempt_count >= 0),
    reconciliation_attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (reconciliation_attempt_count >= 0),
    lease_token TEXT,
    lease_expires_at TEXT,
    reconciliation_not_before TEXT,
    destination_reference TEXT,
    destination_url TEXT,
    last_error_code TEXT,
    accepted_at TEXT NOT NULL,
    payload_purge_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    delivered_at TEXT,
    payload_purged_at TEXT,
    PRIMARY KEY (project_id, report_id),
    UNIQUE (project_id, idempotency_key_hash),
    FOREIGN KEY (project_id, routing_revision)
        REFERENCES project_routes(project_id, routing_revision)
        ON DELETE RESTRICT,
    CHECK (
        (payload_ciphertext IS NULL AND payload_iv IS NULL)
        OR (payload_ciphertext IS NOT NULL AND payload_iv IS NOT NULL)
    )
);

CREATE INDEX reports_status_updated_idx
    ON reports(status, updated_at);

CREATE INDEX reports_reconciliation_due_idx
    ON reports(status, reconciliation_not_before, lease_expires_at);

CREATE INDEX reports_payload_purge_idx
    ON reports(payload_purge_at)
    WHERE payload_ciphertext IS NOT NULL;

CREATE INDEX reports_project_fingerprint_idx
    ON reports(project_id, content_fingerprint, accepted_at);

CREATE TABLE report_outbox (
    project_id TEXT NOT NULL,
    report_id TEXT NOT NULL,
    available_at TEXT NOT NULL,
    publish_attempt_count INTEGER NOT NULL DEFAULT 0 CHECK (publish_attempt_count >= 0),
    published_at TEXT,
    last_error_code TEXT,
    created_at TEXT NOT NULL,
    updated_at TEXT NOT NULL,
    PRIMARY KEY (project_id, report_id),
    FOREIGN KEY (project_id, report_id)
        REFERENCES reports(project_id, report_id)
        ON DELETE CASCADE
);

CREATE INDEX report_outbox_pending_idx
    ON report_outbox(published_at, available_at);
