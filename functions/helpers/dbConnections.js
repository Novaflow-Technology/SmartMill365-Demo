const admin = require("firebase-admin");
const { InfluxDB } = require("@influxdata/influxdb-client");
const mysql = require("mysql2");

// Cache keyed by clientId so we reuse connections across requests
const _influxCache = new Map();
const _mysqlCache = new Map(); // key: `${clientId}::${database}`
const _firestoreCache = new Map(); // key: clientId → Firestore instance

// Default (Danapac/ENERGY_DEMO) InfluxDB connection — used when a request has no
// x-client-id header. Keeps the original single-tenant behaviour for clients that
// don't send x-client-id, instead of redirecting them to whichever client is
// currently set as app_config/active_integration (which is for admin/config use).
const DEFAULT_INFLUX = {
  host: "",
  token: "",
  org: "Novaflow",
  bucket: "ENERGY_DEMO",
  measurement: "power_meter",
  deviceIdTag: "device_name",
};

// Default (Danapac) MySQL connection — used when a request has no x-client-id
// header, or the client has no MySQL config in integration_config. Keeps the
// original single-tenant behaviour working without any config.
const DEFAULT_MYSQL = {
  host: "",
  port: 3306,
  user: "novaflow",
  password: "",
  database: "Danapac_Database",
};

// Shared MySQL password across clients — not stored per-client, applied unless
// a client explicitly has its own secret saved under integration_config secrets.
const DEFAULT_MYSQL_PASSWORD = "";

// ── Firestore helpers ─────────────────────────────────────────────────────────

async function _getActiveClientId() {
  const doc = await admin.firestore()
    .collection("app_config")
    .doc("active_integration")
    .get();
  if (!doc.exists) throw new Error("No active integration configured");
  return doc.data().clientId;
}

async function _getClientConfig(clientId) {
  const doc = await admin.firestore()
    .collection("integration_config")
    .doc(clientId)
    .get();
  if (!doc.exists) throw new Error(`Integration config not found for client: ${clientId}`);
  return doc.data();
}

async function _getSecret(clientId, type) {
  const doc = await admin.firestore()
    .collection("integration_config")
    .doc(clientId)
    .collection("secrets")
    .doc(type)
    .get();
  return doc.exists ? doc.data() : {};
}

// ── InfluxDB ──────────────────────────────────────────────────────────────────

/**
 * Returns { queryApi, bucket, org } for the given clientId.
 * If clientId is omitted, resolves the active integration from Firestore.
 */
async function getInfluxClient(clientId, req) {
  const id = clientId || (req && req.clientId) || (req && req.headers && req.headers["x-client-id"]);

  // No client tagged on the request — use the default (Danapac) connection
  // rather than whatever is currently set as the active integration.
  if (!id) {
    if (_influxCache.has("__default__")) return _influxCache.get("__default__");
    const client = new InfluxDB({ url: DEFAULT_INFLUX.host, token: DEFAULT_INFLUX.token, timeout: 30000 });
    const result = {
      client,
      queryApi: client.getQueryApi(DEFAULT_INFLUX.org),
      org: DEFAULT_INFLUX.org,
      bucket: DEFAULT_INFLUX.bucket,
    };
    _influxCache.set("__default__", result);
    return result;
  }

  // Cache hit: return immediately instead of re-fetching config/secrets on
  // every request. (Previously this only checked existence and still fell
  // through to rebuild everything every time, making the cache a no-op and
  // adding an extra blocking Firestore read on every single call.)
  if (_influxCache.has(id)) {
    return _influxCache.get(id);
  }

  const config = await _getClientConfig(id);
  const secrets = await _getSecret(id, "influx");

  const influx = config.influx || {};
  const host = influx.host;
  const org = influx.org;
  const bucket = influx.bucketRaw || influx.bucket || "";
  const token = secrets.token || "";

  if (!host) throw new Error(`InfluxDB host not configured for client: ${id}`);
  if (!token) throw new Error(`InfluxDB token not configured for client: ${id}`);

  // Default client timeout is 10s — too tight for slower/remote Influx hosts
  // (e.g. Thong Guan's), where schema.tagValues metadata queries can run
  // past that and abort with "Request timed out". 30s gives them headroom.
  const client = new InfluxDB({ url: host, token, timeout: 30000 });
  const result = { client, queryApi: client.getQueryApi(org), org, bucket };

  _influxCache.set(id, result);
  return result;
}

/**
 * Returns the Influx schema (measurement/tag names) for a client, read from
 * integration_config/{clientId}.influx. Falls back to Danapac defaults so
 * existing deployments keep working.
 *
 * `measurement` is a single fixed name (e.g. "power_meter") for clients whose
 * devices all write to one measurement. A client can instead set it to an
 * empty string on purpose to mean "no single measurement — scan every
 * measurement in the bucket", for a schema like SmartMill's where each
 * equipment type is its own measurement. That's only honoured when the field
 * is present and explicitly empty; a client that never set it at all keeps
 * defaulting to "power_meter" as before.
 */
