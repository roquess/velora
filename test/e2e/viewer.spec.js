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

const path = require("path");

// NDVI mode: upload a 2-band raster, run the async agent flow, and confirm the
// viewer swaps to the full-resolution job's tiles once the job is done.
test("NDVI mode swaps to full-resolution job tiles", async ({ page }) => {
  const errors = [];
  page.on("console", (m) => {
    if (m.type() === "error" && !m.text().includes("favicon")) errors.push(m.text());
  });
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));

  await page.goto("/");
  await expect(page.locator("#status")).toContainText("Done.", { timeout: 120000 });

  await page.locator("#ndvi").check();
  await page.setInputFiles("#file", path.join(__dirname, "fixtures", "scene.tif"));
  await page.locator("#render").click();

  // the full-resolution NDVI job completes and the viewer swaps to its tiles
  await expect(page.locator("#status")).toContainText("Done (full resolution).", { timeout: 120000 });
  await expect(page.locator('#map img.leaflet-tile[src*="/jobs/"]').first())
    .toBeVisible({ timeout: 15000 });

  expect(errors, "console errors: " + errors.join(" | ")).toHaveLength(0);
});
