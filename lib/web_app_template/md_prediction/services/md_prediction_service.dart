import 'package:flutter/foundation.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/flutter_flow/nav/nav.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/energy_system_settings/energy_system_setting_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/web_app_template/md_prediction/services/md_api_orchestrator.dart';

// ---------------------------------------------------------------------------
// Result types
// ---------------------------------------------------------------------------

class LivePowerResult {
  final double powerKw;
  final DateTime timestamp;
  const LivePowerResult({required this.powerKw, required this.timestamp});
}

class IntervalDataResult {
  final List<double> readings;
  final List<String> labels;
  const IntervalDataResult({required this.readings, required this.labels});
}

class ActiveEquipmentData {
  final String meterId;
  final String meterName;
  final String impactCategory;
  final String plant;
  final String factory;
  /// Human-readable spec string shown under the machine name (e.g. "175 RT", "100 hp")
  final String specs;
  final double currentKw;
  final DateTime? fetchedAt;
  /// When the machine was first detected as running (kW > 0) this session.
  final DateTime? runningSince;

  const ActiveEquipmentData({
    required this.meterId,
    required this.meterName,
    required this.impactCategory,
    required this.plant,
    required this.factory,
    this.specs = '',
    this.currentKw = 0.0,
    this.fetchedAt,
    this.runningSince,
  });
}

// ---------------------------------------------------------------------------
// MD Prediction Service
// ---------------------------------------------------------------------------

/// Encapsulates all remote data access for the MD Prediction module.
/// All methods are static so the page/controller can call them without
/// holding a service instance.
class MdPredictionService {
  MdPredictionService._();

  static const String _baseEnergy =
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

  // ── Device list ───────────────────────────────────────────────────────

  /// Fetches the active client's real device list from InfluxDB.
  ///
  /// Returns an empty list when the request fails or comes back empty. There
  /// is deliberately no stand-in list: showing another client's device names
  /// here made a broken device list look like a working one, which hid the
  /// underlying data problem instead of surfacing it.
  static Future<List<String>> fetchAvailableDevices() async {
    try {
      final res = await http
          .get(Uri.parse('$_baseEnergy/energyDetailsInfluxDb/devices'),
              headers: AppConfig.headers)
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        if (decoded is List) {
          final ids = decoded
              .map((d) => (d is Map ? d['device_id'] : null)?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toList();
          if (ids.isNotEmpty) return ids;
        }
      }
    } catch (e) {
      debugPrint('[MdPrediction] device list fetch failed: $e');
    }
    return const [];
  }

  // ── Contract capacity ──────────────────────────────────────────────────

  /// Loads the contract capacity (kW) from the user's energy system settings.
  /// Returns 0.0 if the setting is missing or the request fails.
  static Future<double> fetchContractCapacity() async {
    final uid = AppStateNotifier.instance.uid ?? '';
    try {
      final response = await EnergySystemSettingsService.getSettings(uid);
      if (response['exists'] == true && response['settings'] != null) {
        final cc = response['settings']['contractCapacity'];
        if (cc != null) {
          return (cc['contractCapacity'] ?? 0.0).toDouble();
        }
      }
    } catch (_) {
      // Non-fatal — caller will fall back to a safe default.
    }
    return 0.0;
  }

  // ── Current live power ─────────────────────────────────────────────────

  /// Fetches the latest live power reading in kW.
  /// Returns null if the request fails.
  static Future<LivePowerResult?> fetchCurrentPower(String deviceId) async {
    try {
      final res = await http.get(Uri.parse(
          '$_baseEnergy/energyDetailsInfluxDb/power-load/current?deviceId=${Uri.encodeComponent(deviceId)}'), headers: AppConfig.headers);
      if (res.statusCode == 200) {
        final decoded = json.decode(res.body);
        double kw = 0.0;
        if (decoded is Map) {
          // Flat map response: { power_kw: 123, ... }
          kw = _extractPowerKw(decoded);
        } else {
          // List / wrapped response — try first item
          final list = _toList(decoded);
          if (list.isNotEmpty) kw = _extractPowerKw(list.first);
        }
        if (kw > 0) {
          return LivePowerResult(powerKw: kw, timestamp: DateTime.now());
        }
      }
    } catch (_) {}
    return null;
  }

  // ── Current 30-min MD interval readings ───────────────────────────────

