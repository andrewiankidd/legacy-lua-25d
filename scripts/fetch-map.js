// fetch-map.js â€” pull real city-centre geometry from OpenStreetMap (Overpass API)
// and bake it into a Lua data file the game loads at runtime.
//
//   node scripts/fetch-map.js
//
// Output: src/game/maps/city/data.lua
//
// What it does:
//   - Queries Overpass for building + highway ways in the city-centre bbox.
//   - Projects lat/lon to local metres around the bbox centre (flat projection; the
//     area is small enough that curvature is irrelevant).
//   - Derives a height for every building: explicit `height` tag, else
//     `building:levels` * STOREY_M, else a default (flagged inferred).
//   - Writes roads (polylines) + buildings ({footprint, height}) as a Lua table.
//
// Data: Â© OpenStreetMap contributors, ODbL. Attribute in-game.

const fs = require('fs');
const path = require('path');

// --- Config ---------------------------------------------------------------

// City-centre bounding box (real-world coords; the in-game setting is "G-town").
const BBOX = { south: 55.855, west: -4.264, north: 55.866, east: -4.245 };

const STOREY_M = 3.2;        // metres per building level
const DEFAULT_HEIGHT = 12;   // fallback for untagged buildings (~4 storeys, a tenement)

// Highway types worth drawing as roads (drive/walkable surface). Others ignored.
const ROAD_TYPES = new Set([
  'motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link',
  'secondary', 'secondary_link', 'tertiary', 'tertiary_link', 'residential',
  'unclassified', 'living_street', 'service', 'pedestrian', 'footway', 'path',
]);

const OVERPASS_ENDPOINTS = [
  'https://overpass-api.de/api/interpreter',
  'https://overpass.kumi.systems/api/interpreter',
  'https://maps.mail.ru/osm/tools/overpass/api/interpreter',
];

const OUT = path.join(__dirname, '..', 'src', 'game', 'maps', 'city', 'data.lua');

// --- Overpass fetch with mirror fallback ----------------------------------

