const express = require("express");
const admin = require("firebase-admin");
const {getClientFirestore} = require("../helpers/dbConnections");
// eslint-disable-next-line new-cap
const router = express.Router();

// Settings for the Equipment Monitoring station pages (Sterilizer, Digester).
// One shared document per station, not per user: every account on the mill
// sees the same station page. Equipment of the station's category are the
// page's lines; this document holds how each line's readings are read
// (device + measurement + field per point), the rules and the page titles.
const COLLECTION = "stationPageSettings";
const STATIONS = ["sterilizer", "digester"];

async function stationRef(req) {
  const db = await getClientFirestore(req.headers["x-client-id"] || null);
  return db.collection(COLLECTION).doc(req.params.station);
}

function validStation(req, res) {
  if (STATIONS.includes(req.params.station)) return true;
  res.status(400).json({error: `Unknown station "${req.params.station}"`});
  return false;
}

// GET /station-page-settings/:station — saved settings, or {exists:false}.
router.get("/:station", async (req, res) => {
  if (!validStation(req, res)) return;
  try {
    const snap = await (await stationRef(req)).get();
    if (!snap.exists) return res.status(200).json({exists: false, settings: null});
    return res.status(200).json({exists: true, settings: snap.data()});
  } catch (e) {
    return res.status(500).json({error: "Failed to load station settings", details: e.message});
  }
});

// POST /station-page-settings/:station — replaces the station's settings.
router.post("/:station", async (req, res) => {
  if (!validStation(req, res)) return;
  const body = req.body;
  if (!body || typeof body !== "object" || Array.isArray(body)) {
    return res.status(400).json({error: "Settings must be an object"});
  }
  try {
    const data = {...body, station: req.params.station, updatedAt: admin.firestore.FieldValue.serverTimestamp()};
    await (await stationRef(req)).set(data);
    return res.status(200).json({success: true});
  } catch (e) {
    return res.status(500).json({error: "Failed to save station settings", details: e.message});
  }
});

module.exports = router;
