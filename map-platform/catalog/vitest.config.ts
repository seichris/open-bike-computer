import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
  const migrations = await readD1Migrations("./migrations");
  return {
    plugins: [
      cloudflareTest({
        wrangler: { configPath: "./wrangler.jsonc" },
        miniflare: {
          bindings: {
            TEST_MIGRATIONS: migrations,
            SERVICE_KEYS_JSON: JSON.stringify({
              "test-development": {
                channel: "development",
                secret: "s".repeat(48),
              },
              "test-production": {
                channel: "production",
                secret: "p".repeat(48),
              },
            }),
            R2_DEVELOPMENT_ACCESS_KEY_ID: "test-development-access-key",
            R2_DEVELOPMENT_SECRET_ACCESS_KEY: "x".repeat(48),
            R2_PRODUCTION_ACCESS_KEY_ID: "test-production-access-key",
            R2_PRODUCTION_SECRET_ACCESS_KEY: "y".repeat(48),
          },
        },
      }),
    ],
    test: {
      setupFiles: ["./test/setup.ts"],
    },
  };
});
