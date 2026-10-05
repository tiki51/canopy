import { defineConfig } from "@playwright/test";

const canopyPort = Number(process.env.CANOPY_E2E_PORT || 4100);
const fakePort = Number(process.env.FAKE_OPENCODE_PORT || 4396);

// The site captures (tests/site-*.spec.ts) move the server's clock so it
// reads 10:40 now; site-shots then waits for 10:42:00 before the story's first
// post, so the story's timestamps come out the same on every run. The offset
// is whole minutes, as a POSIX TZ (Erlang honours it; Node's ICU doesn't), so
// the spec gets it again as SITE_UTC_OFFSET_MIN for its own local-time maths.
if ((process.env.SITE === "1" || process.env.SITE_VIDEO === "1") && !process.env.TZ) {
  const now = new Date();
  const offset = ((10 * 60 + 40 - (now.getUTCHours() * 60 + now.getUTCMinutes()) + 2160) % 1440) - 720;
  const abs = Math.abs(offset);
  const hm = `${Math.floor(abs / 60)}:${String(abs % 60).padStart(2, "0")}`;
  // POSIX signs run west-positive: UTC+01:30 is "<+0130>-1:30".
  process.env.TZ = `<${offset >= 0 ? "+" : "-"}${hm.replace(":", "").padStart(4, "0")}>${offset >= 0 ? "-" : "+"}${hm}`;
  process.env.SITE_UTC_OFFSET_MIN = String(offset);
}

// The user-guide capture shows the fake OpenCode's version and MCP servers;
// give it real-looking ones (both default to test fixtures).
if (process.env.USER_GUIDE === "1") {
  process.env.FAKE_OPENCODE_VERSION ??= "1.18.11";
  process.env.FAKE_OPENCODE_MCP ??= JSON.stringify({
    github: { type: "local", command: ["npx", "-y", "@modelcontextprotocol/server-github"], environment: { GITHUB_TOKEN: "ghp_example" } },
    sentry: { type: "remote", url: "https://mcp.sentry.dev/mcp" },
  });
}

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
