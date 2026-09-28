import 'package:smartmachine365/services/app_config.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/discovery_models.dart';

/// Discovery service — proxies InfluxDB via discoverydevice.js API.
/// Measurement and tags are whatever the active client's integration config
/// says (one fixed measurement, or every measurement in the bucket for a
/// client like SmartMill that doesn't have a single one) — never fixed here.
class InfluxDiscoveryService {
  static String get _apiBase => '${AppConfig.dataApiBase}/discoveryDevice';

  // ── Discovery ──────────────────────────────────────────────────────────────

  /// Set after every [discoverAllDevices] call — null on success (even a
  /// genuinely empty one), or the real reason nothing could be fetched, so
  /// the UI can tell "SmartMill has no devices" apart from "couldn't reach
  /// SmartMill's API" instead of showing the same "No devices found" either way.
  String? lastError;

  Future<List<DiscoveredDevice>> discoverAllDevices({String start = '-24h'}) async {
    lastError = null;
    // The very first call after a cold boot can race AppConfig's own init —
    // make sure the client id is resolved before asking for its devices,
    // instead of silently sending an unscoped request that comes back empty.
    if (AppConfig.clientId.isEmpty) await AppConfig.init();
    if (AppConfig.clientId.isEmpty) {
      lastError = 'No active client resolved for this session — the app never got past AppConfig.init().';
      return [];
    }

    // Fetch enriched device list (InfluxDB + MySQL if configured) and fields in parallel.
    // Fallback: if enriched endpoint fails, fall back to InfluxDB-only meta — data is never lost.
    List<Map<String, dynamic>> enrichedList = [];
    try {
      enrichedList = await _getEnriched(start: start);
    } catch (e) {
      // Enriched failed — fall back to plain meta, but remember why in case
      // that fails too.
      lastError = 'enriched: $e';
      enrichedList = [];
    }

    // If enriched returned nothing, fall back to InfluxDB meta
    if (enrichedList.isEmpty) {
      List<String> deviceIds = [];
      Map<String, Map<String, dynamic>> metaMap = {};
      try {
        final results = await Future.wait([
          _getDevices(start: start),
          _getMeta(start: start),
        ]);
        deviceIds = results[0] as List<String>;
        metaMap   = results[1] as Map<String, Map<String, dynamic>>;
      } catch (e) {
        lastError = '${lastError != null ? '$lastError; ' : ''}devices: $e';
      }
      if (deviceIds.isEmpty) return [];
      final fieldResults = await Future.wait(
        deviceIds.map((id) => _getFields(id, start: start)),
      );
      final seen = <String, DiscoveredDevice>{};
      for (int i = 0; i < deviceIds.length; i++) {
        final id   = deviceIds[i];
        final meta = metaMap[id] ?? {};
        seen[id] = DiscoveredDevice(
          deviceId:    id,
          deviceName:  meta['device_name'] as String? ?? id,
          displayName: meta['device_name'] as String? ?? id,
          deviceType:  null,
          plantId:     meta['site_id'] as String? ?? '',
          zoneId:      '',
          plantName:   meta['site_id'] as String? ?? '',
          zoneName:    '',
          tags:        fieldResults[i],
        );
      }
      return seen.values.toList();
    }

    // Enriched succeeded — fetch fields for all devices in parallel
    final deviceIds = enrichedList.map((e) => e['device_id'] as String).toList();
    final fieldResults = await Future.wait(
      deviceIds.map((id) => _getFields(id, start: start)),
    );

    final seen = <String, DiscoveredDevice>{};
    for (int i = 0; i < enrichedList.length; i++) {
      final e  = enrichedList[i];
      final id = e['device_id'] as String? ?? '';
      if (id.isEmpty) continue;
      seen[id] = DiscoveredDevice(
        deviceId:    id,
        deviceName:  e['device_name'] as String? ?? id,
        displayName: e['device_name'] as String? ?? id,
        deviceType:  null,
        plantId:     e['site_id']   as String? ?? '',
        zoneId:      e['zone_id']   as String? ?? '',
        plantName:   e['site_name'] as String? ?? e['site_id'] as String? ?? '',
        zoneName:    e['zone_name'] as String? ?? '',
        tags:        fieldResults[i],
        siteId:      e['site_id']    as String? ?? '',
        machineId:   e['machine_id'] as String? ?? '',
        machineName: e['machine_name'] as String? ?? '',
        lineId:      e['line_id']    as String? ?? '',
        lineName:    e['line_name']  as String? ?? '',
        parentId:    e['parent_id']  as String? ?? '',
        parentName:  e['parent_name'] as String? ?? '',
      );
    }
    return seen.values.toList();
  }