  /// Fetches the 24-hour power-load history for [deviceId] and slices out
  /// the most recent 30 data points (≈ 30-minute MD interval).
  ///
  /// Throws a [MdPredictionServiceException] with a human-readable message
  /// on HTTP error.
  static Future<IntervalDataResult> fetchIntervalData(String deviceId) async {
    final res = await http.get(Uri.parse(
        '$_baseEnergy/energyDetails/power-load-24h/$deviceId'), headers: AppConfig.headers);

    if (res.statusCode != 200) {
      throw MdPredictionServiceException(
          'Failed to load interval data (${res.statusCode})');
    }

    final decoded = json.decode(res.body);
    final List<dynamic> raw;
    if (decoded is Map) {
      raw = (decoded['data'] as List<dynamic>? ?? []);
    } else {
      raw = _toList(decoded);
    }
    final slice = raw.length > 30 ? raw.sublist(raw.length - 30) : raw;

    return IntervalDataResult(
      readings: slice.map<double>(_extractPowerKw).toList(),
      labels: slice
          .map<String>((e) => (e['time_label'] ?? '').toString())
          .toList(),
    );
  }

  // ── Active equipment list ──────────────────────────────────────────────────

  /// Phase 1 — fast: loads facility metadata from Firestore only (no API calls).
  /// Returns immediately with kw = 0 for every device so the UI can render the
  /// list before any power readings are fetched.
  static Future<List<ActiveEquipmentData>> fetchActiveEquipmentMeta() async {
    try {
      final facilities = await FacilityService.getFacilities();
      final active = facilities.where((f) => f.status == 'Active').toList();
      final results = active.map((f) {
        // Build the specs string from productionArea + equipmentType
        // e.g. "175 RT" or "100 hp · Utility"
        final parts = [
          if (f.productionArea.isNotEmpty) f.productionArea,
          if (f.equipmentType.isNotEmpty && f.equipmentType != f.productionArea)
            f.equipmentType,
        ];
        return ActiveEquipmentData(
          meterId:        f.meterId,
          meterName:      f.meterName.isNotEmpty ? f.meterName : f.meterId,
          impactCategory: f.impactCategory,
          plant:          f.plant,
          factory:        f.factory,
          specs:          parts.join(' · '),
          currentKw:      0.0,
          fetchedAt:      null,
          runningSince:   null,
        );
      }).toList();
      results.sort((a, b) {
        const order = ['ADJUSTABLE', 'PRODUCTION', 'AUXILIARY', 'BACKUP'];
        return order.indexOf(a.impactCategory)
            .compareTo(order.indexOf(b.impactCategory));
      });
      return results;
    } catch (_) {
      return [];
    }
  }

