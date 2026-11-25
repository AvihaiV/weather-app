// All API data is written with textContent / SVG attributes, never innerHTML: no XSS even if data were hostile.
// [label, day icon, night icon, sky]
const CODES = {
  0: ["Clear", "☀️", "🌙", "clear"], 1: ["Mostly clear", "🌤️", "🌙", "clear"], 2: ["Partly cloudy", "⛅", "☁️", "cloudy"],
  3: ["Overcast", "☁️", "☁️", "cloudy"], 45: ["Fog", "🌫️", "🌫️", "fog"], 48: ["Fog", "🌫️", "🌫️", "fog"],
  51: ["Drizzle", "🌦️", "🌧️", "rain"], 53: ["Drizzle", "🌦️", "🌧️", "rain"], 55: ["Drizzle", "🌦️", "🌧️", "rain"],
  61: ["Rain", "🌧️", "🌧️", "rain"], 63: ["Rain", "🌧️", "🌧️", "rain"], 65: ["Heavy rain", "🌧️", "🌧️", "rain"],
  71: ["Snow", "🌨️", "🌨️", "snow"], 73: ["Snow", "🌨️", "🌨️", "snow"], 75: ["Heavy snow", "❄️", "❄️", "snow"],
  80: ["Showers", "🌦️", "🌧️", "rain"], 81: ["Showers", "🌧️", "🌧️", "rain"], 82: ["Heavy showers", "⛈️", "⛈️", "storm"],
  95: ["Thunderstorm", "⛈️", "⛈️", "storm"], 96: ["Thunderstorm", "⛈️", "⛈️", "storm"], 99: ["Thunderstorm", "⛈️", "⛈️", "storm"],
};
const SVG = "http://www.w3.org/2000/svg";
const DIRS = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"];
const state = { data: [], location: null, hours: 24, order: [], dragging: null };

