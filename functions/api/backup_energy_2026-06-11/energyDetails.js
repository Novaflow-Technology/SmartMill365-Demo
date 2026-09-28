const express = require("express");

const router = express.Router();
const mysql = require("mysql2");
const { InfluxDB } = require("@influxdata/influxdb-client");

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
});

// InfluxDB fallback for when MySQL has no data
const influxClient = new InfluxDB({
  url: "",
  token: "",
});
const influxQuery = influxClient.getQueryApi("Novaflow");

function runInfluxQuery(flux) {
  return new Promise((resolve, reject) => {
    const rows = [];
    influxQuery.queryRows(flux, {
      next(row, meta) { rows.push(meta.toObject(row)); },
      error: reject,
      complete() { resolve(rows); },
    });
  });
}

async function influxHourlyFallback(topic, date) {
  const start = `${date}T00:00:00Z`;
  const stop  = `${date}T23:59:59Z`;
  const flux = `
    from(bucket: "ENERGY_DEMO")
      |> range(start: ${start}, stop: ${stop})
      |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}")
      |> filter(fn: (r) => r._field == "P_kW")
      |> aggregateWindow(every: 1h, fn: last, createEmpty: false)
  `;
  const rows = await runInfluxQuery(flux);
  return rows.map((r) => ({
    label: String(new Date(r._time).getUTCHours()),
    value: r._value ?? 0,
  }));
}

async function influxDailyFallback(topic) {
  const flux = `
    from(bucket: "ENERGY_DEMO")
      |> range(start: -7d)
      |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}")
      |> filter(fn: (r) => r._field == "P_kW")
      |> aggregateWindow(every: 1d, fn: mean, createEmpty: false)
  `;
  const rows = await runInfluxQuery(flux);
  return rows.map((r) => {
    const d = new Date(r._time);
    return { label: `${d.getUTCDate()}/${d.getUTCMonth() + 1}`, value: r._value ?? 0 };
  });
}

async function influxMonthlyFallback(topic) {
  const flux = `
    from(bucket: "ENERGY_DEMO")
      |> range(start: -365d)
      |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}")
      |> filter(fn: (r) => r._field == "P_kW")
      |> aggregateWindow(every: 30d, fn: mean, createEmpty: false)
  `;
  const rows = await runInfluxQuery(flux);
  const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
  return rows.map((r) => ({
    label: months[new Date(r._time).getUTCMonth()],
    value: r._value ?? 0,
  }));
}

