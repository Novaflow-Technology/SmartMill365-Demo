const express = require("express");
const { getInfluxClient, getInfluxSchema, sanitize, deviceFilter, getMysqlPool } = require("../helpers/dbConnections");
const admin = require("firebase-admin");

const router = express.Router();

function safeDuration(val, fallback) {
  return /^-?\d+[smhdw]$/.test(String(val)) ? String(val) : fallback;
}

// A client with a single fixed measurement (the common case) filters to it;
// a client set up to scan every measurement (schema.measurement === "")
// omits the filter entirely instead of matching a measurement name that
// doesn't exist.
function measurementFilter(schema) {
  return schema.measurement ? `|> filter(fn: (r) => r["_measurement"] == "${sanitize(schema.measurement)}")` : "";
}

// Real fallback for "Plant" when neither an Influx site_id tag nor a MySQL
// site table exists (SmartMill has neither) — device ids follow
// "<SITE>_POM_<serial>", so the site is decoded straight from the id itself
// rather than left blank or guessed. Same convention /pom/devices already
// relies on for the same reason.
function deriveSiteFromId(id) {
  return String(id || "").split("_")[0] || "";
}

function executeQuery(queryApi, fluxQuery) {
  return new Promise((resolve, reject) => {
    const results = [];
    queryApi.queryRows(fluxQuery, {
      next(row, tableMeta) { results.push(tableMeta.toObject(row)); },
      error(err)           { reject(err); },
      complete()           { resolve(results); },
    });
  });
}

// ── Per-request InfluxDB client + schema ──────────────────────────────────────
// No x-client-id → getInfluxClient/getInfluxSchema fall back to the
// default (Danapac) connection, so untagged requests keep working.
async function getClient(req) {
  const clientId = req.clientId || req.headers["x-client-id"];
  const { queryApi, bucket } = await getInfluxClient(clientId, req);
  const schema = await getInfluxSchema(clientId);
  return { queryApi, bucket, schema };
}