const $ = (id) => document.getElementById(id);
const el = (tag, cls, text) => { const e = document.createElement(tag); if (cls) e.className = cls; if (text !== undefined) e.textContent = text; return e; };
const svg = (tag, attrs) => { const e = document.createElementNS(SVG, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; };
const deg = (v) => (v == null ? "–" : `${Math.round(v)}°`);
const fmtTime = (iso) => new Date(iso).toISOString().slice(5, 16).replace("T", " ");

function weather(d) {
  const [label, dayIcon, nightIcon, sky] = CODES[d.weather_code] ?? [`Code ${d.weather_code}`, "🌡️", "🌡️", "cloudy"];
  const night = d.is_day === false;
  return { label, icon: night ? nightIcon : dayIcon, sky: `sky-${sky}-${night ? "night" : "day"}` };
}
// Local clock for the city: now + its UTC offset (falls back to UTC if unknown).
const localTime = (d) => new Date(Date.now() + (d.utc_offset_seconds ?? 0) * 1000).toISOString().slice(11, 16);

async function getJSON(url) {
  const r = await fetch(url);
  if (!r.ok) throw new Error(`HTTP ${r.status}`);
  return r.json();
}

// City order is a per-viewer preference: kept in this browser only. Storage can be blocked, so never fail on it.
const ORDER_KEY = "cityOrder";
function loadOrder() { try { return JSON.parse(localStorage.getItem(ORDER_KEY)) || []; } catch { return []; } }
function saveOrder() { try { localStorage.setItem(ORDER_KEY, JSON.stringify(state.order)); } catch { /* ignore */ } }

function ordered() {
  const names = state.data.map((d) => d.location);
  // Saved order first (only cities that still exist), then any new cities at the end.
  state.order = [...state.order.filter((n) => names.includes(n)), ...names.filter((n) => !state.order.includes(n))];
  return state.order.map((n) => state.data.find((d) => d.location === n));
}

function move(name, to) {
  const from = state.order.indexOf(name);
  if (from < 0 || to < 0 || to >= state.order.length || from === to) return;
  state.order.splice(to, 0, state.order.splice(from, 1)[0]);
  saveOrder();
  renderSidebar();
  document.querySelector(`[data-city="${CSS.escape(name)}"] .city-select`)?.focus();
}

function renderSidebar() {
  const list = ordered();
  $("cities").replaceChildren(...list.map((d, i) => {
    const w = weather(d);
    const item = el("div", `city ${w.sky}`);
    item.setAttribute("role", "listitem");
    item.dataset.city = d.location;
    item.draggable = !matchMedia("(pointer: coarse)").matches; // touch screens use Edit mode instead

    const pick = el("button", "city-select");
    pick.setAttribute("aria-pressed", String(d.location === state.location));
    pick.setAttribute("aria-keyshortcuts", "Alt+ArrowUp Alt+ArrowDown");
    const top = el("div", "city-row");
    const name = el("div");
    name.append(el("div", "city-name", d.location), el("div", "city-time", localTime(d)));
    top.append(name, el("div", "city-temp", deg(d.temperature_c)));
    const bottom = el("div", "city-row city-sub");
    bottom.append(el("span", "", `${w.icon} ${w.label}`), el("span", "", `H:${deg(d.high_c)} L:${deg(d.low_c)}`));
    pick.append(top, bottom);
    pick.addEventListener("click", () => select(d.location));
    pick.addEventListener("keydown", (e) => {
      if (!e.altKey || !["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"].includes(e.key)) return;
      e.preventDefault();
      move(d.location, i + (e.key === "ArrowUp" || e.key === "ArrowLeft" ? -1 : 1));
    });

    const mover = el("div", "city-move");
    for (const [label, delta, text] of [["Move earlier", -1, "▲"], ["Move later", 1, "▼"]]) {
      const b = el("button", "", text);
      b.setAttribute("aria-label", `${label}: ${d.location}`);
      b.disabled = i + delta < 0 || i + delta >= list.length;
      b.addEventListener("click", () => move(d.location, i + delta));
      mover.append(b);
    }

    item.addEventListener("dragstart", (e) => { state.dragging = d.location; item.classList.add("dragging"); e.dataTransfer.effectAllowed = "move"; e.dataTransfer.setData("text/plain", d.location); });
    item.addEventListener("dragend", () => item.classList.remove("dragging"));
    item.addEventListener("dragover", (e) => e.preventDefault());
    item.addEventListener("drop", (e) => { e.preventDefault(); move(state.dragging, i); });

    item.append(pick, mover);
    return item;
  }));
}

$("edit").addEventListener("click", () => {
  const on = !document.body.classList.contains("editing");
  document.body.classList.toggle("editing", on);
  $("edit").setAttribute("aria-pressed", String(on));
  $("edit").textContent = on ? "Done" : "Edit";
});
if (matchMedia("(pointer: coarse)").matches) $("hint").textContent = "Tap Edit to reorder cities.";

function renderCompass(direction) {
  const root = svg("svg", { viewBox: "0 0 100 100", role: "img", "aria-label": `Wind from ${direction ?? "unknown"} degrees` });
  root.append(svg("circle", { cx: 50, cy: 50, r: 44, class: "compass-ring" }));
  for (const [t, x, y] of [["N", 50, 16], ["E", 86, 54], ["S", 50, 92], ["W", 14, 54]]) {
    const label = svg("text", { x, y, class: "compass-label", "text-anchor": "middle" }); label.textContent = t; root.append(label);
  }
  if (direction != null) {
    // Meteorological direction = where wind comes FROM; arrow points where it blows TO.
    const arrow = svg("g", { transform: `rotate(${direction + 180} 50 50)` });
    arrow.append(svg("line", { x1: 50, y1: 72, x2: 50, y2: 30, class: "compass-arrow" }),
      svg("polygon", { points: "50,24 44,36 56,36", class: "compass-head" }));
    root.append(arrow);
  }
  $("compass").replaceChildren(root);
}

function renderMain() {
  const d = state.data.find((x) => x.location === state.location);
  const w = weather(d);
  document.body.className = `${w.sky}${document.body.classList.contains("editing") ? " editing" : ""}`;
  $("city").textContent = d.location;
  $("temp").textContent = deg(d.temperature_c);
  $("cond").textContent = `${w.icon} ${w.label}`;
  $("hl").textContent = `24h  H:${deg(d.high_c)}  L:${deg(d.low_c)}`;

  $("wind-speed").textContent = `${Math.round(d.wind_speed_kmh)} km/h`;
  $("wind-dir").textContent = d.wind_direction_deg == null ? "Direction unknown"
    : `From ${DIRS[Math.round(d.wind_direction_deg / 45) % 8]} (${d.wind_direction_deg}°)`;
  renderCompass(d.wind_direction_deg);

  $("feels").textContent = deg(d.apparent_temperature_c);
  const diff = (d.apparent_temperature_c ?? d.temperature_c) - d.temperature_c;
  $("feels-note").textContent = Math.abs(diff) < 1.5 ? "Similar to the actual temperature."
    : diff < 0 ? "Wind makes it feel colder." : "Humidity makes it feel warmer.";

  const h = d.humidity_pct;
  $("humidity").textContent = h == null ? "–" : `${h}%`;
  $("humidity-bar").style.width = `${h ?? 0}%`;
  $("humidity-note").textContent = h == null ? "" : h < 30 ? "Dry air." : h < 60 ? "Comfortable." : h < 80 ? "Humid." : "Very humid.";

  $("clock").textContent = `🕒 ${localTime(d)} local time`;
  $("main").hidden = false;
}

function renderStats(rows) {
  const vs = rows.map((r) => r.temperature_c);
  const items = rows.length
    ? [["Min", deg(Math.min(...vs))], ["Max", deg(Math.max(...vs))],
       ["Avg", deg(vs.reduce((a, b) => a + b, 0) / vs.length)], ["Samples", String(rows.length)]]
    : [];
  $("stats").replaceChildren(...items.map(([k, v]) => {
    const s = el("div", "stat"); s.append(el("span", "stat-k", k), el("span", "stat-v", v)); return s;
  }));
}

// Time in the selected city's local zone (UTC offset comes from the collector).
const fmtCity = (iso, offset) => new Date(Date.parse(iso) + (offset ?? 0) * 1000).toISOString().slice(5, 16).replace("T", " ");

function renderChart(rows, offset) {
  const box = $("chart");
  if (!rows.length) { box.replaceChildren(el("p", "tile-note", "No history in this range yet.")); return; }
  const W = 800, H = 170, P = 26;
  const ts = rows.map((r) => Date.parse(r.observed_at)), vs = rows.map((r) => r.temperature_c);
  const [t0, t1] = [Math.min(...ts), Math.max(...ts)];
  // Y range in whole degrees, at least 4° wide, so a flat day never stacks the axis labels on each other.
  let [v0, v1] = [Math.floor(Math.min(...vs)) - 1, Math.ceil(Math.max(...vs)) + 1];
  if (v1 - v0 < 4) { const mid = Math.round((v0 + v1) / 2); [v0, v1] = [mid - 2, mid + 2]; }
  const ticks = [v0, Math.round((v0 + v1) / 2), v1];
  const x = (t) => P + (t1 === t0 ? (W - 2 * P) / 2 : (t - t0) / (t1 - t0) * (W - 2 * P));
  const y = (v) => H - P - (v - v0) / (v1 - v0) * (H - 2 * P);
  const pts = rows.map((r, i) => `${x(ts[i]).toFixed(1)},${y(vs[i]).toFixed(1)}`);

  const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, role: "img", "aria-label": "Temperature history chart" });
  const grad = svg("linearGradient", { id: "fill", x1: 0, y1: 0, x2: 0, y2: 1 });
  grad.append(svg("stop", { offset: "0%", class: "stop-top" }), svg("stop", { offset: "100%", class: "stop-bottom" }));
  const defs = svg("defs", {}); defs.append(grad); root.append(defs);
  for (const v of ticks) {
    root.append(svg("line", { x1: P, x2: W - P, y1: y(v), y2: y(v), class: "grid" }));
    const label = svg("text", { x: 2, y: y(v) + 4, class: "axis" }); label.textContent = deg(v); root.append(label);
  }
  if (rows.length > 1) {
    root.append(svg("polygon", { points: `${x(t0)},${H - P} ${pts.join(" ")} ${x(t1)},${H - P}`, class: "area" }));
    root.append(svg("polyline", { points: pts.join(" "), class: "line" }));
  }
  rows.forEach((r, i) => root.append(svg("circle", { cx: x(ts[i]), cy: y(vs[i]), r: rows.length > 48 ? 1.6 : 3.2, class: "dot" })));
  for (const [t, anchor] of [[t0, "start"], [t1, "end"]]) {
    const label = svg("text", { x: x(t), y: H - 6, class: "axis", "text-anchor": anchor });
    label.textContent = fmtCity(new Date(t).toISOString(), offset); root.append(label);
  }

  // Hover / touch crosshair: nearest sample -> vertical line, highlighted point, tooltip.
  const guide = svg("line", { y1: P / 2, y2: H - P, class: "guide", visibility: "hidden" });
  const focus = svg("circle", { r: 5.5, class: "focus", visibility: "hidden" });
  const hit = svg("rect", { x: 0, y: 0, width: W, height: H, class: "hit" });
  root.append(guide, focus, hit);
  const tip = el("div", "tip"); tip.hidden = true;

  const show = (evt) => {
    const box_ = root.getBoundingClientRect();
    const px = (evt.clientX - box_.left) / box_.width * W;
    let i = 0;
    for (let k = 1; k < rows.length; k++) if (Math.abs(x(ts[k]) - px) < Math.abs(x(ts[i]) - px)) i = k;
    const cx = x(ts[i]), cy = y(vs[i]), r = rows[i];
    guide.setAttribute("x1", cx); guide.setAttribute("x2", cx); focus.setAttribute("cx", cx); focus.setAttribute("cy", cy);
    guide.setAttribute("visibility", "visible"); focus.setAttribute("visibility", "visible");
    const { label } = weather({ weather_code: r.weather_code });
    tip.replaceChildren(el("strong", "", `${r.temperature_c.toFixed(1)}°C`), el("span", "", label),
      el("span", "", `💨 ${r.wind_speed_kmh.toFixed(0)} km/h`), el("small", "", `${fmtCity(r.observed_at, offset)} local`));
    tip.hidden = false;
    // Keep the tooltip inside the chart: flip to the left of the point on the right half.
    const left = cx / W * box_.width, top = cy / H * box_.height;
    tip.style.left = `${left}px`; tip.style.top = `${top}px`;
    tip.classList.toggle("flip", left > box_.width / 2);
  };
  const hide = () => { tip.hidden = true; guide.setAttribute("visibility", "hidden"); focus.setAttribute("visibility", "hidden"); };
  hit.addEventListener("pointermove", show);
  hit.addEventListener("pointerdown", show);
  hit.addEventListener("pointerleave", hide);

  box.replaceChildren(root, tip);
}