router.get("/devices", (req, res) => {
  const query = "SELECT DISTINCT device_id FROM energy_data";

  pool.query(query, (error, results) => {
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
router.get("/total/:device_id", async (req, res) => {
  const { device_id } = req.params;

  if (!device_id) {
    return res.status(400).json({ error: "Missing device_id parameter" });
  }

  const sql = `
    SELECT 'daily' AS period, 
           COALESCE(today_energy, 0) - COALESCE(yesterday_energy, 0) AS total_energy
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
           COALESCE(today_energy, 0) - COALESCE(last_month_energy, 0) AS total_energy
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
           COALESCE(today_energy, 0) - COALESCE(last_year_energy, 0) AS total_energy
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

  async function influxTotalFallback(deviceId) {
    const now = new Date();
    const todayStart = new Date(now); todayStart.setUTCHours(0,0,0,0);
    const monthStart = new Date(now); monthStart.setUTCDate(1); monthStart.setUTCHours(0,0,0,0);
    const yearStart  = new Date(now); yearStart.setUTCMonth(0,1); yearStart.setUTCHours(0,0,0,0);

    async function getEdelRange(start, stop) {
      const firstQ = `
        from(bucket: "ENERGY_DEMO")
          |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
          |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${deviceId}" and r._field == "Edel")
          |> first()
      `;
      const lastQ = `
        from(bucket: "ENERGY_DEMO")
          |> range(start: ${start.toISOString()}, stop: ${stop.toISOString()})
          |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${deviceId}" and r._field == "Edel")
          |> last()
      `;
      const [firstRows, lastRows] = await Promise.all([runInfluxQuery(firstQ), runInfluxQuery(lastQ)]);
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
    const [rows] = await pool.promise().query(sql, [device_id, device_id, device_id, device_id, device_id, device_id]);

    if (rows.length === 0 || rows.every((r) => !r.total_energy || Number(r.total_energy) === 0)) {
      try {
        const influxData = await influxTotalFallback(device_id);
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
router.get("/data/:topic/:period", (req, res) => {
  const { topic, period } = req.params;

  if (!topic || !period) {
    return res.status(400).json({
      error: "Missing topic or period parameter",
    });
  }
  let query = "";
  let params = [];
  switch (period) {
    case "hourly":
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
    // If MySQL has no real data (all values are 0), fallback to InfluxDB
    const allZero = results.every((r) => !r.value || Number(r.value) === 0);
    if (allZero) {
      try {
        const today = new Date().toISOString().slice(0, 10);
        let influxData = [];
        if (period === "hourly") influxData = await influxHourlyFallback(topic, today);
        else if (period === "daily") influxData = await influxDailyFallback(topic);
        else if (period === "monthly") influxData = await influxMonthlyFallback(topic);
        if (influxData.length > 0 && influxData.some((r) => Number(r.value) > 0)) {
          return res.json(influxData);
        }
      } catch (e) {
        // ignore fallback errors, return MySQL zeros
      }
    }
    return res.json(results);
  });
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
        const today = new Date();
        const todayStart = new Date(today); todayStart.setUTCHours(0,0,0,0);
        const peakQ = `
          from(bucket: "ENERGY_DEMO")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}" and r._field == "P_kW")
            |> max()
        `;
        const edelFirstQ = `
          from(bucket: "ENERGY_DEMO")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}" and r._field == "Edel")
            |> first()
        `;
        const edelLastQ = `
          from(bucket: "ENERGY_DEMO")
            |> range(start: ${todayStart.toISOString()})
            |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${topic}" and r._field == "Edel")
            |> last()
        `;
        const [peakRows, firstRows, lastRows] = await Promise.all([
          runInfluxQuery(peakQ), runInfluxQuery(edelFirstQ), runInfluxQuery(edelLastQ),
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
router.get("/power-load-24h/:deviceId", (req, res) => {
  const { deviceId } = req.params;
  if (!deviceId) return res.status(400).json({ error: "Missing deviceId parameter" });

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
          const flux = `
            from(bucket: "ENERGY_DEMO")
              |> range(start: -24h)
              |> filter(fn: (r) => r._measurement == "power_meter" and r.device_name == "${deviceId}" and r._field == "P_kW")
              |> aggregateWindow(every: 30m, fn: max, createEmpty: false)
          `;
          const rows = await runInfluxQuery(flux);
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
router.get("/monthly-max-demand/:deviceId", async (req, res) => {
  const { deviceId } = req.params;
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
  const lastMonthStart = new Date(now.getFullYear(), now.getMonth() - 1, 1).toISOString();
  const lastMonthEnd = new Date(now.getFullYear(), now.getMonth(), 0, 23, 59, 59).toISOString();
  try {
    const [currRows, prevRows] = await Promise.all([
      runInfluxQuery(`from(bucket:"ENERGY_DEMO")|>range(start:${monthStart})|>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")|>max()`),
      runInfluxQuery(`from(bucket:"ENERGY_DEMO")|>range(start:${lastMonthStart},stop:${lastMonthEnd})|>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")|>max()`),
    ]);
    return res.json({
      max_demand_kW: parseFloat((currRows[0]?._value || 0).toFixed(2)),
      previous_month_max_demand_kW: parseFloat((prevRows[0]?._value || 0).toFixed(2)),
    });
  } catch (e) {
    return res.json({ max_demand_kW: 0, previous_month_max_demand_kW: 0 });
  }
});

