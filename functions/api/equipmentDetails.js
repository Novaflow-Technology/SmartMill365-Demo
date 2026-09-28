const express = require("express");
const {
  calculateRemainingHours,
  calculateEstimatedCompletion,
} = require("../helpers/calculated-planned-wo");
const { convertTimeToMinutes } = require("../helpers/convert-time-to-minutes");

// eslint-disable-next-line new-cap
const router = express.Router();
const mysql = require("mysql2");

const pool = mysql
  .createPool({
    host: "",
    user: "novaflow",
    password: "",
    database: "Intech_Database",
  })
  .promise();

router.get("/oee-machine-ids", async (req, res) => {
  try {
    const [rows] = await pool.query("SELECT DISTINCT MachineID, MAX(Date) as lastDate FROM Overall_Daily_Machine_OEE GROUP BY MachineID LIMIT 20");
    res.json(rows);
  } catch (err) { res.status(500).json({ error: err.message }); }
});

const areaMap = { 'p1': 'p2', 'intech-p1': 'p2', 'intech-p2': 'p2' };
const getDbArea = (area) => areaMap[area.toLowerCase()] || area.toLowerCase();

router.get("/daily-status/:equipment", async (req, res) => {
  const equipment = req.params.equipment;
  if (!equipment) {
    return res.status(400).json({ error: "Missing equipment parameter" });
  }

  try {
    // Step 1: Get today's records for all matching devices
    const query = `
      SELECT timestamp, device_name, status
      FROM device_status_summary
      WHERE device_name LIKE ?
        AND DATE(timestamp) = DATE(CONVERT_TZ(NOW(), '+00:00', '+08:00'))
      ORDER BY timestamp
    `;
    const [rows] = await pool.query(query, [`%${equipment}%`]);

    if (rows.length === 0) {
      return res.json({ running: 0, idle: 0, alarm: 0, stopped: 0 });
    }

    // Step 2: Group by timestamp (minute) and collect statuses from all matched devices
    const timelineMap = new Map();

    rows.forEach((row) => {
      const timeKey = new Date(row.timestamp).toISOString().split(".")[0];
      if (!timelineMap.has(timeKey)) {
        timelineMap.set(timeKey, []);
      }
      timelineMap.get(timeKey).push(row.status);
    });

    // Step 3: Determine overall status at each minute (highest priority wins)
    const statusPriority = {
      1: "running",
      2: "alarm",
      0: "idle",
      3: "stopped",
    };
    const priorityOrder = [1, 2, 0, 3]; // highest to lowest
    const durations = { running: 0, idle: 0, alarm: 0, stopped: 0 };

    timelineMap.forEach((statusList) => {
      for (const p of priorityOrder) {
        if (statusList.includes(p)) {
          const key = statusPriority[p];
          durations[key]++;
          break;
        }
      }
    });

    res.json(durations);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

router.get("/alarm/:equipment", async (req, res) => {
  const { equipment } = req.params;
  if (!equipment) {
    return res.status(400).json({ error: "Missing equipment parameter" });
  }

  try {
    const query = `
      SELECT alarm_trigger_date_time, alarm_description_status, alarm_resolve_date, spending_duration
      FROM equipment_alarm_status
      WHERE machine_id = ?
      ORDER BY alarm_trigger_date_time DESC
      LIMIT 10
    `;
    const [results] = await pool.query(query, [equipment]);
    return res.json(results);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

router.get(
  "/overall-wo-efficiency/:machineId/:workOrderId",
  async (req, res) => {
    const { machineId, workOrderId } = req.params;

    if (!machineId) {
      return res.status(400).json({ error: "Missing Machine Id" });
    } else if (!workOrderId) {
      return res.status(400).json({ error: "Missing Work Order Id" });
    }

    try {
      const query = `
      SELECT WO_Actual_Quantity, WO_Planned_Quantity
      FROM Overall_WO_Efficiency
      WHERE MachineID = ? AND WorkOrderID = ?
    `;
      const [results] = await pool.query(query, [machineId, workOrderId]);
      return res.json(results);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
  }
);

router.get("/overall-daily-machine-oee/:machineId", async (req, res) => {
  const { machineId } = req.params;

  if (!machineId) {
    return res.status(400).json({ error: "Missing Machine Id" });
  }

  try {
    const query = `
      SELECT Overall_Machine_OEE, Machine_Quality, Machine_Availability, Machine_Efficiency
      FROM Overall_Daily_Machine_OEE
      WHERE MachineID = ?
      ORDER BY ID DESC
      LIMIT 1
    `;
    const [results] = await pool.query(query, [machineId]);

    if (results.length === 0) {
      return res.status(404).json({ error: "No data found for this machine" });
    }

    return res.json(results[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

router.get("/overall-daily-machine-oee/latest/:machineId", async (req, res) => {
  const { machineId } = req.params;

  if (!machineId) {
    return res.status(400).json({ error: "Missing Machine Id" });
  }

  try {
    const query = `
      SELECT Overall_Machine_OEE, Machine_Quality, Machine_Availability, Machine_Efficiency
      FROM Overall_Daily_Machine_OEE
      WHERE MachineID = ?
      ORDER BY ID DESC
      LIMIT 1
    `;
    const [results] = await pool.query(query, [machineId]);
    
    if (results.length === 0) {
      return res.status(404).json({ error: "No data found for this machine on current date" });
    }

    return res.json(results[0]);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// POST /overall-daily-machine-oee/latest/batch — OEE for multiple machines
router.post("/overall-daily-machine-oee/latest/batch", async (req, res) => {
  const { machineIds } = req.body;
  if (!Array.isArray(machineIds) || machineIds.length === 0) {
    return res.status(400).json({ error: "machineIds must be a non-empty array" });
  }
  try {
    const placeholders = machineIds.map(() => '?').join(',');
    const query = `
      SELECT t1.MachineID, t1.Overall_Machine_OEE, t1.Machine_Quality, t1.Machine_Availability, t1.Machine_Efficiency
      FROM Overall_Daily_Machine_OEE t1
      INNER JOIN (
        SELECT MachineID, MAX(ID) as maxId
        FROM Overall_Daily_Machine_OEE
        WHERE MachineID IN (${placeholders})
        GROUP BY MachineID
      ) t2 ON t1.MachineID = t2.MachineID AND t1.ID = t2.maxId
    `;
    const [results] = await pool.query(query, machineIds);
    const resultMap = {};
    for (const row of results) {
      resultMap[row.MachineID] = {
        Overall_Machine_OEE: row.Overall_Machine_OEE,
        Machine_Quality: row.Machine_Quality,
        Machine_Availability: row.Machine_Availability,
        Machine_Efficiency: row.Machine_Efficiency,
      };
    }
    return res.json(resultMap);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

// router.get('/utilization/last-24-hours/:machineId/:workOrderId/:page?/:limit?', async (req, res) => {
//   const { machineId, workOrderId, page = 1, limit = 10 } = req.params;

//   if (!machineId) {
//     return res.status(400).json({ error: 'Missing Machine Id' });
//   } else if (!workOrderId) {
//     return res.status(400).json({ error: 'Missing Work Order Id' });
//   }

//   try {
//     const offset = (parseInt(page) - 1) * parseInt(limit);

//     const query = `
//       SELECT alarm_trigger_date_time, alarm_resolve_date, spending_duration
//       FROM equipment_alarm_status
//       WHERE machine_id = ? AND wo_id = ?
//       ORDER BY alarm_trigger_date_time DESC
//       LIMIT ? OFFSET ?
//     `;

//     const countQuery = `
//       SELECT COUNT(*) as total
//       FROM equipment_alarm_status
//       WHERE machine_id = ? AND wo_id = ?
//     `;

//     const [results] = await pool.query(query, [machineId, workOrderId, parseInt(limit), offset]);
//     const [countResult] = await pool.query(countQuery, [machineId, workOrderId]);

//     const totalRecords = countResult[0].total;
//     const totalPages = Math.ceil(totalRecords / parseInt(limit));

//     return res.json({
//       data: results,
//       pagination: {
//         currentPage: parseInt(page),
//         totalPages,
//         totalRecords,
//         limit: parseInt(limit),
//         hasNextPage: parseInt(page) < totalPages,
//         hasPreviousPage: parseInt(page) > 1
//       }
//     });
//   } catch (err) {
//     console.error(err);
//     res.status(500).json({ error: err.message });
//   }
// });
// Add this new endpoint to your equipmentDetails.js file

router.get(
  "/utilization/machine-status-24h/:productionArea/:equipmentId",
  async (req, res) => {
    const { productionArea, equipmentId } = req.params;

    if (!productionArea) {
      return res
        .status(400)
        .json({ error: "Missing Production Area parameter" });
    }
    if (!equipmentId) {
      return res.status(400).json({ error: "Missing Equipment Id parameter" });
    }

    try {
      // Construct the table name: productionArea_equipmentId_ms
      const tableName = `${getDbArea(productionArea)}_${equipmentId}_ms`;

      // Calculate 24 hours ago from now
      const now = new Date();
      const last24Hours = new Date(now.getTime() - 24 * 60 * 60 * 1000);

      // Query to get all records in the last 24 hours including ProcessID
      const query = `
      SELECT Timestamp, RunStatus, ProcessID
      FROM ??
      WHERE Timestamp >= ?
      ORDER BY Timestamp ASC
    `;

      const [results] = await pool.query(query, [
        tableName,
        last24Hours.toISOString().slice(0, 19).replace("T", " "),
      ]);

      if (results.length === 0) {
        return res.json({
          equipmentId,
          productionArea,
          tableName,
          currentTime: now.toISOString(),
          last24HoursFrom: last24Hours.toISOString(),
          data: [],
          summary: {
            totalRecords: 0,
            running: 0,
            idle: 0,
            stopped: 0,
            runningMinutes: 0,
            idleMinutes: 0,
            stoppedMinutes: 0,
          },
          message: "No data available for the last 24 hours",
        });
      }

      // Process the data to calculate durations for each status
      let runningCount = 0;
      let idleCount = 0;
      let stoppedCount = 0;

      // Count records for each status
      results.forEach((record) => {
        const status = record.RunStatus;
        if (status === 1) {
          runningCount++;
        } else if (status === 2) {
          idleCount++;
        } else if (status === 3) {
          stoppedCount++;
        }
      });

      // Calculate minutes (assuming each record represents 1 minute)
      const runningMinutes = runningCount;
      const idleMinutes = idleCount;
      const stoppedMinutes = stoppedCount;

      // Get ProcessID from first record (should be same for all records in the table)
      const processID = results.length > 0 ? results[0].ProcessID : null;

      // Format data for Flutter widget
      const formattedData = results.map((record) => ({
        timestamp: record.Timestamp,
        runStatus: record.RunStatus,
        statusName:
          record.RunStatus === 1
            ? "Running"
            : record.RunStatus === 2
            ? "Idle"
            : record.RunStatus === 3
            ? "Stopped"
            : "Unknown",
        processID: processID,
      }));

      return res.json({
        equipmentId,
        productionArea,
        tableName,
        currentTime: now.toISOString(),
        last24HoursFrom: last24Hours.toISOString(),
        data: formattedData,
        summary: {
          totalRecords: results.length,
          running: runningCount,
          idle: idleCount,
          stopped: stoppedCount,
          runningMinutes: runningMinutes,
          idleMinutes: idleMinutes,
          stoppedMinutes: stoppedMinutes,
          runningPercentage: ((runningMinutes / 1440) * 100).toFixed(2),
          idlePercentage: ((idleMinutes / 1440) * 100).toFixed(2),
          stoppedPercentage: ((stoppedMinutes / 1440) * 100).toFixed(2),
        },
      });
    } catch (err) {
      console.error("Error fetching machine status:", err);

      // Check if error is due to table not existing
      if (err.code === "ER_NO_SUCH_TABLE") {
        return res.status(404).json({
          error: `Table ${productionArea}_${equipmentId}_ms does not exist`,
          equipmentId,
          productionArea,
        });
      }

      res.status(500).json({ error: err.message });
    }
  }
);

// Alternative endpoint with aggregated data by time intervals (hourly)
router.get(
  "/utilization/machine-status-24h-hourly/:productionArea/:equipmentId",
  async (req, res) => {
    const { productionArea, equipmentId } = req.params;

    if (!productionArea) {
      return res
        .status(400)
        .json({ error: "Missing Production Area parameter" });
    }
    if (!equipmentId) {
      return res.status(400).json({ error: "Missing Equipment Id parameter" });
    }

    try {
      const tableName = `${getDbArea(productionArea)}_${equipmentId}_ms`;
      const now = new Date();
      const last24Hours = new Date(now.getTime() - 24 * 60 * 60 * 1000);

      // Query to get hourly aggregated data
      const query = `
      SELECT 
        DATE_FORMAT(Timestamp, '%Y-%m-%d %H:00:00') as hour,
        RunStatus,
        COUNT(*) as count
      FROM ??
      WHERE Timestamp >= ?
      GROUP BY DATE_FORMAT(Timestamp, '%Y-%m-%d %H:00:00'), RunStatus
      ORDER BY hour ASC, RunStatus ASC
    `;

      const [results] = await pool.query(query, [
        tableName,
        last24Hours.toISOString().slice(0, 19).replace("T", " "),
      ]);

      if (results.length === 0) {
        return res.json({
          equipmentId,
          productionArea,
          tableName,
          currentTime: now.toISOString(),
          last24HoursFrom: last24Hours.toISOString(),
          hourlyData: [],
          message: "No data available for the last 24 hours",
        });
      }

      // Process hourly data
      const hourlyMap = {};

      results.forEach((record) => {
        const hour = record.hour;
        if (!hourlyMap[hour]) {
          hourlyMap[hour] = {
            hour: hour,
            running: 0,
            idle: 0,
            stopped: 0,
          };
        }

        if (record.RunStatus === 1) {
          hourlyMap[hour].running = record.count;
        } else if (record.RunStatus === 2) {
          hourlyMap[hour].idle = record.count;
        } else if (record.RunStatus === 3) {
          hourlyMap[hour].stopped = record.count;
        }
      });

      const hourlyData = Object.values(hourlyMap);

      return res.json({
        equipmentId,
        productionArea,
        tableName,
        currentTime: now.toISOString(),
        last24HoursFrom: last24Hours.toISOString(),
        hourlyData: hourlyData,
      });
    } catch (err) {
      console.error("Error fetching hourly machine status:", err);

      if (err.code === "ER_NO_SUCH_TABLE") {
        return res.status(404).json({
          error: `Table ${productionArea}_${equipmentId}_ms does not exist`,
          equipmentId,
          productionArea,
        });
      }

      res.status(500).json({ error: err.message });
    }
  }
);

router.get("/planned-wo-input/:machineId/:workOrderId", async (req, res) => {
  const { machineId, workOrderId } = req.params;

  if (!machineId) {
    return res.status(400).json({ error: "Missing Machine Id" });
  } else if (!workOrderId) {
    return res.status(400).json({ error: "Missing Work Order Id" });
  }

  try {
    const query = `
      SELECT Planned_Production_Start_Date, Planned_Production_Completion_Date, Planned_Quantity  
      FROM Planned_WO_Input
      WHERE MachineID = ? AND WorkOrderID = ?
    `;
    const [results] = await pool.query(query, [machineId, workOrderId]);

    if (results.length === 0) {
      return res.status(404).json({
        error: "No data found for the given MachineId and WorkOrderId",
      });
    }

    const {
      Planned_Production_Start_Date,
      Planned_Production_Completion_Date,
      Planned_Quantity,
    } = results[0];

    const remainingHours = calculateRemainingHours(
      Planned_Production_Completion_Date
    );
    const estimatedCompletionDate = calculateEstimatedCompletion(
      Planned_Production_Completion_Date
    );

    const responseData = {
      Planned_Production_Start_Date,
      Planned_Production_Completion_Date,
      Planned_Quantity,
      Remaining_Hours: remainingHours,
      Estimated_Completion: estimatedCompletionDate.toISOString(),
    };

    return res.json(responseData);
  } catch (err) {
    console.error(err);
    res.status(500).json({ error: err.message });
  }
});

router.get(
  "/overall-wo-performance/:machineId/:workOrderId",
  async (req, res) => {
    const { machineId, workOrderId } = req.params;

    if (!machineId) {
      return res.status(400).json({ error: "Missing Machine Id" });
    } else if (!workOrderId) {
      return res.status(400).json({ error: "Missing Work Order Id" });
    }

    try {
      const query = `
      SELECT CheckIn_Timestamp, WO_Throughput   
      FROM Overall_WO_Performance
      WHERE MachineID = ? AND WorkOrderID = ?
    `;
      const [results] = await pool.query(query, [machineId, workOrderId]);

      if (results.length === 0) {
        return res.status(404).json({
          error: "No data found for the given MachineId and WorkOrderId",
        });
      }

      return res.json(results[0]);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
  }
);

// router.get('/overall-daily-machine-efficiency/:machineId', async (req, res) => {
//   const { machineId } = req.params;

//   if (!machineId) {
//     return res.status(400).json({ error: 'Missing Machine Id' });
//   }

//   try {
//     const query = `
//       SELECT Machine_Actual_Quantity, Machine_Planned_Quantity
//       FROM Overall_Daily_Machine_Efficiency
//       WHERE MachineID = ?
//       AND Date = CURDATE()
//     `;
//     const [results] = await pool.query(query, [machineId]);
//     return res.json(results);
//   } catch (err) {
//     console.error(err);
//     res.status(500).json({ error: err.message });
//   }
// });
router.get(
  "/overall-daily-machine-efficiency/:productionArea/:equipmentId",
  async (req, res) => {
    const { productionArea, equipmentId } = req.params;

    if (!productionArea) {
      return res
        .status(400)
        .json({ error: "Missing productionArea parameter" });
    }

    if (!equipmentId) {
      return res.status(400).json({ error: "Missing equipmentId parameter" });
    }

    try {
      const tableName = `${getDbArea(productionArea)}_${equipmentId}_wo`;

      const query = `
      SELECT
        JobOrderID AS WorkOrderID,
        ProcessID AS ProcessID,
        JobOrder_GrossQuantity AS ActualProductionQuantity,
        CASE
          WHEN @prev_time IS NOT NULL AND @prev_time != timestamp THEN
            ROUND(
              JobOrder_GrossQuantity /
              (TIMESTAMPDIFF(SECOND, @prev_time, timestamp) / 3600),
              2
            )
          ELSE JobOrder_GrossQuantity
        END AS PlannedProductionQuantity,
        @prev_time := timestamp AS Timestamp
      FROM ??
      CROSS JOIN (SELECT @prev_time := NULL) AS init
      ORDER BY timestamp ASC
      LIMIT 500
    `;

      const [results] = await pool.query(query, [tableName]);

      // Reverse to DESC order after calculation
      const orderedResults = results.reverse().map((row) => ({
        WorkOrderID: row.WorkOrderID,
        ProcessID: row.ProcessID,
        ActualProductionQuantity: row.ActualProductionQuantity,
        PlannedProductionQuantity: row.PlannedProductionQuantity,
        Timestamp: row.Timestamp,
      }));

      return res.json(orderedResults);
    } catch (err) {
      console.error(err);
      res.status(500).json({ error: err.message });
    }
  }
);

// router.get('/overall-machine-efficiency/:machineId/:period', async (req, res) => {
//   const { machineId } = req.params;
//   const { period = 'daily' } = req.query; // Default to daily if not specified

//   if (!machineId) {
//     return res.status(400).json({ error: 'Missing Machine Id' });
//   }

//   // Validate period parameter
//   const validPeriods = ['daily', 'weekly', 'monthly'];
//   if (!validPeriods.includes(period.toLowerCase())) {
//     return res.status(400).json({ error: 'Invalid period. Must be daily, weekly, or monthly' });
//   }

//   try {
//     let query = '';
//     let queryParams = [machineId];

//     switch (period.toLowerCase()) {
//       case 'daily':
//         // Get data for the last 30 days
//         query = `
//           SELECT
//             Date,
//             Machine_Actual_Quantity,
//             Machine_Planned_Quantity,
//             DATE_FORMAT(Date, '%d/%m') as formatted_date
//           FROM Overall_Daily_Machine_Efficiency
//           WHERE MachineID = ?
//             AND Date >= DATE_SUB(CURDATE(), INTERVAL 30 DAY)
//             AND Date <= CURDATE()
//           ORDER BY Date DESC
//           LIMIT 30
//         `;
//         break;

//       case 'weekly':
//         // Get weekly aggregated data for the last 12 weeks
//         query = `
//           SELECT
//             YEAR(Date) as year,
//             WEEK(Date, 1) as week_number,
//             MIN(Date) as week_start_date,
//             MAX(Date) as week_end_date,
//             SUM(Machine_Actual_Quantity) as Machine_Actual_Quantity,
//             SUM(Machine_Planned_Quantity) as Machine_Planned_Quantity,
//             CONCAT('W', WEEK(Date, 1)) as formatted_date
//           FROM Overall_Daily_Machine_Efficiency
//           WHERE MachineID = ?
//             AND Date >= DATE_SUB(CURDATE(), INTERVAL 12 WEEK)
//             AND Date <= CURDATE()
//           GROUP BY YEAR(Date), WEEK(Date, 1)
//           ORDER BY year DESC, week_number DESC
//           LIMIT 12
//         `;
//         break;

//       case 'monthly':
//         // Get monthly aggregated data for the last 12 months
//         query = `
//           SELECT
//             YEAR(Date) as year,
//             MONTH(Date) as month_number,
//             MIN(Date) as month_start_date,
//             MAX(Date) as month_end_date,
//             SUM(Machine_Actual_Quantity) as Machine_Actual_Quantity,
//             SUM(Machine_Planned_Quantity) as Machine_Planned_Quantity,
//             DATE_FORMAT(MIN(Date), '%m/%y') as formatted_date
//           FROM Overall_Daily_Machine_Efficiency
//           WHERE MachineID = ?
//             AND Date >= DATE_SUB(CURDATE(), INTERVAL 12 MONTH)
//             AND Date <= CURDATE()
//           GROUP BY YEAR(Date), MONTH(Date)
//           ORDER BY year DESC, month_number DESC
//           LIMIT 12
//         `;
//         break;
//     }

//     const [results] = await pool.query(query, queryParams);

//     // Add metadata to response
//     const response = {
//       period: period.toLowerCase(),
//       machineId: machineId,
//       dataCount: results.length,
//       data: results
//     };

//     return res.json(response);

//   } catch (err) {
//     console.error('Error fetching machine efficiency data:', err);
//     res.status(500).json({ error: err.message });
//   }
// });
router.get(
  "/overall-machine-efficiency/:productionArea/:equipmentId/:period",
  async (req, res) => {
    const { productionArea, equipmentId, period = "daily" } = req.params;

    if (!productionArea || !equipmentId) {
      return res
        .status(400)
        .json({ error: "Missing Production Area or Equipment Id" });
    }

    // Construct dynamic table name
    const tableName = `${getDbArea(productionArea)}_${equipmentId}_wo`;

    // Validate period parameter
    const validPeriods = ["daily", "weekly", "monthly"];
    if (!validPeriods.includes(period.toLowerCase())) {
      return res
        .status(400)
        .json({ error: "Invalid period. Must be daily, weekly, or monthly" });
    }

    try {
      let query = "";
      let queryParams = [];

      switch (period.toLowerCase()) {
        case "daily":
          query = `
          SELECT
    DATE(Timestamp) as date_only,
    SUM(JobOrder_GrossQuantity) as Machine_Actual_Quantity,
    SUM(JobOrder_GrossQuantity) as Machine_Planned_Quantity,
    DATE_FORMAT(DATE(Timestamp), '%d/%m') as formatted_date
FROM ??
GROUP BY DATE(Timestamp), DATE_FORMAT(DATE(Timestamp), '%d/%m')
ORDER BY DATE(Timestamp) DESC
LIMIT 30
        `;
          queryParams = [tableName];
          break;

        case "weekly":
          query = `
          SELECT
    YEAR(Timestamp) as year,
    WEEK(Timestamp, 1) as week_number,
    DATE(DATE_SUB(Timestamp, INTERVAL WEEKDAY(Timestamp) DAY)) as week_start_date,
    DATE(DATE_ADD(DATE_SUB(Timestamp, INTERVAL WEEKDAY(Timestamp) DAY), INTERVAL 6 DAY)) as week_end_date,
    SUM(JobOrder_GrossQuantity) as Machine_Actual_Quantity,
    SUM(JobOrder_GrossQuantity) as Machine_Planned_Quantity,
    CONCAT('W', WEEK(Timestamp, 1)) as formatted_date
FROM ??
GROUP BY YEAR(Timestamp), WEEK(Timestamp, 1)
ORDER BY year DESC, week_number DESC
LIMIT 12
        `;
          queryParams = [tableName];
          break;

        case "monthly":
          // Get monthly aggregated data for the last 12 months
          query = `
          SELECT
    YEAR(Timestamp) as year,
    MONTH(Timestamp) as month_number,
    DATE(CONCAT(YEAR(Timestamp), '-', LPAD(MONTH(Timestamp), 2, '0'), '-01')) as month_start_date,
    LAST_DAY(DATE(CONCAT(YEAR(Timestamp), '-', LPAD(MONTH(Timestamp), 2, '0'), '-01'))) as month_end_date,
    SUM(JobOrder_GrossQuantity) as Machine_Actual_Quantity,
    SUM(JobOrder_GrossQuantity) as Machine_Planned_Quantity,
    DATE_FORMAT(DATE(CONCAT(YEAR(Timestamp), '-', LPAD(MONTH(Timestamp), 2, '0'), '-01')), '%m/%y') as formatted_date
FROM ??
GROUP BY YEAR(Timestamp), MONTH(Timestamp)
ORDER BY year DESC, month_number DESC
LIMIT 12
        `;
          queryParams = [tableName];
          break;
      }

      const [results] = await pool.query(query, queryParams);

      // Add metadata to response
      const response = {
        period: period.toLowerCase(),
        productionArea: productionArea,
        equipmentId: equipmentId,
        tableName: tableName,
        dataCount: results.length,
        data: results,
      };

      return res.json(response);
    } catch (err) {
      console.error("Error fetching machine production data:", err);
      res.status(500).json({ error: err.message });
    }
  }
);

router.get(
  "/alarms/status-duration/:machineId/:workOrderId",
  async (req, res) => {
    const { machineId, workOrderId } = req.params;

    // Validate required parameters
    if (!machineId) {
      return res.status(400).json({ error: "Missing Machine ID" });
    }
    if (!workOrderId) {
      return res.status(400).json({ error: "Missing Work Order ID" });
    }

    try {
      // Query to fetch alarm data filtered by machine_id and wo_id
      const query = `
        SELECT 
          alarm_description_status, 
          spending_duration
        FROM equipment_alarm_status
        WHERE machine_id = ? AND wo_id = ?
      `;

      const [results] = await pool.query(query, [machineId, workOrderId]);

      // Handle case when no data is found
      if (results.length === 0) {
        return res.json({
          machineId,
          workOrderId,
          categories: [],
          durations: [],
          totalDuration: 0,
          recordCount: 0,
          message: "No alarm data found for the specified Machine ID and Work Order ID"
        });
      }

      // Accumulate spending_duration by alarm_description_status
      const accumulatedData = {};
      
      results.forEach((record) => {
        const status = record.alarm_description_status || "Unknown";
        const duration = convertTimeToMinutes(record.spending_duration);

        if (accumulatedData[status]) {
          accumulatedData[status] += duration;
        } else {
          accumulatedData[status] = duration;
        }
      });

      // Convert accumulated data to array and sort by duration (descending)
      const sortedData = Object.entries(accumulatedData)
        .map(([status, duration]) => ({
          status,
          duration: Math.round(duration * 100) / 100 // Round to 2 decimal places
        }))
        .filter(item => item.duration > 0) // Remove zero or negative values
        .sort((a, b) => b.duration - a.duration);

      // Handle case when all durations are zero
      if (sortedData.length === 0) {
        return res.json({
          machineId,
          workOrderId,
          categories: [],
          durations: [],
          totalDuration: 0,
          recordCount: results.length,
          message: "All alarm durations are zero"
        });
      }

      // Calculate total duration
      const totalDuration = sortedData.reduce((sum, item) => sum + item.duration, 0);

      // Prepare response data optimized for bar graph
      const categories = sortedData.map(item => item.status);
      const durations = sortedData.map(item => item.duration);

      // Calculate percentages for each category
      const percentages = sortedData.map(item => 
        Math.round((item.duration / totalDuration) * 100 * 100) / 100
      );

      // Response structure optimized for plotting
      const response = {
        machineId,
        workOrderId,
        categories,           // X-axis labels (alarm descriptions)
        durations,           // Y-axis values (accumulated durations in minutes)
        percentages,         // Percentage of total for each category
        totalDuration: Math.round(totalDuration * 100) / 100,
        recordCount: results.length,
        uniqueStatuses: sortedData.length,
        chartConfig: {
          title: `Alarm Status Duration - Machine ${machineId} | Work Order ${workOrderId}`,
          xAxisLabel: "Alarm Description Status",
          yAxisLabel: "Duration (minutes)",
          maxY: Math.ceil(Math.max(...durations) * 1.1) // 10% padding
        },
        topAlarms: sortedData.slice(0, 5).map((item, index) => ({
          rank: index + 1,
          status: item.status,
          duration: item.duration,
          percentage: percentages[index]
        }))
      };

      return res.json(response);

    } catch (err) {
      console.error("Error fetching alarm status duration:", err);
      return res.status(500).json({ 
        error: "Internal server error",
        message: err.message 
      });
    }
  }
);

// Batch endpoint to get ProcessID for multiple equipment efficiently
// router.post("/equipment-process-id/batch", async (req, res) => {
//   const { equipmentList } = req.body;

//   if (!equipmentList || !Array.isArray(equipmentList)) {
//     return res.status(400).json({
//       error: "Missing or invalid equipmentList array in request body",
//       example: {
//         equipmentList: [{ equipmentId: "EQ001", productionArea: "PA001" }],
//       },
//     });
//   }

//   try {
//     const results = await Promise.all(
//       equipmentList.map(async (equipment) => {
//         const { equipmentId, productionArea } = equipment;

//         if (!equipmentId || !productionArea) {
//           return {
//             equipmentId: equipmentId || "unknown",
//             productionArea: productionArea || "unknown",
//             error: "Missing equipmentId or productionArea",
//             processID: null,
//           };
//         }

//         try {
//           // Construct the table name: productionArea_equipmentId_latest
//           const tableName = `${getDbArea(productionArea)}_${equipmentId}_latest`;

//           const query = `SELECT ProcessID FROM ?? LIMIT 1`;
//           const [queryResults] = await pool.query(query, [tableName]);

//           if (queryResults.length > 0) {
//             return {
//               equipmentId,
//               productionArea,
//               tableName,
//               processID: queryResults[0].ProcessID,
//               success: true,
//             };
//           } else {
//             return {
//               equipmentId,
//               productionArea,
//               tableName,
//               processID: null,
//               error: "No data found",
//             };
//           }
//         } catch (err) {
//           return {
//             equipmentId,
//             productionArea,
//             tableName: `${productionArea}_${equipmentId}_latest`,
//             processID: null,
//             error:
//               err.code === "ER_NO_SUCH_TABLE"
//                 ? "Table does not exist"
//                 : err.message,
//           };
//         }
//       })
//     );

//     return res.json({
//       totalRequested: equipmentList.length,
//       successCount: results.filter((r) => r.success).length,
//       results,
//     });
//   } catch (err) {
//     console.error("Error in batch ProcessID fetch:", err);
//     res.status(500).json({ error: err.message });
//   }
// });
router.post("/equipment-process-id/batch", async (req, res) => {
  const { equipmentList } = req.body;
  
  if (!equipmentList || !Array.isArray(equipmentList)) {
    return res.status(400).json({
      error: "Missing or invalid equipmentList array in request body",
      example: {
        equipmentList: [{ equipmentId: "EQ001", productionArea: "PA001" }],
      },
    });
  }
  
  try {
    const results = await Promise.all(
      equipmentList.map(async (equipment) => {
        const { equipmentId, productionArea } = equipment;
        
        if (!equipmentId || !productionArea) {
          return {
            equipmentId: equipmentId || "unknown",
            productionArea: productionArea || "unknown",
            error: "Missing equipmentId or productionArea",
            processID: null,
            JobOrderID: null,
            JobOrder_GrossQuantity: null,
            JobOrder_ExpectedQuantity: null,
            RunStatus: null,
          };
        }
        
        try {
          const tableName = `${getDbArea(productionArea)}_${equipmentId}_latest`;
          const query = `SELECT ProcessID, JobOrderID, JobOrder_GrossQuantity, JobOrder_ExpectedQuantity, RunStatus FROM ?? LIMIT 1`;
          const [queryResults] = await pool.query(query, [tableName]);
          
          if (queryResults.length > 0) {
            return {
              equipmentId,
              productionArea,
              tableName,
              processID: queryResults[0].ProcessID,
              JobOrderID: queryResults[0].JobOrderID,
              JobOrder_GrossQuantity: queryResults[0].JobOrder_GrossQuantity,
              JobOrder_ExpectedQuantity: queryResults[0].JobOrder_ExpectedQuantity,
              RunStatus: queryResults[0].RunStatus,
              success: true,
            };
          } else {
            return {
              equipmentId,
              productionArea,
              tableName,
              processID: null,
              JobOrderID: null,
              JobOrder_GrossQuantity: null,
              JobOrder_ExpectedQuantity: null,
              RunStatus: null,
              error: "No data found",
            };
          }
        } catch (err) {
          return {
            equipmentId,
            productionArea,
            tableName: `${productionArea}_${equipmentId}_latest`,
            processID: null,
            JobOrderID: null,
            JobOrder_GrossQuantity: null,
            JobOrder_ExpectedQuantity: null,
            RunStatus: null,
            error:
              err.code === "ER_NO_SUCH_TABLE"
                ? "Table does not exist"
                : err.message,
          };
        }
      })
    );
    
    return res.json({
      totalRequested: equipmentList.length,
      successCount: results.filter((r) => r.success).length,
      results,
    });
  } catch (err) {
    console.error("Error in batch ProcessID fetch:", err);
    res.status(500).json({ error: err.message });
  }
});

// Keep the single endpoint for individual lookups if needed
router.get(
  "/equipment-process-id/:equipmentId/:productionArea",
  async (req, res) => {
    const { equipmentId, productionArea } = req.params;

    if (!equipmentId) {
      return res.status(400).json({ error: "Missing equipmentId parameter" });
    }
    if (!productionArea) {
      return res
        .status(400)
        .json({ error: "Missing productionArea parameter" });
    }

    try {
      // Construct the table name: productionArea_equipmentId_latest
      const tableName = `${getDbArea(productionArea)}_${equipmentId}_latest`;

      const query = `SELECT ProcessID FROM ?? LIMIT 1`;
      const [results] = await pool.query(query, [tableName]);

      if (results.length === 0) {
        return res.status(404).json({
          error: "No ProcessID data found",
          tableName: tableName,
        });
      }

      return res.json({
        equipmentId,
        productionArea,
        tableName,
        processID: results[0].ProcessID,
        success: true,
      });
    } catch (err) {
      console.error("Error fetching ProcessID:", err);

      if (err.code === "ER_NO_SUCH_TABLE") {
        return res.status(404).json({
          error: `Table ${productionArea}_${equipmentId}_latest does not exist`,
          equipmentId,
          productionArea,
        });
      }

      res.status(500).json({ error: err.message });
    }
  }
);

module.exports = router;
