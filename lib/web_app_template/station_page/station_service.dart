import 'dart:convert';

import 'package:http/http.dart' as http;

import '/services/app_config.dart';
import 'station_models.dart';

/// A field a device reports, as offered when mapping a point.
class DeviceField {
  const DeviceField(this.measurement, this.field);
  final String measurement;
  final String field;
  String get label => measurement.isEmpty ? field : '$measurement · $field';
}

/// One point of the history chart.
class TrendPoint {
  const TrendPoint(this.time, this.value);
  final DateTime time;
  final double value;
}

/// API calls behind the station pages and their settings.
class StationService {
  static String get _base => AppConfig.dataApiBaseSafe;
  static Map<String, String> get _headers => AppConfig.headers;

  /// Equipment whose category belongs to [station], in name order.
  static Future<List<Map<String, dynamic>>> equipmentFor(StationDef station) async {
    final res = await http
        .get(Uri.parse('$_base/equipment'), headers: _headers)
        .timeout(const Duration(seconds: 20));
    if (res.statusCode != 200) return [];
    final list = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    final mine = list.where(station.matches).toList()
      ..sort((a, b) => _natural(a['name']?.toString() ?? '', b['name']?.toString() ?? ''));
    return mine;
  }

  /// "Digester 2" before "Digester 10".
  static int _natural(String a, String b) {
    final re = RegExp(r'(\d+)|(\D+)');
    final pa = re.allMatches(a.toLowerCase()).map((m) => m[0]!).toList();
    final pb = re.allMatches(b.toLowerCase()).map((m) => m[0]!).toList();
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
      final c = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
      if (c != 0) return c;
    }
    return pa.length.compareTo(pb.length);
  }

  static Future<StationSettings> loadSettings(StationDef station) async {
    try {
      final res = await http
          .get(Uri.parse('$_base/station-page-settings/${station.key}'), headers: _headers)
          .timeout(const Duration(seconds: 15));
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        return StationSettings.fromJson(station, body['settings'] as Map<String, dynamic>?);
      }
    } catch (_) {}
    return StationSettings.defaults(station);
  }

  static Future<bool> saveSettings(StationDef station, StationSettings s) async {
    try {
      final res = await http
          .post(
            Uri.parse('$_base/station-page-settings/${station.key}'),
            headers: _headers,
            body: jsonEncode(s.toJson()),
          )
          .timeout(const Duration(seconds: 15));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Every live device this client has.
  static Future<List<String>> devices() async {
    try {
      final res = await http
          .get(Uri.parse('$_base/discoveryDevice/enriched?start=-24h'), headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return [];
      final j = jsonDecode(res.body);
      final list = j is List ? j : (j['devices'] ?? j['data'] ?? []) as List;
      final ids = list
          .map((d) => (d is Map ? (d['device_id'] ?? d['deviceId'] ?? d['id']) : null)?.toString() ?? '')
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
      return ids;
    } catch (_) {
      return [];
    }
  }

  static final Map<String, List<DeviceField>> _fieldCache = {};

  /// The fields [device] reports (cached for the session).
  static Future<List<DeviceField>> fields(String device) async {
    if (device.isEmpty) return [];
    final cached = _fieldCache[device];
    if (cached != null) return cached;
    try {
      final res = await http
          .get(Uri.parse('$_base/discoveryDevice/fields/${Uri.encodeComponent(device)}?start=-24h'), headers: _headers)
          .timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return [];
      final j = jsonDecode(res.body) as Map<String, dynamic>;
      final out = ((j['fields'] as List?) ?? [])
          .whereType<Map>()
          .map((f) => DeviceField((f['measurement'] ?? '').toString(), (f['field'] ?? '').toString()))
          .where((f) => f.field.isNotEmpty)
          .toList();
      _fieldCache[device] = out;
      return out;
    } catch (_) {
      return [];
    }
  }

  /// Latest value of every field of [device], keyed "measurement|field".
  static Future<Map<String, double>> latest(String device) async {
    try {
      final res = await http
          .get(Uri.parse('$_base/discoveryDevice/realtime/${Uri.encodeComponent(device)}'), headers: _headers)
          .timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) return {};
      final list = jsonDecode(res.body);
      if (list is! List) return {};
      final out = <String, double>{};
      for (final r in list.whereType<Map>()) {
        final v = (r['value'] as num?)?.toDouble();
        if (v == null) continue;
        out['${r['measurement'] ?? ''}|${r['field'] ?? ''}'] = v;
      }
      return out;
    } catch (_) {
      return {};
    }
  }

  /// History of one source over [start] (e.g. "-6h"), averaged per [window].
  static Future<List<TrendPoint>> history(PointSource src, {String start = '-6h', String window = '5m'}) async {
    if (!src.isSet) return [];
    try {
      final q = {
        'field': src.field,
        if (src.measurement.isNotEmpty) 'measurement': src.measurement,
        'start': start,
        'window': window,
      };
      final uri = Uri.parse('$_base/discoveryDevice/history/${Uri.encodeComponent(src.device)}')
          .replace(queryParameters: q);
      final res = await http.get(uri, headers: _headers).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) return [];
      final j = jsonDecode(res.body);
      final rows = j is List ? j : (j['data'] ?? j['points'] ?? []) as List;
      return rows
          .whereType<Map>()
          .map((r) {
            final t = DateTime.tryParse((r['time'] ?? r['_time'] ?? '').toString());
            final v = (r['value'] ?? r['_value']) as num?;
            return (t == null || v == null) ? null : TrendPoint(t.toLocal(), v.toDouble());
          })
          .whereType<TrendPoint>()
          .toList();
    } catch (_) {
      return [];
    }
  }
}
