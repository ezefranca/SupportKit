import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { D1Persistence } from "../src/adapters/cloudflare/d1";
import { decodeGitHubTarget } from "../src/adapters/github/github-issue-tracker";

describe("explicit GitHub repository visibility migration", () => {
  it("pins legacy private-only routes before restoring immutability", async () => {
    const visibilityMigrationName = "0003_explicit_github_visibility.sql";
    const visibilityMigrationIndex = env.TEST_MIGRATIONS.findIndex(
      (migration) => migration.name === visibilityMigrationName,
    );
    expect(visibilityMigrationIndex).toBeGreaterThan(0);
    const earlierMigrations = env.TEST_MIGRATIONS.slice(0, visibilityMigrationIndex);
    await applyD1Migrations(env.SUPPORTKIT_DB, earlierMigrations);
    await env.SUPPORTKIT_DB.prepare(
      `INSERT INTO projects (
           project_id, enabled, current_routing_revision, payload_retention_days
       ) VALUES ('legacy.project', 1, 1, 30)`,
    ).run();
    await env.SUPPORTKIT_DB.prepare(
      `INSERT INTO project_routes (
           project_id, routing_revision, destination_adapter, destination_config_json,
           allowed_labels_json, default_labels_json
       ) VALUES (?, 1, 'github', ?, '[]', '[]')`,
    )
      .bind(
        "legacy.project",
        JSON.stringify({
          owner: "example",
          repository: "legacy-private-support",
          installationID: "1234",
        }),
      )
      .run();

    await applyD1Migrations(
      env.SUPPORTKIT_DB,
      env.TEST_MIGRATIONS.slice(visibilityMigrationIndex),
    );

    const persistence = new D1Persistence(env.SUPPORTKIT_DB, decodeGitHubTarget);
    const project = await persistence.findEnabledProject("legacy.project");
    expect(project?.destination).toEqual({
      owner: "example",
      repository: "legacy-private-support",
      installationID: "1234",
      repositoryVisibility: "private",
    });
    await expect(env.SUPPORTKIT_DB.prepare(
      `UPDATE project_routes
          SET destination_config_json = ?
        WHERE project_id = 'legacy.project' AND routing_revision = 1`,
    )
      .bind(JSON.stringify({
        owner: "example",
        repository: "legacy-private-support",
        installationID: "1234",
        repositoryVisibility: "public",
      }))
      .run()).rejects.toThrow(/project_route_revision_is_immutable/u);
  });
});
