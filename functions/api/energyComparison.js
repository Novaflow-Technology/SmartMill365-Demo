const express = require("express");
const mysql = require("mysql2");
const { getMysqlPoolSafe } = require("../helpers/dbConnections");

const router = express.Router();

// Resolve the pool: client's own MySQL when x-client-id is present (e.g. Thong
// Guan reads its own Overall_* tables); otherwise the default Danapac pool —
// so untagged Danapac/Demo requests are unchanged.
async function poolFor(req) {
  const clientId = req.clientId || req.headers["x-client-id"];
  if (!clientId) return pool;
  return getMysqlPoolSafe(clientId, undefined, req);
}

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
}).promise();

// List distinct device_ids across all tables (debug helper)
router.get("/devices", async (req, res) => {
  const query = `
    SELECT 'yearly' AS source, device_id FROM Overall_yearly_energy_consumption
    UNION
    SELECT 'monthly', device_id FROM Overall_monthly_energy_consumption
    UNION
    SELECT 'daily', device_id FROM Overall_daily_energy_consumption
    UNION
    SELECT 'hourly', device_id FROM Overall_hourly_energy_consumption
    ORDER BY source, device_id
  `;
  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query);
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

// Yearly energy consumption for a device (year-over-year chart)
router.get("/yearly/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const query = `
    SELECT year, SUM(energy_consumption_kWh) AS energy_consumption_kWh
    FROM Overall_yearly_energy_consumption
    WHERE device_id = ?
    GROUP BY year
    ORDER BY year ASC
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id]);
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

// Monthly energy consumption for a device (monthly chart)
router.get("/monthly/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const query = `
    SELECT year, month, SUM(energy_consumption_kWh) AS energy_consumption_kWh
    FROM Overall_monthly_energy_consumption
    WHERE device_id = ?
    GROUP BY year, month
    ORDER BY year ASC, month ASC
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id]);
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

// Daily energy consumption for a device (daily chart)
// Optional query param: ?scope=month  → filter by current month instead of last 31 days
router.get("/daily/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const { scope } = req.query;
  const dateFilter = scope === "month"
    ? "YEAR(date) = YEAR(CONVERT_TZ(NOW(), '+00:00', '+08:00')) AND MONTH(date) = MONTH(CONVERT_TZ(NOW(), '+00:00', '+08:00'))"
    : "date >= DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL 31 DAY)";

  const query = `
    SELECT DATE(date) AS date,
           SUM(energy_consumption_kWh) AS energy_consumption_kWh,
           MAX(max_demand_kW) AS max_demand_kW
    FROM Overall_daily_energy_consumption
    WHERE device_id = ?
      AND ${dateFilter}
    GROUP BY DATE(date)
    ORDER BY DATE(date) ASC
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id]);
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

// Hourly energy consumption for a device (hourly chart with previous day comparison)
// Accepts optional ?date=YYYY-MM-DD query param; defaults to today (MYT)
router.get("/hourly/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const { date } = req.query;
  const dateExpr = date ? "?" : "DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))";
  const params = date
    ? [device_id, date, device_id, date]
    : [device_id, device_id];

  const query = `
    SELECT
      today.hour_time AS event_time,
      today.energy_consumption_kWh AS today_kWh,
      yesterday.energy_consumption_kWh AS yesterday_kWh
    FROM (
      SELECT TIME(event_time) AS hour_time, SUM(energy_consumption_kWh) AS energy_consumption_kWh
      FROM Overall_hourly_energy_consumption
      WHERE device_id = ?
        AND DATE(event_time) = ${dateExpr}
      GROUP BY TIME(event_time)
    ) today
    LEFT JOIN (
      SELECT TIME(event_time) AS hour_time, SUM(energy_consumption_kWh) AS energy_consumption_kWh
      FROM Overall_hourly_energy_consumption
      WHERE device_id = ?
        AND DATE(event_time) = ${dateExpr} - INTERVAL 1 DAY
      GROUP BY TIME(event_time)
    ) yesterday
      ON today.hour_time = yesterday.hour_time
    ORDER BY today.hour_time ASC
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, params);
    if (results && results.length > 0) return res.json(results);

    // Solar meters: Overall_hourly_energy_generation (timestamp + energy_generated_kWh)
    const genDateExpr = date ? "?" : "DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))";
    const genParams = date
      ? [device_id, date, device_id, date]
      : [device_id, device_id];
    const genQuery = `
      SELECT
        today.hour_time AS event_time,
        today.energy_generated_kWh AS today_kWh,
        yesterday.energy_generated_kWh AS yesterday_kWh
      FROM (
        SELECT TIME(\`timestamp\`) AS hour_time, SUM(energy_generated_kWh) AS energy_generated_kWh
        FROM Overall_hourly_energy_generation
        WHERE device_id = ?
          AND DATE(\`timestamp\`) = ${genDateExpr}
        GROUP BY TIME(\`timestamp\`)
      ) today
      LEFT JOIN (
        SELECT TIME(\`timestamp\`) AS hour_time, SUM(energy_generated_kWh) AS energy_generated_kWh
        FROM Overall_hourly_energy_generation
        WHERE device_id = ?
          AND DATE(\`timestamp\`) = ${genDateExpr} - INTERVAL 1 DAY
        GROUP BY TIME(\`timestamp\`)
      ) yesterday
        ON today.hour_time = yesterday.hour_time
      ORDER BY today.hour_time ASC
    `;
    try {
      const [genResults] = await cpool.query(genQuery, genParams);
      return res.json(genResults);
    } catch (ge) {
      console.warn(`[energyComparison/hourly] generation fallback failed for ${device_id}: ${ge.message}`);
      return res.json(results);
    }
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

