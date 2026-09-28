const express = require("express");
const mysql = require("mysql2");

const router = express.Router();

// Create MySQL pool
const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Intech_Database",
});

// POST /api/equipment/status
router.post("/status", (req, res) => {
  const equipmentList = req.body;

  if (!Array.isArray(equipmentList) || equipmentList.length === 0) {
    return res.status(400).json({ error: "Invalid request body: Expected non-empty array" });
  }

  const results = [];
  let completed = 0;

  const setQuery = `SET @today_myt := DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'));`;

  pool.query(setQuery, (err) => {
    if (err) {
      return res.status(500).json({ error: "Timezone initialization failed", message: err.message });
    }

    equipmentList.forEach(({ equipmentId, productionArea }) => {
      if (!equipmentId || !productionArea) {
        results.push({
          id: equipmentId || "unknown",
          machine_status: { m_status: -1 },
          total_good_quantity: 0,
          total_gross_quantity: 0,
          job_order_id: null,
          oee: null,
          alarm: {}
        });
        completed++;
        if (completed === equipmentList.length) return res.json(results);
        return;
      }

      const areaMap = { 'p1': 'p2', 'intech-p1': 'p2', 'intech-p2': 'p2' };
      const areaKey = productionArea.toLowerCase();
      const dbArea = areaMap[areaKey] || areaKey;
      const tableName = `${dbArea}_${equipmentId}_latest`;
      const query = `
        SELECT 
          MachineID AS id,
          RunStatus AS m_status,
          Total_GoodQuantity AS total_good_quantity,
          Total_GrossQuantity AS total_gross_quantity,
          JobOrderID AS job_order_id,
          NULL AS oee,
          '{}' AS alarm
        FROM ${tableName}
        LIMIT 1
      `;

      pool.query(query, (error, rows) => {
        if (error || rows.length === 0) {
          results.push({
            id: equipmentId,
            machine_status: { m_status: -1 },
            total_good_quantity: 0,
            total_gross_quantity: 0,
            job_order_id: null,
            oee: null,
            alarm: {}
          });
        } else {
          results.push({
            id: equipmentId,
            machine_status: { m_status: rows[0].m_status },
            total_good_quantity: rows[0].total_good_quantity || 0,
            total_gross_quantity: rows[0].total_gross_quantity || 0,
            job_order_id: rows[0].job_order_id || null,
            oee: null,
            alarm: {}
          });
        }

        completed++;
        if (completed === equipmentList.length) {
          return res.json(results);
        }
      });
    });
  });
});

// Diagnostic: list all tables in DB
router.get("/tables", (req, res) => {
  pool.query("SHOW TABLES", (err, rows) => {
    if (err) return res.status(500).json({ error: err.message });
    res.json(rows);
  });
});

module.exports = router;