async function getInfluxSchema(clientId) {
  if (!clientId) {
    return {
      measurement:   DEFAULT_INFLUX.measurement,
      deviceIdTag:   DEFAULT_INFLUX.deviceIdTag,
      deviceTypeTag: null,
      deviceTypeVal: null,
      siteIdTag:     null,
    };
  }
  try {
    const config = await _getClientConfig(clientId);
    const influx = config.influx || {};
    const measurementSet = Object.prototype.hasOwnProperty.call(influx, "measurement");
    return {
      measurement:   measurementSet ? influx.measurement : "power_meter",
      deviceIdTag:   influx.deviceIdTag   || "device_name",
      deviceTypeTag: influx.deviceTypeTag || null,
      deviceTypeVal: influx.deviceTypeVal || null,
      siteIdTag:     influx.siteIdTag     || null,
    };
  } catch (_) {
    return {
      measurement: "power_meter",
      deviceIdTag: "device_name",
      deviceTypeTag: null,
      deviceTypeVal: null,
      siteIdTag: null,
    };
  }
}

function sanitize(str) {
  return String(str || "").replace(/["\\]/g, "");
}

// Build a device filter line for Flux, supporting both device_name and device_id tags.
// deviceId may be a single id, a comma-separated list, or an array — multiple ids are
// OR'd together so callers can scope a query to a fixed set of devices (e.g. summing
// power across specific meters) instead of just one.
function deviceFilter(schema, deviceId) {
  const tag = schema.deviceIdTag;
  const lines = [];
  if (schema.deviceTypeTag && schema.deviceTypeVal) {
    lines.push(`  |> filter(fn: (r) => r["${schema.deviceTypeTag}"] == "${sanitize(schema.deviceTypeVal)}")`);
  }
  const ids = Array.isArray(deviceId)
    ? deviceId.filter(Boolean)
    : String(deviceId || "").split(",").map((s) => s.trim()).filter(Boolean);
  if (ids.length === 1) {
    lines.push(`  |> filter(fn: (r) => r["${tag}"] == "${sanitize(ids[0])}")`);
  } else if (ids.length > 1) {
    const clause = ids.map((id) => `r["${tag}"] == "${sanitize(id)}"`).join(" or ");
    lines.push(`  |> filter(fn: (r) => (${clause}))`);
  }
  return lines.join("\n");
}

// Field names across client schemas that represent cumulative delivered energy ("Edel")
const ENERGY_FIELD_NAMES = ["Edel", "Accum_Energy_Consumption", "Accum_Energy_Consumption_kWh"];

// ── MySQL ─────────────────────────────────────────────────────────────────────

/**
 * Returns a promise-based mysql2 pool for the given clientId + database.
 * The database parameter overrides the database stored in config (because
 * some modules use a different db on the same host).
 * If clientId is omitted, resolves the active integration from Firestore.
 */
async function getMysqlPool(clientId, database, req) {
  const id = clientId || (req && req.clientId) || await _getActiveClientId();
  const cacheKey = `${id}::${database || "__default__"}`;

  // Always verify config exists — evict cache if client was deleted
  if (_mysqlCache.has(cacheKey)) {
    const doc = await admin.firestore().collection("integration_config").doc(id).get();
    if (!doc.exists) {
      for (const key of _mysqlCache.keys()) {
        if (key.startsWith(`${id}::`)) _mysqlCache.delete(key);
      }
      throw new Error(`Integration config not found for client: ${id}`);
    }
  }

  const config = await _getClientConfig(id);
  const secrets = await _getSecret(id, "mysql");

  const mysqlCfg = config.mysql || {};
  // Some client configs store the host with a leading http(s):// and/or a
  // trailing :port (copied from the Influx URL). mysql2 needs a bare hostname,
  // so strip both — the port comes from the separate `port` field below.
  const host = String(mysqlCfg.host || "").replace(/^https?:\/\//, "").replace(/:\d+$/, "");
  const port = parseInt(mysqlCfg.port || "3306", 10);
  const user = mysqlCfg.username;
  const password = secrets.password || DEFAULT_MYSQL_PASSWORD;
  const db = database || mysqlCfg.database;

  if (!host) throw new Error(`MySQL host not configured for client: ${id}`);
  if (!user) throw new Error(`MySQL username not configured for client: ${id}`);

  const pool = mysql.createPool({ host, port, user, password, database: db }).promise();

  _mysqlCache.set(cacheKey, pool);
  return pool;
}

/**
 * Returns the default (Danapac) promise-based mysql2 pool, optionally overriding
 * the database. Cached so repeated calls reuse the same pool.
 */
function getDefaultMysqlPool(database) {
  const cacheKey = `__default__::${database || DEFAULT_MYSQL.database}`;
  if (_mysqlCache.has(cacheKey)) return _mysqlCache.get(cacheKey);

  const pool = mysql.createPool({
    host: DEFAULT_MYSQL.host,
    port: DEFAULT_MYSQL.port,
    user: DEFAULT_MYSQL.user,
    password: DEFAULT_MYSQL.password,
    database: database || DEFAULT_MYSQL.database,
  }).promise();

  _mysqlCache.set(cacheKey, pool);
  return pool;
}

/**
 * Like getMysqlPool, but never throws — falls back to the default (Danapac)
 * pool when no x-client-id is present, or when the client has no MySQL config
 * (or no integration_config at all). Use this for request-driven endpoints that
 * must keep working for clients without MySQL configured.
 */
async function getMysqlPoolSafe(clientId, database, req) {
  const id = clientId || (req && req.clientId) || (req && req.headers && req.headers["x-client-id"]);
  if (!id) return getDefaultMysqlPool(database);

  try {
    return await getMysqlPool(id, database, req);
  } catch (err) {
    console.warn(`[getMysqlPoolSafe] Falling back to default MySQL for client ${id}: ${err.message}`);
    return getDefaultMysqlPool(database);
  }
}

/**
 * Returns custom MySQL table-name overrides for a client, read from
 * integration_config/{clientId}.mysql.tables. Only known keys with safe
 * identifier names are returned; unrecognized/invalid entries are dropped.
 * Returns {} when not configured, so callers can fall back to default tables.
 */
async function getMysqlTables(clientId) {
  if (!clientId) return {};
  try {
    const config = await _getClientConfig(clientId);
    const tables = (config.mysql && config.mysql.tables) || {};
    const valid = {};
    for (const key of ["hourly", "daily", "monthly", "yearly"]) {
      const name = tables[key];
      if (typeof name === "string" && /^[A-Za-z0-9_]+$/.test(name)) {
        valid[key] = name;
      }
    }
    return valid;
  } catch (_) {
    return {};
  }
}

// ── Client-specific Firestore ─────────────────────────────────────────────────
/**
 * Returns a Firestore instance for the given clientId.
 * - If the client has a Firebase service account secret stored → uses their own Firebase project.
 * - Otherwise → falls back to default admin.firestore() (current behavior, no breaking change).
 *
 * Safe to call for all clients — clients without a Firebase secret behave exactly as before.
 */
async function getClientFirestore(clientId) {
  if (!clientId) return admin.firestore();
  const strict = isStrictClient(clientId);

  if (_firestoreCache.has(clientId)) {
    return _firestoreCache.get(clientId);
  }

  try {
    // ── Load from Firestore secrets subcollection ─────────────────────────────
    const secret = await _getSecret(clientId, "firebase");
    const privateKey = secret.privateKey;
    const clientEmail = secret.clientEmail;
    const firestoreProjectId = secret.projectId || clientId;
    if (!privateKey || !clientEmail) {
      if (strict) throw new Error(`No Firestore credentials for strict client ${clientId}`);
      return admin.firestore();
    }
    const serviceAccount = {
      type: "service_account",
      project_id: firestoreProjectId,
      private_key: privateKey.replace(/\\n/g, "\n"),
      client_email: clientEmail,
    };

    const appName = `client_${clientId}`;
    // Always delete existing app so fresh credentials are used
    try { await admin.app(appName).delete(); } catch (_) {}
    const app = admin.initializeApp(
      { credential: admin.credential.cert(serviceAccount) },
      appName,
    );

    const db = app.firestore();
    if (strict) _strictDbs.add(db);
    _firestoreCache.set(clientId, db);
    return db;
  } catch (err) {
    // A strict client never lands on the shared default — the request fails.
    if (strict) throw err;
    // Any error (bad JSON, invalid credentials, etc.) → safe fallback
    console.warn(`[getClientFirestore] Falling back to default for ${clientId}:`, err.message);
    return admin.firestore();
  }
}

// ── Strict clients ────────────────────────────────────────────────────────────
// Clients whose data lives only in their own Firestore. For these nothing
// reads from, merges with, or falls back to the default Firestore: a missing
// document is missing, and a failed write fails instead of landing in the
// shared database another customer also reads. Demo (DEV) is here so it can
// never read or change Thong Guan's records. Kept in code, not in the
// integration config, so re-saving a client record cannot switch it off.
const STRICT_FIRESTORE_CLIENTS = new Set(["DEV"]);

function isStrictClient(clientId) {
  return !!clientId && STRICT_FIRESTORE_CLIENTS.has(String(clientId));
}

// Firestore instances that belong to a strict client, so code holding only a
// db handle (not the request) can still tell it must not reach the default.
const _strictDbs = new WeakSet();

function isStrictDb(db) {
  return !!db && _strictDbs.has(db);
}

// ── Firestore with fallback ───────────────────────────────────────────────────
/**
 * Queries a Firestore collection for a clientId.
 * - Tries client's own Firestore first (if secret configured).
 * - If the result is empty OR any error occurs → falls back to default Firestore.
 * - Ensures data is NEVER missing during transition.
 *
 * @param {string} clientId
 * @param {string} collection  - collection name, e.g. "facilities"
 * @param {function} queryFn   - (collectionRef) => Query  — add your .where() etc here
 * @returns {Promise<FirebaseFirestore.QuerySnapshot>}
 */
async function queryWithFallback(clientId, collection, queryFn) {
  if (isStrictClient(clientId)) {
    const clientDb = await getClientFirestore(clientId);
    const ref = queryFn ? queryFn(clientDb.collection(collection)) : clientDb.collection(collection);
    return ref.get();
  }

  const defaultDb = admin.firestore();

  try {
    const clientDb = await getClientFirestore(clientId);
    const isClientDb = clientDb !== defaultDb;

    if (isClientDb) {
      const clientRef = queryFn ? queryFn(clientDb.collection(collection)) : clientDb.collection(collection);
      const defaultRef = queryFn ? queryFn(defaultDb.collection(collection)) : defaultDb.collection(collection);
      const [clientSnap, defaultSnap] = await Promise.all([clientRef.get(), defaultRef.get()]);

      if (clientSnap.empty) return defaultSnap;
      if (defaultSnap.empty) return clientSnap;

      // Client data isn't always fully migrated yet — merge both sources so
      // partially-migrated collections (e.g. one productionLine created in
      // the client db while the rest still live in default) don't silently
      // hide the documents that haven't been migrated. Client doc wins on id
      // collision since it's the more recently edited/authoritative copy.
      const merged = new Map();
      defaultSnap.docs.forEach((d) => merged.set(d.id, d));
      clientSnap.docs.forEach((d) => merged.set(d.id, d));
      const docs = Array.from(merged.values());
      return {docs, empty: docs.length === 0};
    }
  } catch (err) {
    console.warn(`[queryWithFallback] Error on client db for ${clientId}:`, err.message);
  }

  // Default fallback
  const ref = queryFn ? queryFn(defaultDb.collection(collection)) : defaultDb.collection(collection);
  return ref.get();
}

// ── Write helper with client Firestore fallback ───────────────────────────────
/**
 * Runs `operation(db)` against the client's Firestore (if x-client-id is set
 * and credentials exist), falling back to the default Firestore on any error
 * — or when the operation reports `{ notFound: true }`, since documents
 * created before a client had its own dedicated Firestore project still live
 * in the default Firestore (mirrors queryWithFallback's read-side behaviour).
 * x-client-id is optional — omitting it uses the default Firestore.
 */
async function withDbFallback(req, operation) {
  const clientId = (req && req.headers && req.headers["x-client-id"]) || null;
  if (isStrictClient(clientId)) {
    // No retry on the default: not-found stays not-found, errors stay errors.
    return operation(await getClientFirestore(clientId));
  }
  const defaultDb = admin.firestore();
  const clientDb = await getClientFirestore(clientId);
  const isClientDb = clientDb !== defaultDb;
  console.log(`[withDbFallback] clientId=${clientId} isClientDb=${isClientDb}`);
  try {
    const result = await operation(clientDb);
    if (isClientDb && result && result.notFound) {
      console.log(`[withDbFallback] not found in client db — retrying default`);
      return operation(defaultDb);
    }
    if (isClientDb) console.log(`[withDbFallback] client db write SUCCESS`);
    return result;
  } catch (err) {
    console.warn("[withDbFallback] Client db failed, using default:", err.message);
    return operation(defaultDb);
  }
}

// ── Cache invalidation ────────────────────────────────────────────────────────
// Call this after saving new credentials so stale pools are evicted.

function invalidateCache(clientId) {
  if (clientId) {
    _influxCache.delete(clientId);
    _firestoreCache.delete(clientId);
    for (const key of _mysqlCache.keys()) {
      if (key.startsWith(`${clientId}::`)) _mysqlCache.delete(key);
    }
  } else {
    _influxCache.clear();
    _mysqlCache.clear();
    _firestoreCache.clear();
  }
}

module.exports = {
  getInfluxClient,
  getMysqlPool,
  getMysqlPoolSafe,
  getMysqlTables,
  getClientFirestore,
  isStrictClient,
  isStrictDb,
  queryWithFallback,
  withDbFallback,
  invalidateCache,
  getInfluxSchema,
  sanitize,
  deviceFilter,
  ENERGY_FIELD_NAMES,
};
