const express = require("express");

const router = express.Router();
const mysql = require("mysql2");
const { getInfluxClient, getInfluxSchema, deviceFilter, ENERGY_FIELD_NAMES, getMysqlPoolSafe } = require("../helpers/dbConnections");

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
});

// ── Per-request InfluxDB client + schema ──────────────────────────────────────
// No x-client-id → getInfluxClient/getInfluxSchema fall back to the
// default (Danapac) connection, so untagged requests keep working.
async function getInflux(req) {
  const clientId = req.clientId || req.headers["x-client-id"];
  const { queryApi, bucket } = await getInfluxClient(clientId, req);
  const schema = await getInfluxSchema(clientId);
  return { queryApi, bucket, schema };
}

// ── Per-request MySQL pool ────────────────────────────────────────────────────
// Resolves the client's MySQL pool from integration_config (host/port/username/
// database). If the client has no MySQL config, falls back to the default
// (Danapac) pool so existing single-tenant behaviour keeps working.
async function getMysql(req) {
  const clientId = req.clientId || req.headers["x-client-id"];
  return getMysqlPoolSafe(clientId, undefined, req);
}

/** True when every period row is missing / zero / negative (no usable reading yet). */
function isZeroTotals(rows) {
  return !rows || rows.length === 0 || rows.every((r) => !r.total_energy || Number(r.total_energy) <= 0);
}

/**
 * Solar / generation meters live in Overall_hourly_energy_generation
 * (energy_generated_kWh), not Overall_*_energy_consumption.
 * Used when consumption totals are empty for the device.
 */
async function totalsFromGeneration(cpool, deviceId, dateStr) {
  const hasDate = typeof dateStr === "string" && /^\d{4}-\d{2}-\d{2}$/.test(dateStr);
  let dailySql;
  let dailyParams;
  if (hasDate) {
    dailySql = `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
                FROM Overall_hourly_energy_generation
                WHERE device_id = ? AND DATE(\`timestamp\`) = ?`;
    dailyParams = [deviceId, dateStr];
  } else {
    // Latest day <= today (matches consumption-card "latest available" behaviour)
    dailySql = `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
                FROM Overall_hourly_energy_generation
                WHERE device_id = ? AND DATE(\`timestamp\`) = (
                  SELECT MAX(DATE(\`timestamp\`))
                  FROM Overall_hourly_energy_generation
                  WHERE device_id = ? AND DATE(\`timestamp\`) <= CURDATE()
                )`;
    dailyParams = [deviceId, deviceId];
  }

  const refYear = hasDate ? Number(dateStr.slice(0, 4)) : null;
  const refMonth = hasDate ? Number(dateStr.slice(5, 7)) : null;

  const monthlySql = hasDate
    ? `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
       FROM Overall_hourly_energy_generation
       WHERE device_id = ? AND YEAR(\`timestamp\`) = ? AND MONTH(\`timestamp\`) = ?`
    : `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
       FROM Overall_hourly_energy_generation
       WHERE device_id = ? AND YEAR(\`timestamp\`) = YEAR(CURDATE()) AND MONTH(\`timestamp\`) = MONTH(CURDATE())`;
  const monthlyParams = hasDate ? [deviceId, refYear, refMonth] : [deviceId];

  const yearlySql = hasDate
    ? `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
       FROM Overall_hourly_energy_generation
       WHERE device_id = ? AND YEAR(\`timestamp\`) = ?`
    : `SELECT COALESCE(SUM(energy_generated_kWh), 0) AS e
       FROM Overall_hourly_energy_generation
       WHERE device_id = ? AND YEAR(\`timestamp\`) = YEAR(CURDATE())`;
  const yearlyParams = hasDate ? [deviceId, refYear] : [deviceId];

  const [dQ, mQ, yQ] = await Promise.all([
    cpool.query(dailySql, dailyParams),
    cpool.query(monthlySql, monthlyParams),
    cpool.query(yearlySql, yearlyParams),
  ]);
  const daily = dQ[0]?.[0];
  const monthly = mQ[0]?.[0];
  const yearly = yQ[0]?.[0];
  return [
    { period: "daily", total_energy: Number(daily?.e ?? 0), daily_emission: 0 },
    { period: "monthly", total_energy: Number(monthly?.e ?? 0) },
    { period: "yearly", total_energy: Number(yearly?.e ?? 0) },
  ];
}

/**
 * Chart series from generation table — same [{label,value}] shape as consumption.
 * Column is `timestamp` (not event_time) and `energy_generated_kWh`.
 * dateStr (hourly) / monthStr (daily) pin the series to a specific calendar
 * day / month instead of the default "today" / "last 31 days" windows.
 */
async function dataFromGeneration(cpool, topic, period, rolling, dateStr, monthStr) {
  const myt = "CONVERT_TZ(NOW(), '+00:00', '+08:00')";
  let sql = "";
  let sqlParams = [topic];
  if (period === "daily" && monthStr) {
    sql = `SELECT DATE_FORMAT(d, '%e/%c') AS label, SUM(v) AS value FROM (
              SELECT DATE(\`timestamp\`) AS d, energy_generated_kWh AS v
              FROM Overall_hourly_energy_generation
              WHERE device_id = ?
                AND DATE_FORMAT(\`timestamp\`, '%Y-%m') = ?
            ) x
            GROUP BY d ORDER BY d ASC`;
    sqlParams = [topic, monthStr];
  } else if (period === "daily") {
    sql = `SELECT DATE_FORMAT(d, '%e/%c') AS label, SUM(v) AS value FROM (
              SELECT DATE(\`timestamp\`) AS d, energy_generated_kWh AS v
              FROM Overall_hourly_energy_generation
              WHERE device_id = ?
                AND \`timestamp\` >= DATE_SUB(DATE(${myt}), INTERVAL 31 DAY)
            ) x
            GROUP BY d ORDER BY d ASC`;
  } else if (period === "monthly") {
    sql = `SELECT DATE_FORMAT(STR_TO_DATE(CONCAT(YEAR(\`timestamp\`), '-', LPAD(MONTH(\`timestamp\`), 2, '0'), '-01'), '%Y-%m-%d'), '%b') AS label,
                  SUM(energy_generated_kWh) AS value
           FROM Overall_hourly_energy_generation
           WHERE device_id = ? AND YEAR(\`timestamp\`) = YEAR(${myt})
           GROUP BY YEAR(\`timestamp\`), MONTH(\`timestamp\`)
           ORDER BY YEAR(\`timestamp\`) ASC, MONTH(\`timestamp\`) ASC`;
  } else if (period === "yearly") {
    sql = `SELECT CAST(YEAR(\`timestamp\`) AS CHAR) AS label,
                  SUM(energy_generated_kWh) AS value
           FROM Overall_hourly_energy_generation
           WHERE device_id = ?
           GROUP BY YEAR(\`timestamp\`) ORDER BY YEAR(\`timestamp\`) ASC`;
  } else if (period === "hourly" && dateStr) {
    sql = `SELECT DATE_FORMAT(\`timestamp\`, '%H:00') AS label,
                  SUM(energy_generated_kWh) AS value
           FROM Overall_hourly_energy_generation
           WHERE device_id = ?
             AND DATE(\`timestamp\`) = ?
           GROUP BY DATE_FORMAT(\`timestamp\`, '%H:00')
           ORDER BY MIN(\`timestamp\`) ASC`;
    sqlParams = [topic, dateStr];
  } else if (period === "hourly" && rolling) {
    sql = `SELECT DATE_FORMAT(\`timestamp\`, '%H:00') AS label,
                  SUM(energy_generated_kWh) AS value
           FROM Overall_hourly_energy_generation
           WHERE device_id = ?
             AND \`timestamp\` >  DATE_SUB(${myt}, INTERVAL 24 HOUR)
             AND \`timestamp\` <= ${myt}
           GROUP BY DATE(\`timestamp\`), DATE_FORMAT(\`timestamp\`, '%H:00')
           ORDER BY DATE(\`timestamp\`) ASC, MIN(\`timestamp\`) ASC`;
  } else if (period === "hourly") {
    sql = `SELECT DATE_FORMAT(\`timestamp\`, '%H:00') AS label,
                  SUM(energy_generated_kWh) AS value
           FROM Overall_hourly_energy_generation
           WHERE device_id = ?
             AND DATE(\`timestamp\`) = DATE(${myt})
           GROUP BY DATE_FORMAT(\`timestamp\`, '%H:00')
           ORDER BY MIN(\`timestamp\`) ASC`;
  }
  if (!sql) return null;
  const [rows] = await cpool.query(sql, sqlParams);
  return rows.map((r) => ({ label: String(r.label), value: Number(r.value) || 0 }));
}

function runInfluxQuery(queryApi, flux) {
  return new Promise((resolve, reject) => {
    const rows = [];
    queryApi.queryRows(flux, {
      next(row, meta) { rows.push(meta.toObject(row)); },
      error: reject,
      complete() { resolve(rows); },
    });
  });
}

// Accept both Danapac (P_kW/P) and other clients' (Active_Power_kW) power fields
const POWER_FIELD_FILTER = `r._field == "P_kW" or r._field == "P" or r._field == "Active_Power_kW"`;
const ENERGY_FIELD_FILTER = ENERGY_FIELD_NAMES.map((f) => `r._field == "${f}"`).join(" or ");

async function influxHourlyFallback(topic, date, req) {
  const { queryApi, bucket, schema } = await getInflux(req);
  const start = `${date}T00:00:00Z`;
  const stop  = `${date}T23:59:59Z`;
  const flux = `
    from(bucket: "${bucket}")
      |> range(start: ${start}, stop: ${stop})
      |> filter(fn: (r) => r._measurement == "${schema.measurement}")
      ${deviceFilter(schema, topic)}
      |> filter(fn: (r) => ${POWER_FIELD_FILTER})
      |> aggregateWindow(every: 1h, fn: last, createEmpty: false)
  `;
  const rows = await runInfluxQuery(queryApi, flux);
  return rows.map((r) => ({
    label: String(new Date(r._time).getUTCHours()),
    value: r._value ?? 0,
  }));
}

async function influxDailyFallback(topic, req) {
  const { queryApi, bucket, schema } = await getInflux(req);
  const flux = `
    from(bucket: "${bucket}")
      |> range(start: -7d)
      |> filter(fn: (r) => r._measurement == "${schema.measurement}")
      ${deviceFilter(schema, topic)}
      |> filter(fn: (r) => ${POWER_FIELD_FILTER})
      |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
  `;
  const rows = await runInfluxQuery(queryApi, flux);
  return rows.map((r) => {
    const d = new Date(r._time);
    return { label: `${d.getUTCDate()}/${d.getUTCMonth() + 1}`, value: r._value ?? 0 };
  });
}

// Daily fallback pinned to a specific calendar month (monthStr = "YYYY-MM").
async function influxDailyMonthFallback(topic, monthStr, req) {
  const { queryApi, bucket, schema } = await getInflux(req);
  const [y, m] = monthStr.split("-").map(Number);
  const start = new Date(Date.UTC(y, m - 1, 1)).toISOString();
  const stop = new Date(Date.UTC(y, m, 1)).toISOString();
  const flux = `
    from(bucket: "${bucket}")
      |> range(start: ${start}, stop: ${stop})
      |> filter(fn: (r) => r._measurement == "${schema.measurement}")
      ${deviceFilter(schema, topic)}
      |> filter(fn: (r) => ${POWER_FIELD_FILTER})
      |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
  `;
  const rows = await runInfluxQuery(queryApi, flux);
  return rows.map((r) => {
    const d = new Date(r._time);
    return { label: `${d.getUTCDate()}/${d.getUTCMonth() + 1}`, value: r._value ?? 0 };
  });
}

async function influxMonthlyFallback(topic, req) {
  const { queryApi, bucket, schema } = await getInflux(req);
  const flux = `
    from(bucket: "${bucket}")
      |> range(start: -365d)
      |> filter(fn: (r) => r._measurement == "${schema.measurement}")
      ${deviceFilter(schema, topic)}
      |> filter(fn: (r) => ${POWER_FIELD_FILTER})
      |> aggregateWindow(every: 30d, fn: mean, createEmpty: false)
  `;
  const rows = await runInfluxQuery(queryApi, flux);
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return rows.map((r) => ({
    label: months[new Date(r._time).getUTCMonth()],
    value: r._value ?? 0,
  }));
}

router.get("/devices", async (req, res) => {
  // Try client-specific MySQL first (consumption + generation meters),
  // fall back to default pool querying energy_data.
  try {
    const clientPool = await getMysql(req);
    const [rows] = await clientPool.query(
      `SELECT device_id FROM (
         SELECT DISTINCT device_id FROM Overall_hourly_energy_consumption
         UNION
         SELECT DISTINCT device_id FROM Overall_hourly_energy_generation
       ) t
       ORDER BY device_id`
    );
    if (rows && rows.length > 0) return res.json(rows);
  } catch (_) {
    // Generation table may be missing on older tenants — try consumption only.
    try {
      const clientPool = await getMysql(req);
      const [rows] = await clientPool.query(
        "SELECT DISTINCT device_id FROM Overall_hourly_energy_consumption ORDER BY device_id"
      );
      if (rows && rows.length > 0) return res.json(rows);
    } catch (__) {}
  }

  pool.query("SELECT DISTINCT device_id FROM energy_data", (error, results) => {
    if (error) {
      return res.status(500).json({ error: "Database error", message: error.message, code: error.code });
    }
    return res.json(results);
  });
});

router.get("/peak/:topic", (req, res) => {
  const { topic } = req.params;

  if (!topic) {
    return res.status(400).json({
      error: "Missing topic parameter",
    });
  }

  const query = `
    SELECT COALESCE(MAX(power_p), 0) AS peak_energy
    FROM energy_data
    WHERE device_id = ? 
    AND DATE(timestamp) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))
  `;

  pool.query(query, [topic, topic, topic], (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }
    return res.json(results[0]);
  });
});