  Future<DiscoveredDevice?> refreshSingleDevice(String deviceId) async {
    try {
      final results = await Future.wait([
        _getMeta(start: '-7d'),
        _getFields(deviceId, start: '-7d'),
      ]);
      final metaMap = results[0] as Map<String, Map<String, dynamic>>;
      final tags    = results[1] as List<InfluxTag>;
      final meta    = metaMap[deviceId] ?? {};
      return DiscoveredDevice(
        deviceId:    deviceId,
        deviceName:  meta['device_name'] as String? ?? deviceId,
        displayName: meta['device_name'] as String? ?? deviceId,
        deviceType:  null,
        plantId:     meta['site_id'] as String? ?? '',
        zoneId:      '',
        plantName:   meta['site_id'] as String? ?? '',
        zoneName:    '',
        tags:        tags,
        isApproved:  true,
      );
    } catch (_) {
      return null;
    }
  }

  // ── Realtime values ────────────────────────────────────────────────────────

  /// Latest value for every tag, keyed "<deviceId>.<realMeasurement>.<field>"
  /// — the measurement is part of the key because SmartMill (and any other
  /// client scanning every measurement) can have the same field name under
  /// several real measurements for one device; keying on field name alone
  /// would make those overwrite each other and show as identical values.
  Future<Map<String, dynamic>> getBatchRealtimeValues(List<InfluxTag> tags) async {
    if (tags.isEmpty) return {};

    final grouped = <String, List<InfluxTag>>{};
    for (final t in tags) {
      grouped.putIfAbsent(t.measurement, () => []).add(t); // t.measurement = device id here
    }

    final result = <String, dynamic>{};
    await Future.wait(grouped.entries.map((entry) async {
      final deviceId = entry.key;
      final values = await _getRealtime(deviceId, entry.value);
      result.addAll(values);
    }));
    return result;
  }

  // ── Field history ──────────────────────────────────────────────────────────

  Future<List<HistoryPoint>> fetchFieldHistory(
      String deviceId, String fieldName,
      {String range = '-1h', String? realMeasurement}) async {
    try {
      final uri = Uri.parse('$_apiBase/history/$deviceId').replace(
        queryParameters: {
          'field':  fieldName,
          'start':  range,
          'window': '1m',
          if (realMeasurement != null && realMeasurement.isNotEmpty) 'measurement': realMeasurement,
        },
      );
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return [];
      final body = json.decode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      return data.map((item) {
        final t = DateTime.tryParse(item['time'] as String? ?? '');
        final v = (item['value'] as num?)?.toDouble();
        if (t == null || v == null) return null;
        return HistoryPoint(t, v);
      }).whereType<HistoryPoint>().toList();
    } catch (_) {
      return [];
    }
  }

  // ── Private API calls ──────────────────────────────────────────────────────

  // These three throw on failure rather than swallowing it — discoverAllDevices
  // needs to tell a request that genuinely failed apart from one that
  // succeeded and truly found nothing, and a caller further down the fallback
  // chain (refreshSingleDevice) already wraps its own call in try/catch.

