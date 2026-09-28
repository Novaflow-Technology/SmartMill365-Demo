const functions = require("firebase-functions");
// firebase-functions v6's default export is the v2 API — functions.pubsub
// there only has the v2 onMessagePublished trigger, not .schedule(). The
// v1-style pubsub.schedule(...).onRun(...) API (used below, to match this
// project's "platform": "gcfv1" pin in firebase.json) lives under the
// /v1 compat entrypoint instead.
const functionsV1 = require("firebase-functions/v1");
const express = require("express");
const cors = require("cors");
const admin = require("firebase-admin");

// Initialize Firebase Admin SDK
admin.initializeApp();

const app = express();

// Middleware for CORS and JSON handling
app.use(cors({ origin: true }));
app.use(express.json());
app.use(express.text({ type: "application/vnd.flux" }));

// Middleware to log all requests for debugging
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.originalUrl}`);
  console.log('Request headers:', req.headers);
  console.log('Request body:', JSON.stringify(req.body, null, 2));

  // Intercepting the response
  const oldSend = res.send;
  res.send = function (data) {
    console.log(`[${new Date().toISOString()}] Response status: ${res.statusCode}`);
    console.log('Response body:', data);
    oldSend.apply(res, arguments);
  };

  next();
});

// Import modular functions
const groupsFunctions = require("./api/groupFunctions");
const userFunctions = require("./api/userFunctions");
const equipmentFunctions = require("./api/equipmentFunctions");
const equipmentStatusFunctions = require("./api/equipmentStatusFunctions"); // For status-related operations
const productionAreaFunctions = require("./api/productionAreaFunctions");
const factoryFunctions = require("./api/factoryFunctions");
const workOrderFunctions = require("./api/workOrderFunctions");
const customerFunctions = require("./api/customerFunctions");
const energyDetailsFunctions = require("./api/energyDetails");
const energyOverviewFunctions = require("./api/energyOverview");
const equipmentDetailsFunctions = require("./api/equipmentDetails");
const equipmentAlarmDataFunctions = require("./api/equipmentAlarmData");
const energyDataLoggerFunctions = require("./api/energyDataLogger");
const productionTaskFunctions = require("./api/productionTask");
const energySystemSettingFunction = require("./api/energySystemSettingFunction");
const masterBillingConfigFunction = require("./api/masterBillingConfigFunction");
const kanbanDashboardSettingFunction = require("./api/kanbanDashboardSettingFunction");
const pomDataFunction = require("./api/pomDataFunction"); // Group POM Command Center — real device catalog + live Influx values
const facilityFunctions = require("./api/facilityFunctions");
const tariffCategorySetupFunction = require("./api/tariffCategorySetupFunction");
const productionLineFunctions = require("./api/productionLineFunctions");
const processFunctions = require("./api/processFunctions");
const abnormalReasonFunctions = require("./api/abnormalReasonFunctions");
const emissionFactorFunctions = require("./api/emissionFactorFunctions");
const sankyFlowSettingFunction = require("./api/sankyFlowSettingFunction");
const carbonDashboardConfigFunction = require("./api/carbonDashboardConfigFunction");
const airCompressorDashboardConfigFunction = require("./api/airCompressorDashboardConfigFunction");
const mdInsightReportConfigFunction = require("./api/mdInsightReportConfigFunction");
const maxDemandChartConfigFunction = require("./api/maxDemandChartConfigFunction");
const mdInsightRulesFunction = require("./api/mdInsightRulesFunction");
const mdInsightReportLogFunction = require("./api/mdInsightReportLogFunction");
const discoveryDeviceFunctions = require("./api/discoverydevice");
const shiftFunctions = require("./api/shiftFunctions");
const deviceTypeFunctions = require("./api/deviceTypeFunctions");
const productionOutputLogFunctions = require("./api/productionOutputLogFunctions");
const equipmentCategoryFunctions = require("./api/equipmentCategoryFunctions");
const integrationConfigApi = require("./api/integrationConfigApi");
const energyDetailsInfluxDbFunctions = require("./api/energyDetailsInfluxDb");
const passwordResetFunctions = require("./api/passwordResetFunctions");
const productFunctions = require("./api/productFunctions");
const alarmFunctions = require("./api/alarmFunctions");
const deviceFunctions = require("./api/deviceFunctions");
const plantEnergyCommandCenterFunction = require("./api/plantEnergyCommandCenterFunction");
const energyComparisonFunctions = require("./api/energyComparison");
const tnbMeterFunctions = require("./api/tnbMeterFunctions");
const kwhPerTonneDataLogFunctions = require("./api/kwhPerTonneDataLog");
const tnbE3SimulatorFunctions = require("./api/tnbE3SimulatorFunction");
const { runMonthlyRollup, previousPeriod } = require("./helpers/mdInsightMonthlyRollup");

// Define routes for different API modules
app.use("/users", userFunctions);
app.use("/groups", groupsFunctions);

// Define route for CRUD operations on equipment
app.use("/equipment", equipmentFunctions); // Handles create, read, update, delete operations for equipment
// Define route for equipment status-related operations
app.use("/equipmentStatus", equipmentStatusFunctions); // Handles equipment status queries, like /status
app.use("/energy-settings", energySystemSettingFunction); // Handles energy system settings operations
app.use("/masterBillingConfig", masterBillingConfigFunction); // Handles master billing configuration operations
app.use("/facilities", facilityFunctions); // Handles facility-related operations
app.use("/tariff-categories", tariffCategorySetupFunction); // Handles tariff category setup operations
app.use("/sankey-setting", sankyFlowSettingFunction); // Handles sankey flow setting operations
app.use("/carbon-dashboard-config", carbonDashboardConfigFunction); // Handles Carbon Intelligence Dashboard card→Device ID config
app.use("/air-compressor-dashboard-config", airCompressorDashboardConfigFunction); // Handles Air Compressor Monitoring dashboard card→Device ID config
app.use("/md-insight-report-config", mdInsightReportConfigFunction); // Handles MD Insight Report plant photo/footer logo image config
app.use("/max-demand-chart-config", maxDemandChartConfigFunction); // Handles Max Demand Monitoring Equipment Load Correlation / Equipment MD Ranking chart device selection
app.use("/md-insight-rules", mdInsightRulesFunction); // Computes the MD Insight Report's 18 rule lines (MD001-MD404)
app.use("/md-insight-report-log", mdInsightReportLogFunction); // Logs each MD Insight Report generation to md_insight_report_log

app.use("/productionAreas", productionAreaFunctions);
app.use("/productionLines", productionLineFunctions);
app.use("/process", processFunctions);
app.use("/abnormalReasons", abnormalReasonFunctions);
app.use("/emission-factors", emissionFactorFunctions);
app.use("/shifts", shiftFunctions);
app.use("/deviceTypes", deviceTypeFunctions);
app.use("/factory", factoryFunctions);
app.use("/workOrders", workOrderFunctions);
app.use("/customers", customerFunctions);
app.use("/energyDetails", energyDetailsFunctions);
app.use("/energyOverview", energyOverviewFunctions);
app.use("/equipmentDetails", equipmentDetailsFunctions);
app.use("/equipmentAlarmData", equipmentAlarmDataFunctions);
app.use("/energyDataLogger", energyDataLoggerFunctions);
app.use("/kanban-settings", kanbanDashboardSettingFunction);
app.use("/pom", pomDataFunction); // Group POM Command Center — real device catalog + live Influx values
app.use("/productionTask", productionTaskFunctions); // Handles production task-related operation
app.use("/productionOutputLog", productionOutputLogFunctions);
app.use("/discoveryDevice", discoveryDeviceFunctions);
app.use("/equipmentCategory", equipmentCategoryFunctions);
app.use("/integrationConfig", integrationConfigApi);
app.use("/energyDetailsInfluxDb", energyDetailsInfluxDbFunctions);
app.use("/password-reset", passwordResetFunctions);
app.use("/products", productFunctions);
app.use("/alarms", alarmFunctions);
app.use("/devices", deviceFunctions);
app.use("/plant-energy-command-center", plantEnergyCommandCenterFunction);
app.use("/energyComparison", energyComparisonFunctions);
app.use("/tnbMeters", tnbMeterFunctions);
app.use("/kwhPerTonneDataLog", kwhPerTonneDataLogFunctions);
app.use("/tnbE3Simulator", tnbE3SimulatorFunctions);

// Health check endpoint (optional, useful for debugging and monitoring)
app.get("/api/health", (req, res) => {
  res.status(200).json({ status: "OK" });
});

// 404 Handler for undefined routes
app.use((req, res) => {
  console.log(`[${new Date().toISOString()}] 404 - Route not found: ${req.method} ${req.originalUrl}`);
  res.status(404).send(`Cannot ${req.method} ${req.originalUrl}`);
});

// Export the Firebase Cloud Function
exports.api = functions.https.onRequest(app);

// Runs at 00:00 Asia/Kuala_Lumpur on the 1st of every month: auto-generates
// and permanently logs the just-closed month's MD Insight Report for every
// active TNB meter, across every tenant, so a plant's report for a closed
// month is a locked historical record instead of always recomputing against
// today's settings. See functions/helpers/mdInsightMonthlyRollup.js for what
// each snapshot contains (and the known cc/mdRate resolution limits).
exports.mdInsightMonthlyRollup = functionsV1.pubsub
  .schedule("0 0 1 * *")
  .timeZone("Asia/Kuala_Lumpur")
  .onRun(async () => {
    const period = previousPeriod();
    await runMonthlyRollup({ period });
    return null;
  });
