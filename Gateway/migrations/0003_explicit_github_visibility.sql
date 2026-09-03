-- Before repositoryVisibility was stored, the GitHub adapter accepted only
-- private repositories. This one-time semantic migration records that exact
-- historical expectation; it does not introduce a permissive fallback.
DROP TRIGGER project_routes_are_immutable_before_update;

UPDATE project_routes
SET destination_config_json = json_set(
    destination_config_json,
    '$.repositoryVisibility',
    'private'
)
WHERE destination_adapter = 'github'
  AND json_type(destination_config_json) = 'object'
  AND json_type(destination_config_json, '$.repositoryVisibility') IS NULL;

-- Restore the append-only guard before application traffic can observe the
-- migrated routes. All future visibility changes require a new route revision.
CREATE TRIGGER project_routes_are_immutable_before_update
BEFORE UPDATE ON project_routes
BEGIN
    SELECT RAISE(ABORT, 'project_route_revision_is_immutable');
END;
