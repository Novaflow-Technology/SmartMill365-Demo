const express = require("express");

// eslint-disable-next-line new-cap
const router = express.Router();
const mysql = require("mysql2");

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
});

router.get("/devices", (req, res) => {
  const query = "SELECT DISTINCT DeviceID FROM energy_datalogger";

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

/**
 * GET /energyDataLogger/data
 * Query params:
 *   devices   — comma-separated DeviceID list (required)
 *   fromDate  — YYYY-MM-DD start date (optional, inclusive)
 *   toDate    — YYYY-MM-DD end date   (optional, inclusive)
 *
 * Returns all matching rows ordered by Datetime DESC.
 * Client-side pagination (DataTableWidget) handles paging.
 */
router.get("/data", (req, res) => {
  const { devices, fromDate, toDate } = req.query;

  if (!devices) {
    return res.status(400).json({ error: "Missing devices parameter" });
  }

  const deviceList = devices.split(",").map((d) => d.trim()).filter(Boolean);
  if (deviceList.length === 0) {
    return res.status(400).json({ error: "No valid devices provided" });
  }

  const placeholders = deviceList.map(() => "?").join(",");
  let whereClause = `WHERE DeviceID IN (${placeholders})`;
  const params = [...deviceList];

  if (fromDate) {
    whereClause += " AND DATE(Datetime) >= ?";
    params.push(fromDate);
  }
  if (toDate) {
    whereClause += " AND DATE(Datetime) <= ?";
    params.push(toDate);
  }

  const query = `
    SELECT id, DeviceID, Datetime, KwH, Hour_Power_Consumption,
           Total_Carbon_Emission, Total_Energy_Cost
    FROM energy_datalogger
    ${whereClause}
    ORDER BY Datetime DESC
  `;

  pool.query(query, params, (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }

    const data = results.map((row) => ({
      id: row["id"],
      device: row["DeviceID"],
      timestamp: row["Datetime"],
      kwh: row["KwH"],
      power: row["Hour_Power_Consumption"],
      carbon: row["Total_Carbon_Emission"],
      energy: row["Total_Energy_Cost"],
    }));

    return res.json({ data, total: data.length });
  });
});

router.get("/:device", (req, res) => {
  const { device } = req.params;

  if (!device) {
    return res.status(400).json({
      error: "Missing device parameter",
    });
  }

  const query = `
    SELECT *
    FROM energy_datalogger
    WHERE (MINUTE(Datetime) = 0 AND DATE(Datetime) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')) AND DeviceID = ?)
    OR (Datetime IN (
      SELECT MIN(Datetime)
      FROM energy_datalogger
      WHERE DATE(Datetime) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')) AND DeviceID = ?
      GROUP BY YEAR(Datetime), MONTH(Datetime), DAY(Datetime), HOUR(Datetime)
    ) AND DeviceID = ?)
    ORDER BY Datetime
    `;

  pool.query(query, [device, device, device], (error, results) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }

    const updatedResults = results.map((row) => {
      return {
        id: row["id"],
        device: row["DeviceID"],
        timestamp: row["Datetime"],
        kwh: row["KwH"],
        power: row["Hour_Power_Consumption"],
        carbon: row["Total_Carbon_Emission"],
        energy: row["Total_Energy_Cost"],
      };
    });

    return res.json(updatedResults);
  });
});

module.exports = router;

// ---------------- ORIGINAL CODE ----------------

// const express = require("express");
// const router = express.Router();
// const mysql = require("mysql2/promise"); // Using promise-based API

// // Create MySQL connection pool
// const pool = mysql.createPool({
//   host: "219.92.5.163",
//   user: "novaflow",
//   password: "",
//   database: "Danapac_Database",
//   waitForConnections: true,
//   connectionLimit: 10,
//   queueLimit: 0
// });

// // GET all energy data with pagination
// router.get("/api/energy-data", async (req, res) => {
//   try {
//     // Pagination parameters
//     const page = parseInt(req.query.page) || 1;
//     const limit = parseInt(req.query.limit) || 10;
//     const offset = (page - 1) * limit;

//     // Sorting parameters
//     const sortBy = req.query.sortBy || 'timestamp';
//     const sortOrder = req.query.sortOrder === 'desc' ? 'DESC' : 'ASC';

//     // Search/filter parameters
//     const searchTerm = req.query.search || '';
//     const filterField = req.query.filterField || 'equipment_id';

//     // Build WHERE clause for search
//     let whereClause = '';
//     let queryParams = [];

//     if (searchTerm) {
//       whereClause = `WHERE ${filterField} LIKE ?`;
//       queryParams.push(`%${searchTerm}%`);
//     }

//     // Get total count for pagination
//     const [countRows] = await pool.query(
//       `SELECT COUNT(*) as total FROM energy_datalogger ${whereClause}`,
//       queryParams
//     );
//     const total = countRows[0].total;

//     // Get paginated data
//     const [rows] = await pool.query(
//       `SELECT * FROM energy_datalogger
//        ${whereClause}
//        ORDER BY ${sortBy} ${sortOrder}
//        LIMIT ? OFFSET ?`,
//       [...queryParams, limit, offset]
//     );

//     res.json({
//       success: true,
//       data: rows,
//       pagination: {
//         page,
//         limit,
//         total,
//         totalPages: Math.ceil(total / limit)
//       }
//     });

//   } catch (error) {
//     console.error("Error fetching energy data:", error);
//     res.status(500).json({
//       success: false,
//       message: "Failed to fetch energy data",
//       error: error.message
//     });
//   }
// });

// // GET energy data by equipment ID
// router.get("/api/energy-data/:equipmentId", async (req, res) => {
//   try {
//     const { equipmentId } = req.params;
//     const [rows] = await pool.query(
//       "SELECT * FROM energy_datalogger WHERE equipment_id = ? ORDER BY timestamp DESC",
//       [equipmentId]
//     );

//     if (rows.length === 0) {
//       return res.status(404).json({
//         success: false,
//         message: "No energy data found for this equipment"
//       });
//     }

//     res.json({
//       success: true,
//       data: rows
//     });

//   } catch (error) {
//     console.error("Error fetching equipment energy data:", error);
//     res.status(500).json({
//       success: false,
//       message: "Failed to fetch equipment energy data",
//       error: error.message
//     });
//   }
// });

// // GET latest energy data for all equipment
// router.get("/api/energy-data/latest", async (req, res) => {
//   try {
//     const [rows] = await pool.query(`
//       SELECT e1.*
//       FROM energy_datalogger e1
//       INNER JOIN (
//         SELECT equipment_id, MAX(timestamp) as latest_timestamp
//         FROM energy_datalogger
//         GROUP BY equipment_id
//       ) e2 ON e1.equipment_id = e2.equipment_id AND e1.timestamp = e2.latest_timestamp
//     `);

//     res.json({
//       success: true,
//       data: rows
//     });

//   } catch (error) {
//     console.error("Error fetching latest energy data:", error);
//     res.status(500).json({
//       success: false,
//       message: "Failed to fetch latest energy data",
//       error: error.message
//     });
//   }
// });

// module.exports = router;
