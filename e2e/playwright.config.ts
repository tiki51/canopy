import { defineConfig } from "@playwright/test";

const canopyPort = Number(process.env.CANOPY_E2E_PORT || 4100);
const fakePort = Number(process.env.FAKE_OPENCODE_PORT || 4396);

export default defineConfig({
  testDir: "./tests",
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"], ["html", { open: "never" }]],
  use: {
    baseURL: `http://127.0.0.1:${canopyPort}`,
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
  },
  webServer: [
    {
      command: `node fake-opencode.mjs`,
      url: `http://127.0.0.1:${fakePort}/global/health`,
      reuseExistingServer: false,
      env: { FAKE_OPENCODE_PORT: String(fakePort) },
    },
    {
      command: `bash bin/server.sh`,
      url: `http://127.0.0.1:${canopyPort}/repositories`,
      reuseExistingServer: false,
      timeout: 240_000,
      env: {
        CANOPY_E2E_PORT: String(canopyPort),
        FAKE_OPENCODE_PORT: String(fakePort),
        ...(process.env.CANOPY_DB ? { CANOPY_DB: process.env.CANOPY_DB } : {}),
      },
    },
  ],
});
