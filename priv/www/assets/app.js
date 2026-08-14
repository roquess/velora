// velora viewer: pick a source (local file or URL); the server (Erlang + GDAL)
// warps it to a web-mercator COG and serves XYZ PNG tiles; the browser only
// draws the visible tiles on a Leaflet map.
const $ = (s) => document.querySelector(s);
const statusEl = $("#status"), renderBtn = $("#render");
const fileIn = $("#file"), fnameEl = $("#fname"), urlIn = $("#url");
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

async function renderSource(src) {
  if (busy) return;
  busy = true;
  renderBtn.disabled = true;
  emptyEl.classList.add("hidden");
  try {
    const uri = await resolveUri(src);
    showOverlay("Processing on the server…");
    setStatus("Processing…");
    const r = await fetch("/render", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ uri })
    });
    if (!r.ok) throw new Error("render failed: " + (await r.text()));
    const { id, bounds, maxNativeZoom } = await r.json();
    const nz = maxNativeZoom || 19;

    ensureMap();
    map.setMaxZoom(nz + 8);
    if (tiles) map.removeLayer(tiles);
    const b = L.latLngBounds(bounds);
    // Stop asking the server for tiles past the data's native zoom; Leaflet just
    // scales the sharpest tiles (kept crisp by image-rendering: pixelated in CSS).
    tiles = L.tileLayer("/tiles/" + id + "/{z}/{x}/{y}", {
      bounds: b, noWrap: true, maxNativeZoom: nz, maxZoom: nz + 8, tileSize: 256
    });
    tiles.addTo(map);
    homeBounds = b;
    fitCover(b);
    setStatus("Done.");
  } catch (e) {
    setStatus(String(e), true);
    if (!map) emptyEl.classList.remove("hidden");
  } finally {
    hideOverlay();
    renderBtn.disabled = false;
    busy = false;
  }
}

// open with the galaxy by default so the viewer isn't an empty black screen
const defaultChip = document.querySelector(".chip");
if (defaultChip) renderSource({ url: defaultChip.dataset.uri });
