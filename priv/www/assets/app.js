// velora viewer: pick a source (local file or URL); the server (Erlang + GDAL)
// warps it to a web-mercator COG and serves XYZ PNG tiles; the browser only
// draws the visible tiles on a Leaflet map.
const $ = (s) => document.querySelector(s);
const statusEl = $("#status"), renderBtn = $("#render");
const fileIn = $("#file"), fnameEl = $("#fname"), urlIn = $("#url");
const ndviIn = $("#ndvi"), ndviStatsEl = $("#ndvistats");
const overlay = $("#overlay"), ovtext = $("#ovtext"), emptyEl = $("#empty"), appEl = $("#app");
let map, tiles, homeBounds, busy = false;

fileIn.addEventListener("change", () => {
  fnameEl.textContent = fileIn.files[0] ? fileIn.files[0].name : "no file selected";
});

function setStatus(msg, err) {
  statusEl.textContent = msg;
  statusEl.classList.toggle("err", !!err);
}
function showOverlay(msg) { ovtext.textContent = msg; overlay.classList.remove("hidden"); }
function hideOverlay() { overlay.classList.add("hidden"); }

// fill the viewport with the image (cover: crop overflow rather than letterbox)
function fitCover(b) { map.setView(b.getCenter(), map.getBoundsZoom(b, true), { animate: false }); }

renderBtn.addEventListener("click", () =>
  renderSource({ file: fileIn.files[0], url: urlIn.value.trim() }));

// sample chips
document.querySelectorAll(".chip").forEach((c) =>
  c.addEventListener("click", () => renderSource({ url: c.dataset.uri })));

// drag & drop a file anywhere onto the app
["dragenter", "dragover"].forEach((ev) =>
  appEl.addEventListener(ev, (e) => { e.preventDefault(); appEl.classList.add("dragging"); }));
["dragleave", "drop"].forEach((ev) =>
  appEl.addEventListener(ev, (e) => { e.preventDefault(); if (ev !== "dragleave" || e.target === appEl) appEl.classList.remove("dragging"); }));
appEl.addEventListener("drop", (e) => {
  const f = e.dataTransfer && e.dataTransfer.files && e.dataTransfer.files[0];
  if (f) { fileIn.value = ""; fnameEl.textContent = f.name; renderSource({ file: f }); }
});

// Map + a custom zoom/reset control: three square buttons stacked (+, home, −).
function ensureMap() {
  if (map) return;
  map = L.map("map", { attributionControl: false, zoomControl: false, minZoom: 0, maxZoom: 27 });
  const Ctl = L.Control.extend({
    options: { position: "topright" },
    onAdd: function () {
      const d = L.DomUtil.create("div", "zoombar");
      d.innerHTML =
        '<button class="zin" title="Zoom in">+</button>' +
        '<button class="home" title="Reset view">⌂</button>' +
        '<button class="zout" title="Zoom out">−</button>';
      L.DomEvent.disableClickPropagation(d);
      d.querySelector(".zin").onclick = () => map.zoomIn();
      d.querySelector(".zout").onclick = () => map.zoomOut();
      d.querySelector(".home").onclick = () => { if (homeBounds) fitCover(homeBounds); };
      return d;
    }
  });
  map.addControl(new Ctl());
}

async function resolveUri({ file, url }) {
  if (file) {
    showOverlay("Uploading…");
    const fd = new FormData();
    fd.append("file", file, file.name);
    const r = await fetch("/uploads", { method: "POST", body: fd });
    if (!r.ok) throw new Error("upload failed: " + (await r.text()));
    return (await r.json()).uri;
  }
  if (url) return url.startsWith("/") ? location.origin + url : url;
  throw new Error("Choose a local file or enter a URL.");
}

// Swap the map's tile layer to a new XYZ template. Stops asking past the data's
// native zoom; Leaflet scales the sharpest tiles (kept crisp by CSS).
function setTiles(tpl, bounds, nz) {
  ensureMap();
  map.setMaxZoom(nz + 8);
  if (tiles) map.removeLayer(tiles);
  const b = L.latLngBounds(bounds);
  tiles = L.tileLayer(tpl, { bounds: b, noWrap: true, maxNativeZoom: nz, maxZoom: nz + 8, tileSize: 256 });
  tiles.addTo(map);
  homeBounds = b;
  fitCover(b);
  return b;
}

function showStats(s) {
  if (!s || typeof s.mean !== "number") { ndviStatsEl.classList.add("hidden"); return; }
  const f = (x) => (typeof x === "number" ? x.toFixed(3) : x);
  ndviStatsEl.textContent = `NDVI  mean ${f(s.mean)} · min ${f(s.min)} · max ${f(s.max)}`;
  ndviStatsEl.classList.remove("hidden");
}

async function renderSource(src) {
  if (busy) return;
  busy = true;
  renderBtn.disabled = true;
  emptyEl.classList.add("hidden");
  try {
    const uri = await resolveUri(src);
    if (ndviIn && ndviIn.checked) await renderNdvi(uri);
    else await plainRender(uri);
  } catch (e) {
    setStatus(String(e), true);
    if (!map) emptyEl.classList.remove("hidden");
  } finally {
    hideOverlay();
    renderBtn.disabled = false;
    busy = false;
  }
}

async function plainRender(uri) {
  showStats(null);
  showOverlay("Processing on the server…");
  setStatus("Processing…");
  const r = await fetch("/render", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ uri })
  });
  if (!r.ok) throw new Error("render failed: " + (await r.text()));
  const { id, bounds, maxNativeZoom } = await r.json();
  setTiles("/tiles/" + id + "/{z}/{x}/{y}", bounds, maxNativeZoom || 19);
  setStatus("Done.");
}

// NDVI via the agent's async contract: show the instant capped preview, then
// poll the full-resolution job and swap to its sharper tiles when it is done.
async function renderNdvi(query) {
  showStats(null);
  showOverlay("Computing NDVI on the server…");
  setStatus("NDVI…");
  const r = await fetch("/agent/query", {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({ query, intent: "ndvi" })
  });
  if (!r.ok) throw new Error("NDVI failed: " + (await r.text()));
  const results = (await r.json()).results;
  const card = results && results[0];
  if (!card) throw new Error("No NDVI result — a place name needs a geocoder + STAC configured; otherwise pass a raster URL.");
  const p = card.preview;
  if (p && p.tiles) { setTiles(p.tiles, p.bounds, p.maxNativeZoom || 19); showStats(p.stats); }
  if (card.status === "processing" && card.job && card.result_tiles) {
    setStatus("Preview shown — computing full resolution…");
    await pollNdviJob(card, p);
  } else {
    setStatus("Done.");
  }
}

async function pollNdviJob(card, preview) {
  for (let i = 0; i < 150; i++) {              // ~5 min at 2s intervals
    await new Promise((res) => setTimeout(res, 2000));
    let st;
    try { st = await (await fetch(card.poll)).json(); } catch (_) { continue; }
    if (st.status === "done") {
      const bounds = preview && preview.bounds ? preview.bounds : homeBounds;
      const nz = (preview && preview.maxNativeZoom) || 19;
      setTiles(card.result_tiles, bounds, nz);
      setStatus("Done (full resolution).");
      return;
    }
    if (st.status === "error") { setStatus("Full-res NDVI failed; showing preview.", true); return; }
  }
  setStatus("Full-res NDVI timed out; showing preview.", true);
}

// open with the galaxy by default so the viewer isn't an empty black screen
const defaultChip = document.querySelector(".chip");
if (defaultChip) renderSource({ url: defaultChip.dataset.uri });
