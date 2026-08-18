const { defineConfig } = require("@playwright/test");
const path = require("path");

const repo = path.resolve(__dirname, "..", "..");
const ebins = "_build/default/lib/*/ebin";
const evalExpr = "application:ensure_all_started(velora), receive stop -> ok end";
// Start velora if it isn't already running (reuseExistingServer attaches when it is).
const startCmd =
  process.platform === "win32"
    ? `set "GDAL_BIN_DIR=C:/Program Files/GDAL" && erl -noshell -pa ${ebins} -eval "${evalExpr}"`
    : `erl -noshell -pa ${ebins} -eval '${evalExpr}'`;

module.exports = defineConfig({
  testDir: ".",
  timeout: 180000,
  globalSetup: require.resolve("./global-setup.js"),
  use: { baseURL: "http://127.0.0.1:8080", headless: true },
  webServer: {
    command: startCmd,
    cwd: repo,
    url: "http://127.0.0.1:8080/health",
    reuseExistingServer: true,
    timeout: 120000
  }
});