router.get("/average/:topic", (req, res) => {
  const { topic } = req.params;

  if (!topic) {
    return res.status(400).json({
      error: "Missing topic parameter",
    });
  }

  const query = `
    SELECT
      ROUND(
        COALESCE(SUM(CASE 
          WHEN DATE(timestamp) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')) 
          THEN power_p 
        END), 0)
        /
        GREATEST(
          TIMESTAMPDIFF(SECOND, 
            DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), 
            CONVERT_TZ(NOW(), '+00:00', '+08:00')
          ) / 60.0,
          0.01
        ),
        3
      ) AS average_energy
    FROM energy_data
    WHERE device_id = ?;
  `;

  pool.query(query, [topic], (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }
    return res.json(results);
  });
});
// Generalizes the "today vs yesterday/last month/last year" energy_data +
// daily_device_summary logic below to an arbitrary calendar date, so callers
// (e.g. the kWh/Tonne Add Data form) can get a given day's actual consumption
// instead of always getting today's.
async function getEnergyAsOf(deviceId, dateStr) {
  // energy_data only retains the device's current/live reading (so a row only
  // exists there for "today"). Past dates have already been rolled into
  // daily_device_summary as that day's final cumulative reading.
  const [liveRows] = await pool.promise().query(
    `SELECT energy_edel FROM energy_data WHERE device_id = ? AND DATE(timestamp) = ? ORDER BY timestamp DESC LIMIT 1`,
    [deviceId, dateStr]
  );
  if (liveRows.length > 0) return Number(liveRows[0].energy_edel) || 0;

  const [summaryRows] = await pool.promise().query(
    `SELECT energy_edel FROM daily_device_summary WHERE device_id = ? AND DATE(timestamp) = ? ORDER BY timestamp DESC LIMIT 1`,
    [deviceId, dateStr]
  );
  return summaryRows.length > 0 ? (Number(summaryRows[0].energy_edel) || 0) : 0;
}

function ymd(d) { return d.toISOString().slice(0, 10); }

async function totalsForDate(deviceId, dateStr) {
  const refDate = new Date(`${dateStr}T00:00:00Z`);
  if (Number.isNaN(refDate.getTime())) throw new Error(`Invalid date: ${dateStr}`);

  const prevDay = new Date(refDate); prevDay.setUTCDate(prevDay.getUTCDate() - 1);
  const prevMonthEnd = new Date(Date.UTC(refDate.getUTCFullYear(), refDate.getUTCMonth(), 0));
  const prevYearEnd = `${refDate.getUTCFullYear() - 1}-12-31`;

  const [current, prevDayEnergy, prevMonthEndEnergy, prevYearEndEnergy] = await Promise.all([
    getEnergyAsOf(deviceId, dateStr),
    getEnergyAsOf(deviceId, ymd(prevDay)),
    getEnergyAsOf(deviceId, ymd(prevMonthEnd)),
    getEnergyAsOf(deviceId, prevYearEnd),
  ]);

  return [
    { period: "daily",   total_energy: parseFloat(Math.max(0, current - prevDayEnergy).toFixed(3)) },
    { period: "monthly", total_energy: parseFloat(Math.max(0, current - prevMonthEndEnergy).toFixed(3)) },
    { period: "yearly",  total_energy: parseFloat(Math.max(0, current - prevYearEndEnergy).toFixed(3)) },
  ];
}

async function influxTotalFallbackForDate(deviceId, dateStr, req) {
  const { queryApi, bucket, schema } = await getInflux(req);
  const refDate = new Date(`${dateStr}T00:00:00Z`);
  const dayStart   = refDate;
  const dayEnd     = new Date(Date.UTC(refDate.getUTCFullYear(), refDate.getUTCMonth(), refDate.getUTCDate(), 23, 59, 59));
  const monthStart = new Date(Date.UTC(refDate.getUTCFullYear(), refDate.getUTCMonth(), 1));
  const yearStart  = new Date(Date.UTC(refDate.getUTCFullYear(), 0, 1));

  async function getEdelRange(start, stop) {
    const firstQ = `
      from(bucket: "${bucket}")
        |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
        |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
        ${deviceFilter(schema, deviceId)}
        |> first()
    `;
    const lastQ = `
      from(bucket: "${bucket}")
        |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
        |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
        ${deviceFilter(schema, deviceId)}
        |> last()
    `;
    const [firstRows, lastRows] = await Promise.all([runInfluxQuery(queryApi, firstQ), runInfluxQuery(queryApi, lastQ)]);
    const first = firstRows[0]?._value ?? 0;
    const last  = lastRows[0]?._value ?? 0;
    return Math.max(0, last - first);
  }

  const [daily, monthly, yearly] = await Promise.all([
    getEdelRange(dayStart, dayEnd),
    getEdelRange(monthStart, dayEnd),
    getEdelRange(yearStart, dayEnd),
  ]);
  return [
    { period: "daily",   total_energy: parseFloat(daily.toFixed(3)) },
    { period: "monthly", total_energy: parseFloat(monthly.toFixed(3)) },
    { period: "yearly",  total_energy: parseFloat(yearly.toFixed(3)) },
  ];
}