router.get("/interval-demand/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const { date } = req.query;

  let query;
  let params;

  if (date) {
    query = `
      SELECT event_time, max_demand_kW
      FROM Overall_hourly_energy_consumption
      WHERE device_id = ? AND DATE(event_time) = ?
      ORDER BY event_time ASC
    `;
    params = [device_id, date];
  } else {
    query = `
      SELECT event_time, max_demand_kW
      FROM Overall_hourly_energy_consumption
      WHERE device_id = ?
      ORDER BY event_time DESC
      LIMIT 48
    `;
    params = [device_id];
  }

  try {
    const cpool = await poolFor(req);
    let [results] = await cpool.query(query, params);
    if (!date && results.length > 0) {
      results.reverse();
    }
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

router.get("/usage/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const query = `
    SELECT
      COALESCE(d.energy_consumption_kWh, 0) AS daily_usage,
      COALESCE(d.carbon_emission_kgCO2e, 0) AS daily_emission,
      COALESCE(m.energy_consumption_kWh, 0) AS monthly_usage,
      COALESCE(y.energy_consumption_kWh, 0) AS yearly_usage
    FROM (SELECT 1) AS dummy
    LEFT JOIN (
      SELECT energy_consumption_kWh, carbon_emission_kgCO2e
      FROM Overall_daily_energy_consumption
      WHERE device_id = ?
      ORDER BY date DESC
      LIMIT 1
    ) d ON 1=1
    LEFT JOIN (
      SELECT energy_consumption_kWh
      FROM Overall_monthly_energy_consumption
      WHERE device_id = ?
      ORDER BY year DESC, month DESC
      LIMIT 1
    ) m ON 1=1
    LEFT JOIN (
      SELECT energy_consumption_kWh
      FROM Overall_yearly_energy_consumption
      WHERE device_id = ?
      ORDER BY year DESC
      LIMIT 1
    ) y ON 1=1
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id, device_id, device_id]);
    if (results.length === 0) {
      return res.json({ daily_usage: 0, daily_emission: 0, monthly_usage: 0, yearly_usage: 0 });
    }
    return res.json(results[0]);
  } catch (error) {
    return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
  }
});

