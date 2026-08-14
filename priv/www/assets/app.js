const $ = (s) => document.querySelector(s);
const statusEl = $("#status"), statsEl = $("#stats"), runBtn = $("#run");
let map, layer;

function setStatus(msg, err) { statusEl.textContent = msg; statusEl.classList.toggle("err", !!err); }

runBtn.addEventListener("click", () => run().catch((e) => setStatus(String(e), true)));

async function run() {
  runBtn.disabled = true; statsEl.innerHTML = ""; setStatus("Preparing…");
  try {
    const uri = await sourceUri();
    const nir = +$("#nir").value, red = +$("#red").value;
    const out = "work://ndvi_" + Date.now() + "_" + Math.random().toString(36).slice(2) + ".tif";
    const body = {
      op: "ndvi",
      sources: [ { uri, band: nir }, { uri, band: red } ],
      out_uri: out,
      tile: [512, 512]
    };
    setStatus("Submitting…");
    const sub = await fetch("/jobs", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) });
    if (!sub.ok) throw new Error("submit failed: " + (await sub.text()));
    const { job_id } = await sub.json();
    const job = await poll(job_id);
    renderStats(job.stats);
    await renderResult(job_id);
    setStatus("Done.");
  } finally { runBtn.disabled = false; }
}

async function sourceUri() {
  const file = $("#file").files[0], url = $("#url").value.trim();
  if (file) {
    setStatus("Uploading…");
    const fd = new FormData(); fd.append("file", file, file.name);
    const r = await fetch("/uploads", { method: "POST", body: fd });
    if (!r.ok) throw new Error("upload failed: " + (await r.text()));
    return (await r.json()).uri;
  }
  if (url) return url;
  throw new Error("Choose a local file or enter a URL.");
}

async function poll(id) {
  for (let i = 0; i < 600; i++) {
    const r = await fetch("/jobs/" + id);
    const j = await r.json();
    setStatus("Status: " + j.status + " (" + j.progress.done + "/" + j.progress.total + ")");
    if (j.status === "done") return j;
    if (j.status === "error") throw new Error("job error: " + JSON.stringify(j.error));
    await new Promise((res) => setTimeout(res, 1000));
  }
  throw new Error("timed out");
}

// brown -> yellow -> green ramp over NDVI [-1, 1]; transparent for nodata
function ndviColor(vals) {
  const v = vals[0];
  if (v === null || v === undefined || Number.isNaN(v)) return null;
  const t = Math.max(0, Math.min(1, (v + 1) / 2));
  const stops = [ [120,72,0], [200,180,40], [30,140,40] ];
  const seg = t < 0.5 ? 0 : 1, f = t < 0.5 ? t / 0.5 : (t - 0.5) / 0.5;
  const a = stops[seg], b = stops[seg + 1];
  const c = a.map((x, i) => Math.round(x + (b[i] - x) * f));
  return "rgba(" + c[0] + "," + c[1] + "," + c[2] + ",1)";
}

async function renderResult(id) {
  setStatus("Loading raster…");
  const url = "/jobs/" + id + "/result";
  // Range-based COG read (falls back to full fetch if the lazy path is unavailable)
  let georaster;
  try {
    const tiff = await GeoTIFF.fromUrl(url);
    georaster = await parseGeoraster(tiff);
  } catch (e) {
    const buf = await (await fetch(url)).arrayBuffer();
    georaster = await parseGeoraster(buf);
  }
  if (!map) { map = L.map("map", { center: [0, 0], zoom: 2, crs: L.CRS.EPSG4326 }); }
  if (layer) { map.removeLayer(layer); }
  layer = new GeoRasterLayer({ georaster, pixelValuesToColorFn: ndviColor, resolution: 256, opacity: 1 });
  layer.addTo(map);
  map.fitBounds(layer.getBounds());
}

function renderStats(s) {
  if (!s) { statsEl.innerHTML = ""; return; }
  const rows = [ ["count", s.count], ["min", fmt(s.min)], ["max", fmt(s.max)], ["mean", fmt(s.mean)], ["stddev", fmt(s.stddev)] ];
  const table = "<table>" + rows.map((r) => "<tr><td>" + r[0] + "</td><td>" + r[1] + "</td></tr>").join("") + "</table>";
  statsEl.innerHTML = "<h4>Stats</h4>" + table + histogramSvg(s.histogram);
}
function fmt(x) { return (x === null || x === undefined) ? "—" : (+x).toFixed(4); }

function histogramSvg(h) {
  if (!h || !h.counts) return "";
  const counts = h.counts, max = Math.max(1, ...counts), W = 280, H = 80, bw = W / counts.length;
  const bars = counts.map((c, i) => {
    const bh = Math.round((c / max) * (H - 2));
    return '<rect x="' + (i * bw).toFixed(1) + '" y="' + (H - bh) + '" width="' + Math.max(1, bw - 0.5).toFixed(1) + '" height="' + bh + '" fill="#4caf50"/>';
  }).join("");
  return '<h4>Histogram</h4><svg width="' + W + '" height="' + H + '" style="background:#181818;border:1px solid #333">' + bars + "</svg>";
}