router.get("/total/:device_id", async (req, res) => {
  const { device_id } = req.params;
  // Optional ?date=YYYY-MM-DD. When present, returns that day's totals instead
  // of today's — used by the kWh/Tonne Add Data form to auto-fill kWh consumed
  // for the date the user picked. Omitting it preserves the original "today"
  // behaviour byte-for-byte for the other callers (Sankey, SEC comparison,
  // kWh/Tonne fleet energy, Energy Details "Total Energy" card).
  const { date } = req.query;
  const isValidDate = typeof date === "string" && /^\d{4}-\d{2}-\d{2}$/.test(date);

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const sql = `
    SELECT 'daily' AS period,
           GREATEST(0, COALESCE(today_energy, 0) - COALESCE(yesterday_energy, 0)) AS total_energy
    FROM (
      SELECT
        (SELECT energy_edel 
         FROM energy_data 
         WHERE device_id = ? 
           AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
         ORDER BY timestamp DESC 
         LIMIT 1) AS today_energy,
        (SELECT energy_edel 
         FROM daily_device_summary 
         WHERE device_id = ? 
           AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR - INTERVAL 1 DAY)
         ORDER BY timestamp DESC 
         LIMIT 1) AS yesterday_energy
    ) AS sub_daily
    UNION ALL
    SELECT 'monthly' AS period,
           GREATEST(0, COALESCE(today_energy, 0) - COALESCE(last_month_energy, 0)) AS total_energy
    FROM (
      SELECT
        (SELECT energy_edel 
         FROM energy_data 
         WHERE device_id = ? 
           AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
         ORDER BY timestamp DESC 
         LIMIT 1) AS today_energy,
        (SELECT energy_edel 
         FROM daily_device_summary 
         WHERE device_id = ? 
           AND DATE(timestamp) = LAST_DAY(NOW() + INTERVAL 8 HOUR - INTERVAL 1 MONTH)
         ORDER BY timestamp DESC 
         LIMIT 1) AS last_month_energy
    ) AS sub_monthly
    UNION ALL
    SELECT 'yearly' AS period,
           GREATEST(0, COALESCE(today_energy, 0) - COALESCE(last_year_energy, 0)) AS total_energy
    FROM (
      SELECT
        (SELECT energy_edel 
         FROM energy_data 
         WHERE device_id = ? 
           AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
         ORDER BY timestamp DESC 
         LIMIT 1) AS today_energy,
        (SELECT energy_edel 
         FROM daily_device_summary 
         WHERE device_id = ? 
           AND DATE(timestamp) = CONCAT(YEAR(NOW() + INTERVAL 8 HOUR - INTERVAL 1 YEAR), '-12-31')
         ORDER BY timestamp DESC 
         LIMIT 1) AS last_year_energy
    ) AS sub_yearly;
  `;

  async function influxTotalFallback(deviceId, req) {
    const { queryApi, bucket, schema } = await getInflux(req);
    const now = new Date();
    const todayStart = new Date(now); todayStart.setUTCHours(0,0,0,0);
    const monthStart = new Date(now); monthStart.setUTCDate(1); monthStart.setUTCHours(0,0,0,0);
    const yearStart  = new Date(now); yearStart.setUTCMonth(0,1); yearStart.setUTCHours(0,0,0,0);

    async function getEdelRange(start, stop) {
      const firstQ = `
        from(bucket: "${bucket}")
          |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
          |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
          ${deviceFilter(schema, deviceId)}
          |> first()
      `;
      const lastQ = `
        from(bucket: "${bucket}")
          |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
          |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
          ${deviceFilter(schema, deviceId)}
          |> last()
      `;
      const [firstRows, lastRows] = await Promise.all([runInfluxQuery(queryApi, firstQ), runInfluxQuery(queryApi, lastQ)]);
      const first = firstRows[0]?._value ?? 0;
      const last  = lastRows[0]?._value ?? 0;
      return Math.max(0, last - first);
    }

    const stopNow = now;
    const [daily, monthly, yearly] = await Promise.all([
      getEdelRange(todayStart, stopNow),
      getEdelRange(monthStart, stopNow),
      getEdelRange(yearStart,  stopNow),
    ]);
    return [
      { period: "daily",   total_energy: parseFloat(daily.toFixed(3)) },
      { period: "monthly", total_energy: parseFloat(monthly.toFixed(3)) },
      { period: "yearly",  total_energy: parseFloat(yearly.toFixed(3)) },
    ];
  }

  try {
    // ── Multi-tenant path ──────────────────────────────────────────────────
    // Clients tagged with x-client-id (e.g. Thong Guan F0004) read the
    // pre-aggregated daily/monthly/yearly consumption straight from their own
    // MySQL Overall_*_energy_consumption tables. Untagged requests (Danapac /
    // Demo — the default tenant) NEVER enter this branch and keep the original
    // energy_data/daily_device_summary logic below, byte-for-byte unchanged.
    const clientId = req.clientId || req.headers["x-client-id"];
    if (clientId) {
      try {
        const cpool = await getMysql(req);

        if (isValidDate) {
          // Date-aware: read the exact date's row instead of "latest <= today",
          // so picking a past date in the Add Data form reflects that day's
          // actual consumption rather than today's.
          const refDate = new Date(`${date}T00:00:00Z`);
          const [[daily]] = await cpool.query(
            `SELECT SUM(energy_consumption_kWh) AS e, SUM(carbon_emission_kgCO2e) AS c
             FROM Overall_daily_energy_consumption
             WHERE device_id = ? AND date = ?`,
            [device_id, date]);
          const [[monthly]] = await cpool.query(
            `SELECT SUM(energy_consumption_kWh) AS e
             FROM Overall_monthly_energy_consumption
             WHERE device_id = ? AND year = ? AND month = ?`,
            [device_id, refDate.getUTCFullYear(), refDate.getUTCMonth() + 1]);
          const [[yearly]] = await cpool.query(
            `SELECT SUM(energy_consumption_kWh) AS e
             FROM Overall_yearly_energy_consumption
             WHERE device_id = ? AND year = ?`,
            [device_id, refDate.getUTCFullYear()]);
          const consumption = [
            { period: "daily",   total_energy: Number(daily?.e ?? 0), daily_emission: Number(daily?.c ?? 0) },
            { period: "monthly", total_energy: Number(monthly?.e ?? 0) },
            { period: "yearly",  total_energy: Number(yearly?.e ?? 0) },
          ];
          if (!isZeroTotals(consumption)) return res.json(consumption);
          try {
            const gen = await totalsFromGeneration(cpool, device_id, date);
            if (!isZeroTotals(gen)) return res.json(gen);
          } catch (ge) {
            console.warn(`[energyDetails/total] generation fallback failed for ${device_id}: ${ge.message}`);
          }
          return res.json(consumption);
        }

        // Sum the latest date's rows so the card matches the chart's last bar
        // (the table can hold more than one row per date).
        const [[daily]] = await cpool.query(
          `SELECT SUM(energy_consumption_kWh) AS e, SUM(carbon_emission_kgCO2e) AS c
           FROM Overall_daily_energy_consumption
           WHERE device_id = ? AND date = (
             SELECT MAX(date) FROM Overall_daily_energy_consumption WHERE device_id = ? AND date <= CURDATE())`,
          [device_id, device_id]);
        const [[monthly]] = await cpool.query(
          `SELECT SUM(energy_consumption_kWh) AS e
           FROM Overall_monthly_energy_consumption
           WHERE device_id = ? AND year = YEAR(CURDATE()) AND month = MONTH(CURDATE())`,
          [device_id]);
        const [[yearly]] = await cpool.query(
          `SELECT SUM(energy_consumption_kWh) AS e
           FROM Overall_yearly_energy_consumption
           WHERE device_id = ? AND year = YEAR(CURDATE())`,
          [device_id]);
        const consumption = [
          { period: "daily",   total_energy: Number(daily?.e ?? 0), daily_emission: Number(daily?.c ?? 0) },
          { period: "monthly", total_energy: Number(monthly?.e ?? 0) },
          { period: "yearly",  total_energy: Number(yearly?.e ?? 0) },
        ];
        if (!isZeroTotals(consumption)) return res.json(consumption);
        // Solar / virtual meters: fall back to Overall_hourly_energy_generation.
        try {
          const gen = await totalsFromGeneration(cpool, device_id);
          if (!isZeroTotals(gen)) return res.json(gen);
        } catch (ge) {
          console.warn(`[energyDetails/total] generation fallback failed for ${device_id}: ${ge.message}`);
        }
        return res.json(consumption);
      } catch (e) {
        console.warn(`[energyDetails/total] Overall_* query failed for client ${clientId}: ${e.message}`);
        // fall through to the default behaviour below — never hard-fail a client
      }
    }

    if (isValidDate) {
      try {
        const dateData = await totalsForDate(device_id, date);
        if (dateData.some((r) => r.total_energy > 0)) return res.json(dateData);
      } catch (e) {
        console.warn(`[energyDetails/total] date-aware MySQL query failed for ${device_id} on ${date}: ${e.message}`);
      }
      try {
        const influxData = await influxTotalFallbackForDate(device_id, date, req);
        return res.json(influxData);
      } catch (e) {
        return res.json([
          { period: "daily",   total_energy: 0 },
          { period: "monthly", total_energy: 0 },
          { period: "yearly",  total_energy: 0 },
        ]);
      }
    }

    const [rows] = await pool.promise().query(sql, [device_id, device_id, device_id, device_id, device_id, device_id]);

    if (isZeroTotals(rows)) {
      try {
        const influxData = await influxTotalFallback(device_id, req);
        return res.json(influxData);
      } catch (e) {
        // fallback failed, return MySQL result
      }
    }

    return res.json(rows);
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

// ── Peak / Off-Peak split for a device's monthly generation ────────────────
// TNB E3 Bill Simulator's Solar Savings card needs to know how much of a
// solar device's MTD generation falls inside the site's peak ToU window vs
// outside it, since avoided cost is only worth the peak rate for the
// peak-hour portion (off-peak generation would otherwise have been billed at
// the lower off-peak rate).
//
// Tries three sources in order, per-request, since which one actually holds
// data for a given device_id varies by tenant/pipeline — confirmed live
// against this app's real active client (F0004/Thong Guan, solarDeviceId
// DPM001):
//   1) Overall_hourly_energy_consumption (event_time, energy_consumption_kWh)
//      — the SAME table GET /total/:device_id and GET /data/:topic/hourly
//      already read for this tenant, and the one DPM001 actually has real
//      hourly rows in (confirmed live: 200-ish kWh spread across all 24
//      hours, including off-peak — this deployment logs its demo "solar"
//      device through the regular consumption pipeline, not a dedicated
//      generation table). Checked first so the split always agrees with the
//      total these other endpoints already show.
//   2) Overall_hourly_energy_generation (timestamp, energy_generated_kWh) —
//      for tenants whose pipeline does log solar separately from
//      consumption. Missing table for tenants that don't (confirmed live:
//      ER_NO_SUCH_TABLE for both F0004/ThongGuan_Database and the untagged
//      default Danapac_Database) — caught and treated as "try the next
//      source" rather than a hard failure.
//   3) hourly_device_summary (timestamp, cumulative energy_edel) — the
//      default/untagged (Danapac) pool's own per-device hourly readings;
//      each hour's generation is the delta against its immediately
//      preceding reading.
// Each tier is skipped (not returned) when it comes back completely empty,
// so a device with real data in a later tier still gets a real split instead
// of a false 0/0 from an earlier, merely-inapplicable one.
//
// ?peakStart=HH:mm & ?peakEnd=HH:mm (default 08:00/22:00, matching the bill
// simulator's own fallback) — only the hour component is used, and the
// window is assumed same-day (start < end), matching every ToU window this
// app configures today. ?year=&?month= default to the current month.
router.get("/peak-off-peak/:device_id", async (req, res) => {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const parseHour = (val, fallback) => {
    const m = /^(\d{1,2}):\d{2}$/.exec(val || "");
    if (!m) return fallback;
    const h = parseInt(m[1], 10);
    return h >= 0 && h <= 23 ? h : fallback;
  };
  const peakStartHour = parseHour(req.query.peakStart, 8);
  const peakEndHour = parseHour(req.query.peakEnd, 22);

  const now = new Date();
  const year = /^\d{4}$/.test(req.query.year || "") ? Number(req.query.year) : now.getFullYear();
  const month = /^(0?[1-9]|1[0-2])$/.test(req.query.month || "") ? Number(req.query.month) : now.getMonth() + 1;

  const respondIfNonEmpty = (res, peakKwh, offPeakKwh) => {
    if (peakKwh <= 0 && offPeakKwh <= 0) return false;
    res.json({ peak_kwh: peakKwh, off_peak_kwh: offPeakKwh, total_kwh: peakKwh + offPeakKwh });
    return true;
  };

  try {
    const cpool = await getMysql(req);

    // 1) Overall_hourly_energy_consumption — see comment block above.
    try {
      const [rows] = await cpool.query(
        `SELECT
           COALESCE(SUM(CASE WHEN HOUR(event_time) >= ? AND HOUR(event_time) < ?
                              THEN energy_consumption_kWh ELSE 0 END), 0) AS peak_kwh,
           COALESCE(SUM(CASE WHEN HOUR(event_time) >= ? AND HOUR(event_time) < ?
                              THEN 0 ELSE energy_consumption_kWh END), 0) AS off_peak_kwh
         FROM Overall_hourly_energy_consumption
         WHERE device_id = ? AND YEAR(event_time) = ? AND MONTH(event_time) = ?`,
        [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, year, month]
      );
      const row = rows[0] || {};
      if (respondIfNonEmpty(res, Number(row.peak_kwh) || 0, Number(row.off_peak_kwh) || 0)) return;
    } catch (e1) {
      console.warn(`[energyDetails/peak-off-peak] Overall_hourly_energy_consumption unavailable for ${device_id}: ${e1.message}`);
    }

    // 2) Overall_hourly_energy_generation — see comment block above.
    try {
      const [rows] = await cpool.query(
        `SELECT
           COALESCE(SUM(CASE WHEN HOUR(\`timestamp\`) >= ? AND HOUR(\`timestamp\`) < ?
                              THEN energy_generated_kWh ELSE 0 END), 0) AS peak_kwh,
           COALESCE(SUM(CASE WHEN HOUR(\`timestamp\`) >= ? AND HOUR(\`timestamp\`) < ?
                              THEN 0 ELSE energy_generated_kWh END), 0) AS off_peak_kwh
         FROM Overall_hourly_energy_generation
         WHERE device_id = ? AND YEAR(\`timestamp\`) = ? AND MONTH(\`timestamp\`) = ?`,
        [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, year, month]
      );
      const row = rows[0] || {};
      if (respondIfNonEmpty(res, Number(row.peak_kwh) || 0, Number(row.off_peak_kwh) || 0)) return;
    } catch (e2) {
      console.warn(`[energyDetails/peak-off-peak] Overall_hourly_energy_generation unavailable for ${device_id}: ${e2.message}`);
    }

    // 3) hourly_device_summary — see comment block above. Missing baseline
    //    (device's very first-ever reading) is treated as 0, matching the
    //    COALESCE(...,0) convention /total/:device_id already uses.
    try {
      const [rows] = await cpool.query(
        `SELECT
           COALESCE(SUM(CASE WHEN HOUR(cur.\`timestamp\`) >= ? AND HOUR(cur.\`timestamp\`) < ?
                              THEN GREATEST(0, cur.energy_edel - COALESCE(prev.energy_edel, 0))
                              ELSE 0 END), 0) AS peak_kwh,
           COALESCE(SUM(CASE WHEN HOUR(cur.\`timestamp\`) >= ? AND HOUR(cur.\`timestamp\`) < ?
                              THEN 0
                              ELSE GREATEST(0, cur.energy_edel - COALESCE(prev.energy_edel, 0)) END), 0) AS off_peak_kwh
         FROM hourly_device_summary cur
         LEFT JOIN hourly_device_summary prev
           ON prev.device_id = cur.device_id
          AND prev.\`timestamp\` = (
                SELECT MAX(\`timestamp\`) FROM hourly_device_summary
                WHERE device_id = cur.device_id AND \`timestamp\` < cur.\`timestamp\`
              )
         WHERE cur.device_id = ?
           AND YEAR(cur.\`timestamp\`) = ?
           AND MONTH(cur.\`timestamp\`) = ?`,
        [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, year, month]
      );
      const row = rows[0] || {};
      if (respondIfNonEmpty(res, Number(row.peak_kwh) || 0, Number(row.off_peak_kwh) || 0)) return;
    } catch (e3) {
      console.warn(`[energyDetails/peak-off-peak] hourly_device_summary unavailable for ${device_id}: ${e3.message}`);
    }

    // All three sources came back empty (or unavailable) — genuinely no
    // hourly data for this device this month, not an error.
    return res.json({ peak_kwh: 0, off_peak_kwh: 0, total_kwh: 0 });
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

// ── Peak / Off-Peak split for a device's DAILY generation ──────────────────
// Day-by-day version of /peak-off-peak/:device_id above — the Bill Simulator
// Data Logger's Solar Gen columns need one row per day instead of a single
// month total. Same three-tier source (Overall_hourly_energy_consumption
// first, Overall_hourly_energy_generation second, hourly_device_summary
// cumulative-reading delta third — see the comment block above
// /peak-off-peak/:device_id for why: this deployment's real demo solar
// device (F0004/Thong Guan, DPM001) logs through Overall_hourly_energy_
// consumption, not a dedicated generation table) and the same ToU window
// semantics; just grouped by calendar day over a ?days= window instead of
// aggregated for one ?year=&?month=.
router.get("/solar-daily/:device_id", async (req, res) => {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const parseHour = (val, fallback) => {
    const m = /^(\d{1,2}):\d{2}$/.exec(val || "");
    if (!m) return fallback;
    const h = parseInt(m[1], 10);
    return h >= 0 && h <= 23 ? h : fallback;
  };
  const peakStartHour = parseHour(req.query.peakStart, 8);
  const peakEndHour = parseHour(req.query.peakEnd, 22);
  const days = Math.min(180, Math.max(1, parseInt(req.query.days, 10) || 30));

  try {
    const cpool = await getMysql(req);

    // 1) Overall_hourly_energy_consumption — see comment block above
    // /peak-off-peak/:device_id. Checked first so this always agrees with
    // that endpoint's monthly split and with /total/:device_id.
    try {
      const [consRows] = await cpool.query(
        `SELECT DATE_FORMAT(d, '%Y-%m-%d') AS date,
                SUM(peak_kwh) AS peak_kwh, SUM(off_peak_kwh) AS off_peak_kwh
         FROM (
           SELECT DATE(event_time) AS d,
                  CASE WHEN HOUR(event_time) >= ? AND HOUR(event_time) < ? THEN energy_consumption_kWh ELSE 0 END AS peak_kwh,
                  CASE WHEN HOUR(event_time) >= ? AND HOUR(event_time) < ? THEN 0 ELSE energy_consumption_kWh END AS off_peak_kwh
           FROM Overall_hourly_energy_consumption
           WHERE device_id = ?
             AND event_time >= DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL ? DAY)
         ) t
         GROUP BY d
         ORDER BY d ASC`,
        [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, days]
      );
      if (consRows.length > 0) {
        return res.json(consRows.map((r) => ({
          date: r.date,
          peak_kwh: Number(r.peak_kwh) || 0,
          off_peak_kwh: Number(r.off_peak_kwh) || 0,
        })));
      }
    } catch (ce) {
      console.warn(`[energyDetails/solar-daily] Overall_hourly_energy_consumption unavailable for ${device_id}: ${ce.message}`);
    }

    // 2) Overall_hourly_energy_generation. Grouping is done
    // on a derived table's plain `d` column (not a second function of
    // `timestamp`) so this satisfies ONLY_FULL_GROUP_BY without the DATE()
    // vs DATE_FORMAT() mismatch that trips it up when both are applied
    // directly to the same source column.
    try {
      const [genRows] = await cpool.query(
        `SELECT DATE_FORMAT(d, '%Y-%m-%d') AS date,
                SUM(peak_kwh) AS peak_kwh, SUM(off_peak_kwh) AS off_peak_kwh
         FROM (
           SELECT DATE(\`timestamp\`) AS d,
                  CASE WHEN HOUR(\`timestamp\`) >= ? AND HOUR(\`timestamp\`) < ? THEN energy_generated_kWh ELSE 0 END AS peak_kwh,
                  CASE WHEN HOUR(\`timestamp\`) >= ? AND HOUR(\`timestamp\`) < ? THEN 0 ELSE energy_generated_kWh END AS off_peak_kwh
           FROM Overall_hourly_energy_generation
           WHERE device_id = ?
             AND \`timestamp\` >= DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL ? DAY)
         ) t
         GROUP BY d
         ORDER BY d ASC`,
        [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, days]
      );
      if (genRows.length > 0) {
        return res.json(genRows.map((r) => ({
          date: r.date,
          peak_kwh: Number(r.peak_kwh) || 0,
          off_peak_kwh: Number(r.off_peak_kwh) || 0,
        })));
      }
    } catch (ge) {
      console.warn(`[energyDetails/solar-daily] Overall_hourly_energy_generation unavailable for ${device_id}: ${ge.message}`);
    }

    // 3) Fallback: hourly_device_summary cumulative-reading delta (see
    // /peak-off-peak/:device_id above for why the correlated MAX(timestamp)
    // lookup is needed instead of a plain LAG).
    const [sumRows] = await cpool.query(
      `SELECT DATE_FORMAT(d, '%Y-%m-%d') AS date,
              SUM(peak_kwh) AS peak_kwh, SUM(off_peak_kwh) AS off_peak_kwh
       FROM (
         SELECT DATE(cur.\`timestamp\`) AS d,
                CASE WHEN HOUR(cur.\`timestamp\`) >= ? AND HOUR(cur.\`timestamp\`) < ?
                     THEN GREATEST(0, cur.energy_edel - COALESCE(prev.energy_edel, 0)) ELSE 0 END AS peak_kwh,
                CASE WHEN HOUR(cur.\`timestamp\`) >= ? AND HOUR(cur.\`timestamp\`) < ?
                     THEN 0 ELSE GREATEST(0, cur.energy_edel - COALESCE(prev.energy_edel, 0)) END AS off_peak_kwh
         FROM hourly_device_summary cur
         LEFT JOIN hourly_device_summary prev
           ON prev.device_id = cur.device_id
          AND prev.\`timestamp\` = (
                SELECT MAX(\`timestamp\`) FROM hourly_device_summary
                WHERE device_id = cur.device_id AND \`timestamp\` < cur.\`timestamp\`
              )
         WHERE cur.device_id = ?
           AND cur.\`timestamp\` >= DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL ? DAY)
       ) t
       GROUP BY d
       ORDER BY d ASC`,
      [peakStartHour, peakEndHour, peakStartHour, peakEndHour, device_id, days]
    );
    return res.json(sumRows.map((r) => ({
      date: r.date,
      peak_kwh: Number(r.peak_kwh) || 0,
      off_peak_kwh: Number(r.off_peak_kwh) || 0,
    })));
  } catch (error) {
    return res.status(500).json({
      error: "Database error",
      message: error.message,
      code: error.code,
    });
  }
});

router.get("/vs/:topic/:period", (req, res) => {
  const { topic, period } = req.params;

  if (!topic || !period) {
    return res.status(400).json({
      error: "Missing topic or period parameter",
    });
  }

  // Choose the correct query based on the period parameter.
  let selectedQuery;
  switch (period.toLowerCase()) {
    case "daily":
      selectedQuery = `
        SELECT 
        t.device_id,
        (t.today_energy - y.yesterday_energy) AS diff_today,
        (y.yesterday_energy - d.daybefore_energy) AS diff_yesterday,
        
        -- Calculate the percentage change with the specified rules:
        CONCAT(
          CASE 
            WHEN (t.today_energy - y.yesterday_energy) IS NULL 
                  OR (t.today_energy - y.yesterday_energy) = 0 
                THEN -100
            WHEN (y.yesterday_energy - d.daybefore_energy) IS NULL 
                  OR (y.yesterday_energy - d.daybefore_energy) = 0 
                THEN 100
            ELSE ROUND(
                  (
                    ((t.today_energy - y.yesterday_energy) - (y.yesterday_energy - d.daybefore_energy))
                    /
                    (y.yesterday_energy - d.daybefore_energy)
                  ) * 100, 3)
          END,
          '%'
        ) AS percentage_changed
      FROM 
        (
          -- Latest record from energy_data for today (using 8-hour adjustment for Malaysia time)
          SELECT 
            device_id,
            energy_edel AS today_energy
          FROM energy_data
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS t
      LEFT JOIN 
        (
          -- Latest record from daily_device_summary for yesterday
          SELECT 
            device_id,
            energy_edel AS yesterday_energy
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR - INTERVAL 1 DAY)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS y 
        ON t.device_id = y.device_id
      LEFT JOIN 
        (
          -- Latest record from daily_device_summary for the day before yesterday
          SELECT 
            device_id,
            energy_edel AS daybefore_energy
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR - INTERVAL 2 DAY)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS d 
        ON t.device_id = d.device_id;
      `;
      break;
    case "monthly":
      selectedQuery = `
        SELECT 
        ed.device_id,
        (COALESCE(ed.today_energy, 0) - COALESCE(lmd.last_month_value, 0)) AS this_month_energy,
        (COALESCE(lmd.last_month_value, 0) - COALESCE(lld.last_last_month_value, 0)) AS last_month_energy,
        CONCAT(
          CASE 
            WHEN (COALESCE(lmd.last_month_value, 0) - COALESCE(lld.last_last_month_value, 0)) = 0 
                THEN 100
            WHEN (COALESCE(ed.today_energy, 0) - COALESCE(lmd.last_month_value, 0)) = 0 
                THEN -100
            ELSE ROUND( 
                  (
                    (
                      (COALESCE(ed.today_energy, 0) - COALESCE(lmd.last_month_value, 0))
                      -
                      (COALESCE(lmd.last_month_value, 0) - COALESCE(lld.last_last_month_value, 0))
                    )
                    /
                    (COALESCE(lmd.last_month_value, 0) - COALESCE(lld.last_last_month_value, 0))
                  ) * 100, 3)
          END, '%'
        ) AS percentage_changed
      FROM
        (
          -- Latest record from energy_data for today (Malaysia time)
          SELECT 
            device_id, 
            energy_edel AS today_energy
          FROM energy_data
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS ed
      LEFT JOIN
        (
          -- Record from daily_device_summary for the last day of last month
          SELECT 
            device_id,
            energy_edel AS last_month_value
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = LAST_DAY(NOW() + INTERVAL 8 HOUR - INTERVAL 1 MONTH)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS lmd ON ed.device_id = lmd.device_id
      LEFT JOIN
        (
          -- Record from daily_device_summary for the last day of the month before last
          SELECT 
            device_id,
            energy_edel AS last_last_month_value
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = LAST_DAY(NOW() + INTERVAL 8 HOUR - INTERVAL 2 MONTH)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS lld ON ed.device_id = lld.device_id;
      `;
      break;
    case "yearly":
      selectedQuery = `
        SELECT 
        t.device_id,
        (COALESCE(t.today_energy,0) - COALESCE(ly.last_year_value, 0)) AS this_year_energy,
        (COALESCE(ly.last_year_value, 0) - COALESCE(lly.last_last_year_value, 0)) AS last_year_energy,
        CONCAT(
          CASE 
            WHEN (COALESCE(t.today_energy,0) - COALESCE(ly.last_year_value, 0)) = 0 THEN -100
            WHEN (COALESCE(ly.last_year_value, 0) - COALESCE(lly.last_last_year_value, 0)) = 0 THEN 100
            ELSE ROUND(
                (
                  ((COALESCE(t.today_energy,0) - COALESCE(ly.last_year_value, 0))
                    - 
                    (COALESCE(ly.last_year_value, 0) - COALESCE(lly.last_last_year_value, 0)))
                  /
                  (COALESCE(ly.last_year_value, 0) - COALESCE(lly.last_last_year_value, 0))
                ) * 100, 3)
          END, '%'
        ) AS percentage_changed
      FROM
        (
          -- Retrieve the latest energy reading for today from energy_data (Malaysia time)
          SELECT 
            device_id,
            energy_edel AS today_energy
          FROM energy_data
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS t
      LEFT JOIN
        (
          -- Retrieve the energy reading for last year's last day (December 31 of last year)
          SELECT 
            device_id,
            energy_edel AS last_year_value
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = CONCAT(YEAR(NOW() - INTERVAL 1 YEAR), '-12-31')
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS ly
          ON t.device_id = ly.device_id
      LEFT JOIN
        (
          -- Retrieve the energy reading for the last day of the year before last 
          -- (December 31 of two years ago)
          SELECT 
            device_id,
            energy_edel AS last_last_year_value
          FROM daily_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = CONCAT(YEAR(NOW() - INTERVAL 2 YEAR), '-12-31')
          ORDER BY timestamp DESC
          LIMIT 1
        ) AS lly
          ON t.device_id = lly.device_id;
      `;
      break;
    default:
      return res.status(400).json({
        error: "Invalid period parameter. Must be one of: daily, monthly, yearly.",
      });
  }

  pool.query(selectedQuery, [topic, topic, topic], (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }
    // Always return at least one row so frontend doesn't throw on [0]
    if (!results || results.length === 0) {
      return res.json([{ percentage_changed: "N/A" }]);
    }
    return res.json(results);
  });
});
function dedupeByLabel(rows) {
  const seen = new Map();
  for (const r of rows) {
    const key = r.date ?? r.label;
    const existing = seen.get(key);
    if (!existing || Number(r.value) > Number(existing.value)) {
      seen.set(key, r);
    }
  }
  return Array.from(seen.values());
}

router.get("/data/:topic/:period", async (req, res) => {
  const { topic, period } = req.params;

  if (!topic || !period) {
    return res.status(400).json({
      error: "Missing topic or period parameter",
    });
  }

  // Opt-in flag for the hourly bucket: a true rolling last-24-hours window
  // (Malaysia time) ending at the current hour, instead of "hours 0..now of
  // today". Callers that need a specific calendar day's 0..23 breakdown (e.g.
  // day-vs-day-before comparisons) must keep omitting this so they're
  // unaffected — see energy_comparison_widget.dart for the opted-in caller.
  const rolling = period === "hourly" && req.query.window === "rolling24h";

  // Optional chart filters (used by the Energy Flow Hourly/Daily cards):
  //   hourly + ?date=YYYY-MM-DD → that calendar day's 0..23 breakdown (MYT)
  //   daily  + ?month=YYYY-MM   → that calendar month's per-day breakdown
  // Both take precedence over the default windows; omitting them preserves the
  // original behaviour byte-for-byte for every other caller.
  const dateParam = period === "hourly" && /^\d{4}-\d{2}-\d{2}$/.test(req.query.date || "")
    ? req.query.date : null;
  const monthParam = period === "daily" && /^\d{4}-\d{2}$/.test(req.query.month || "")
    ? req.query.month : null;

  // ── Multi-tenant path ──────────────────────────────────────────────────────
  // Clients tagged with x-client-id (e.g. Thong Guan F0004) read pre-aggregated
  // consumption from their own MySQL Overall_*_energy_consumption tables, in the
  // same [{label, value}] shape the charts expect. Untagged (Danapac/Demo)
  // requests skip this entirely and keep the original energy_edel logic below.
  const clientId = req.clientId || req.headers["x-client-id"];
  if (clientId) {
    try {
      const cpool = await getMysql(req);
      const myt = "CONVERT_TZ(NOW(), '+00:00', '+08:00')";
      let sql = "";
      let sqlParams = [topic];
      if (period === "daily" && monthParam) {
        sql = `SELECT DATE_FORMAT(date, '%e/%c') AS label, SUM(energy_consumption_kWh) AS value
               FROM Overall_daily_energy_consumption
               WHERE device_id = ? AND DATE_FORMAT(date, '%Y-%m') = ?
               GROUP BY date ORDER BY date ASC`;
        sqlParams = [topic, monthParam];
      } else if (period === "daily") {
        // GROUP BY the raw `date` column (it's a DATE type) so the SELECT is
        // functionally dependent — required by ONLY_FULL_GROUP_BY. '%e/%c' → "18/6".
        sql = `SELECT DATE_FORMAT(date, '%e/%c') AS label, SUM(energy_consumption_kWh) AS value
               FROM Overall_daily_energy_consumption
               WHERE device_id = ? AND date >= DATE_SUB(DATE(${myt}), INTERVAL 31 DAY)
               GROUP BY date ORDER BY date ASC`;
      } else if (period === "monthly") {
        sql = `SELECT DATE_FORMAT(STR_TO_DATE(CONCAT(year, '-', LPAD(month, 2, '0'), '-01'), '%Y-%m-%d'), '%b') AS label,
                      SUM(energy_consumption_kWh) AS value
               FROM Overall_monthly_energy_consumption
               WHERE device_id = ? AND year = YEAR(${myt})
               GROUP BY year, month ORDER BY year ASC, month ASC`;
      } else if (period === "yearly") {
        sql = `SELECT CAST(year AS CHAR) AS label, SUM(energy_consumption_kWh) AS value
               FROM Overall_yearly_energy_consumption
               WHERE device_id = ?
               GROUP BY year ORDER BY year ASC`;
      } else if (period === "hourly" && dateParam) {
        // Specific calendar day picked in the Hourly chart's date filter.
        // event_time is stored in MYT, so the date string compares directly.
        sql = `SELECT DATE_FORMAT(event_time, '%H:00') AS label,
                      SUM(energy_consumption_kWh) AS value
               FROM Overall_hourly_energy_consumption
               WHERE device_id = ?
                 AND DATE(event_time) = ?
               GROUP BY DATE_FORMAT(event_time, '%H:00')
               ORDER BY MIN(event_time) ASC`;
        sqlParams = [topic, dateParam];
      } else if (period === "hourly" && rolling) {
        // Rolling last 24 hours ending at the current MYT hour — spans two
        // calendar dates around midnight, so DATE(event_time) must stay in
        // the GROUP BY/ORDER BY alongside the formatted hour label to keep
        // buckets distinct and chronological. event_time is already stored
        // in MYT (not UTC), so only NOW() needs the CONVERT_TZ.
        sql = `SELECT DATE_FORMAT(event_time, '%H:00') AS label,
                      SUM(energy_consumption_kWh) AS value
               FROM Overall_hourly_energy_consumption
               WHERE device_id = ?
                 AND event_time >  DATE_SUB(${myt}, INTERVAL 24 HOUR)
                 AND event_time <= ${myt}
               GROUP BY DATE(event_time), DATE_FORMAT(event_time, '%H:00')
               ORDER BY DATE(event_time) ASC, MIN(event_time) ASC`;
      } else if (period === "hourly") {
        sql = `SELECT DATE_FORMAT(event_time, '%H:00') AS label,
                      SUM(energy_consumption_kWh) AS value
               FROM Overall_hourly_energy_consumption
               WHERE device_id = ?
                 AND DATE(event_time) = DATE(${myt})
               GROUP BY DATE_FORMAT(event_time, '%H:00')
               ORDER BY MIN(event_time) ASC`;
      }
      if (sql) {
        const [rows] = await cpool.query(sql, sqlParams);
        const mapped = rows.map((r) => ({ label: String(r.label), value: Number(r.value) || 0 }));
        // Fill any point the consumption table has nothing for from the
        // generation table (VSOLAR / SOLAR meters), instead of an all-or-
        // nothing check on the whole series. A solar device that logged a
        // handful of early days into the consumption table — then stopped,
        // while its own generation table kept being fed live — used to read
        // as "has data" from that first handful alone, which skipped the
        // generation table entirely and left every later point blank for the
        // rest of the period.
        let genRows = [];
        try {
          genRows = (await dataFromGeneration(cpool, topic, period, rolling, dateParam, monthParam)) || [];
        } catch (ge) {
          console.warn(`[energyDetails/data] generation fallback failed for ${topic}: ${ge.message}`);
        }
        if (genRows.length === 0) return res.json(mapped);
        if (mapped.length === 0) return res.json(genRows);
        const byLabel = new Map(mapped.map((r) => [r.label, r.value]));
        for (const g of genRows) {
          const existing = byLabel.get(g.label);
          if (existing === undefined || existing <= 0) byLabel.set(g.label, g.value);
        }
        // Order by whichever side actually covers more points — for a
        // device the consumption table only partly logged, that is the
        // generation table; for an ordinary consumption meter with no
        // generation rows at all, it stays the consumption table's own order.
        const orderedLabels = (mapped.length >= genRows.length ? mapped : genRows).map((r) => r.label);
        const seen = new Set();
        const merged = [];
        for (const label of orderedLabels) {
          if (seen.has(label)) continue;
          seen.add(label);
          merged.push({ label, value: byLabel.get(label) || 0 });
        }
        return res.json(merged);
      }
    } catch (e) {
      console.warn(`[energyDetails/data] Overall_* query failed for client ${clientId}: ${e.message}`);
      // Consumption path failed — still try generation before falling through.
      try {
        const cpool = await getMysql(req);
        const genRows = await dataFromGeneration(cpool, topic, period, rolling, dateParam, monthParam);
        if (genRows && genRows.length > 0) return res.json(genRows);
      } catch (ge) {
        console.warn(`[energyDetails/data] generation fallback failed for ${topic}: ${ge.message}`);
      }
      // fall through to the default behaviour below
    }
  }

  let query = "";
  let params = [];
  switch (period) {
    case "hourly":
      if (dateParam) {
        // Specific calendar day from the Hourly chart's date filter. Every
        // hour of a past day is already in hourly_device_summary, so each
        // slot's value is that hour's reading minus the previous hour's
        // (hour 0 baselines against 23:00 of the day before). No energy_data
        // (live) join — the picked day is a completed one; picking "today"
        // is handled by the caller staying on the rolling24h window instead.
        query = `
          SELECT
            CAST(h.hr AS CHAR) AS label,
            IFNULL(cur.energy_edel - prev.energy_edel, 0) AS value
          FROM (
            SELECT 0 AS hr UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
            SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
            SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
            SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL
            SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL
            SELECT 15 UNION ALL SELECT 16 UNION ALL SELECT 17 UNION ALL
            SELECT 18 UNION ALL SELECT 19 UNION ALL SELECT 20 UNION ALL
            SELECT 21 UNION ALL SELECT 22 UNION ALL SELECT 23
          ) h
          LEFT JOIN (
            SELECT HOUR(timestamp) AS hr, energy_edel
            FROM hourly_device_summary
            WHERE device_id = ? AND DATE(timestamp) = ?
          ) cur ON h.hr = cur.hr
          LEFT JOIN (
            -- Previous-hour baseline: 23:00 of the day before maps to slot 0.
            SELECT
              CASE WHEN DATE(timestamp) < ? THEN 0 ELSE HOUR(timestamp) + 1 END AS hr,
              energy_edel
            FROM hourly_device_summary
            WHERE device_id = ?
              AND (DATE(timestamp) = ?
                   OR (DATE(timestamp) = DATE_SUB(?, INTERVAL 1 DAY) AND HOUR(timestamp) = 23))
          ) prev ON h.hr = prev.hr
          ORDER BY h.hr;
        `;
        params = [topic, dateParam, dateParam, topic, dateParam, dateParam];
        break;
      }
      if (rolling) {
        // Rolling last 24 hours ending at the current MYT hour. Each of the
        // 24 slots is an actual (date, hour) pair rather than "hour 0..23 of
        // today", so the window correctly spans back across midnight — e.g.
        // "now" = 5pm gives slots 6pm yesterday .. 5pm today, chronological.
        // Because every slot is <= the current hour by construction, the old
        // "zero out hours later than now" case no longer applies.
        query = `
          SELECT
            CAST(HOUR(slot.slot_time) AS CHAR) AS label,
            IFNULL(
              (CASE
                 WHEN slot.slot_time = slot.cur_hour THEN live.energy_edel
                 ELSE cursum.energy_edel
               END) - prevsum.energy_edel, 0)
            AS value
          FROM (
            SELECT
              DATE_SUB(cur.cur_hour, INTERVAL (23 - n.n) HOUR) AS slot_time,
              cur.cur_hour AS cur_hour
            FROM (
              SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL
              SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5 UNION ALL
              SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL
              SELECT 9 UNION ALL SELECT 10 UNION ALL SELECT 11 UNION ALL
              SELECT 12 UNION ALL SELECT 13 UNION ALL SELECT 14 UNION ALL
              SELECT 15 UNION ALL SELECT 16 UNION ALL SELECT 17 UNION ALL
              SELECT 18 UNION ALL SELECT 19 UNION ALL SELECT 20 UNION ALL
              SELECT 21 UNION ALL SELECT 22 UNION ALL SELECT 23
            ) n
            CROSS JOIN (
              SELECT DATE_FORMAT(DATE_ADD(NOW(), INTERVAL 8 HOUR), '%Y-%m-%d %H:00:00') AS cur_hour
            ) cur
          ) slot
          -- Reading for this slot's hour (skipped for the live/current slot).
          LEFT JOIN hourly_device_summary cursum
            ON cursum.device_id = ?
           AND DATE(cursum.timestamp) = DATE(slot.slot_time)
           AND HOUR(cursum.timestamp) = HOUR(slot.slot_time)
          -- Reading for the hour immediately before this slot (the delta baseline).
          LEFT JOIN hourly_device_summary prevsum
            ON prevsum.device_id = ?
           AND DATE(prevsum.timestamp) = DATE(DATE_SUB(slot.slot_time, INTERVAL 1 HOUR))
           AND HOUR(prevsum.timestamp) = HOUR(DATE_SUB(slot.slot_time, INTERVAL 1 HOUR))
          -- Live reading, only used for the current (still in-progress) hour.
          LEFT JOIN (
            SELECT energy_edel
            FROM energy_data
            WHERE device_id = ?
              AND DATE(timestamp) = DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR))
            ORDER BY timestamp DESC
            LIMIT 1
          ) live ON slot.slot_time = slot.cur_hour
          ORDER BY slot.slot_time ASC;
        `;
        params = [topic, topic, topic];
        break;
      }
      query = `
        SELECT
          CAST(h.hr AS CHAR) AS label,
          CASE
            WHEN h.hr > HOUR(DATE_ADD(NOW(), INTERVAL 8 HOUR)) THEN 0
            ELSE IFNULL(
                 (CASE
                     WHEN h.hr = HOUR(DATE_ADD(NOW(), INTERVAL 8 HOUR))
                       THEN curr_edata.energy_edel
                     ELSE curr_summary.energy_edel
                  END) - prev.energy_edel, 0)
          END AS value
        FROM (
          -- Generate numbers 0 through 23 as each hour of the day.
          SELECT 0 AS hr UNION ALL
          SELECT 1 UNION ALL
          SELECT 2 UNION ALL
          SELECT 3 UNION ALL
          SELECT 4 UNION ALL
          SELECT 5 UNION ALL
          SELECT 6 UNION ALL
          SELECT 7 UNION ALL
          SELECT 8 UNION ALL
          SELECT 9 UNION ALL
          SELECT 10 UNION ALL
          SELECT 11 UNION ALL
          SELECT 12 UNION ALL
          SELECT 13 UNION ALL
          SELECT 14 UNION ALL
          SELECT 15 UNION ALL
          SELECT 16 UNION ALL
          SELECT 17 UNION ALL
          SELECT 18 UNION ALL
          SELECT 19 UNION ALL
          SELECT 20 UNION ALL
          SELECT 21 UNION ALL
          SELECT 22 UNION ALL
          SELECT 23
        ) h
        -- Previous reading: For each hour, we need the energy_edel from the previous hour.
        LEFT JOIN (
          SELECT
            CASE
              WHEN DATE(timestamp) = DATE_SUB(DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR)), INTERVAL 1 DAY)
                   AND HOUR(timestamp) = 23
              THEN 0
              ELSE HOUR(timestamp) + 1
            END AS hr,
            energy_edel
          FROM hourly_device_summary
          WHERE device_id = ?
            AND (
                 DATE(timestamp) = DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR))
                 OR (DATE(timestamp) = DATE_SUB(DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR)), INTERVAL 1 DAY)
                     AND HOUR(timestamp) = 23)
            )
        ) prev ON h.hr = prev.hr
        -- For hours earlier than the current hour, use the stored hourly summary.
        LEFT JOIN (
          SELECT
            HOUR(timestamp) AS hr,
            energy_edel
          FROM hourly_device_summary
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR))
            AND HOUR(timestamp) < HOUR(DATE_ADD(NOW(), INTERVAL 8 HOUR))
        ) curr_summary ON h.hr = curr_summary.hr
        -- For the current hour, get the latest reading from the energy_data table.
        LEFT JOIN (
          SELECT
            HOUR(timestamp) AS hr,
            energy_edel
          FROM energy_data
          WHERE device_id = ?
            AND DATE(timestamp) = DATE(DATE_ADD(NOW(), INTERVAL 8 HOUR))
          ORDER BY timestamp DESC
          LIMIT 1
        ) curr_edata ON h.hr = curr_edata.hr
        ORDER BY h.hr;
      `;
      params = [topic, topic, topic];
      break;

    case "daily":
      if (monthParam) {
        // Specific calendar month from the Daily chart's month filter. Each
        // day's consumption is that day's end-of-day cumulative reading minus
        // the previous day's, from daily_device_summary. Today (which has no
        // summary row yet) is included via the live energy_data reading when
        // the picked month is the current one. Only days that actually have
        // a reading appear — gaps are simply absent from the series.
        query = `
          SELECT
            DATE_FORMAT(cur.d, '%e/%c') AS label,
            GREATEST(cur.e - COALESCE(prev.e, 0), 0) AS value
          FROM (
            SELECT d, MAX(e) AS e FROM (
              SELECT DATE(timestamp) AS d, energy_edel AS e
              FROM daily_device_summary
              WHERE device_id = ? AND DATE_FORMAT(timestamp, '%Y-%m') = ?
              UNION ALL
              SELECT DATE(NOW() + INTERVAL 8 HOUR) AS d, energy_edel AS e
              FROM energy_data
              WHERE device_id = ?
                AND DATE(timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
                AND DATE_FORMAT(NOW() + INTERVAL 8 HOUR, '%Y-%m') = ?
            ) u
            GROUP BY d
          ) cur
          LEFT JOIN (
            SELECT DATE(timestamp) AS d, MAX(energy_edel) AS e
            FROM daily_device_summary
            WHERE device_id = ?
            GROUP BY DATE(timestamp)
          ) prev ON prev.d = DATE_SUB(cur.d, INTERVAL 1 DAY)
          ORDER BY cur.d ASC;
        `;
        params = [topic, monthParam, topic, monthParam, topic];
        break;
      }
      query = `
        WITH week_days AS (
          -- Build a week (Monday to Sunday) based on Malaysia time
          SELECT DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY) AS week_day
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 1 DAY)
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 2 DAY)
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 3 DAY)
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 4 DAY)
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 5 DAY)
          UNION ALL
          SELECT DATE_ADD(DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL WEEKDAY(DATE(NOW() + INTERVAL 8 HOUR)) DAY), INTERVAL 6 DAY)
        )
        SELECT 
          DATE_FORMAT(week_day, '%e/%c') AS label,
          CASE
            WHEN week_day > DATE(NOW() + INTERVAL 8 HOUR) THEN 0
            WHEN week_day = DATE(NOW() + INTERVAL 8 HOUR) THEN 
              COALESCE((
                SELECT ed.energy_edel 
                FROM energy_data ed 
                WHERE ed.device_id = ? 
                  AND DATE(ed.timestamp) = DATE(NOW() + INTERVAL 8 HOUR)
                ORDER BY ed.timestamp DESC 
                LIMIT 1
              ), 0)
              -
              COALESCE((
                SELECT dds.energy_edel 
                FROM daily_device_summary dds
                WHERE dds.device_id = ? 
                  AND DATE(dds.timestamp) = DATE_SUB(DATE(NOW() + INTERVAL 8 HOUR), INTERVAL 1 DAY)
              ), 0)
            ELSE
              COALESCE((
                SELECT dds.energy_edel 
                FROM daily_device_summary dds
                WHERE dds.device_id = ? 
                  AND DATE(dds.timestamp) = week_day
              ), 0)
              -
              COALESCE((
                SELECT dds_prev.energy_edel 
                FROM daily_device_summary dds_prev
                WHERE dds_prev.device_id = ? 
                  AND DATE(dds_prev.timestamp) = DATE_SUB(week_day, INTERVAL 1 DAY)
              ), 0)
          END AS value
        FROM week_days
        ORDER BY week_day;
      `;
      params = [topic, topic, topic, topic];
      break;

    case "monthly":
      query = `
      WITH months AS (
        SELECT 1 AS month_index, 'Jan' AS label UNION ALL
        SELECT 2, 'Feb' UNION ALL
        SELECT 3, 'Mar' UNION ALL
        SELECT 4, 'Apr' UNION ALL
        SELECT 5, 'May' UNION ALL
        SELECT 6, 'Jun' UNION ALL
        SELECT 7, 'Jul' UNION ALL
        SELECT 8, 'Aug' UNION ALL
        SELECT 9, 'Sep' UNION ALL
        SELECT 10, 'Oct' UNION ALL
        SELECT 11, 'Nov' UNION ALL
        SELECT 12, 'Dec'
      )
      SELECT 
        m.label,
        CASE 
          WHEN m.month_index > MONTH(DATE(NOW() + INTERVAL 8 HOUR)) THEN 0
          WHEN m.month_index = MONTH(DATE(NOW() + INTERVAL 8 HOUR)) THEN 
              COALESCE((
                  SELECT ed.energy_edel 
                  FROM energy_data ed 
                  WHERE ed.device_id = ? 
                    AND YEAR(ed.timestamp) = YEAR(DATE(NOW() + INTERVAL 8 HOUR))
                    AND MONTH(ed.timestamp) = MONTH(DATE(NOW() + INTERVAL 8 HOUR))
                  ORDER BY ed.timestamp DESC 
                  LIMIT 1
              ), 0)
              -
              COALESCE((
                  SELECT dds.energy_edel 
                  FROM daily_device_summary dds
                  WHERE dds.device_id = ? 
                    AND YEAR(dds.timestamp) = CASE 
                                                WHEN MONTH(DATE(NOW() + INTERVAL 8 HOUR)) = 1 
                                                THEN YEAR(DATE(NOW() + INTERVAL 8 HOUR)) - 1 
                                                ELSE YEAR(DATE(NOW() + INTERVAL 8 HOUR)) 
                                              END
                    AND MONTH(dds.timestamp) = CASE 
                                                  WHEN MONTH(DATE(NOW() + INTERVAL 8 HOUR)) = 1 
                                                  THEN 12 
                                                  ELSE MONTH(DATE(NOW() + INTERVAL 8 HOUR)) - 1 
                                                END
                  ORDER BY dds.timestamp DESC
                  LIMIT 1
              ), 0)
          ELSE 
              COALESCE((
                  SELECT dds.energy_edel 
                  FROM daily_device_summary dds
                  WHERE dds.device_id = ? 
                    AND YEAR(dds.timestamp) = YEAR(DATE(NOW() + INTERVAL 8 HOUR))
                    AND MONTH(dds.timestamp) = m.month_index
                  ORDER BY dds.timestamp DESC 
                  LIMIT 1
              ), 0)
              -
              COALESCE((
                  SELECT dds_prev.energy_edel 
                  FROM daily_device_summary dds_prev
                  WHERE dds_prev.device_id = ? 
                    AND YEAR(dds_prev.timestamp) = CASE 
                                                    WHEN m.month_index = 1 
                                                    THEN YEAR(DATE(NOW() + INTERVAL 8 HOUR)) - 1 
                                                    ELSE YEAR(DATE(NOW() + INTERVAL 8 HOUR)) 
                                                  END
                    AND MONTH(dds_prev.timestamp) = CASE 
                                                      WHEN m.month_index = 1 
                                                      THEN 12 
                                                      ELSE m.month_index - 1 
                                                    END
                  ORDER BY dds_prev.timestamp DESC 
                  LIMIT 1
              ), 0)
        END AS value
      FROM months m
      ORDER BY m.month_index;
      `;
      params = [topic, topic, topic, topic];
      break;

    case "yearly":
      query = `
        SELECT
            CAST(target_years.yr AS CHAR) AS label,
            CASE
                WHEN target_years.yr = YEAR(DATE(NOW() + INTERVAL 8 HOUR)) THEN
                     COALESCE((
                       SELECT ed.energy_edel
                       FROM energy_data ed
                       WHERE ed.device_id = ? 
                         AND YEAR(ed.timestamp) = target_years.yr
                       ORDER BY ed.timestamp DESC
                       LIMIT 1
                     ), 0)
                     -
                     COALESCE((
                       SELECT dds.energy_edel
                       FROM daily_device_summary dds
                       WHERE dds.device_id = ? 
                         AND YEAR(dds.timestamp) = target_years.yr - 1
                       ORDER BY dds.timestamp DESC
                       LIMIT 1
                     ), 0)
                ELSE
                     COALESCE((
                       SELECT dds.energy_edel
                       FROM daily_device_summary dds
                       WHERE dds.device_id = ? 
                         AND YEAR(dds.timestamp) = target_years.yr
                       ORDER BY dds.timestamp DESC
                       LIMIT 1
                     ), 0)
                     -
                     COALESCE((
                       SELECT dds_prev.energy_edel
                       FROM daily_device_summary dds_prev
                       WHERE dds_prev.device_id = ? 
                         AND YEAR(dds_prev.timestamp) = target_years.yr - 1
                       ORDER BY dds_prev.timestamp DESC
                       LIMIT 1
                     ), 0)
            END AS value
        FROM
        (
          SELECT params.start_year + numbers.n AS yr
          FROM
          (
            SELECT 0 AS n UNION ALL SELECT 1 UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 
            UNION ALL SELECT 5 UNION ALL SELECT 6 UNION ALL SELECT 7 UNION ALL SELECT 8 UNION ALL SELECT 9
          ) AS numbers
          CROSS JOIN
          (
            SELECT IF(MIN(YEAR(timestamp)) < (YEAR(DATE(NOW() + INTERVAL 8 HOUR)) - 2),
                      MIN(YEAR(timestamp)),
                      (YEAR(DATE(NOW() + INTERVAL 8 HOUR)) - 2)
                     ) AS start_year
            FROM daily_device_summary
            WHERE device_id = ?
          ) AS params
          WHERE (params.start_year + numbers.n) <= YEAR(DATE(NOW() + INTERVAL 8 HOUR))
        ) AS target_years
        ORDER BY target_years.yr;
      `;
      params = [topic, topic, topic, topic, topic];
      break;

    default:
      return res.status(400).json({
        error: "Invalid period parameter. Use hourly, daily, monthly, or yearly.",
      });
  }

  pool.query(query, params, async (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }
    // Defensive: collapse any duplicate labels/dates from MySQL before checking/returning
    const deduped = dedupeByLabel(results);

    // If MySQL has no real data (all values are 0), fallback to InfluxDB
    const allZero = deduped.every((r) => !r.value || Number(r.value) === 0);
    if (allZero) {
      try {
        const today = new Date().toISOString().slice(0, 10);
        let influxData = [];
        if (period === "hourly") influxData = await influxHourlyFallback(topic, dateParam || today, req);
        else if (period === "daily") influxData = monthParam
          ? await influxDailyMonthFallback(topic, monthParam, req)
          : await influxDailyFallback(topic, req);
        else if (period === "monthly") influxData = await influxMonthlyFallback(topic, req);

        // Defensive: collapse any duplicate labels/dates from Influx too
        influxData = dedupeByLabel(influxData);

        if (influxData.length > 0 && influxData.some((r) => Number(r.value) > 0)) {
          return res.json(influxData);
        }
      } catch (e) {
        // ignore fallback errors, return MySQL (deduped) results
      }
    }
    return res.json(deduped);
  });
});

// ── GET /energyDetails/reading/:topic ─────────────────────────────────────────
// Returns the actual cumulative meter reading (energy_edel) — NOT a
// consumption delta, and not limited to today. Built for kWh/Tonne's Add Data
// tab, which needs the DPM's raw register value (not a per-hour delta like
// /data/:topic/hourly returns) in two shapes:
//   - ?date=&hour=  → reading at/immediately before that specific hour
//     boundary. Used for the "Previous Reading" anchor, which needs the DPM's
//     reading at shift start on whatever date was picked.
//   - ?date= only   → the latest reading available for that date, with no
//     hour bound. Used for "Meter Reading Now" — the operator needs the
//     DPM's current register value at the moment of weighing, not last
//     hour's, so pinning to an hour boundary would make it stale by up to
//     ~59 minutes.
router.get("/reading/:topic", async (req, res) => {
  const { topic } = req.params;
  const { date, hour } = req.query;

  if (!topic) return res.status(400).json({ error: "Missing topic parameter" });
  if (!/^\d{4}-\d{2}-\d{2}$/.test(date || "")) {
    return res.status(400).json({ error: "Missing/invalid date parameter — expected YYYY-MM-DD" });
  }
  const hasHour = hour !== undefined && hour !== "";
  let hr = null;
  if (hasHour) {
    hr = parseInt(hour, 10);
    if (!Number.isInteger(hr) || hr < 0 || hr > 23) {
      return res.status(400).json({ error: "Missing/invalid hour parameter — expected 0-23" });
    }
  }

  // Malaysia time is UTC+8 — parsing with an explicit offset gets the correct
  // UTC instant regardless of the server's own timezone. When there's no hour
  // (the "latest reading" mode), the Influx lookup's upper bound is simply now.
  const targetUtc = hasHour ? new Date(`${date}T${String(hr).padStart(2, "0")}:00:00+08:00`) : new Date();
  if (isNaN(targetUtc.getTime())) {
    return res.status(400).json({ error: "Invalid date/hour" });
  }

  const clientId = req.clientId || req.headers["x-client-id"];

  const readInflux = async () => {
    const { queryApi, bucket, schema } = await getInflux(req);
    const stop = targetUtc.toISOString();
    const start = new Date(targetUtc.getTime() - 48 * 3600 * 1000).toISOString();
    // Widen the lookback to 48h and take the last value at/before the target
    // instant — devices don't always report exactly on the hour, so "closest
    // prior reading" is a more reliable anchor than "reading inside this hour".
    const flux = `
      from(bucket: "${bucket}")
        |> range(start: ${start}, stop: ${stop})
        |> filter(fn: (r) => r._measurement == "${schema.measurement}")
        ${deviceFilter(schema, topic)}
        |> filter(fn: (r) => ${ENERGY_FIELD_FILTER})
        |> last()
    `;
    const rows = await runInfluxQuery(queryApi, flux);
    if (!rows.length) return null;
    return { reading: rows[0]._value, timestamp: rows[0]._time, source: "influx" };
  };

  // Primary source for every tenant: the cumulative register value
  // (accum_energy_consumption_kWh) from MySQL Overall_hourly_energy_consumption,
  // filtered by device_id (the meterId the kWh/Tonne tab passes as :topic):
  //   - ?date=&hour= ("Previous Reading" anchor) → latest row at/before the
  //     shift-start instant.
  //   - no hour ("Meter Reading Now") → the device's latest row in the
  //     table, no time bound.
  // Deployments disagree on the time column name (timestamp vs event_time —
  // see the data-logger endpoint below), so try both. When the table is
  // missing or has no rows, fall through to the legacy per-tenant logic
  // below (Influx for client-tagged requests, energy_data/summaries for
  // Danapac/demo).
  try {
    const cpool = await getMysql(req);
    // Rows are stored in MYT (not UTC), so compare against the target
    // instant shifted to MYT.
    const targetMyt = new Date(targetUtc.getTime() + 8 * 3600 * 1000)
      .toISOString().slice(0, 19).replace("T", " ");
    for (const timeCol of ["timestamp", "event_time"]) {
      try {
        const [rows] = await cpool.query(
          `SELECT accum_energy_consumption_kWh, ${timeCol} AS ts
           FROM Overall_hourly_energy_consumption
           WHERE device_id = ?${hasHour ? ` AND ${timeCol} <= ?` : ""}
           ORDER BY ${timeCol} DESC LIMIT 1`,
          hasHour ? [topic, targetMyt] : [topic]
        );
        if (rows.length && rows[0].accum_energy_consumption_kWh != null) {
          return res.json({
            reading: Number(rows[0].accum_energy_consumption_kWh),
            timestamp: rows[0].ts,
            source: "mysql_overall_hourly",
          });
        }
        break; // time column exists but no rows for this device — use the legacy fallback
      } catch (e) {
        if (e.code === "ER_BAD_FIELD_ERROR") continue;
        throw e;
      }
    }
  } catch (e) {
    console.warn(`[reading] Overall_hourly query failed${clientId ? ` for client ${clientId}` : ""}: ${e.message}`);
  }

  if (clientId) {
    try {
      const result = await readInflux();
      return res.json(result || { reading: null });
    } catch (err) {
      return res.status(500).json({ error: err.message });
    }
  }

  // Default (Danapac/demo) tenant: MySQL has the raw energy_edel reading.
  try {
    const cpool = await getMysql(req);

    if (!hasHour) {
      // "Latest reading" mode — no hour bound. energy_data only retains
      // today's live readings (see getEnergyAsOf above), so try it first,
      // then fall back to daily_device_summary for a backfilled past date.
      const [liveRows] = await cpool.query(
        `SELECT energy_edel, timestamp FROM energy_data
         WHERE device_id = ? AND DATE(timestamp) = ?
         ORDER BY timestamp DESC LIMIT 1`,
        [topic, date]
      );
      if (liveRows.length) {
        return res.json({ reading: liveRows[0].energy_edel, timestamp: liveRows[0].timestamp, source: "mysql_live" });
      }

      const [dailyRows] = await cpool.query(
        `SELECT energy_edel, timestamp FROM daily_device_summary
         WHERE device_id = ? AND DATE(timestamp) = ?
         ORDER BY timestamp DESC LIMIT 1`,
        [topic, date]
      );
      if (dailyRows.length) {
        return res.json({ reading: dailyRows[0].energy_edel, timestamp: dailyRows[0].timestamp, source: "mysql_daily_summary" });
      }

      const influxResult = await readInflux();
      return res.json(influxResult || { reading: null });
    }

    const [summaryRows] = await cpool.query(
      `SELECT energy_edel, timestamp FROM hourly_device_summary
       WHERE device_id = ? AND DATE(timestamp) = ? AND HOUR(timestamp) = ?
       LIMIT 1`,
      [topic, date, hr]
    );
    if (summaryRows.length) {
      return res.json({ reading: summaryRows[0].energy_edel, timestamp: summaryRows[0].timestamp, source: "mysql_summary" });
    }

    const [rawRows] = await cpool.query(
      `SELECT energy_edel, timestamp FROM energy_data
       WHERE device_id = ? AND timestamp <= ?
       ORDER BY timestamp DESC LIMIT 1`,
      [topic, `${date} ${String(hr).padStart(2, "0")}:00:00`]
    );
    if (rawRows.length) {
      return res.json({ reading: rawRows[0].energy_edel, timestamp: rawRows[0].timestamp, source: "mysql_raw" });
    }

    // Neither MySQL table has data for this device/hour — fall back to Influx.
    const influxResult = await readInflux();
    return res.json(influxResult || { reading: null });
  } catch (err) {
    return res.status(500).json({ error: err.message });
  }
});

// Current day max demand + energy consumption (called by energy details widget)
router.get("/current/:topic", (req, res) => {
  const { topic } = req.params;
  if (!topic) return res.status(400).json({ error: "Missing topic parameter" });

  const query = `
    SELECT
      COALESCE(MAX(power_p), 0) AS max_demand_kW,
      COALESCE(
        (SELECT ed2.energy_edel FROM energy_data ed2
          WHERE ed2.device_id = ?
            AND DATE(CONVERT_TZ(ed2.timestamp, '+00:00', '+08:00')) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))
          ORDER BY ed2.timestamp DESC LIMIT 1)
        -
        (SELECT dds.energy_edel FROM daily_device_summary dds
          WHERE dds.device_id = ?
            AND DATE(CONVERT_TZ(dds.timestamp, '+00:00', '+08:00')) = DATE_SUB(DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')), INTERVAL 1 DAY)
          ORDER BY dds.timestamp DESC LIMIT 1),
        0
      ) AS energy_consumption_kWh
    FROM energy_data ed
    WHERE ed.device_id = ?
      AND DATE(CONVERT_TZ(ed.timestamp, '+00:00', '+08:00')) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))
  `;

  pool.promise().query(query, [topic, topic, topic]).then(async ([results]) => {
    const row = results[0] ?? {};
    const maxDemand = Number(row.max_demand_kW ?? 0);
    const energyKwh = Number(row.energy_consumption_kWh ?? 0);

    if (maxDemand === 0 && energyKwh === 0) {
      // Fallback to InfluxDB for peak demand and today's energy consumption
      try {
        const { queryApi, bucket, schema } = await getInflux(req);
        const today = new Date();
        const todayStart = new Date(today); todayStart.setUTCHours(0,0,0,0);
        const peakQ = `
          from(bucket: "${bucket}")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${POWER_FIELD_FILTER}))
            ${deviceFilter(schema, topic)}
            |> max()
        `;
        const edelFirstQ = `
          from(bucket: "${bucket}")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
            ${deviceFilter(schema, topic)}
            |> first()
        `;
        const edelLastQ = `
          from(bucket: "${bucket}")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${ENERGY_FIELD_FILTER}))
            ${deviceFilter(schema, topic)}
            |> last()
        `;
        const [peakRows, firstRows, lastRows] = await Promise.all([
          runInfluxQuery(queryApi, peakQ), runInfluxQuery(queryApi, edelFirstQ), runInfluxQuery(queryApi, edelLastQ),
        ]);
        const peak = peakRows[0]?._value ?? 0;
        const edelFirst = firstRows[0]?._value ?? 0;
        const edelLast  = lastRows[0]?._value ?? 0;
        return res.json({
          max_demand_kW: parseFloat(peak.toFixed(2)),
          energy_consumption_kWh: parseFloat(Math.max(0, edelLast - edelFirst).toFixed(3)),
        });
      } catch (e) {
        // ignore, return zeros
      }
    }
    res.json({ max_demand_kW: maxDemand, energy_consumption_kWh: energyKwh });
  }).catch((error) => {
    res.status(500).json({ error: "Database error", message: error.message });
  });
});

// 24h power load history (called by MD Prediction)
router.get("/power-load-24h/:deviceId", async (req, res) => {
  const { deviceId } = req.params;
  if (!deviceId) return res.status(400).json({ error: "Missing deviceId parameter" });

  // Multi-tenant clients (e.g. Thong Guan) read the 30-min MD interval reading
  // (max_demand_kW, x-axis = timestamp) from their own MySQL
  // Overall_hourly_energy_consumption. Untagged (Danapac/Demo) requests skip this
  // and keep the energy_data + Influx logic below.
  const clientId = req.clientId || req.headers["x-client-id"];
  if (clientId) {
    try {
      const cpool = await getMysql(req);
      const [rows] = await cpool.query(
        `SELECT DATE_FORMAT(timestamp, '%H:%i') AS time_label, power_kW, max_demand_kW
         FROM Overall_hourly_energy_consumption
         WHERE device_id = ?
         ORDER BY timestamp DESC LIMIT 48`, [deviceId]);
      const data = rows.reverse().map((r) => ({
        time_label: r.time_label,
        power_kW: Number(r.power_kW) || 0,
        max_demand_kW: Number(r.max_demand_kW) || 0,
      }));
      const vals = data.map((r) => r.max_demand_kW).filter((v) => v > 0);
      const maxD = vals.length ? Math.max(...vals) : 0;
      const statistics = {
        max_demand_kW: maxD,
        min_demand_kW: vals.length ? Math.min(...vals) : 0,
        avg_demand_kW: vals.length ? Number((vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(2)) : 0,
        current_max_demand_kW: maxD,
      };
      return res.json({ data, statistics });
    } catch (e) {
      console.warn(`[power-load-24h] Overall_hourly query failed for client ${clientId}: ${e.message}`);
      // fall through to the default behaviour below
    }
  }

  const dataSql = `
    SELECT
      DATE_FORMAT(FROM_UNIXTIME(slot * 1800), '%H:%i') AS time_label,
      ROUND(MAX(power_p), 2) AS max_demand_kW
    FROM (
      SELECT FLOOR(UNIX_TIMESTAMP(CONVERT_TZ(timestamp, '+00:00', '+08:00')) / 1800) AS slot, power_p
      FROM energy_data
      WHERE device_id = ? AND timestamp >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
    ) t
    GROUP BY slot ORDER BY slot
  `;
  const statsSql = `
    SELECT
      ROUND(MAX(power_p), 2) AS max_demand_kW,
      ROUND(MIN(power_p), 2) AS min_demand_kW,
      ROUND(AVG(power_p), 2) AS avg_demand_kW
    FROM energy_data
    WHERE device_id = ? AND timestamp >= DATE_SUB(NOW(), INTERVAL 24 HOUR)
  `;

  Promise.all([pool.promise().query(dataSql, [deviceId]), pool.promise().query(statsSql, [deviceId])])
    .then(async ([[dataRows], [statsRows]]) => {
      const allZero = dataRows.every((r) => !r.max_demand_kW || Number(r.max_demand_kW) === 0);
      if (allZero) {
        try {
          const { queryApi, bucket, schema } = await getInflux(req);
          const flux = `
            from(bucket: "${bucket}")
              |> range(start: -24h)
              |> filter(fn: (r) => r._measurement == "${schema.measurement}" and (${POWER_FIELD_FILTER}))
              ${deviceFilter(schema, deviceId)}
              |> aggregateWindow(every: 30m, fn: max, createEmpty: false)
          `;
          const rows = await runInfluxQuery(queryApi, flux);
          const data = rows.map((r) => {
            const d = new Date(r._time);
            const hh = String(d.getUTCHours()).padStart(2, "0");
            const mm = String(d.getUTCMinutes()).padStart(2, "0");
            return { time_label: `${hh}:${mm}`, max_demand_kW: parseFloat((r._value || 0).toFixed(2)) };
          });
          const vals = data.map((r) => r.max_demand_kW).filter((v) => v > 0);
          const maxVal = vals.length ? Math.max(...vals) : 0;
          const stats = {
            max_demand_kW: maxVal,
            current_max_demand_kW: maxVal,
            min_demand_kW: vals.length ? Math.min(...vals) : 0,
            avg_demand_kW: vals.length ? parseFloat((vals.reduce((a, b) => a + b, 0) / vals.length).toFixed(2)) : 0,
          };
          return res.json({ data, statistics: stats });
        } catch (e) { /* fallthrough */ }
      }
      const s = statsRows[0] || { max_demand_kW: 0, min_demand_kW: 0, avg_demand_kW: 0 };
      res.json({ data: dataRows, statistics: { ...s, current_max_demand_kW: s.max_demand_kW || 0 } });
    }).catch((error) => {
      res.json({ data: [], statistics: { max_demand_kW: 0, current_max_demand_kW: 0, min_demand_kW: 0, avg_demand_kW: 0 } });
    });
});

// ── Monthly max demand ────────────────────────────────────────────────────────
// Scans the full calendar month (1st 00:00 → last day 23:59:59) and, when the
// caller supplies the site's peak-hour (TOU) window, restricts the scan to
// only readings that fall inside it before taking the highest one — matching
// how MD is actually billed instead of picking up an off-peak spike.
// Query params (all optional): peak_start=HH:mm, peak_end=HH:mm,
// peak_days=1,2,3,4,5 (Dart DateTime.weekday convention, 1=Mon…7=Sun).
router.get("/monthly-max-demand/:deviceId", async (req, res) => {
  const { deviceId } = req.params;
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
  const monthEnd = new Date(now.getFullYear(), now.getMonth() + 1, 0, 23, 59, 59).toISOString();
  const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString();
  const lastMonthEnd = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59).toISOString();

  const peakStart = /^\d{1,2}:\d{2}$/.test(req.query.peak_start || "") ? req.query.peak_start : null;
  const peakEnd = /^\d{1,2}:\d{2}$/.test(req.query.peak_end || "") ? req.query.peak_end : null;
  let peakFilterFlux = "";
  let daysSet = null;
  if (peakStart && peakEnd) {
    daysSet = (req.query.peak_days || "")
      .split(",")
      .map((d) => parseInt(d, 10))
      .filter((d) => d >= 1 && d <= 7)
      .map((d) => d % 7); // Dart weekday (1=Mon…7=Sun) → Flux date.weekDay (0=Sun…6=Sat)
    if (!daysSet.length) daysSet = [0, 1, 2, 3, 4, 5, 6];

    const [sh, sm] = peakStart.split(":").map(Number);
    const [eh, em] = peakEnd.split(":").map(Number);
    const startMin = sh * 60 + sm;
    const endMin = eh * 60 + em;
    const inWindow = startMin < endMin
      ? `minuteOfDay >= ${startMin} and minuteOfDay < ${endMin}`
      : `minuteOfDay >= ${startMin} or minuteOfDay < ${endMin}`; // window crosses midnight

    peakFilterFlux = `
      |>filter(fn:(r) => {
          minuteOfDay = date.hour(t: r._time) * 60 + date.minute(t: r._time)
          wd = date.weekDay(t: r._time)
          return contains(value: wd, set: [${daysSet.join(",")}]) and (${inWindow})
        })`;
  }
  const fluxImports = peakFilterFlux ? `import "date"\n` : "";

  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const [currRows, prevRows] = await Promise.all([
      runInfluxQuery(queryApi, `${fluxImports}from(bucket:"${bucket}")|>range(start:${monthStart},stop:${monthEnd})|>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))${deviceFilter(schema, deviceId)}${peakFilterFlux}|>max()`),
      runInfluxQuery(queryApi, `${fluxImports}from(bucket:"${bucket}")|>range(start:${lastMonthStart},stop:${lastMonthEnd})|>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))${deviceFilter(schema, deviceId)}${peakFilterFlux}|>max()`),
    ]);
    const result = {
      max_demand_kW: parseFloat((currRows[0]?._value || 0).toFixed(2)),
      previous_month_max_demand_kW: parseFloat((prevRows[0]?._value || 0).toFixed(2)),
    };
    console.log(
      `[monthly-max-demand] device=${deviceId} range=${monthStart}..${monthEnd} ` +
      `peak=${peakStart || "-"}-${peakEnd || "-"} days=${daysSet ? daysSet.join(",") : "-"} ` +
      `-> max=${result.max_demand_kW}kW prev=${result.previous_month_max_demand_kW}kW`
    );
    return res.json(result);
  } catch (e) {
    return res.json({ max_demand_kW: 0, previous_month_max_demand_kW: 0 });
  }
});

// ── Max demand chart (daily max per day this month) ───────────────────────────
router.get("/max-demand-chart", async (req, res) => {
  const deviceId = req.query.device_id;
  if (!deviceId) return res.status(400).json({ error: "Missing device_id" });

  // Multi-tenant clients read this month's daily max demand straight from their
  // own MySQL Overall_daily_energy_consumption.max_demand_kW. Untagged
  // (Danapac/Demo) requests skip this and keep the Influx aggregation below.
  const clientId = req.clientId || req.headers["x-client-id"];
  if (clientId) {
    try {
      const cpool = await getMysql(req);
      const [rows] = await cpool.query(
        `SELECT DATE_FORMAT(date, '%b %e') AS label, MAX(max_demand_kW) AS value, DATE_FORMAT(date, '%Y-%m-%d') AS d
         FROM Overall_daily_energy_consumption
         WHERE device_id = ? AND YEAR(date) = YEAR(CURDATE()) AND MONTH(date) = MONTH(CURDATE())
         GROUP BY date ORDER BY date ASC`, [deviceId]);
      return res.json(rows.map((r) => ({ label: String(r.label), value: Number(r.value) || 0, date: r.d })));
    } catch (e) {
      console.warn(`[max-demand-chart] Overall_daily query failed for client ${clientId}: ${e.message}`);
      // fall through to the Influx behaviour below
    }
  }

  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const rows = await runInfluxQuery(queryApi, `
      from(bucket:"${bucket}")
        |>range(start:${monthStart})
        |>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))
        ${deviceFilter(schema, deviceId)}
        |>aggregateWindow(every:1d,fn:max,createEmpty:false)
    `);
    const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    const result = rows.map((r) => {
      const d = new Date(r._time);
      return { label: `${months[d.getUTCMonth()]} ${d.getUTCDate()}`, value: parseFloat((r._value || 0).toFixed(2)), date: r._time.slice(0,10) };
    });
    // Defensive: a device reporting under more than one power-field alias
    // (P, P_kW, Active_Power_kW) produces one aggregated row per field per
    // day — collapse to one row per day, keeping the higher reading.
    return res.json(dedupeByLabel(result));
  } catch (e) {
    return res.json([]);
  }
});

// ── Max demand events (peak events this month) ────────────────────────────────
router.get("/max-demand-events", async (req, res) => {
  const deviceId = req.query.device_id;
  if (!deviceId) return res.status(400).json({ error: "Missing device_id" });
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();

  // ── MySQL primary: per-day max demand reading from Overall_hourly_energy_consumption ──
  try {
    const pool = await getMysql(req);
    // max_demand_kW is a running monthly-peak value (only increases through the
    // billing month), so each distinct value's first timestamp is a new MD event.
    const [rows] = await pool.query(
      `SELECT
         DATE_FORMAT(MIN(timestamp), '%Y-%m-%d') AS date,
         DATE_FORMAT(MIN(timestamp), '%H:%i:00') AS time,
         max_demand_kW AS maximum_demand_kw
       FROM Overall_hourly_energy_consumption
       WHERE device_id = ? AND timestamp >= DATE_FORMAT(NOW(), '%Y-%m-01')
       GROUP BY max_demand_kW
       ORDER BY maximum_demand_kw DESC`,
      [deviceId]
    );

    if (rows && rows.length > 0) {
      let overallMax = 0;
      const events = rows.map((r) => {
        const val = Number(r.maximum_demand_kw) || 0;
        if (val > overallMax) overallMax = val;
        return {
          date: r.date,
          time: r.time,
          duration: "30 min",
          maximum_demand_kw: parseFloat(val.toFixed(2)),
          contract_capacity_percent: "N/A",
          status: "Normal",
        };
      });
      return res.json({ data: events, max_demand: parseFloat(overallMax.toFixed(2)) });
    }
  } catch (e) {
    // fall through to InfluxDB
  }

  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const rows = await runInfluxQuery(queryApi, `
      from(bucket:"${bucket}")
        |>range(start:${monthStart})
        |>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))
        ${deviceFilter(schema, deviceId)}
        |>aggregateWindow(every:1d,fn:max,createEmpty:false)
    `);
    let overallMax = 0;
    const events = rows.map((r) => {
      const val = r._value || 0;
      if (val > overallMax) overallMax = val;
      const d = new Date(r._time);
      const dateStr = r._time.slice(0,10);
      return {
        date: dateStr,
        time: `${String(d.getUTCHours()).padStart(2,"0")}:${String(d.getUTCMinutes()).padStart(2,"0")}:00`,
        duration: "30 min",
        maximum_demand_kw: parseFloat(val.toFixed(2)),
        contract_capacity_percent: "N/A",
        status: "Normal",
      };
    }).sort((a, b) => b.maximum_demand_kw - a.maximum_demand_kw);
    return res.json({ data: events, max_demand: parseFloat(overallMax.toFixed(2)) });
  } catch (e) {
    return res.json({ data: [], max_demand: 0 });
  }
});

// ── Equipment MD ranking (peak per device in event window) ────────────────────
// MySQL-only by design: every device this chart ranks (physical meters and
// virtual/derived ones like VDPM003 alike) has a daily rollup row here, so
// there's no need for an Influx leg. Overall_hourly_energy_consumption.max_demand_kW
// is a running monthly-peak value (only increases through the billing month),
// so MAX() over an intraday window would just return the latest cumulative
// reading — Overall_daily_energy_consumption.max_demand_kW holds that day's
// own peak instead.
router.get("/equipment-md-ranking", async (req, res) => {
  const { event_date, event_start, event_end, device_id } = req.query;
  if (!event_date) return res.status(400).json({ error: "Missing event_date" });
  const startSql = event_start || `${event_date} 00:00:00`;
  const stopSql  = event_end   || `${event_date} 23:59:59`;
  const requestedIds = (device_id || "")
    .split(",")
    .map((s) => s.trim())
    .filter(Boolean);

  if (requestedIds.length === 0) return res.json({ data: [] });

  let peaks = {};
  try {
    const cpool = await getMysql(req);
    const dateStart = startSql.slice(0, 10);
    const dateStop = stopSql.slice(0, 10);
    const [rows] = await cpool.query(
      `SELECT device_id, MAX(max_demand_kW) AS peak
       FROM Overall_daily_energy_consumption
       WHERE device_id IN (?) AND date BETWEEN ? AND ?
       GROUP BY device_id`,
      [requestedIds, dateStart, dateStop]
    );
    rows.forEach((r) => {
      const peak = Number(r.peak) || 0;
      if (peak > 0) peaks[r.device_id] = peak;
    });
  } catch (e) {
    // No MySQL for this tenant / table missing — return whatever we have (nothing).
  }

  const total = Object.values(peaks).reduce((s, v) => s + v, 0);
  const data = Object.entries(peaks)
    .map(([id, peak]) => ({
      device_id: id,
      peak_demand_kW: parseFloat(peak.toFixed(2)),
      percentage: total > 0 ? parseFloat(((peak / total) * 100).toFixed(1)) : 0,
    }))
    .sort((a, b) => b.peak_demand_kW - a.peak_demand_kW);
  return res.json({ data });
});

// ── Year-on-year analysis ─────────────────────────────────────────────────────
router.get("/year-on-year-analysis", async (req, res) => {
  const deviceId = req.query.device_id;
  if (!deviceId) return res.status(400).json({ error: "Missing device_id" });
  const now = new Date();
  const thisYearStart = new Date(now.getFullYear(), 0, 1).toISOString();
  const lastYearStart = new Date(now.getFullYear() - 1, 0, 1).toISOString();
  const lastYearEnd   = new Date(now.getFullYear() - 1, 11, 31, 23, 59, 59).toISOString();
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];

  // ── MySQL primary: per-month max demand from Overall_monthly_energy_consumption ──
  try {
    const currentYear = now.getFullYear();
    const pool = await getMysql(req);
    const [rows] = await pool.query(
      `SELECT year, month, max_demand_kW
       FROM Overall_monthly_energy_consumption
       WHERE device_id = ? AND year IN (?, ?)`,
      [deviceId, currentYear, currentYear - 1]
    );

    if (rows && rows.length > 0) {
      const currMap = {};
      const prevMap = {};
      rows.forEach((r) => {
        const val = Number(r.max_demand_kW) || 0;
        if (r.year === currentYear) currMap[r.month] = val;
        else if (r.year === currentYear - 1) prevMap[r.month] = val;
      });
      const data = months.map((label, i) => {
        const m = i + 1;
        return {
          month: m,
          month_label: label,
          current_period_max_demand_kW: parseFloat((currMap[m] || 0).toFixed(2)),
          previous_period_max_demand_kW: parseFloat((prevMap[m] || 0).toFixed(2)),
          device_id: deviceId,
        };
      });
      return res.json({
        data,
        comparison: { previous_period: String(currentYear - 1), current_period: String(currentYear), description: "Year-on-Year comparison" },
      });
    }
  } catch (e) {
    // fall through to InfluxDB
  }

  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const [currRows, prevRows] = await Promise.all([
      runInfluxQuery(queryApi, `from(bucket:"${bucket}")|>range(start:${thisYearStart})|>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))${deviceFilter(schema, deviceId)}|>aggregateWindow(every:30d,fn:max,createEmpty:false)`),
      runInfluxQuery(queryApi, `from(bucket:"${bucket}")|>range(start:${lastYearStart},stop:${lastYearEnd})|>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))${deviceFilter(schema, deviceId)}|>aggregateWindow(every:30d,fn:max,createEmpty:false)`),
    ]);
    const prevMap = {};
    prevRows.forEach((r) => { const m = new Date(r._time).getUTCMonth(); prevMap[m] = r._value || 0; });
    const data = currRows.map((r) => {
      const m = new Date(r._time).getUTCMonth();
      return {
        month: m + 1,
        month_label: months[m],
        current_period_max_demand_kW: parseFloat((r._value || 0).toFixed(2)),
        previous_period_max_demand_kW: parseFloat((prevMap[m] || 0).toFixed(2)),
        device_id: deviceId,
      };
    });
    return res.json({
      data,
      comparison: { previous_period: String(now.getFullYear() - 1), current_period: String(now.getFullYear()), description: "Year-on-Year comparison" },
    });
  } catch (e) {
    return res.json({ data: [], comparison: {} });
  }
});

