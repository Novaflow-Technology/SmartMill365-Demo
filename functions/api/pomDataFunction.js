const express = require("express");
const { getInfluxClient, getMysqlPool } = require("../helpers/dbConnections");

const router = express.Router();

function sanitize(s) {
  return String(s || "").replace(/["\\]/g, "");
}

// Every POM route is scoped to one client's own Influx/MySQL config — the
// group dashboard for one domain must never read another domain's database.
// x-client-id is required explicitly here rather than falling through to
// whatever integration_config/active_integration happens to be set to, so
// isolation doesn't depend on that value never changing.
router.use((req, res, next) => {
  if (!req.headers["x-client-id"]) {
    return res.status(400).json({ error: "Missing x-client-id header" });
  }
  next();
});

// ── GET /pom/devices ──────────────────────────────────────────────────────────
// The Group POM Command Center's real device/field catalog, read straight from
// MySQL (mqtt_channel_mapping + measurement_metadata). Replaces any hardcoded
// device list in the frontend — every device id, measurement and field here is
// exactly what SmartMill's own database currently has wired up.
router.get("/devices", async (req, res) => {
  try {
    const clientId = req.headers["x-client-id"];
    const pool = await getMysqlPool(clientId, undefined, req);
    const [rows] = await pool.query(
      `SELECT m.pom_id, m.measurement, m.equipment_field, md.unit, md.description
       FROM mqtt_channel_mapping m
       LEFT JOIN measurement_metadata md ON md.measurement = m.measurement
       ORDER BY m.pom_id, m.measurement, m.equipment_field`
    );

    const byDevice = new Map();
    for (const r of rows) {
      if (!byDevice.has(r.pom_id)) {
        byDevice.set(r.pom_id, {
          id: r.pom_id,
          // pom_id looks like "<SITE>_POM_<serial>" — the site prefix is the
          // only grouping this data actually supports today.
          site: String(r.pom_id).split("_")[0] || r.pom_id,
          fields: [],
          seen: new Set(),
        });
      }
      const d = byDevice.get(r.pom_id);
      const key = `${r.measurement}|${r.equipment_field}`;
      if (d.seen.has(key)) continue;
      d.seen.add(key);
      d.fields.push({
        key,
        measurement: r.measurement,
        field: r.equipment_field,
        unit: r.unit || "",
        label: r.description || r.measurement,
      });
    }

    const devices = [...byDevice.values()].map((d) => ({ id: d.id, site: d.site, fields: d.fields }));
    return res.json({ devices });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// ── POST /pom/values ──────────────────────────────────────────────────────────
// Body: { points: [{ id, measurement, field }] }
// Returns: { values: { "<id>|<measurement>|<field>": { value, time } } }
// Looks up the latest value for each requested device/measurement/field triple.
// A point missing from the result means no data was written for it recently —
// the caller shows that honestly (a dash) rather than inventing a number.
router.post("/values", async (req, res) => {
  const points = Array.isArray(req.body && req.body.points) ? req.body.points : [];
  if (points.length === 0) return res.json({ values: {} });

  try {
    const clientId = req.headers["x-client-id"];
    const { queryApi, bucket } = await getInfluxClient(clientId, req);

    // Group requested points by measurement so each measurement is one query
    // instead of one query per point.
    const byMeasurement = new Map();
    for (const p of points) {
      if (!p || !p.id || !p.measurement || !p.field) continue;
      if (!byMeasurement.has(p.measurement)) byMeasurement.set(p.measurement, { ids: new Set(), fields: new Set() });
      const g = byMeasurement.get(p.measurement);
      g.ids.add(p.id);
      g.fields.add(p.field);
    }

    const values = {};
    for (const [measurement, g] of byMeasurement) {
      const idClause = [...g.ids].map((id) => `r.id == "${sanitize(id)}"`).join(" or ");
      const fieldClause = [...g.fields].map((f) => `r._field == "${sanitize(f)}"`).join(" or ");
      const flux = `from(bucket: "${sanitize(bucket)}")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "${sanitize(measurement)}" and (${idClause}) and (${fieldClause}))
  |> last()`;

      // eslint-disable-next-line no-await-in-loop
      await new Promise((resolve, reject) => {
        queryApi.queryRows(flux, {
          next(row, tableMeta) {
            const o = tableMeta.toObject(row);
            values[`${o.id}|${measurement}|${o._field}`] = { value: o._value, time: o._time };
          },
          error: reject,
          complete: resolve,
        });
      });
    }

    return res.json({ values });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

module.exports = router;