async function loadHistory() {
  const rows = await getJSON(`/api/weather/history?location=${encodeURIComponent(state.location)}&hours=${state.hours}`);
  document.querySelectorAll(".ranges button").forEach((b) => b.setAttribute("aria-pressed", String(+b.dataset.hours === state.hours)));
  renderStats(rows);
  const city = state.data.find((x) => x.location === state.location);
  renderChart(rows, city?.utc_offset_seconds);
}

function select(location) {
  state.location = location;
  history.replaceState(null, "", `#${encodeURIComponent(location)}`); // shareable link to a city
  renderSidebar();
  renderMain();
  loadHistory().catch((e) => { $("status").textContent = `History failed: ${e.message}`; });
}

document.querySelectorAll(".ranges button").forEach((b) => b.addEventListener("click", () => {
  state.hours = +b.dataset.hours;
  if (state.location) select(state.location);
}));

async function load() {
  const status = $("status");
  try {
    state.data = await getJSON("/api/weather/current");
    if (!state.data.length) { status.textContent = "No data yet. The collector runs every 15 minutes."; return; }
    const newest = state.data.reduce((m, d) => (d.observed_at > m ? d.observed_at : m), "");
    const mins = Math.round((Date.now() - Date.parse(newest)) / 60000);
    status.textContent = `Data from ${mins < 1 ? "just now" : `${mins} min ago`} · new data every 15 min`;
    const fromHash = decodeURIComponent(location.hash.slice(1));
    const known = (name) => state.data.some((d) => d.location === name);
    select(known(state.location) ? state.location : known(fromHash) ? fromHash : state.data[0].location);
  } catch (e) {
    status.textContent = `Could not load weather: ${e.message}`;
  }
}

// Keep the page live: re-render clocks/"updated X ago" every 15s, refetch data every 60s
// (new data lands every 15 min), and refetch right away when the user comes back to the tab.
function tick() {
  if (!state.data.length) return;
  // Update clock text in place (re-rendering would break a drag in progress or keyboard focus).
  document.querySelectorAll(".city").forEach((c) => {
    const d = state.data.find((x) => x.location === c.dataset.city);
    if (d) c.querySelector(".city-time").textContent = localTime(d);
  });
  const d = state.data.find((x) => x.location === state.location);
  if (d) $("clock").textContent = `🕒 ${localTime(d)} local time`;
  const newest = state.data.reduce((m, x) => (x.observed_at > m ? x.observed_at : m), "");
  const mins = Math.round((Date.now() - Date.parse(newest)) / 60000);
  $("status").textContent = `Data from ${mins < 1 ? "just now" : `${mins} min ago`} · new data every 15 min`;
}

state.order = loadOrder();
load();
setInterval(load, 60 * 1000);
setInterval(tick, 15 * 1000);
document.addEventListener("visibilitychange", () => { if (document.visibilityState === "visible") load(); });
