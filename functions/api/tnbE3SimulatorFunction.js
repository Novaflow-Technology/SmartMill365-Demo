const express = require("express");
const mysql = require("mysql2");
const { getMysqlPoolSafe, withDbFallback } = require("../helpers/dbConnections");

// eslint-disable-next-line new-cap
const router = express.Router();

// Default Danapac pool — kept explicitly as fallback for untagged requests
// (Danapac domain / legacy callers without x-client-id). Same as energyComparison.js.
const pool = mysql.createPool({
  host: "",
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
}).promise();

// Multi-tenant: client's MySQL when x-client-id is present; otherwise Danapac pool.
async function poolFor(req) {
  const clientId = req.clientId || req.headers["x-client-id"];
  if (!clientId) return pool;
  return getMysqlPoolSafe(clientId, undefined, req);
}

async function loadElectricityTariff(req, userId) {
  return withDbFallback(req, async (db) => {
    const doc = await db
      .collection("masterBillingConfig")
      .doc(userId)
      .collection("settings")
      .doc("electricityTariff")
      .get();
    if (!doc.exists) return { notFound: true };
    return { data: doc.data() };
  });
}

function num(v) {
  const n = parseFloat(v);
  return Number.isFinite(n) ? n : 0;
}

function pfSteps(upper, lower) {
  if (upper <= lower) return 0;
  return Math.round((upper - lower) * 100);
}

/** Same formula as TNB Bill Simulator (_buildFromConfig) in Flutter. */
function calcTnbBillTotal({
  peakUsage,
  offPeakUsage,
  peakRate,
  offPeakRate,
  maxDemandKw,
  pfValue,
  mdCapacityCharge,
  mdNetworkCharge,
  currentAFA,
  tier1Threshold,
  tier1Rate,
  tier2Trigger,
  tier2Rate,
  peakAmount: peakAmountIn,
  offPeakAmount: offPeakAmountIn,
}) {
  let peakAmount = peakAmountIn;
  let offPeakAmount = offPeakAmountIn;
  if (peakAmount <= 0) peakAmount = peakUsage * peakRate;
  if (offPeakAmount <= 0) offPeakAmount = offPeakUsage * offPeakRate;

  const totalKwh = peakUsage + offPeakUsage;
  const mdRate = mdCapacityCharge + mdNetworkCharge;
  const mdAmount = maxDemandKw * mdRate;
  const icptAmount = totalKwh * currentAFA;

  const pf = Math.min(1, Math.max(0, pfValue));
  let pfPenaltyAmount = 0;
  if (pf < tier1Threshold) {
    const tier1Lower = Math.max(pf, tier2Trigger);
    const tier1Penalty = pfSteps(tier1Threshold, tier1Lower) * tier1Rate;
    let tier2Penalty = 0;
    if (pf < tier2Trigger) {
      tier2Penalty = pfSteps(tier2Trigger, pf) * tier2Rate;
    }
    const pfPenaltyPercent = tier1Penalty + tier2Penalty;
    const billingBeforePf = peakAmount + offPeakAmount + mdAmount + icptAmount;
    pfPenaltyAmount = billingBeforePf * (pfPenaltyPercent / 100);
  }

  const totalBill = peakAmount + offPeakAmount + mdAmount + pfPenaltyAmount + icptAmount;
  return {
    totalBill: parseFloat(totalBill.toFixed(2)),
    peakAmount: parseFloat(peakAmount.toFixed(2)),
    offPeakAmount: parseFloat(offPeakAmount.toFixed(2)),
    mdAmount: parseFloat(mdAmount.toFixed(2)),
    icptAmount: parseFloat(icptAmount.toFixed(2)),
    pfPenaltyAmount: parseFloat(pfPenaltyAmount.toFixed(2)),
    totalKwh,
  };
}

async function loadBillingConfig(req, userId, categoryId) {
  return withDbFallback(req, async (db) => {
    const userRef = db.collection("masterBillingConfig").doc(userId);
    let cfg = null;

    const cat = (categoryId || "").toString().trim();
    if (cat) {
      const snap = await userRef.collection("categories").doc(cat).get();
      if (snap.exists) cfg = snap.data();
    }

    if (!cfg) {
      const userSnap = await userRef.get();
      const applied = userSnap.exists ? userSnap.data().appliedCategory : null;
      if (applied) {
        const catSnap = await userRef.collection("categories").doc(applied).get();
        if (catSnap.exists) cfg = catSnap.data();
      }
    }

    return cfg;
  });
}

/**
 * GET /bill-total/:userId/:year/:month
 * Full TNB Bill Simulator total (peak + off-peak + MD + ICPT + PF penalty).
 * Query: ?device_id=VDPM002&category_id=<tariffCategoryId> (optional)
 */