// ── Equipment PF ranking (avg PF per device in event window) ─────────────────
router.get("/equipment-pf-ranking", async (req, res) => {
  const { event_date, event_start, event_end } = req.query;
  if (!event_date) return res.status(400).json({ error: "Missing event_date" });
  const start = event_start ? event_start.replace(" ", "T") + "Z" : `${event_date}T00:00:00Z`;
  const stop  = event_end   ? event_end.replace(" ", "T") + "Z"   : `${event_date}T23:59:59Z`;
  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const tag = schema.deviceIdTag;
    const rows = await runInfluxQuery(queryApi, `
      from(bucket:"${bucket}")
        |>range(start:${start},stop:${stop})
        |>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (r._field=="PF" or r._field=="Power_Factor"))
        ${deviceFilter(schema, null)}
        |>mean()
        |>group(columns:["${tag}"])
    `);
    const data = rows
      .filter((r) => r[tag])
      .map((r) => ({
        device_id: r[tag],
        power_factor_avg: parseFloat((r._value || 0).toFixed(4)),
        percentage: parseFloat(((r._value || 0) * 100).toFixed(1)),
      }))
      .sort((a, b) => a.power_factor_avg - b.power_factor_avg); // worst PF first
    return res.json({ data });
  } catch (e) {
    return res.json({ data: [] });
  }
});