function buildQuery(b) {
  return `[out:json][timeout:180];
(
  way["building"](${b.south},${b.west},${b.north},${b.east});
  way["highway"](${b.south},${b.west},${b.north},${b.east});
);
out geom;`;
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

async function fetchOverpass(query) {
  const headers = {
    // Overpass mirrors reject requests without a descriptive User-Agent.
    'User-Agent': 'gtown-mapgen/1.0 (hobby project)',
    'Accept': 'application/json',
  };
  let lastErr;
  for (const url of OVERPASS_ENDPOINTS) {
    for (let attempt = 1; attempt <= 3; attempt++) {
      try {
        process.stdout.write(`Querying ${url} (attempt ${attempt})... `);
        // GET with the query in the URL â€” proved more reliable than POST on these mirrors.
        const res = await fetch(url + '?data=' + encodeURIComponent(query), { headers });
        if (res.status === 429 || res.status === 504) {
          console.log(`HTTP ${res.status} (busy), backing off`);
          lastErr = new Error('HTTP ' + res.status);
          await sleep(5000 * attempt);
          continue;
        }
        if (!res.ok) { console.log(`HTTP ${res.status}`); lastErr = new Error('HTTP ' + res.status); break; }
        const json = await res.json();
        console.log(`ok (${json.elements.length} elements)`);
        return json;
      } catch (e) {
        console.log('failed: ' + e.message);
        lastErr = e;
        await sleep(2000);
      }
    }
  }
  throw lastErr || new Error('all Overpass endpoints failed');
}

// --- Projection -----------------------------------------------------------

function makeProjector(b) {
  const lat0 = (b.south + b.north) / 2;
  const lon0 = (b.west + b.east) / 2;
  const mPerLat = 111320;
  const mPerLon = 111320 * Math.cos((lat0 * Math.PI) / 180);
  // x = east metres from centre, y = NORTH metres from centre (renderer flips for screen).
  return {
    origin: { lat: lat0, lon: lon0 },
    project: (lat, lon) => [(lon - lon0) * mPerLon, (lat - lat0) * mPerLat],
  };
}

// --- Height derivation ----------------------------------------------------

function deriveHeight(tags) {
  if (tags.height) {
    const h = parseFloat(String(tags.height).replace(/[^0-9.]/g, ''));
    if (!isNaN(h) && h > 0) return { height: h, inferred: false };
  }
  if (tags['building:levels']) {
    const lv = parseFloat(tags['building:levels']);
    if (!isNaN(lv) && lv > 0) return { height: lv * STOREY_M, inferred: false };
  }
  return { height: DEFAULT_HEIGHT, inferred: true };
}

// --- Lua emit -------------------------------------------------------------

function num(n) { return Number(n.toFixed(2)); }

function ptsToLua(geom, project) {
  const out = [];
  for (const g of geom) {
    const [x, y] = project(g.lat, g.lon);
    out.push(num(x), num(y));
  }
  return '{' + out.join(',') + '}';
}

function luaStr(s) {
  if (s == null) return 'nil';
  return '"' + String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"') + '"';
}

function main() {
  return fetchOverpass(buildQuery(BBOX)).then((json) => {
    const proj = makeProjector(BBOX);
    const buildings = [];
    const roads = [];
    let tagged = 0;

    for (const el of json.elements) {
      if (el.type !== 'way' || !el.geometry || el.geometry.length < 2) continue;
      const tags = el.tags || {};
      if (tags.building) {
        const { height, inferred } = deriveHeight(tags);
        if (!inferred) tagged++;
        buildings.push({
          name: tags.name || null,
          height: num(height),
          inferred,
          pts: ptsToLua(el.geometry, proj.project),
        });
      } else if (tags.highway && ROAD_TYPES.has(tags.highway)) {
        roads.push({
          name: tags.name || null,
          kind: tags.highway,
          pts: ptsToLua(el.geometry, proj.project),
        });
      }
    }

    // Bounds (metres) for the camera to know the world extent.
    const [minx, miny] = proj.project(BBOX.south, BBOX.west);
    const [maxx, maxy] = proj.project(BBOX.north, BBOX.east);

    const lines = [];
    lines.push('-- City map â€” generated by scripts/fetch-map.js. DO NOT EDIT BY HAND.');
    lines.push('-- Geometry: Â© OpenStreetMap contributors (ODbL). Coords in metres from bbox centre.');
    lines.push('return {');
    lines.push(`  attribution = "Â© OpenStreetMap contributors",`);
    lines.push(`  origin = { lat = ${proj.origin.lat}, lon = ${proj.origin.lon} },`);
    lines.push(`  bounds = { minx = ${num(minx)}, miny = ${num(miny)}, maxx = ${num(maxx)}, maxy = ${num(maxy)} },`);
    lines.push('  roads = {');
    for (const r of roads) {
      lines.push(`    { kind = ${luaStr(r.kind)}, pts = ${r.pts} },`);
    }
    lines.push('  },');
    lines.push('  buildings = {');
    for (const bld of buildings) {
      lines.push(`    { height = ${bld.height}, inferred = ${bld.inferred}, pts = ${bld.pts} },`);
    }
    lines.push('  },');
    lines.push('}');

    fs.mkdirSync(path.dirname(OUT), { recursive: true });
    fs.writeFileSync(OUT, lines.join('\n'));

    const pct = buildings.length ? Math.round((tagged / buildings.length) * 100) : 0;
    console.log(`\nWrote ${OUT}`);
    console.log(`  roads:     ${roads.length}`);
    console.log(`  buildings: ${buildings.length} (${tagged} with real height = ${pct}%, rest inferred @ ${DEFAULT_HEIGHT}m)`);
    console.log(`  file size: ${(fs.statSync(OUT).size / 1024).toFixed(0)} KB`);
  });
}

main().catch((e) => { console.error('\nFAILED:', e.message); process.exit(1); });
