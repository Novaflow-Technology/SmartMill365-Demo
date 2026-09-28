// const express = require('express');
// const mysql = require('mysql2/promise');

// const app = express();
// const port = 3000;

// const dbConfig = {
//   host: "219.92.5.163",
//   user: "novaflow",
//   password: "",
//   database: "Danapac_Database",
// };

// async function main() {
//   const pool = mysql.createPool(dbConfig);

//   app.get('/daily-status/:equipment', async (req, res) => {
//     const equipment = req.params.equipment;
//     if (!equipment) {
//       return res.status(400).json({ error: 'Missing equipment parameter' });
//     }

//     try {
//       // Step 1: Get today's records for all matching devices
//       const query = `
//         SELECT timestamp, device_name, status
//         FROM device_status_summary
//         WHERE device_name LIKE ?
//           AND DATE(timestamp) = DATE(CONVERT_TZ(NOW() - INTERVAL 3 DAY, '+00:00', '+08:00'))
//         ORDER BY timestamp
//       `;
//       const [rows] = await pool.query(query, [`%${equipment}%`]);

//       if (rows.length === 0) {
//         return res.json({ running: 0, idle: 0, alarm: 0, stopped: 0 });
//       }

//       // Step 2: Group by timestamp (minute) and collect statuses from all matched devices
//       const timelineMap = new Map();

//       rows.forEach(row => {
//         const timeKey = new Date(row.timestamp).toISOString().split('.')[0];
//         if (!timelineMap.has(timeKey)) {
//           timelineMap.set(timeKey, []);
//         }
//         timelineMap.get(timeKey).push(row.status);
//       });

//       // Step 3: Determine overall status at each minute (highest priority wins)
//       const statusPriority = { 1: 'running', 2: 'alarm', 0: 'idle', 3: 'stopped' };
//       const priorityOrder = [1, 2, 0, 3]; // highest to lowest
//       const durations = { running: 0, idle: 0, alarm: 0, stopped: 0 };

//       timelineMap.forEach(statusList => {
//         for (const p of priorityOrder) {
//           if (statusList.includes(p)) {
//             const key = statusPriority[p];
//             durations[key]++;
//             break;
//           }
//         }
//       });

//       res.json(durations);
//     } catch (err) {
//       console.error(err);
//       res.status(500).json({ error: err.message });
//     }
//   });

//   app.listen(port, () => {
//     console.log(`Server running on port ${port}`);
//   });
// }

// main().catch(console.error);
