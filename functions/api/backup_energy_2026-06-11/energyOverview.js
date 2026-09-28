const express = require("express");

// eslint-disable-next-line new-cap
const router = express.Router();
const mysql = require("mysql2");
const { InfluxDB } = require("@influxdata/influxdb-client");

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
});

const influxClient = new InfluxDB({
  url: "",
  token: "",
});
const influxQueryApi = influxClient.getQueryApi("Novaflow");

function runInfluxQuery(flux) {
  return new Promise((resolve, reject) => {
    const rows = [];
    influxQueryApi.queryRows(flux, {
      next(row, meta) { rows.push(meta.toObject(row)); },
      error: reject,
      complete() { resolve(rows); },
    });
  });
}

async function influxEnergyFallback(period) {
  let rangeStart = "-1d";
  if (period === "monthly") rangeStart = "-30d";
  if (period === "yearly") rangeStart = "-365d";

  // Get first and last Edel per device to compute consumption
  const firstQ = `
    from(bucket: "ENERGY_DEMO")
      |> range(start: ${rangeStart})
      |> filter(fn: (r) => r._measurement == "power_meter" and r._field == "Edel")
      |> first()
      |> group(columns: ["device_name"])
  `;
  const lastQ = `
    from(bucket: "ENERGY_DEMO")
      |> range(start: ${rangeStart})
      |> filter(fn: (r) => r._measurement == "power_meter" and r._field == "Edel")
      |> last()
      |> group(columns: ["device_name"])
  `;
  const [firstRows, lastRows] = await Promise.all([runInfluxQuery(firstQ), runInfluxQuery(lastQ)]);
  const firstMap = {};
  firstRows.forEach((r) => { if (r.device_name) firstMap[r.device_name] = r._value ?? 0; });
  const result = [];
  lastRows.forEach((r) => {
    if (!r.device_name) return;
    const first = firstMap[r.device_name] ?? 0;
    const last  = r._value ?? 0;
    const energy = Math.max(0, last - first);
    result.push({ device: r.device_name, total_energy: parseFloat(energy.toFixed(3)), energy1: last, energy2: first });
  });
  return result;
}

router.get("/data/:period", (req, res) => {
  const { period } = req.params;

  let setQuery = `SET @today_myt := DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'));`;
  let referenceDateSQL = "";
  let mainQuery = "";

  if (period === "monthly") {
    referenceDateSQL = `SET @ref_date := LAST_DAY(DATE_SUB(@today_myt, INTERVAL 1 MONTH));`;
  } else if (period === "yearly") {
    referenceDateSQL = `SET @ref_date := DATE(CONCAT(YEAR(@today_myt) - 1, '-12-31'));`;
  } else {
    referenceDateSQL = `SET @ref_date := DATE_SUB(@today_myt, INTERVAL 1 DAY);`;
  }

  if (period === "daily") {
    mainQuery = `
      WITH today_max AS (
        SELECT device_id, MAX(energy_edel) AS energy1
        FROM energy_data
        WHERE timestamp >= @today_myt
          AND timestamp < DATE_ADD(@today_myt, INTERVAL 1 DAY)
        GROUP BY device_id
      ),
      summary_max AS (
        SELECT dds.device_id, dds.energy_edel AS energy2
        FROM daily_device_summary dds
        WHERE DATE(dds.timestamp) = @ref_date
      )
    SELECT 
      COALESCE(t.device_id, s.device_id) AS device,
      COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) AS energy1,
      COALESCE(s.energy2, 0) AS energy2,
      COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) - COALESCE(s.energy2, 0) AS total_energy
    FROM today_max t
    LEFT JOIN summary_max s ON t.device_id = s.device_id

    UNION

    SELECT 
      COALESCE(t.device_id, s.device_id) AS device,
      COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) AS energy1,
      COALESCE(s.energy2, 0) AS energy2,
      COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) - COALESCE(s.energy2, 0) AS total_energy
    FROM summary_max s
    LEFT JOIN today_max t ON s.device_id = t.device_id
    WHERE t.device_id IS NULL;
    `;
  } else {
    mainQuery = `
      WITH raw_today AS (
        SELECT device_id, MAX(energy_edel) AS energy1
        FROM energy_data
        WHERE timestamp >= @today_myt
          AND timestamp < DATE_ADD(@today_myt, INTERVAL 1 DAY)
        GROUP BY device_id
      ),
      all_devices AS (
        SELECT device_id FROM energy_data
        UNION
        SELECT device_id FROM daily_device_summary
      ),
      today_max AS (
        SELECT 
          d.device_id,
          COALESCE(NULLIF(r.energy1, 0), fallback.energy_edel, 0) AS energy1
        FROM all_devices d
        LEFT JOIN raw_today r ON d.device_id = r.device_id
        LEFT JOIN LATERAL (
          SELECT energy_edel
          FROM daily_device_summary
          WHERE device_id = d.device_id AND energy_edel != 0
          ORDER BY timestamp DESC
          LIMIT 1
        ) fallback ON TRUE
      ),
      summary_max AS (
        SELECT d.device_id,
              COALESCE(dds.energy_edel, 0) AS energy2
        FROM all_devices d
        LEFT JOIN daily_device_summary dds
          ON d.device_id = dds.device_id AND dds.timestamp = @ref_date
      )
      SELECT 
        d.device_id AS device,
        COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) AS energy1,
        COALESCE(s.energy2, 0) AS energy2,
        COALESCE(NULLIF(t.energy1, 0), s.energy2, 0) - COALESCE(s.energy2, 0) AS total_energy
      FROM all_devices d
      LEFT JOIN today_max t ON d.device_id = t.device_id
      LEFT JOIN summary_max s ON d.device_id = s.device_id;
    `;
  }

  pool.query(setQuery, (err) => {
    if (err)
      return res
        .status(500)
        .json({ error: "Set date error", message: err.message });

    pool.query(referenceDateSQL, (err2) => {
      if (err2)
        return res
          .status(500)
          .json({ error: "Ref date error", message: err2.message });

      pool.query(mainQuery, async (error, results) => {
        if (error) {
          return res
            .status(500)
            .json({ error: "Main query error", message: error.message });
        }
        // If MySQL has no data, fallback to InfluxDB
        if (!results || results.length === 0) {
          try {
            const influxData = await influxEnergyFallback(period);
            return res.json(influxData);
          } catch (e) {
            return res.json([]);
          }
        }
        return res.json(results);
      });
    });
  });
});

module.exports = router;
