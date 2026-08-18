// Build the raster fixture (test/e2e/fixtures/scene.tif) before the suite runs,
// so the NDVI test has a 2-band georeferenced source. Needs GDAL on PATH (the
// CI viewer-e2e job installs gdal-bin; locally set GDAL_BIN_DIR).
const { execFileSync } = require("child_process");
const path = require("path");

module.exports = async () => {
  execFileSync("node", [path.join(__dirname, "fixtures", "make-fixture.js")], {
    stdio: "inherit"
  });
};