// ── Average power load distribution (by time-of-day period) ──────────────────
// Default Power Load Distribution buckets — matches the TNB Meter Setting
// dialog's default config (see TnbMeterDashboardConfig.defaultBuckets on the
// Flutter side) so a meter with no saved config renders identically to today.
const DEFAULT_DISTRIBUTION_BUCKETS = [
  { key: "morning", label: "Morning", startTime: "06:00", endTime: "12:00" },
  { key: "afternoon", label: "Afternoon", startTime: "12:00", endTime: "18:00" },
  { key: "evening", label: "Evening", startTime: "18:00", endTime: "22:00" },
  { key: "night", label: "Night", startTime: "22:00", endTime: "06:00" },
];

// Parses the optional ?buckets= query param (JSON array of
// {key,label,startTime,endTime} with "HH:mm" times) sent by the TNB Meter
// Setting dialog's Power Load Distribution panel. Falls back to null (→
// DEFAULT_DISTRIBUTION_BUCKETS) on anything malformed rather than erroring,
// since this only affects a chart's bucketing, never a write.
function parseBucketsParam(raw) {
  if (!raw) return null;
  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length === 0) return null;
    const timeRe = /^([01]?\d|2[0-3]):[0-5]\d$/;
    const clean = parsed
      .filter((b) => b && typeof b === "object" && timeRe.test(b.startTime) && timeRe.test(b.endTime))
      .slice(0, 12)
      .map((b) => ({
        key: String(b.key || b.label || "bucket").slice(0, 40),
        label: String(b.label || b.key || "Bucket").slice(0, 60),
        startTime: b.startTime,
        endTime: b.endTime,
      }));
    return clean.length ? clean : null;
  } catch (e) {
    return null;
  }
}

