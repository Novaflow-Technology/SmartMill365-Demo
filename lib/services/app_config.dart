import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:js_interop';

import 'site_tenant.dart';

/// Singleton that holds the active integration config.
/// Call [AppConfig.init()] once after login.
/// All modules read [AppConfig.apiBase] and [AppConfig.clientId].
class AppConfig {
  AppConfig._();

  static final AppConfig _instance = AppConfig._();
  static AppConfig get instance => _instance;

  // SmartMill's own deployed API (smartmill365-demo project). One function
  // handles both data (Influx/MySQL) and CRUD (users, factory) routes, unlike
  // the SmartFactory app this was forked from, which splits them across ui7
  // and ic7 — both constants point at the same SmartMill URL for that reason.
  static const String _fallbackUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static const String _crudUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

  String _apiBase = _crudUrl;
  String _dataApiBase = _fallbackUrl;
  String _clientId = '';
  String _clientName = '';

  /// Base URL for CRUD operations (users, facilities, equipment) — intech ic7
  static String get apiBase => _instance._apiBase;

  /// True when an active client is configured — guards all data API calls.
  static bool get hasActiveClient => _instance._clientId.isNotEmpty;

  /// Base URL for data queries (InfluxDB/MySQL energy data) — smartmachine ui7
  /// Returns empty string when no client is active, causing all callers to skip requests.
  static String get dataApiBase => hasActiveClient ? _instance._dataApiBase : '';

  /// Always returns a valid ui7 URL regardless of active client.
  /// Use for endpoints that must work even before a client is configured (e.g. plant setting).
  static String get dataApiBaseSafe => _instance._dataApiBase;

  /// Active client ID (Firestore doc ID in integration_config collection).
  static String get clientId => _instance._clientId;

  /// Display name of the active client (from integration config).
  static String get clientName => _instance._clientName;

  /// Whether a client may be listed on the site being viewed. A customer site
  /// lists only its own client; anywhere else every client is listed.
  static bool showsClient(String clientId) {
    final locked = SiteTenant.lockedClientId;
    return locked == null || clientId == locked;
  }

  /// Fixed owner key for config that's shared across every logged-in user of
  /// the same client (billing config, tariff categories, MD Insight Report
  /// image/exclusion config, TNB meters) — used in place of the individual
  /// signed-in user's uid, since those backends key documents by whatever
  /// id is passed in with no auth logic tied to it. Tenant isolation still
  /// comes from x-client-id/getClientFirestore; this only removes the
  /// extra, incorrect per-login split within one client.
  static const String sharedConfigOwnerId = 'shared';

  /// Standard headers to inject on every API request.
  ///
  /// The API answers without a Cache-Control header, so a browser is free to
  /// apply its own heuristics and reuse a stored response without asking. That
  /// is why a normal refresh came back with saved settings missing while a
  /// force refresh showed them: the ordinary reload was reading a copy from
  /// before the save. The API sends an ETag but answers 200 to a conditional
  /// request rather than 304, so this costs a re-fetch — about 27 KB for the
  /// largest of these documents, which is worth paying to never show a stale
  /// configuration.
  static Map<String, String> get headers => {
    'Content-Type': 'application/json',
    'Cache-Control': 'no-cache',
    if (clientId.isNotEmpty) 'x-client-id': clientId,
  };

