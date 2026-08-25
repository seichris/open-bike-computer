import type { D1Migration } from "cloudflare:test";
import type { Env as CatalogEnv } from "../src/types";

declare global {
  namespace Cloudflare {
    interface Env extends CatalogEnv {
      TEST_MIGRATIONS: D1Migration[];
    }
  }
}

export {};