  /// Phase 2 — streaming: resolves kW for each device one-by-one through the
  /// throttled queue and calls [onUpdate] after every resolved device so the UI
  /// can incrementally update without waiting for the full batch.
  static Future<void> streamEquipmentKw(
    List<ActiveEquipmentData> devices,
    void Function(int index, double kw) onUpdate,
  ) async {
    // Sequential — one device at a time to prevent overwhelming the
    // Cloud Function and triggering 500 errors.
    for (int i = 0; i < devices.length; i++) {
      final kw = await _fetchRealtimeKw(devices[i].meterId);
      onUpdate(i, kw);
      // Small gap between requests for server stability.
      if (i < devices.length - 1) {
        await Future.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  /// Fetches current live power (kW) for a single device.
  ///
  /// Each field is requested **individually** to avoid InfluxDB's
  /// "schema: group collision" error that occurs when a multi-field query
  /// mixes integer and float measurement types in the same result set.
  ///
  /// Priority order:
  ///   1. `P(kW)`   — kilowatts directly
  ///   2. `P(W)`    — watts, divided by 1000
  ///   3. 24h history endpoint — last recorded interval value
  static Future<double> _fetchRealtimeKw(String deviceId) async {
    // Field name priority list — ordered from most to least specific.
    // Each field is requested individually (single-field) to bypass the
    // InfluxDB "schema: group collision" error that occurs when mixing
    // int and float measurements in the same multi-field query result.
    const kwFields  = ['P_kW', 'P(kW)', 'power_kw', 'power_kW', 'kW'];
    const wattFields = ['P_W', 'P(W)', 'power_w', 'power_W'];

    // Use the /discoveryDevice/ base (matches the confirmed working endpoint
    // used by InfluxDiscoveryService across the rest of the app).
    const _baseDiscovery = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/discoveryDevice';

    // 1. Try each kW field — first non-null positive value wins.
    for (final field in kwFields) {
      final v = await _fetchSingleField(_baseDiscovery, deviceId, field);
      if (v != null && v > 0) return v > 50000 ? v / 1000.0 : v;
    }

    // 2. Try watt fields — convert to kW.
    for (final field in wattFields) {
      final v = await _fetchSingleField(_baseDiscovery, deviceId, field);
      if (v != null && v > 0) return v / 1000.0;
    }

    // 3. Fallback: last point from history endpoint with a wider window.
    final hist = await MdApiOrchestrator.fetch(
      '$_baseDiscovery/history/$deviceId?field=P_kW&start=-15m&window=1m',
      timeout: const Duration(seconds: 10),
    );
    if (hist != null) {
      final body = hist is Map ? hist : <String, dynamic>{};
      final data = body['data'] as List<dynamic>? ?? [];
      if (data.isNotEmpty) {
        final raw = data.last['value'];
        final v = raw is num ? raw.toDouble() : double.tryParse(raw.toString()) ?? 0.0;
        if (v > 0) return v > 50000 ? v / 1000.0 : v;
      }
    }

    return 0.0;
  }

  /// Fetches a single field from the /discoveryDevice/realtime or /history
  /// endpoint.  Returns null on any error or empty response.
  static Future<double?> _fetchSingleField(
    String baseUrl, String deviceId, String field) async {
    // Try realtime first (fastest — only last few minutes)
    final rtUrl = '$baseUrl/realtime/$deviceId?fields=${Uri.encodeComponent(field)}';
    final rtBody = await MdApiOrchestrator.fetch(rtUrl, timeout: const Duration(seconds: 8));
    if (rtBody != null) {
      final list = rtBody is List ? rtBody : (rtBody is Map ? (rtBody['data'] ?? []) : []);
      if (list is List && list.isNotEmpty) {
        for (final item in list) {
          if (item is! Map) continue;
          final f = (item['field'] ?? item['Field'] ?? '').toString();
          if (f == field || f.isEmpty) {
            final v = item['value'] ?? item['Value'];
            if (v != null) {
              final d = v is num ? v.toDouble() : double.tryParse(v.toString());
              if (d != null && d > 0) return d;
            }
          }
        }
      }
    }

    // Fallback: history with -15m window (wider than realtime's default -5m)
    final histUrl = '$baseUrl/history/$deviceId?field=${Uri.encodeComponent(field)}&start=-15m&window=1m';
    final histBody = await MdApiOrchestrator.fetch(histUrl, timeout: const Duration(seconds: 8));
    if (histBody != null && histBody is Map) {
      final data = histBody['data'] as List<dynamic>? ?? [];
      if (data.isNotEmpty) {
        final raw = data.last['value'];
        final d = raw is num ? raw.toDouble() : double.tryParse(raw.toString() ?? '');
        if (d != null && d > 0) return d;
      }
    }
    return null;
  }

  /// Normalises an API response body into a flat List regardless of whether
  /// the server returned a plain array, a Map wrapper, or a stringified JSON.
  static List<dynamic> _toList(dynamic body) {
    dynamic decoded = body;
    // Double-encoded: server wraps the JSON in a string
    if (decoded is String) {
      try { decoded = json.decode(decoded); } catch (_) { return []; }
    }
    if (decoded is List) return decoded;
    if (decoded is Map) {
      final inner = decoded['value'] ?? decoded['data'] ?? decoded['items'];
      if (inner is List) return inner;
    }
    return [];
  }

  /// Robust double parsing: handles num, int, double, and string values.
  static double _parseDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is num)  return v.toDouble();
    return double.tryParse(v.toString()) ?? 0.0;
  }

  /// Tries multiple field names in priority order and handles W→kW conversion.
  /// Uses robust string-safe parsing — the API sometimes returns numeric
  /// values as JSON strings (e.g. `"25.4"`).
  static double _extractPowerKw(dynamic e) {
    if (e is! Map) return 0.0;
    const keys = [
      'max_demand_kW', 'maxDemandKW', 'MaxDemandKW',
      'power_kw', 'power_kW', 'P_kW', 'P(kW)',
      'kW', 'kw', 'power',
    ];
    for (final key in keys) {
      final raw = e[key];
      if (raw == null) continue;
      final v = _parseDouble(raw);
      if (v > 0) {
        // Heuristic: real-world MD rarely exceeds 50 MW; if value > 50 000
        // the unit is almost certainly Watts — convert to kW.
        return v > 50000 ? v / 1000.0 : v;
      }
    }
    return 0.0;
  }
}

// ---------------------------------------------------------------------------
// Exception
// ---------------------------------------------------------------------------

class MdPredictionServiceException implements Exception {
  final String message;
  const MdPredictionServiceException(this.message);

  @override
  String toString() => message;
}
