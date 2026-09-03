-- Replace every REPLACE_* value before running this file. Routing revisions are
-- immutable. To change a destination or label policy, insert revision 2, verify
-- it, and only then update projects.current_routing_revision to 2. A partial
-- initial setup fails closed until both rows exist.
--
-- The example deliberately expects a private repository. Use "public" only as
-- an explicit policy choice: every created issue, including report content and
-- any user-approved diagnostics, is then publicly readable.

INSERT INTO projects (
    project_id,
    current_routing_revision,
    payload_retention_days
) VALUES (
    'REPLACE_PROJECT_ID',
    1,
    30
);

INSERT INTO project_routes (
    project_id,
    routing_revision,
    destination_adapter,
    destination_config_json,
    allowed_labels_json,
    default_labels_json
) VALUES (
    'REPLACE_PROJECT_ID',
    1,
    'github',
    '{"owner":"REPLACE_GITHUB_OWNER","repository":"REPLACE_GITHUB_REPOSITORY","installationID":"REPLACE_GITHUB_APP_INSTALLATION_ID","repositoryVisibility":"private"}',
    '["support","bug"]',
    '["support"]'
);
