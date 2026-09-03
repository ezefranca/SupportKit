import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

const migrations = await readD1Migrations("./migrations");

export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.jsonc" },
      miniflare: {
        bindings: {
          TEST_MIGRATIONS: migrations,
          AUTH_REQUIRED: "false",
          GITHUB_APP_CLIENT_ID: "TEST_CLIENT_ID",
          GITHUB_APP_PRIVATE_KEY: "TEST_PRIVATE_KEY_NOT_USED_BY_INGESTION",
          REPORT_ENCRYPTION_KEY_RING:
            '{"activeVersion":1,"keys":{"1":"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"}}',
          ISSUE_MARKER_KEY_RING:
            '{"activeVersion":1,"keys":{"1":"BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"}}',
        },
      },
    }),
  ],
  test: {
    testTimeout: 10_000,
  },
});