// Latest monthly average power factor for a device. Restored to keep parity with
// the Danapac repo (its TNB E3 Bill Simulator calls this); uses the default
// Danapac pool, unchanged from the original Danapac implementation.
router.get("/power-factor/:device_id", async (req, res) => {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const query = `
    SELECT power_factor_avg
    FROM Overall_monthly_energy_consumption
    WHERE device_id = ?
      AND year = YEAR(CURDATE())
      AND month = MONTH(CURDATE())
    LIMIT 1
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id]);

    if (results.length === 0) {
      return res.json({ power_factor: 0 });
    }

    return res.json({
      power_factor: results[0].power_factor_avg ?? 0,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

// `year`/`month` (optional) let callers browsing a past MD Insight Report
// pull that period's max demand instead of always the current month;
// omitted -> same current-month behaviour every other caller (TNB E3 Bill
// Simulator, Max Demand Monitoring) already relies on.
router.get("/tnb-bill-simulator/:device_id", async (req, res) => {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const now = new Date();
  const year = /^\d{4}$/.test(req.query.year || "") ? Number(req.query.year) : now.getFullYear();
  const month = /^(0?[1-9]|1[0-2])$/.test(req.query.month || "") ? Number(req.query.month) : now.getMonth() + 1;

  const query = `
    SELECT power_factor_avg, max_demand_kW, peak_usage_kWh, off_peak_usage_kWh
    FROM Overall_monthly_energy_consumption
    WHERE device_id = ?
      AND year = ?
      AND month = ?
    LIMIT 1
  `;

  try {
    const cpool = await poolFor(req);
    const [results] = await cpool.query(query, [device_id, year, month]);

    if (results.length === 0) {
      return res.json({ power_factor: 0, max_demand_kW: 0, peak_usage_kWh: 0, off_peak_usage_kWh: 0 });
    }

    // DECIMAL columns come back from mysql2 as strings (not JS numbers) unless
    // the pool sets decimalNumbers:true — neither the default nor per-client
    // pool does, so coerce explicitly. Otherwise callers doing `.toDouble()`
    // client-side (Flutter) crash with NoSuchMethodError on the string value.
    return res.json({
      power_factor: Number(results[0].power_factor_avg) || 0,
      max_demand_kW: Number(results[0].max_demand_kW) || 0,
      peak_usage_kWh: Number(results[0].peak_usage_kWh) || 0,
      off_peak_usage_kWh: Number(results[0].off_peak_usage_kWh) || 0,
    });
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

// Daily bill log — one row per day, for the TNB Bill Simulator Data Logger.
// Reads the exact same Overall_daily_energy_consumption columns the monthly
// bill simulator sums from (peak_usage_kWh / off_peak_usage_kWh /
// power_factor_avg / max_demand_kW), just left at daily grain instead of
// pre-aggregated by month, so the frontend can show/export a real day-by-day
// breakdown instead of a single MTD figure.
// ?days=1-180 (default 30) controls how far back to read, anchored on MYT
// "today" — matches the ?scope=month convention used by /daily/:device_id
// above. power_factor_avg is averaged with zero readings excluded: several
// sub-meters log 0 for PF (no PF sensor wired), which would otherwise drag a
// real day's average down to near-zero.
router.get("/daily-bill-log/:device_id", async (req, res) => {
  const { device_id } = req.params;
  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const days = Math.min(180, Math.max(1, parseInt(req.query.days, 10) || 30));

  const query = `
    SELECT DATE_FORMAT(date, '%Y-%m-%d') AS date,
           SUM(energy_consumption_kWh) AS energy_consumption_kWh,
           SUM(peak_usage_kWh) AS peak_usage_kWh,
           SUM(off_peak_usage_kWh) AS off_peak_usage_kWh,
           MAX(max_demand_kW) AS max_demand_kW,
           AVG(NULLIF(power_factor_avg, 0)) AS power_factor_avg,
           SUM(carbon_emission_kgCO2e) AS carbon_emission_kgCO2e
    FROM Overall_daily_energy_consumption
    WHERE device_id = ?
      AND date >= DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL ? DAY)
    GROUP BY date
    ORDER BY date ASC
  `;

  try {
    const cpool = await poolFor(req);
    const [rows] = await cpool.query(query, [device_id, days]);
    const data = rows.map((r) => ({
      date: r.date,
      energy_consumption_kWh: Number(r.energy_consumption_kWh) || 0,
      peak_usage_kWh: Number(r.peak_usage_kWh) || 0,
      off_peak_usage_kWh: Number(r.off_peak_usage_kWh) || 0,
      max_demand_kW: Number(r.max_demand_kW) || 0,
      power_factor_avg: Number(r.power_factor_avg) || 0,
      carbon_emission_kgCO2e: Number(r.carbon_emission_kgCO2e) || 0,
    }));
    return res.json(data);
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

// Per-device energy + carbon totals for a period (Energy Overview source).
// Restored from the Danapac repo to keep our backend a complete superset. The
// original referenced an undefined helper/constant (getMysqlPool/DB) and would
// 500 — fixed to use the default Danapac pool. Left ungated for now: Thong
// Guan's Energy Overview is intentionally not wired here yet.
router.get("/data/:period", async (req, res) => {
  const { period } = req.params;

  const setQuery = `SET @today_myt := DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'));`;

  let table;
  let whereClause;
  if (period === "monthly") {
    table = "Overall_monthly_energy_consumption";
    whereClause = "year = YEAR(@today_myt) AND month = MONTH(@today_myt)";
  } else if (period === "yearly") {
    table = "Overall_yearly_energy_consumption";
    whereClause = "year = YEAR(@today_myt)";
  } else {
    table = "Overall_daily_energy_consumption";
    whereClause = "DATE(date) = @today_myt";
  }

  const mainQuery = `
    SELECT device_id AS device,
      SUM(energy_consumption_kWh) AS total_energy,
      SUM(energy_consumption_kWh) AS energy_consumption_kWh,
      SUM(carbon_emission_kgCO2e) AS carbon_emission_kgCO2e
    FROM ${table}
    WHERE ${whereClause}
    GROUP BY device_id
  `;

  try {
    await pool.query(setQuery);
    const [results] = await pool.query(mainQuery);
    return res.json(results);
  } catch (error) {
    return res.status(500).json({ error: "Query error", message: error.message });
  }
});



module.exports = router;