router.get("/bill-total/:userId/:year/:month", async (req, res) => {
  const { userId, year, month } = req.params;
  const deviceId = (req.query.device_id || "MSB").toString().trim() || "MSB";
  const categoryId = (req.query.category_id || "").toString().trim();

  if (!userId || !year || !month) {
    return res.status(400).json({ error: "Missing userId, year, or month parameter" });
  }

  try {
    const cpool = await poolFor(req);
    const y = parseInt(year, 10);
    const m = parseInt(month, 10);

    const [rows] = await cpool.query(
      `SELECT power_factor_avg, max_demand_kW, peak_usage_kWh, off_peak_usage_kWh
       FROM Overall_monthly_energy_consumption
       WHERE year = ? AND month = ? AND device_id = ?
       LIMIT 1`,
      [y, m, deviceId]
    );

    const row = rows[0] || {};
    const peakUsage = num(row.peak_usage_kWh);
    const offPeakUsage = num(row.off_peak_usage_kWh);
    const maxDemandKw = num(row.max_demand_kW);
    const pfValue = num(row.power_factor_avg);

    const tariffResult = await loadElectricityTariff(req, userId);
    if (!tariffResult || tariffResult.notFound || !tariffResult.data) {
      return res.status(404).json({ error: "No electricity tariff found", userId });
    }

    let peakRate = num(tariffResult.data.peakRate);
    let offPeakRate = num(tariffResult.data.offPeakRate);
    if (peakRate <= 0) peakRate = 0.355;
    if (offPeakRate <= 0) offPeakRate = 0.219;

    const peakAmount = parseFloat((peakUsage * peakRate).toFixed(2));
    const offPeakAmount = parseFloat((offPeakUsage * offPeakRate).toFixed(2));

    const cfg = await loadBillingConfig(req, userId, categoryId);
    if (!cfg) {
      return res.status(404).json({ error: "No billing config found", userId, categoryId });
    }

    const bill = calcTnbBillTotal({
      peakUsage,
      offPeakUsage,
      peakRate,
      offPeakRate,
      maxDemandKw,
      pfValue,
      mdCapacityCharge: num(cfg.mdCapacityCharge),
      mdNetworkCharge: num(cfg.mdNetworkCharge),
      currentAFA: num(cfg.currentAFA),
      tier1Threshold: num(cfg.targetThreshold) || 0.98,
      tier1Rate: num(cfg.tier1Rate) || 1.5,
      tier2Trigger: num(cfg.tier2Trigger) || 0.96,
      tier2Rate: num(cfg.tier2Rate) || 3,
      peakAmount,
      offPeakAmount,
    });

    return res.json({
      year: y,
      month: m,
      device_id: deviceId,
      category_id: categoryId || null,
      source: "tnb_bill_simulator",
      ...bill,
      total_amount: bill.totalBill,
      total_usage_kWh: bill.totalKwh,
    });
  } catch (err) {
    console.error("[bill-total] Error:", err.message);
    return res.status(500).json({ error: err.message });
  }
});

/**
 * GET /usage-unit/:userId/:year/:month
 * Optional query: ?device_id=VDPM002  (defaults to MSB for legacy callers)
 *
 * Example: GET /usage-unit/user123/2026/3?device_id=VDPM002
 */
router.get("/usage-unit/:userId/:year/:month", async (req, res) => {
  const { userId, year, month } = req.params;
  const deviceId = (req.query.device_id || "MSB").toString().trim() || "MSB";

  if (!userId || !year || !month) {
    return res.status(400).json({ error: "Missing userId, year, or month parameter" });
  }

  try {
    const cpool = await poolFor(req);

    // Usage from Overall_monthly for the requested device (linked DPM ID).
    const [rows] = await cpool.query(
      `SELECT
         COALESCE(SUM(peak_usage_kWh), 0)     AS peak_usage_kWh,
         COALESCE(SUM(off_peak_usage_kWh), 0) AS off_peak_usage_kWh
       FROM Overall_monthly_energy_consumption
       WHERE year = ? AND month = ? AND device_id = ?`,
      [parseInt(year, 10), parseInt(month, 10), deviceId]
    );

    const peak_usage_kWh = parseFloat(rows[0]?.peak_usage_kWh) || 0;
    const off_peak_usage_kWh = parseFloat(rows[0]?.off_peak_usage_kWh) || 0;

    // Rates from Firestore — client project when x-client-id is set,
    // else default Danapac Firestore (same withDbFallback pattern as tnbMeters).
    const tariffResult = await loadElectricityTariff(req, userId);
    if (!tariffResult || tariffResult.notFound || !tariffResult.data) {
      return res.status(404).json({ error: "No electricity tariff found", userId });
    }

    const { peakRate, offPeakRate } = tariffResult.data;
    const peak_rate = parseFloat(peakRate) || 0;
    const off_peak_rate = parseFloat(offPeakRate) || 0;

    const peak_amount = parseFloat((peak_usage_kWh * peak_rate).toFixed(2));
    const off_peak_amount = parseFloat((off_peak_usage_kWh * off_peak_rate).toFixed(2));
    const total_amount = parseFloat((peak_amount + off_peak_amount).toFixed(2));

    return res.json({
      year: parseInt(year, 10),
      month: parseInt(month, 10),
      device_id: deviceId,
      peak_usage_kWh,
      off_peak_usage_kWh,
      total_usage_kWh: peak_usage_kWh + off_peak_usage_kWh,
      peak_rate,
      off_peak_rate,
      peak_amount,
      off_peak_amount,
      total_amount,
    });
  } catch (err) {
    console.error("[usage-unit] Error:", err.message);
    return res.status(500).json({ error: err.message });
  }
});

module.exports = router;
