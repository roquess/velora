const { test, expect } = require("@playwright/test");

// End-to-end for the raster viewer: the default sample is warped server-side and
// streamed as map tiles; the browser only draws them. Attaches to an already
// running velora (see playwright.config.js, reuseExistingServer).
test("viewer renders a raster as server-streamed map tiles", async ({ page }) => {
  const errors = [];
  page.on("console", (m) => {
    if (m.type() === "error" && !m.text().includes("favicon")) errors.push(m.text());
  });
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));

  await page.goto("/");

  // the default sample auto-loads, is prepared on the server, then displayed
  await expect(page.locator("#status")).toContainText("Done.", { timeout: 120000 });

  // at least one PNG tile rendered by the server is drawn on the map
  await expect(page.locator("#map img.leaflet-tile").first()).toBeVisible({ timeout: 15000 });

  // custom zoom + reset control is present
  await expect(page.locator(".zoombar .home")).toBeVisible();

  expect(errors, "console errors: " + errors.join(" | ")).toHaveLength(0);
});
