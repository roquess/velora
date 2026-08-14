const { test, expect } = require("@playwright/test");
const path = require("path");

test("upload a scene, run NDVI, see the raster and stats", async ({ page }) => {
  const errors = [];
  page.on("console", (m) => { if (m.type() === "error") errors.push(m.text()); });
  page.on("pageerror", (e) => errors.push("pageerror: " + e.message));

  await page.goto("/");
  await expect(page.locator("#run")).toBeVisible();

  await page.setInputFiles("#file", path.join(__dirname, "fixtures", "scene.tif"));
  await page.fill("#nir", "1");
  await page.fill("#red", "2");
  await page.click("#run");

  await expect(page.locator("#status")).toContainText("Done.", { timeout: 90000 });
  await expect(page.locator("#stats")).toContainText("mean");
  // georaster-layer renders the raster as one or more Leaflet canvas tiles
  await expect(page.locator("#map canvas").first()).toBeVisible({ timeout: 15000 });
  const canvasCount = await page.locator("#map canvas").count();
  expect(canvasCount, "map should render at least one canvas").toBeGreaterThan(0);

  expect(errors, "console errors: " + errors.join(" | ")).toHaveLength(0);
});