// Buckets a Map<hour(0-23), {avg, count}> (average power + sample count per
// hour-of-day) into the given custom windows, supporting windows that wrap
// past midnight (e.g. 22:00–06:00). Each bucket's average is the sample-
// count-weighted mean of the hours it covers.
function bucketAverages(hourlyByHour, buckets) {
  return buckets.map((b) => {
    const sh = parseInt(String(b.startTime).split(":")[0], 10) || 0;
    const eh = parseInt(String(b.endTime).split(":")[0], 10) || 0;
    const hours = [];
    if (sh === eh) {
      for (let h = 0; h < 24; h++) hours.push(h);
    } else if (sh < eh) {
      for (let h = sh; h < eh; h++) hours.push(h);
    } else {
      for (let h = sh; h < 24; h++) hours.push(h);
      for (let h = 0; h < eh; h++) hours.push(h);
    }
    let sumWeighted = 0;
    let totalCount = 0;
    hours.forEach((h) => {
      const r = hourlyByHour.get(h);
      if (r) {
        sumWeighted += r.avg * r.count;
        totalCount += r.count;
      }
    });
    const avg = totalCount > 0 ? sumWeighted / totalCount : 0;
    return {
      key: b.key,
      time_period: b.label,
      average_power_load_kW: parseFloat(avg.toFixed(2)),
      total_energy_kWh: parseFloat((avg * totalCount).toFixed(2)),
      hours_count: totalCount,
    };
  });
}