// ── GET /discoveryDevice/devices ───────────────────────────────────────────────
router.get("/devices", async (req, res) => {
  const start = safeDuration(req.query.start, "");
  if (!start) return res.status(400).json({ error: "Missing required param: start" });

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const tag = schema.deviceIdTag;
    const query = `
      from(bucket: "${bucket}")
        |> range(start: ${start})
        ${measurementFilter(schema)}
        ${deviceFilter(schema, null)}
        |> map(fn: (r) => ({_value: r["${tag}"]}))
        |> group()
        |> distinct()
    `;
    const data    = await executeQuery(queryApi, query);
    const devices = [...new Set(data.map((r) => r._value))].filter(Boolean);
    res.json(devices.map((id) => ({ device_id: id })));
  } catch (err) {
    console.error("Discovery /devices error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/meta ──────────────────────────────────────────────────
router.get("/meta", async (req, res) => {
  const start = safeDuration(req.query.start, "");
  if (!start) return res.status(400).json({ error: "Missing required param: start" });

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const tag = schema.deviceIdTag;
    const query = `
      from(bucket: "${bucket}")
        |> range(start: ${start})
        ${measurementFilter(schema)}
        ${deviceFilter(schema, null)}
        |> map(fn: (r) => ({
            _value:      r["${tag}"],
            device_id:   r["${tag}"],
            device_name: if exists r["device_name"] then r["device_name"] else r["${tag}"],
            site_id:     if exists r["site_id"]     then r["site_id"]     else ""
          }))
        |> group()
        |> unique(column: "_value")
    `;
    const data = await executeQuery(queryApi, query);
    const meta = data
      .filter((r) => r.device_id)
      .map((r) => ({
        device_id:   r.device_id   || "",
        device_name: r.device_name || r.device_id || "",
        site_id:     r.site_id     || deriveSiteFromId(r.device_id),
        device_type: schema.deviceTypeVal || "",
      }));
    res.json(meta);
  } catch (err) {
    console.error("Discovery /meta error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/fields/:deviceId ──────────────────────────────────────
router.get("/fields/:deviceId", async (req, res) => {
  const deviceId = sanitize(req.params.deviceId);
  const start    = safeDuration(req.query.start, "");
  if (!start) return res.status(400).json({ error: "Missing required param: start" });

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    // Grouped by measurement AND field, not field alone — a schema scanning
    // every measurement (schema.measurement === "") can have the same field
    // name under several measurements for one device (SmartMill's sterilizer
    // devices report "stp1" under pressure, bar and temperature readings
    // alike), and grouping by field only would silently collapse those into
    // one, dropping the rest.
    const query = `
      from(bucket: "${bucket}")
        |> range(start: ${start})
        ${measurementFilter(schema)}
        ${deviceFilter(schema, deviceId)}
        |> group(columns: ["_measurement", "_field"])
        |> last()
        |> group()
    `;
    const data   = await executeQuery(queryApi, query);
    const seen   = new Set();
    const fields = [];
    for (const r of data) {
      if (!r._field) continue;
      const key = `${r._measurement}|${r._field}`;
      if (seen.has(key)) continue;
      seen.add(key);
      fields.push({ field: r._field, measurement: r._measurement || schema.measurement });
    }
    res.json({ device_id: deviceId, fields });
  } catch (err) {
    console.error(`Discovery /fields/${deviceId} error:`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/realtime/:deviceId ────────────────────────────────────
router.get("/realtime/:deviceId", async (req, res) => {
  const deviceId = sanitize(req.params.deviceId);
  const { fields } = req.query;

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    let fieldFilter = "";
    if (fields) {
      const conditions = String(fields)
        .split(",")
        .map((f) => `r["_field"] == "${sanitize(f.trim())}"`)
        .join(" or ");
      fieldFilter = `|> filter(fn: (r) => ${conditions})`;
    }

    // Grouped by measurement AND field — a schema scanning every measurement
    // can have the same field name under several measurements for one
    // device (SmartMill's "stp1" exists under pressure, bar and temperature
    // readings alike). Grouping by field alone would pick just one of those
    // per last(), silently discarding the others as if they were duplicates.
    const query = `
      from(bucket: "${bucket}")
        |> range(start: -15m)
        ${measurementFilter(schema)}
        ${deviceFilter(schema, deviceId)}
        ${fieldFilter}
        |> group(columns: ["_field", "_measurement", "${schema.deviceIdTag}"])
        |> last()
        |> group()
    `;
    const data        = await executeQuery(queryApi, query);
    const currentTime = new Date().toISOString();
    res.json(data.map((r) => ({
      device_id:    r[schema.deviceIdTag] || deviceId,
      measurement:  r._measurement,
      field:        r._field,
      value:        r._value,
      time:         r._time,
      retrieved_at: currentTime,
    })));
  } catch (err) {
    console.error(`Discovery /realtime/${deviceId} error:`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/history/:deviceId ─────────────────────────────────────
router.get("/history/:deviceId", async (req, res) => {
  const deviceId    = sanitize(req.params.deviceId);
  const field       = sanitize(req.query.field);
  // Optional — disambiguates a field name that exists under more than one
  // measurement for the same device (only relevant when schema.measurement
  // is "" and the caller got this from /fields, which now reports it).
  const measurement = sanitize(req.query.measurement);
  const start    = safeDuration(req.query.start,  "");
  const window   = safeDuration(req.query.window, "");
  const timezone = parseInt(req.query.timezone, 10) || 0;

  if (!field || !start || !window) {
    return res.status(400).json({ error: "Missing required params: field, start, window" });
  }

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const tzOffsetMs = timezone * 60 * 1000;
    const toLabel = (iso) => {
      const d = new Date(new Date(iso).getTime() + tzOffsetMs);
      return `${String(d.getUTCHours()).padStart(2,"0")}:${String(d.getUTCMinutes()).padStart(2,"0")}`;
    };
    const measFilter = measurement
      ? `|> filter(fn: (r) => r["_measurement"] == "${measurement}")`
      : measurementFilter(schema);

    const query = `
      from(bucket: "${bucket}")
        |> range(start: ${start})
        ${measFilter}
        ${deviceFilter(schema, deviceId)}
        |> filter(fn: (r) => r["_field"] == "${field}")
        |> aggregateWindow(every: ${window}, fn: last, createEmpty: false)
        |> sort(columns: ["_time"])
        |> yield(name: "history")
    `;
    const data = await executeQuery(queryApi, query);
    res.json({
      device_id: deviceId,
      field,
      measurement: measurement || schema.measurement,
      start,
      window,
      timezone: `UTC+${timezone / 60}`,
      data: data.map((r) => ({
        time:      r._time,
        timestamp: new Date(r._time).getTime(),
        value:     r._value,
        label:     toLabel(r._time),
      })),
    });
  } catch (err) {
    console.error(`Discovery /history/${deviceId} error:`, err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── POST /discoveryDevice/syncToFacility ──────────────────────────────────────
router.post("/syncToFacility", async (req, res) => {
  const clientId = req.clientId || req.headers["x-client-id"];
  if (!clientId) return res.status(400).json({ error: "Missing x-client-id" });

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const tag = schema.deviceIdTag;
    const query = `
      from(bucket: "${bucket}")
        |> range(start: -30d)
        ${measurementFilter(schema)}
        ${deviceFilter(schema, null)}
        |> map(fn: (r) => ({
            _value:      r["${tag}"],
            device_id:   r["${tag}"],
            device_name: if exists r["device_name"] then r["device_name"] else r["${tag}"],
            site_id:     if exists r["site_id"]     then r["site_id"]     else ""
          }))
        |> group()
        |> unique(column: "_value")
    `;
    const data = await executeQuery(queryApi, query);
    const devices = data.filter((r) => r.device_id).map((r) => ({
      device_id:   r.device_id   || "",
      device_name: r.device_name || r.device_id || "",
      site_id:     r.site_id     || deriveSiteFromId(r.device_id),
      client_id:   clientId,
    }));

    // Write to facilities collection
    const db = admin.firestore();
    const batch = db.batch();
    for (const d of devices) {
      const ref = db.collection("facilities").doc(`${clientId}_${d.device_id}`);
      batch.set(ref, { ...d, updatedAt: admin.firestore.FieldValue.serverTimestamp() }, { merge: true });
    }
    await batch.commit();
    res.json({ ok: true, synced: devices.length });
  } catch (err) {
    console.error("syncToFacility error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/enriched ─────────────────────────────────────────────
// Returns InfluxDB device list merged with MySQL enrichment (if configured).
// Safe: if MySQL is not configured or fails, returns InfluxDB-only data with
// empty MySQL columns — data is NEVER lost.
router.get("/enriched", async (req, res) => {
  const clientId = req.clientId || req.headers["x-client-id"];
  const start = safeDuration(req.query.start || "-30d", "-30d");

  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const tag = schema.deviceIdTag;

    // ── Step 1: Fetch distinct device IDs from InfluxDB ───────────────────────
    // schema.tagValues is an index/metadata lookup — much faster than a raw
    // range-scan over every point in the window, which was timing out on
    // slower/remote Influx hosts. device_name/site_id aren't in the tag
    // index, so they fall back to device_id/"" same as before when absent.
    let metaQuery = `
      import "influxdata/influxdb/schema"
      schema.tagValues(bucket: "${bucket}", tag: "${tag}")
    `;
    if (schema.deviceTypeTag && schema.deviceTypeVal) {
      metaQuery = `
        import "influxdata/influxdb/schema"
        schema.tagValues(
          bucket: "${bucket}",
          tag: "${tag}",
          predicate: (r) => r._measurement == "${schema.measurement}" and r["${schema.deviceTypeTag}"] == "${sanitize(schema.deviceTypeVal)}",
          start: ${start}
        )
      `;
    }
    const metaRows = await executeQuery(queryApi, metaQuery);
    const influxDevices = [...new Set(metaRows.map((r) => r._value || r[tag]).filter(Boolean))]
      .map((id) => ({ device_id: id, device_name: id, site_id: deriveSiteFromId(id) }));

    // ── Step 2: Attempt MySQL enrichment (safe — never throws) ────────────────
    let mysqlMap = {}; // keyed by device_id

    try {
      if (clientId) {
        const pool = await getMysqlPool(clientId, null, req);
        const [rows] = await pool.query(`
          SELECT
            d.device_id,
            d.device_name          AS mysql_device_name,
            m.machine_id,
            m.machine_name,
            pl.line_id,
            pl.line_name,
            z.zone_id,
            z.zone_name,
            s.site_id              AS mysql_site_id,
            s.site_name,
            pd.device_id           AS parent_id,
            pd.device_name         AS parent_name
          FROM device d
          LEFT JOIN machine m          ON d.machine_code  = m.machine_code
          LEFT JOIN production_line pl ON m.line_code     = pl.line_code
          LEFT JOIN zone z             ON m.zone_code     = z.zone_code
          LEFT JOIN site s             ON z.site_code     = s.site_code
          LEFT JOIN device pd          ON d.parent_device_code = pd.device_code
          WHERE d.is_active = 1
        `);
        for (const row of rows) {
          mysqlMap[row.device_id] = row;
        }
      }
    } catch (mysqlErr) {
      // MySQL not configured or failed — continue with InfluxDB-only data
      console.warn(`[enriched] MySQL enrichment skipped for ${clientId}: ${mysqlErr.message}`);
    }

    // ── Step 3: Merge InfluxDB + MySQL — InfluxDB data always wins ────────────
    const enriched = influxDevices.map((d) => {
      const m = mysqlMap[d.device_id] || {};
      return {
        device_id:    d.device_id,
        device_name:  d.device_name,
        site_id:      d.site_id,
        // MySQL enrichment — empty string when not available
        machine_id:   m.machine_id   || "",
        machine_name: m.machine_name || "",
        line_id:      m.line_id      || "",
        line_name:    m.line_name    || "",
        zone_id:      m.zone_id      || "",
        zone_name:    m.zone_name    || "",
        site_name:    m.site_name    || d.site_id,
        parent_id:    m.parent_id    || "",
        parent_name:  m.parent_name  || "",
      };
    });

    res.json(enriched);
  } catch (err) {
    console.error("Discovery /enriched error:", err.message);
    res.status(500).json({ error: err.message });
  }
});

// ── GET /discoveryDevice/test/connection ───────────────────────────────────────
router.get("/test/connection", async (req, res) => {
  try {
    const { queryApi, bucket, schema } = await getClient(req);
    const query = `
      from(bucket: "${bucket}")
        |> range(start: -1h)
        ${measurementFilter(schema)}
        |> limit(n: 1)
    `;
    const data = await executeQuery(queryApi, query);
    res.json({
      status:      "Connected",
      message:     schema.measurement ? `InfluxDB connected — measurement: ${schema.measurement}` : "InfluxDB connected — scanning every measurement in the bucket",
      bucket,
      measurement: schema.measurement,
      sampleData:  data,
    });
  } catch (err) {
    res.status(500).json({ status: "Failed", error: err.message });
  }
});


module.exports = router;
