const { defineConfig } = require("@playwright/test");
module.exports = defineConfig({
  testDir: ".",
  timeout: 120000,
  use: { baseURL: "http://127.0.0.1:8080", headless: true },
  webServer: {
    command: "echo velora-already-running",
    url: "http://127.0.0.1:8080/health",
    reuseExistingServer: true,
    timeout: 60000
  }
});