router.get("/average-power-load/:deviceId", async (req, res) => {
  const { deviceId } = req.params;
  const buckets = parseBucketsParam(req.query.buckets) || DEFAULT_DISTRIBUTION_BUCKETS;

  // ── MySQL primary: hourly readings from Overall_hourly_energy_consumption ──
  try {
    const pool = await getMysql(req);
    const [rows] = await pool.query(
      `SELECT HOUR(timestamp) AS hr, AVG(power_kW) AS avg_kw, COUNT(*) AS cnt
       FROM Overall_hourly_energy_consumption
       WHERE device_id = ? AND timestamp >= DATE_SUB(NOW(), INTERVAL 30 DAY)
       GROUP BY hr`,
      [deviceId]
    );

    if (rows && rows.length > 0) {
      const hourlyByHour = new Map();
      rows.forEach((r) => {
        hourlyByHour.set(Number(r.hr), { avg: Number(r.avg_kw) || 0, count: Number(r.cnt) || 0 });
      });
      return res.json({ data: bucketAverages(hourlyByHour, buckets) });
    }
  } catch (e) {
    // fall through to InfluxDB
  }

  try {
    const { queryApi, bucket, schema } = await getInflux(req);
    const rows = await runInfluxQuery(queryApi, `
      from(bucket:"${bucket}")
        |>range(start:-30d)
        |>filter(fn:(r)=>r._measurement=="${schema.measurement}" and (${POWER_FIELD_FILTER}))
        ${deviceFilter(schema, deviceId)}
        |>aggregateWindow(every:1h,fn:mean,createEmpty:false)
    `);
    const hourlyTotals = new Map();
    rows.forEach((r) => {
      const h = new Date(r._time).getUTCHours();
      const v = r._value || 0;
      const existing = hourlyTotals.get(h) || { sum: 0, count: 0 };
      existing.sum += v;
      existing.count += 1;
      hourlyTotals.set(h, existing);
    });
    const hourlyByHour = new Map();
    hourlyTotals.forEach((v, h) => hourlyByHour.set(h, { avg: v.count ? v.sum / v.count : 0, count: v.count }));
    return res.json({ data: bucketAverages(hourlyByHour, buckets) });
  } catch (e) {
    return res.json({ data: [] });
  }
});

