-- Safe route/label-policy update. Replace every REPLACE_* value and choose a
-- monotonically increasing revision. The immutable row is written first. If the
-- second statement does not run, new reports keep using the old revision.
-- This example remains private by default. A change to "public" is itself a new
-- route revision and makes report content and included diagnostics public.
INSERT INTO project_routes (
    project_id,
    routing_revision,
    destination_adapter,
    destination_config_json,
    allowed_labels_json,
    default_labels_json
) VALUES (
    'REPLACE_PROJECT_ID',
    REPLACE_NEW_ROUTING_REVISION,
    'github',
    '{"owner":"REPLACE_GITHUB_OWNER","repository":"REPLACE_GITHUB_REPOSITORY","installationID":"REPLACE_GITHUB_APP_INSTALLATION_ID","repositoryVisibility":"private"}',
    '["support","bug"]',
    '["support"]'
);

-- Inspect/decode the new row with your adapter and verify its destination before
-- running this conditional pointer update. Existing reports retain their prior
-- reports.routing_revision value.
UPDATE projects
SET current_routing_revision = REPLACE_NEW_ROUTING_REVISION,
    updated_at = CURRENT_TIMESTAMP
WHERE project_id = 'REPLACE_PROJECT_ID'
  AND current_routing_revision = REPLACE_PREVIOUS_ROUTING_REVISION
  AND EXISTS (
      SELECT 1
      FROM project_routes
      WHERE project_id = 'REPLACE_PROJECT_ID'
        AND routing_revision = REPLACE_NEW_ROUTING_REVISION
  );