// ── Max demand chart (daily max per day this month) ───────────────────────────
router.get("/max-demand-chart", async (req, res) => {
  const deviceId = req.query.device_id;
  if (!deviceId) return res.status(400).json({ error: "Missing device_id" });
  const now = new Date();
  const monthStart = new Date(now.getFullYear(), now.getMonth(), 1).toISOString();
  try {
    const rows = await runInfluxQuery(`
      from(bucket:"ENERGY_DEMO")
        |>range(start:${monthStart})
        |>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")
        |>aggregateWindow(every:1d,fn:max,createEmpty:false)
    `);
    const months = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    const result = rows.map((r) => {
      const d = new Date(r._time);
      return { label: `${months[d.getUTCMonth()]} ${d.getUTCDate()}`, value: parseFloat((r._value || 0).toFixed(2)), date: r._time.slice(0,10) };
    });
    return res.json(result);
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
  try {
    const rows = await runInfluxQuery(`
      from(bucket:"ENERGY_DEMO")
        |>range(start:${monthStart})
        |>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")
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
router.get("/equipment-md-ranking", async (req, res) => {
  const { event_date, event_start, event_end } = req.query;
  if (!event_date) return res.status(400).json({ error: "Missing event_date" });
  const start = event_start ? event_start.replace(" ", "T") + "Z" : `${event_date}T00:00:00Z`;
  const stop  = event_end   ? event_end.replace(" ", "T") + "Z"   : `${event_date}T23:59:59Z`;
  try {
    const rows = await runInfluxQuery(`
      from(bucket:"ENERGY_DEMO")
        |>range(start:${start},stop:${stop})
        |>filter(fn:(r)=>r._measurement=="power_meter" and r._field=="P_kW")
        |>max()
        |>group(columns:["device_name"])
    `);
    const total = rows.reduce((s, r) => s + (r._value || 0), 0);
    const data = rows
      .filter((r) => r.device_name)
      .map((r) => ({
        device_id: r.device_name,
        peak_demand_kW: parseFloat((r._value || 0).toFixed(2)),
        percentage: total > 0 ? parseFloat(((r._value / total) * 100).toFixed(1)) : 0,
      }))
      .sort((a, b) => b.peak_demand_kW - a.peak_demand_kW);
    return res.json({ data });
  } catch (e) {
    return res.json({ data: [] });
  }
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
  try {
    const [currRows, prevRows] = await Promise.all([
      runInfluxQuery(`from(bucket:"ENERGY_DEMO")|>range(start:${thisYearStart})|>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")|>aggregateWindow(every:30d,fn:max,createEmpty:false)`),
      runInfluxQuery(`from(bucket:"ENERGY_DEMO")|>range(start:${lastYearStart},stop:${lastYearEnd})|>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")|>aggregateWindow(every:30d,fn:max,createEmpty:false)`),
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
    const rows = await runInfluxQuery(`
      from(bucket:"ENERGY_DEMO")
        |>range(start:${start},stop:${stop})
        |>filter(fn:(r)=>r._measurement=="power_meter" and r._field=="PF")
        |>mean()
        |>group(columns:["device_name"])
    `);
    const data = rows
      .filter((r) => r.device_name)
      .map((r) => ({
        device_id: r.device_name,
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
router.get("/average-power-load/:deviceId", async (req, res) => {
  const { deviceId } = req.params;
  try {
    const rows = await runInfluxQuery(`
      from(bucket:"ENERGY_DEMO")
        |>range(start:-30d)
        |>filter(fn:(r)=>r._measurement=="power_meter" and r.device_name=="${deviceId}" and r._field=="P_kW")
        |>aggregateWindow(every:1h,fn:mean,createEmpty:false)
    `);
    const periods = { Morning: [], Afternoon: [], Evening: [], Night: [] };
    rows.forEach((r) => {
      const h = new Date(r._time).getUTCHours();
      const v = r._value || 0;
      if (h >= 6  && h < 12) periods.Morning.push(v);
      else if (h >= 12 && h < 18) periods.Afternoon.push(v);
      else if (h >= 18 && h < 22) periods.Evening.push(v);
      else periods.Night.push(v);
    });
    const data = Object.entries(periods).map(([name, vals]) => {
      const avg = vals.length ? vals.reduce((a, b) => a + b, 0) / vals.length : 0;
      return {
        time_period: name,
        average_power_load_kW: parseFloat(avg.toFixed(2)),
        total_energy_kWh: parseFloat((avg * vals.length).toFixed(2)),
        hours_count: vals.length,
      };
    });
    return res.json({ data });
  } catch (e) {
    return res.json({ data: [] });
  }
});

module.exports = router;