// ── Energy Data Logger: raw hourly rows from Overall_hourly_energy_consumption ──
// Returns the latest hourly readings (all electrical parameters) so the Energy
// Data Logger table can show real MySQL data joined to Master Facilities by
// device_id. Optional filters: ?device_id=, ?from=YYYY-MM-DD, ?to=YYYY-MM-DD,
// ?limit= (default 500, or auto-sized for from/to range; max 50000).
function dataLoggerLimit({ device_id, from, to, limit }) {
  const requested = parseInt(limit, 10);
  if (requested > 0) return Math.min(requested, 200000);
  if (from && to) {
    const start = new Date(from);
    const end = new Date(to);
    const days = Math.max(1, Math.ceil((end - start) / 86400000) + 1);
    const deviceCount = device_id
      ? device_id.split(",").map((id) => id.trim()).filter(Boolean).length
      : 50;
    return Math.min(days * Math.max(deviceCount, 1) * 96 + 500, 200000);
  }
  return 500;
}

router.get("/data-logger", async (req, res) => {
  const { device_id, from, to, limit, order } = req.query;
  const lim = dataLoggerLimit({ device_id, from, to, limit });
  const sortDir = String(order || (from && to ? "asc" : "desc")).toLowerCase() === "desc" ? "DESC" : "ASC";

  // The hourly table's time column differs across client DBs (`timestamp` vs
  // `event_time`), so try one and retry with the other on an unknown-column
  // error.
  const buildQuery = (timeCol) => {
    const clauses = [];
    const params = [];
    if (device_id) {
      if (device_id.includes(",")) {
        const ids = device_id.split(",").map(id => id.trim()).filter(Boolean);
        if (ids.length > 0) {
          clauses.push(`device_id IN (${ids.map(() => "?").join(",")})`);
          params.push(...ids);
        }
      } else {
        clauses.push("device_id = ?");
        params.push(device_id);
      }
    }
    if (from) { clauses.push(`DATE(${timeCol}) >= ?`); params.push(from); }
    if (to)   { clauses.push(`DATE(${timeCol}) <= ?`); params.push(to); }
    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    const sql = `
      SELECT device_id,
             ${timeCol} AS timestamp,
             energy_consumption_kWh,
             power_kW,
             reactive_power_kVAR,
             apparent_power_kVA,
             max_demand_kW,
             power_factor,
             frequency_Hz,
             carbon_emission_kgCO2
      FROM Overall_hourly_energy_consumption
      ${where}
      ORDER BY ${timeCol} ${sortDir}
      LIMIT ${lim}`;
    return { sql, params };
  };

  try {
    const cpool = await getMysql(req);
    for (const timeCol of ["timestamp", "event_time"]) {
      try {
        const { sql, params } = buildQuery(timeCol);
        const [rows] = await cpool.query(sql, params);
        return res.json(rows);
      } catch (e) {
        if (e.code === "ER_BAD_FIELD_ERROR") continue;
        throw e;
      }
    }
    return res.json([]);
  } catch (e) {
    return res.status(500).json({ error: "Database error", message: e.message, code: e.code });
  }
});

// ── Solar Generation Data Logger: raw hourly rows from Overall_hourly_energy_generation ──
// Same contract as /data-logger (?device_id=, ?from=, ?to=, ?limit=, ?order=)
// but reads the generation table. Selects * because generation-table schemas
// vary across client DBs; energy_generated_kWh + timestamp are guaranteed.
router.get("/data-logger-generation", async (req, res) => {
  const { device_id, from, to, limit, order } = req.query;
  const lim = dataLoggerLimit({ device_id, from, to, limit });
  const sortDir = String(order || (from && to ? "asc" : "desc")).toLowerCase() === "desc" ? "DESC" : "ASC";

  const buildQuery = (timeCol) => {
    const clauses = [];
    const params = [];
    if (device_id) {
      if (device_id.includes(",")) {
        const ids = device_id.split(",").map(id => id.trim()).filter(Boolean);
        if (ids.length > 0) {
          clauses.push(`device_id IN (${ids.map(() => "?").join(",")})`);
          params.push(...ids);
        }
      } else {
        clauses.push("device_id = ?");
        params.push(device_id);
      }
    }
    if (from) { clauses.push(`DATE(\`${timeCol}\`) >= ?`); params.push(from); }
    if (to)   { clauses.push(`DATE(\`${timeCol}\`) <= ?`); params.push(to); }
    const where = clauses.length ? `WHERE ${clauses.join(" AND ")}` : "";
    const sql = `
      SELECT t.*, \`${timeCol}\` AS timestamp
      FROM Overall_hourly_energy_generation t
      ${where}
      ORDER BY \`${timeCol}\` ${sortDir}
      LIMIT ${lim}`;
    return { sql, params };
  };

  try {
    const cpool = await getMysql(req);
    for (const timeCol of ["timestamp", "event_time"]) {
      try {
        const { sql, params } = buildQuery(timeCol);
        const [rows] = await cpool.query(sql, params);
        return res.json(rows);
      } catch (e) {
        if (e.code === "ER_BAD_FIELD_ERROR") continue;
        throw e;
      }
    }
    return res.json([]);
  } catch (e) {
    return res.status(500).json({ error: "Database error", message: e.message, code: e.code });
  }
});

module.exports = router;
