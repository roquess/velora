const fs = require("fs"), path = require("path"), cp = require("child_process");
const W = 32, H = 32, dir = __dirname;
const nir = Buffer.alloc(W*H*2), red = Buffer.alloc(W*H*2);
let k = 0;
for (let r = 0; r < H; r++) for (let c = 0; c < W; c++) { nir.writeUInt16LE(r < H/2 ? 800 : 300, k); red.writeUInt16LE(200, k); k += 2; }
fs.writeFileSync(path.join(dir, "scene.raw"), Buffer.concat([nir, red]));
fs.writeFileSync(path.join(dir, "scene.hdr"),
  `ENVI\nsamples = ${W}\nlines = ${H}\nbands = 2\nheader offset = 0\ndata type = 12\ninterleave = bsq\nbyte order = 0\n`);
const gdalDir = process.env.GDAL_BIN_DIR || (process.platform === "win32" ? "C:/Program Files/GDAL" : "");
const exe = gdalDir ? path.join(gdalDir, "gdal_translate" + (process.platform === "win32" ? ".exe" : "")) : "gdal_translate";
const env = Object.assign({}, process.env);
if (gdalDir) {
  env.PROJ_LIB = env.PROJ_LIB || path.join(gdalDir, "projlib");
  env.PROJ_DATA = env.PROJ_DATA || path.join(gdalDir, "projlib");
  env.GDAL_DATA = env.GDAL_DATA || path.join(gdalDir, "gdal-data");
}
cp.execFileSync(exe, ["-q","-a_srs","EPSG:4326","-a_ullr","0","32","32","0","-of","COG", path.join(dir,"scene.raw"), path.join(dir,"scene.tif")], { stdio: "inherit", env });
console.log("fixture built:", path.join(dir, "scene.tif"));