  /// Loads active clientId and apiBaseUrl from the Functions API.
  /// Safe to call multiple times — subsequent calls refresh the cache.
  static Future<void> init() async {
    // A customer site serves exactly one client, ahead of anything else.
    if (await _applyHostLock()) return;
    // A customer chosen from the switcher outranks everything below it.
    if (await _applySavedOverride()) return;
    try {
      final response = await http
          .get(Uri.parse('$_fallbackUrl/integrationConfig/activeClient'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final clientId = (data['clientId'] as String?) ?? '';
        _instance._clientId = clientId;

        if (clientId.isNotEmpty) {
          // Verify client config exists
          final cfgResponse = await http
              .get(Uri.parse('$_fallbackUrl/integrationConfig/loadConfigs'))
              .timeout(const Duration(seconds: 10));

          if (cfgResponse.statusCode == 200) {
            final List<dynamic> clients = jsonDecode(cfgResponse.body);
            final client = clients.firstWhere(
              (c) => c['id'] == clientId,
              orElse: () => null,
            );
            if (client == null) {
              // clientId in activeClient but config deleted — treat as no active client
              _instance._clientId   = '';
              _instance._clientName = '';
            } else {
              _instance._clientName = (client['clientName'] as String?)
                  ?? (client['name'] as String?)
                  ?? clientId;
            }
          }
        }
      }
    } catch (_) {
      // Keep fallback — app still works even if API is unreachable
    }
  }

  static Future<void> refresh() => init();

  /// Key under which a chosen customer is remembered, per browser.
  static const String _overrideKey = 'sf365.activeClientOverride';

  /// Switches the whole app to another customer.
  ///
  /// One site can serve more than one customer, and someone administering both
  /// needs to move between them without signing out. The choice is remembered
  /// and the page reloaded rather than pushed through every open screen: the
  /// client id is carried on every request and cached in a dozen services, so a
  /// clean boot is the only way to be sure nothing is left over from the
  /// customer just left — which is exactly the mixing this is meant to end.
  static Future<void> switchClient(String clientId, String clientName) async {
    // A customer site serves one client; nothing may move it onto another.
    final locked = SiteTenant.lockedClientId;
    if (locked != null && clientId != locked) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (clientId.isEmpty) {
        await prefs.remove(_overrideKey);
      } else {
        await prefs.setString(_overrideKey, '$clientId|$clientName');
      }
    } catch (_) {
      // Storage unavailable: apply it for this session only.
    }
    _instance._clientId = clientId;
    _instance._clientName = clientName;
    _reloadPage();
  }

  /// Pins the client to the one this site serves. Returns true when the site
  /// is locked, and the caller then resolves nothing further.
  static Future<bool> _applyHostLock() async {
    final locked = SiteTenant.lockedClientId;
    if (locked == null) return false;
    final needsName =
        _instance._clientId != locked || _instance._clientName.isEmpty;
    _instance._clientId = locked;
    if (!needsName) return true;
    _instance._clientName = locked;
    try {
      final res = await http
          .get(Uri.parse('$_fallbackUrl/integrationConfig/loadConfigs'))
          .timeout(const Duration(seconds: 10));
      final list = res.statusCode == 200 ? jsonDecode(res.body) : null;
      if (list is List) {
        for (final c in list.whereType<Map>()) {
          if (c['id'] == locked) {
            _instance._clientName =
                (c['clientName'] ?? c['name'] ?? locked).toString();
          }
        }
      }
    } catch (_) {
      // The id is what isolates the data; the display name can wait.
    }
    return true;
  }

  /// The customer chosen last time, if any. Applied before the account
  /// resolves a client, so a deliberate choice outranks the account — but
  /// never a customer site's own lock.
  ///
  /// The remembered id is only trusted after checking it still exists on
  /// *this* deployment's own backend. A browser that had a client chosen
  /// before this app was pointed at its own API (or before that client was
  /// ever removed) would otherwise keep pinning every request to an id that
  /// no longer means anything here, breaking in a way that looks nothing
  /// like a stale setting — e.g. "No Firestore credentials for strict client
  /// DEV" several screens away from where the override was ever set.
  static Future<bool> _applySavedOverride() async {
    // A choice remembered in this browser never outranks the site's own lock.
    if (SiteTenant.lockedClientId != null) return false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_overrideKey) ?? '';
      if (raw.isEmpty) return false;
      final parts = raw.split('|');
      final id = parts.first.trim();
      if (id.isEmpty) return false;

