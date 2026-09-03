-- Delivery-affecting acceptance metadata is append-only. A new destination or
-- label policy must be inserted as a new project_routes revision, never edited.
CREATE TRIGGER project_routes_are_immutable_before_update
BEFORE UPDATE ON project_routes
BEGIN
    SELECT RAISE(ABORT, 'project_route_revision_is_immutable');
END;

CREATE TRIGGER project_routes_are_immutable_before_delete
BEFORE DELETE ON project_routes
BEGIN
    SELECT RAISE(ABORT, 'project_route_revision_is_immutable');
END;

-- Duplicate acceptance and later configuration changes cannot rewrite the
-- route/key snapshots or extend the report's original purge deadline. An
-- operator may explicitly shorten the deadline for an early privacy purge.
CREATE TRIGGER report_acceptance_snapshot_is_immutable
BEFORE UPDATE ON reports
WHEN NEW.routing_revision <> OLD.routing_revision
  OR NEW.encryption_version <> OLD.encryption_version
  OR NEW.marker_version <> OLD.marker_version
  OR NEW.accepted_at <> OLD.accepted_at
  OR datetime(NEW.payload_purge_at) IS NULL
  OR datetime(NEW.payload_purge_at) > datetime(OLD.payload_purge_at)
BEGIN
    SELECT RAISE(ABORT, 'report_acceptance_snapshot_is_immutable');
END;
