import type { D1Migration } from "@cloudflare/vitest-plugin";

/* eslint-disable @typescript-eslint/consistent-type-definitions -- declaration merging requires an interface */

declare global {
  namespace Cloudflare {
    interface Env {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export {};