      final res = await http
          .get(Uri.parse('$_fallbackUrl/integrationConfig/loadConfigs'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final clients = jsonDecode(res.body);
        final stillExists = clients is List && clients.any((c) => c is Map && c['id'] == id);
        if (!stillExists) {
          await prefs.remove(_overrideKey);
          return false;
        }
      }
      // Couldn't check (offline/timeout) — keep the override rather than
      // discard a possibly-valid choice on a flaky connection.

      _instance._clientId = id;
      _instance._clientName = parts.length > 1 ? parts[1] : id;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Every customer this build knows about, for the switcher.
  static Future<List<Map<String, String>>> availableClients() async {
    // On a customer site the only customer on offer is that site's own, so
    // the switcher has nothing to switch to and hides itself.
    final locked = SiteTenant.lockedClientId;
    try {
      final res = await http
          .get(Uri.parse('$_fallbackUrl/integrationConfig/loadConfigs'))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return const [];
      final list = jsonDecode(res.body);
      if (list is! List) return const [];
      return list
          .whereType<Map>()
          .map((c) => {
                'id': c['id']?.toString() ?? '',
                'name': (c['clientName'] ?? c['name'] ?? c['id'] ?? '')
                    .toString(),
              })
          .where((c) => (c['id'] ?? '').isNotEmpty)
          .where((c) => locked == null || c['id'] == locked)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Called after login — resolves clientId from user's assigned factory (customer_id).
  /// Falls back to domain match, then active_integration.
  static Future<void> initForUser(String email, {String uid = ''}) async {
    // The site decides the client before the account gets a say: the demo
    // login is assigned to Thong Guan's factory, and resolving from it is what
    // put demo on Thong Guan's data.
    if (await _applyHostLock()) return;
    if (await _applySavedOverride()) return;
    try {
      // Load all clients first
      final cfgResponse = await http
          .get(Uri.parse('$_fallbackUrl/integrationConfig/loadConfigs'))
          .timeout(const Duration(seconds: 10));

      final List<dynamic> clients = cfgResponse.statusCode == 200
          ? jsonDecode(cfgResponse.body)
          : [];

      // 0. The site the browser is on wins, when a client claims it.
      //
      // Two customers can be served from two hostnames off one deployment, and
      // then which customer you are is a property of the site, not of the
      // account that happens to be signing in. Resolving from the account is
      // what made demo.* and thongguan.* behave as one tenant: the demo login
      // is itself assigned to Thong Guan, so both sites came up as Thong Guan
      // and shared a user list.
      //
      // Driven entirely by the `siteHost` (or `domain`) field on the client
      // record, so this does nothing until someone fills it in — and never
      // needs a hostname written into the app.
      final host = Uri.base.host.toLowerCase();
      if (host.isNotEmpty && clients.isNotEmpty) {
        final byHost = clients.cast<Map<String, dynamic>>().firstWhere(
          (c) {
            final claimed = ((c['siteHost'] ?? c['domain'] ?? '') as String)
                .toLowerCase()
                .trim();
            return claimed.isNotEmpty && claimed == host;
          },
          orElse: () => <String, dynamic>{},
        );
        if (byHost.isNotEmpty) {
          _instance._clientId = byHost['id'] as String;
          _instance._clientName = (byHost['clientName'] as String?) ??
              (byHost['name'] as String?) ??
              _instance._clientId;
          return;
        }
      }

      // 1. Match by user's factory_id → the factory's own `customer_id`
      //    field (assigned via General Factory Setting → Plant → "Client"
      //    dropdown, plant_setting_widget.dart). That dropdown already
      //    writes the real integration_config client ID straight onto the
      //    factory record (PUT /factory/:id { customer_id }) — it's the
      //    authoritative source, so resolve through it directly instead of
      //    re-deriving membership from a separately-maintained list.
      if (uid.isNotEmpty) {
        try {
          final usersRes = await http
              .get(Uri.parse('$_crudUrl/users'))
              .timeout(const Duration(seconds: 8));
          if (usersRes.statusCode == 200) {
            final users = jsonDecode(usersRes.body) as List<dynamic>;
            final user = users.cast<Map<String, dynamic>>().firstWhere(
              (u) => u['UID'] == uid,
              orElse: () => <String, dynamic>{},
            );
            final factoryId = (user['factory_id'] as String?) ?? '';
            if (factoryId.isNotEmpty) {
              String? resolvedClientId;
              try {
                final factoriesRes = await http
                    .get(Uri.parse('$_crudUrl/factory'))
                    .timeout(const Duration(seconds: 8));
                if (factoriesRes.statusCode == 200) {
                  final factories = jsonDecode(factoriesRes.body) as List<dynamic>;
                  final factory = factories.cast<Map<String, dynamic>>().firstWhere(
                    (f) => f['id']?.toString() == factoryId,
                    orElse: () => <String, dynamic>{},
                  );
                  final customerId = factory['customer_id']?.toString() ?? '';
                  // Only a real client id counts. A truncated value ('thongg')
                  // used to block the factory-id match below, so the account
                  // fell through to whichever client happened to be active.
                  if (customerId.isNotEmpty &&
                      clients.any((c) => c['id'] == customerId)) {
                    resolvedClientId = customerId;
                  }
                }
              } catch (_) {}

              // Legacy fallback: exact factoryId == clientId match, in case
              // the factory has no customer_id assigned yet.
              resolvedClientId ??= clients.cast<Map<String, dynamic>>().firstWhere(
                (c) => c['id'] == factoryId,
                orElse: () => <String, dynamic>{},
              )['id'] as String?;

              final matched = resolvedClientId == null
                  ? <String, dynamic>{}
                  : clients.cast<Map<String, dynamic>>().firstWhere(
                      (c) => c['id'] == resolvedClientId,
                      orElse: () => <String, dynamic>{},
                    );

              if (matched.isNotEmpty) {
                _instance._clientId   = matched['id'] as String;
                _instance._clientName = (matched['clientName'] as String?)
                    ?? (matched['name'] as String?)
                    ?? _instance._clientId;
                return;
              }
            }
          }
        } catch (_) {}
      }

      // 2. Fallback: match by email domain
      if (clients.isNotEmpty) {
        final domain = email.contains('@') ? email.split('@').last.toLowerCase() : '';
        final matched = clients.cast<Map<String, dynamic>>().firstWhere(
          (c) {
            final clientDomain = ((c['domain'] as String?) ?? '').toLowerCase();
            if (clientDomain.isEmpty || domain.isEmpty) return false;
            // Exact, not contains. A client registered as "009.sf365.com" used
            // to match every address at sf365.com, so adding one client took
            // over the sign-in of users belonging to another — every screen
            // then asked the API for a tenant those users are not in and came
            // back empty. A client's domain now has to be exactly the
            // address's domain to claim it — a subdomain is a different
            // tenant, which is the whole point of registering one.
            return clientDomain == domain;
          },
          orElse: () => <String, dynamic>{},
        );

        if (matched.isNotEmpty) {
          _instance._clientId   = matched['id'] as String;
          _instance._clientName = (matched['clientName'] as String?)
              ?? (matched['name'] as String?)
              ?? _instance._clientId;
          final url = (matched['firebase']?['apiBaseUrl'] as String?) ?? '';
          if (url.isNotEmpty) {
            _instance._dataApiBase = url.endsWith('/') ? url.substring(0, url.length - 1) : url;
          }
          return;
        }
      }
    } catch (_) {}

    // Fallback: use active_integration
    await init();
  }
}

@JS('window.location.reload')
external void _reloadPageRaw();

/// Reloads so every cached client-scoped value is rebuilt from scratch.
void _reloadPage() {
  try {
    _reloadPageRaw();
  } catch (_) {
    // Nothing else to try; the switch still applies to this session.
  }
}