  Future<List<Map<String, dynamic>>> _getEnriched({required String start}) async {
    final uri = Uri.parse('$_apiBase/enriched')
        .replace(queryParameters: {'start': start});
    final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}: ${res.body}');
    final data = json.decode(res.body) as List<dynamic>;
    return data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  Future<List<String>> _getDevices({required String start}) async {
    final uri = Uri.parse('$_apiBase/devices')
        .replace(queryParameters: {'start': start});
    final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}: ${res.body}');
    final data = json.decode(res.body) as List<dynamic>;
    return data
        .map((e) => (e as Map<String, dynamic>)['device_id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
  }

  Future<Map<String, Map<String, dynamic>>> _getMeta({required String start}) async {
    final uri = Uri.parse('$_apiBase/meta')
        .replace(queryParameters: {'start': start});
    final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 30));
    if (res.statusCode != 200) throw Exception('HTTP ${res.statusCode}: ${res.body}');
    final data = json.decode(res.body) as List<dynamic>;
    return {
      for (final item in data)
        if ((item as Map<String, dynamic>)['device_id'] is String &&
            (item['device_id'] as String).isNotEmpty)
          item['device_id'] as String: item,
    };
  }

  /// Fields SmartMill's (or any client's) own database actually reports for
  /// this device. Empty on failure or when nothing is found — never a
  /// guessed field list, which would show values that were never real.
  Future<List<InfluxTag>> _getFields(String deviceId, {required String start}) async {
    try {
      final uri = Uri.parse('$_apiBase/fields/$deviceId')
          .replace(queryParameters: {'start': start});
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return const [];
      final body   = json.decode(res.body) as Map<String, dynamic>;
      final fields = body['fields'] as List<dynamic>? ?? [];
      return fields.map((f) {
        final field = f['field'] as String? ?? '';
        if (field.isEmpty) return null;
        return InfluxTag(
          measurement: deviceId, // used as group key in getBatchRealtimeValues
          fieldName:   field,
          tagName:     field,
          realMeasurement: (f['measurement'] as String?) ?? '',
        );
      }).whereType<InfluxTag>().toList();
    } catch (_) {
      return const [];
    }
  }

  Future<Map<String, dynamic>> _getRealtime(String deviceId, List<InfluxTag> tags) async {
    final fieldNames = tags.map((t) => t.fieldName).toSet().join(',');
    try {
      final params = <String, String>{};
      if (fieldNames.isNotEmpty) params['fields'] = fieldNames;
      final uri = Uri.parse('$_apiBase/realtime/$deviceId')
          .replace(queryParameters: params.isNotEmpty ? params : null);
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final data   = json.decode(res.body) as List<dynamic>;
        final result = <String, dynamic>{};
        for (final item in data) {
          final field = item['field'] as String?;
          final measurement = (item['measurement'] as String?) ?? '';
          final value = item['value'];
          if (field != null && field.isNotEmpty) {
            result['$deviceId.$measurement.$field'] = value?.toString() ?? '';
          }
        }
        // If realtime returned data, use it
        if (result.isNotEmpty) return result;
      }
    } catch (_) {}

    // Fallback: /realtime is hardcoded to -5m on the deployed API.
    // Use /history with a wider window to get the most recent values.
    return _getRealtimeViaHistory(deviceId, tags);
  }

  Future<Map<String, dynamic>> _getRealtimeViaHistory(String deviceId, List<InfluxTag> tags) async {
    // No tags to fetch means no fields were discovered for this device —
    // there's nothing real to guess at, so this returns empty rather than a
    // fixed list of field names that belong to a different client's schema.
    if (tags.isEmpty) return {};

    // Fetch in batches of 5 to avoid hammering the API.
    final result = <String, dynamic>{};
    for (int i = 0; i < tags.length; i += 5) {
      final batch = tags.skip(i).take(5).toList();
      final values = await Future.wait(
        batch.map((t) => _getLatestViaHistory(deviceId, t)),
      );
      for (int j = 0; j < batch.length; j++) {
        if (values[j] != null) {
          result['$deviceId.${batch[j].realMeasurement}.${batch[j].fieldName}'] = values[j];
        }
      }
    }
    return result;
  }

  Future<dynamic> _getLatestViaHistory(String deviceId, InfluxTag tag) async {
    try {
      final uri = Uri.parse('$_apiBase/history/$deviceId').replace(
        queryParameters: {
          'field':  tag.fieldName,
          'start':  '-30m',
          'window': '1m',
          if (tag.realMeasurement.isNotEmpty) 'measurement': tag.realMeasurement,
        },
      );
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (res.statusCode != 200) return null;
      final body = json.decode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      if (data.isEmpty) return null;
      return data.last['value'];
    } catch (_) {
      return null;
    }
  }

}

class HistoryPoint {
  final DateTime time;
  final double value;
  const HistoryPoint(this.time, this.value);
}
