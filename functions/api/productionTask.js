const express = require("express");

const router = express.Router();
const mysql = require("mysql2");

const pool = mysql.createPool({
  host: "219.92.5.163",
  user: "novaflow",
  password: "",
  database: "Intech_Database",
});

router.get("/machines", (req, res) => {
  const query = "SELECT DISTINCT MachineID FROM Production_Task_Status";

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

router.get("/all-status", (req, res) => {
  const query = "SELECT * FROM Production_Task_Status";

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

// router.get('/search', async (req, res) => {
//   const keyword = req.query.q;
//   if (!keyword) return res.status(400).json({ error: 'Missing query parameter: q' });

//   try {
//     const [rows] = await pool.execute(
//       `SELECT * FROM Production_Task_Status WHERE MachineID LIKE ? OR WorkOrderID LIKE ?`,
//       [`%${keyword}%`, `%${keyword}%`]
//     );

//     res.json(rows);
//   } catch (err) {
//     console.error('❌ DB Error:', err.message); // More readable error
//     console.error(err); // Full error
//     res.status(500).json({ error: err.message });
//   }
// });

router.get('/search', (req, res) => {
  const keyword = req.query.q;
  if (!keyword) return res.status(400).json({ error: 'Missing query parameter: q' });

  const query = `SELECT * FROM Production_Task_Status WHERE MachineID LIKE ? OR WorkOrderID LIKE ?`;
  pool.query(query, [`%${keyword}%`, `%${keyword}%`], (error, results) => {
    if (error) {
      console.error('DB Error:', error);
      return res.status(500).json({ error: 'Database error' });
    }
    res.json(results);
  });
});

router.get('/searchMachine', (req, res) => {
  const keyword = req.query.q;
  if (!keyword) return res.status(400).json({ error: 'Missing query parameter: q' });

  const query = `SELECT * FROM Production_Task_Status WHERE MachineID LIKE ?`;
  pool.query(query, [`%${keyword}%`, `%${keyword}%`], (error, results) => {
    if (error) {
      console.error('DB Error:', error);
      return res.status(500).json({ error: 'Database error' });
    }
    res.json(results);
  });
});

router.get('/searchProduct', (req, res) => {
  const keyword = req.query.q;
  if (!keyword) return res.status(400).json({ error: 'Missing query parameter: q' });

  const query = `SELECT * FROM Production_Task_Status WHERE ProductID LIKE ?`;
  pool.query(query, [`%${keyword}%`, `%${keyword}%`], (error, results) => {
    if (error) {
      console.error('DB Error:', error);
      return res.status(500).json({ error: 'Database error' });
    }
    res.json(results);
  });
});

router.get('/searchClass', (req, res) => {
  const keyword = req.query.q;
  if (!keyword) return res.status(400).json({ error: 'Missing query parameter: q' });

  const query = `SELECT * FROM Production_Task_Status WHERE Urgency LIKE ?`;
  pool.query(query, [`%${keyword}%`, `%${keyword}%`], (error, results) => {
    if (error) {
      console.error('DB Error:', error);
      return res.status(500).json({ error: 'Database error' });
    }
    res.json(results);
  });
});

// Express route handler
router.get('/status', async (req, res) => {
  try {
    const { search, status } = req.query;
    let query = {};
    
    if (search) {
      query.$or = [
        { name: { $regex: search, $options: 'i' } },
        { code: { $regex: search, $options: 'i' } }
      ];
    }
    
    if (status) {
      const statusArray = status.split(',');
      query.status = { $in: statusArray };
    }
    
    const machines = await Machine.find(query);
    res.json(machines);
  } catch (error) {
    res.status(500).json({ error: error.message });
  }
});

router.get('/filter', (req, res) => {
  
  const { status, class: classParam, due } = req.query;

  let sql = 'SELECT * FROM Production_Task_Status WHERE 1=1';
  let values = [];

  // Validate and apply status filter
  let statusArray = [];
  if (status && status !== 'null' && status !== 'undefined' && status.trim() !== '') {
    statusArray = status.split(',').filter(s => s.trim() !== '');
    if (statusArray.length > 0) {
      const placeholders = statusArray.map(() => '?').join(',');
      sql += ` AND Status IN (${placeholders})`;
      values.push(...statusArray);
    }
  }

  // Validate and apply class filter
  let classArray = [];
  if (classParam && classParam !== 'null' && classParam !== 'undefined' && classParam.trim() !== '') {
    classArray = classParam.split(',').filter(c => c.trim() !== '');
    if (classArray.length > 0) {
      const placeholders = classArray.map(() => '?').join(',');
      sql += ` AND Urgency IN (${placeholders})`;
      values.push(...classArray);
    }
  }

  // Validate due date
  let hasDue = false;
  if (due && due !== 'null' && due !== 'undefined' && due.trim() !== '') {
    sql += ` AND Planned_End_Date = ?`;
    values.push(due);
    hasDue = true;
  }

  // If any filter was provided but after filtering is empty, return empty result
  if (
    (status && statusArray.length === 0) ||
    (classParam && classArray.length === 0)
  ) {
    return res.json([]); // No possible match
  }

  pool.query(sql, values, (err, results) => {
    if (err) {
      console.error('DB Error:', err);
      return res.status(500).json({ error: 'DB Error', details: err });
    }
    res.json(results);
  });
});







module.exports = router;
