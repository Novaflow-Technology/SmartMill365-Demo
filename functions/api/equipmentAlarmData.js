const express = require("express");

// eslint-disable-next-line new-cap
const router = express.Router();
const mysql = require("mysql2");

const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Intech_Database",
});

router.get("/:area", (req, res) => {
  const { area } = req.params;

  if (!area) {
    return res.status(400).json({
      error: "Missing area parameter",
    });
  }

  const query = `
    SELECT *
    FROM equipment_alarm_status
    WHERE (MINUTE(alarm_trigger_date_time) = 0 AND DATE(alarm_trigger_date_time) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00')) AND machine_id = '${area}')
    ORDER BY alarm_trigger_date_time
  `;

  pool.query(query, (error, results) => {
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
        triggerDate: row["alarm_trigger_date_time"],
        workOrder: row["wo_id"],
        equipment: row["machine_id"],
        operator: row["operator"],
        description: row["alarm_description_status"],
        resolveDate: row["alarm_resolve_date"],
        duration: row["spending_duration"],
      };
    });

    return res.json(updatedResults);
  });
});

router.put("/update/:id", (req, res) => {
  const { id } = req.params;
  const { workOrder, operator } = req.body;

  if (!id || !workOrder || !operator) {
    return res.status(400).json({
      error: "Missing required parameters",
    });
  }

  const query = `
    UPDATE equipment_alarm_status
    SET wo_id = '${workOrder}',
        operator = '${operator}'
    WHERE id = ${id}
  `;

  pool.query(query, (error) => {
    if (error) {
      return res.status(500).json({
        error: "Database error",
        message: error.message,
        code: error.code,
      });
    }

    return res.status(200).json({
      message: "Data updated successfully",
    });
  });
});

module.exports = router;
