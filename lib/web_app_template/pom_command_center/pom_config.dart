import 'dart:convert';
import 'package:flutter/painting.dart' show Color;
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/app_config.dart';

/// The whole Group POM Command Center is described by one JSON-shaped map: the
/// settings page edits it, the dashboard renders it. Kept as a map (rather than
/// a pile of classes) so the settings page can bind any field by its path, the
/// way the design does, and so saving and exporting are just JSON.
typedef Cfg = Map<String, dynamic>;

Cfg cloneCfg(Cfg c) => jsonDecode(jsonEncode(c)) as Cfg;

dynamic getPath(dynamic o, String p) {
  dynamic a = o;
  for (final k in p.split('.')) {
    if (a == null) return null;
    if (a is List) {
      final i = int.tryParse(k);
      a = (i == null || i < 0 || i >= a.length) ? null : a[i];
    } else if (a is Map) {
      a = a[k];
    } else {
      return null;
    }
  }
  return a;
}

void setPath(Cfg o, String p, dynamic v) {
  final ks = p.split('.');
  dynamic a = o;
  for (var i = 0; i < ks.length - 1; i++) {
    final k = ks[i];
    dynamic next;
    if (a is List) {
      next = a[int.parse(k)];
    } else {
      next = (a as Map)[k];
      if (next == null || (next is! Map && next is! List)) {
        next = <String, dynamic>{};
        a[k] = next;
      }
    }
    a = next;
  }
  final last = ks.last;
  if (a is List) {
    a[int.parse(last)] = v;
  } else {
    (a as Map)[last] = v;
  }
}

Color hexColor(String? h, [Color fallback = const Color(0xFF6B7FA3)]) {
  if (h == null || h.isEmpty) return fallback;
  var s = h.replaceAll('#', '');
  if (s.length == 3) s = s.split('').map((c) => '$c$c').join();
  if (s.length != 6) return fallback;
  final v = int.tryParse(s, radix: 16);
  return v == null ? fallback : Color(0xFF000000 | v);
}

String colorHex(Color c) =>
    '#${(c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';

String fmtNum(num v, int d) {
  final s = v.toStringAsFixed(d);
  final neg = s.startsWith('-');
  final body = neg ? s.substring(1) : s;
  final parts = body.split('.');
  final ip = parts[0];
  final buf = StringBuffer();
  for (var i = 0; i < ip.length; i++) {
    if (i > 0 && (ip.length - i) % 3 == 0) buf.write(',');
    buf.write(ip[i]);
  }
  return '${neg ? '-' : ''}$buf${parts.length > 1 ? '.${parts[1]}' : ''}';
}

/// One field a real device exposes — key is "<measurement>|<field>", exactly
/// what SmartMill's own MySQL (mqtt_channel_mapping) says that device writes
/// to Influx. Stored verbatim in a mill's map.<metric>.field so a live lookup
/// never has to guess the measurement back out of a display label.
class PomFieldDef {
  final String key;
  final String label;
  const PomFieldDef(this.key, this.label);
}

/// A real device (Influx tag `id`), grouped from SmartMill's own MySQL, with
/// the exact fields it currently reports.
class PomDevice {
  final String id;
  final String site;
  final String src; // shown in the Data mapping table's "Source" column
  final List<PomFieldDef> fields;
  const PomDevice(this.id, this.site, this.src, this.fields);
}

/// Real device/field catalog, fetched once from SmartMill's own API
/// (/pom/devices → MySQL) and cached for the session. Every id, measurement
/// and field here is something SmartMill's own database actually has wired
/// up — nothing here is invented.
class PomLiveData {
  PomLiveData._();
  static List<PomDevice>? _devices;
  static Future<void>? _loading;

  /// Set when the last load attempt failed, so the UI can tell "nothing
  /// wired up yet" apart from "couldn't reach SmartMill's API" and offer a
  /// retry instead of a permanently empty list.
  static String? lastDevicesError;

  static List<PomDevice> get devices => _devices ?? const [];
  static bool get devicesLoaded => _devices != null;

  /// Loads the device catalog once and caches it — but only a *successful*
  /// load is cached. A cold-started function or a client id that hasn't
  /// resolved yet must not permanently lock the page into "no devices" for
  /// the rest of the browser session; [retry] forces a fresh attempt.
  static Future<void> ensureDevicesLoaded({bool retry = false}) async {
    if (_devices != null && !retry) return;
    if (retry) _loading = null;
    _loading ??= _fetchDevices();
    await _loading;
  }

  static Future<void> _fetchDevices() async {
    try {
      if (AppConfig.clientId.isEmpty) await AppConfig.init();
      final uri = Uri.parse('${AppConfig.dataApiBaseSafe}/pom/devices');
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 20));
      if (res.statusCode != 200) {
        lastDevicesError = 'HTTP ${res.statusCode}: ${res.body}';
        _loading = null;
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      _devices = ((data['devices'] as List?) ?? const [])
          .cast<Map<String, dynamic>>()
          .map((d) => PomDevice(
                (d['id'] ?? '').toString(),
                (d['site'] ?? '').toString(),
                'Device',
                ((d['fields'] as List?) ?? const [])
                    .cast<Map<String, dynamic>>()
                    .map((f) {
                      final measurement = (f['measurement'] ?? '').toString();
                      final field = (f['field'] ?? '').toString();
                      final unit = (f['unit'] ?? '').toString();
                      final label = (f['label'] ?? measurement).toString();
                      return PomFieldDef('$measurement|$field', unit.isNotEmpty && unit != 'none' ? '$label · $field ($unit)' : '$label · $field');
                    })
                    .toList(),
              ))
          .toList();
      lastDevicesError = null;
    } catch (e) {
      lastDevicesError = e.toString();
      _loading = null;
    }
  }

  /// Latest live value for each (deviceId, "<measurement>|<field>") pair,
  /// keyed "<deviceId>|<measurement>|<field>". A pair absent from the result
  /// means SmartMill's database has no recent value for it — callers show
  /// that as a dash rather than a guessed number.
  static Future<Map<String, double>> fetchValues(Iterable<(String deviceId, String fieldKey)> points) async {
    final result = <String, double>{};
    final reqPoints = <Map<String, String>>[];
    for (final p in points) {
      final parts = p.$2.split('|');
      if (parts.length != 2 || p.$1.isEmpty) continue;
      reqPoints.add({'id': p.$1, 'measurement': parts[0], 'field': parts[1]});
    }
    if (reqPoints.isEmpty) return result;
    try {
      if (AppConfig.clientId.isEmpty) await AppConfig.init();
      final uri = Uri.parse('${AppConfig.dataApiBaseSafe}/pom/values');
      final res = await http
          .post(uri, headers: AppConfig.headers, body: jsonEncode({'points': reqPoints}))
          .timeout(const Duration(seconds: 25));
      if (res.statusCode != 200) return result;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final values = (data['values'] as Map<String, dynamic>?) ?? const {};
      values.forEach((k, v) {
        final val = (v is Map) ? v['value'] : null;
        if (val is num) result[k] = val.toDouble();
      });
    } catch (_) {
      // Leave result as-is — every requested point just reads as "no data".
    }
    return result;
  }
}

/// Devices for one mill's tag-code prefix, from the real catalog. Falls back
/// to every known device when nothing matches that prefix — true today,
/// since SmartMill has exactly one wired site (SAMYSK) regardless of what a
/// mill happens to be coded as, and harmless once more sites exist because
/// their devices will then carry their own matching prefix.
List<PomDevice> devicesFor(String code) {
  final all = PomLiveData.devices;
  final bySite = all.where((d) => d.site == code).toList();
  return bySite.isNotEmpty ? bySite : all;
}

class PomEvent {
  final String src; // 'rca' | 'alarm'
  final String mill;
  final String sev; // 'high' | 'medium' | 'low'
  final int ago; // hours
  final Map<String, String> msg;
  const PomEvent(this.src, this.mill, this.sev, this.ago, this.msg);
}

/// No alarm/RCA table is connected for SmartMill yet, so there is nothing
/// real to list here — the Attention feed shows its honest empty state
/// ("Nothing needs attention") until such a source exists.
const List<PomEvent> kEvents = [];

/// Metric keys the SmartMill 365 preset ships with — shown as "Core" in the
/// Metrics table (not deletable) instead of a metric the admin added.
const Set<String> kCoreMetrics = {'ffb', 'cpo', 'tph', 'oer', 'stz', 'proc', 'hrs', 'cyc'};

const Map<String, String> kPeriodLabel = {'today': 'Today', 'mtd': 'MTD', 'monthly': 'Monthly'};
const Map<String, String> kAggLabel = {
  'sum': 'Sum',
  'avg': 'Simple average',
  'wavg': 'Weighted average',
  'max': 'Maximum',
  'min': 'Minimum',
};

/// The SmartMill 365 preset. Seeded with SmartMill's one real, wired site —
/// no device is pre-mapped, because guessing a mapping would show a number
/// with nothing real behind it. Map each metric for real in Data mapping,
/// and add the other mills once their sites are wired up.
Cfg pomTemplate() {
  final mills = <Map<String, dynamic>>[
    {'id': 'samysk', 'code': 'SAMYSK', 'name': 'SAMYSK', 'loc': '', 'target': null, 'x': 50, 'y': 50, 'side': 'top', 'active': true},
  ];
  final map = <String, dynamic>{for (final m in mills) m['id'] as String: <String, dynamic>{}};

  Map<String, dynamic> metric(String k, String label, String short, String unit, int dec, String kind, String agg, String w) =>
      {'k': k, 'label': label, 'short': short, 'unit': unit, 'dec': dec, 'kind': kind, 'agg': agg, 'w': w, 'better': 'higher'};
  Map<String, dynamic> kpi(String title, String metric, String icon, String unit) =>
      {'title': title, 'metric': metric, 'agg': 'inherit', 'w': '', 'unit': unit, 'icon': icon, 'accent': '#3ec6ff', 'color': '#ffffff', 'size': 42, 'spark': true};

  return {
    'top': {
      'product': 'SmartPalmOilMill365',
      'title': 'Group POM Command Center',
      'subtitle': 'Sarawak Operations',
      'titleColor': '#46c3ff',
      'logo': '',
      'fallback': 'icon',
      'initials': 'SP',
      'badge': '#0f7a3d',
      'live': true,
      'clock': true,
      // Only "Today" (the latest live reading) has a real source. MTD/Monthly
      // stay available to switch on, but nothing computes a real historical
      // rollup yet — see PomCalc.value, which returns "no data" for them
      // rather than relabel today's reading as a period it isn't.
      'periods': {'today': true, 'mtd': false, 'monthly': false},
      'defPeriod': 'today',
      'periodMode': 'global',
    },
    'mills': mills,
    'catalog': [
      metric('ffb', 'FFB Processed', 'FFB', 't', 0, 'amount', 'sum', ''),
      metric('cpo', 'CPO Produced', 'CPO', 't', 0, 'amount', 'sum', ''),
      metric('tph', 'Avg Throughput', 'Throughput', 't/h', 1, 'rate', 'wavg', 'hrs'),
      metric('oer', 'OER', 'OER', '%', 1, 'rate', 'wavg', 'ffb'),
      metric('stz', 'Sterilizer Health', 'Health', '', 0, 'rate', 'wavg', 'cyc'),
      metric('proc', 'Overall Process Health', 'Process', '', 0, 'rate', 'wavg', 'cyc'),
      metric('hrs', 'Processing Hours', 'Hours', 'h', 1, 'amount', 'sum', ''),
      metric('cyc', 'Sterilizer Cycles', 'Cycles', '', 0, 'amount', 'sum', ''),
    ],
    // The process stages every mill's Command Center page is broken into —
    // shared across all mills, since every POM mill runs the same stages.
    // healthMetric is left unmapped on purpose: no station-level score exists
    // in real data yet, so each tab honestly shows "no data" until an admin
    // maps one, the same rule as everywhere else in this config.
    'stations': [
      {'id': 'sterilizer', 'label': 'Sterilizer', 'icon': 'flame', 'color': '#ef4444', 'healthMetric': ''},
      {'id': 'boiler', 'label': 'Boiler & Steam', 'icon': 'shield', 'color': '#8f82ff', 'healthMetric': ''},
      {'id': 'pressing', 'label': 'Pressing', 'icon': 'gear', 'color': '#f5b82e', 'healthMetric': ''},
      {'id': 'clarification', 'label': 'Clarification', 'icon': 'drop', 'color': '#3ec6ff', 'healthMetric': ''},
      {'id': 'kernel', 'label': 'Kernel Recovery', 'icon': 'leaf', 'color': '#f59e42', 'healthMetric': ''},
      {'id': 'utilities', 'label': 'Utilities', 'icon': 'chart', 'color': '#94a3b8', 'healthMetric': ''},
    ],
    // Per-mill Command Center page — the KPI row, progress rings and key
    // indicators reuse the group's own catalog/kpi metrics (this mill's own
    // value instead of the group total). These are the parts with no group
    // equivalent to reuse: a shift-by-shift comparison table (no real
    // per-shift data source yet, so every cell honestly reads "—" until one
    // exists) and a small indicator strip.
    'millCenter': {
      'progressMetrics': ['ffb', 'cpo', 'tph'],
      'shiftMetrics': ['cyc', 'hrs'],
      'indicatorMetrics': ['oer', 'stz'],
      'mapBg': '',
    },
    'map': map,
    'status': {
      'metric': 'stz',
      'stable': 85,
      'watch': 70,
      'labels': ['Stable', 'Watch', 'Attention'],
      'colors': ['#22c55e', '#f5b82e', '#ef4444'],
    },
    'band': {
      'metric': 'tph',
      'basis': 'target',
      'width': 3,
      'labels': ['Above', 'Average', 'Below'],
      'colors': ['#22c55e', '#f5b82e', '#ef4444'],
    },
    'kpi': {
      'cards': [
        kpi('Total FFB Processed', 'ffb', 'truck', ''),
        kpi('Total CPO Produced', 'cpo', 'drop', ''),
        kpi('Average Throughput', 'tph', 'gear', ''),
        kpi('Group Sterilizer Health', 'stz', 'shield', '/ 100'),
      ],
      'exclude': <String>[],
      'autoInclude': true,
    },
    'mapc': {
      'title': 'Sarawak Mill Network',
      'subtitle': 'Live Operations Map',
      // The default Sarawak picture already carries its own title, legend,
      // compass, scale, locator inset and town names, so those overlays are
      // off here. Switch them on when a plain map image is used instead.
      'bg': 'assets/images/sarawak_mill_network_map.jpg',
      'header': false,
      'locLabels': false,
      'sea': '',
      'region': '',
      'legend': false,
      'compass': false,
      'inset': false,
      'scale': false,
      'popup': ['oer', 'stz'],
      'popStatus': true,
    },
    'left': {
      'title': 'Mill Production Performance',
      'metrics': ['ffb', 'cpo', 'tph'],
      'band': true,
      'border': 'status',
      'sort': 'registry',
      'sortMetric': 'tph',
      'sortDir': 'desc',
      'bars': true,
    },
    'right': {
      'title': 'Mill Process Health',
      'cols': [
        {'m': 'stz', 'bar': true},
        {'m': 'proc', 'bar': false},
      ],
      'status': true,
      'sortMetric': '',
      'sortDir': 'desc',
    },
    'alerts': {
      'title': 'Attention Required',
      'source': 'rca',
      'window': 24,
      'minSev': 'medium',
      'max': 3,
      'lang': 'en',
      'rel': true,
      'sev': [
        {'k': 'high', 'label': 'High', 'color': '#ef4444'},
        {'k': 'medium', 'label': 'Medium', 'color': '#f5b82e'},
        {'k': 'low', 'label': 'Low', 'color': '#3ec6ff'},
      ],
    },
  };
}

// ── Where a check points the user ───────────────────────────────────────────

class PomGo {
  final String tab; // 'data' | 'layout'
  final int? step;
  final String? mill;
  final String? region;
  const PomGo({required this.tab, this.step, this.mill, this.region});
}

class PomCheck {
  final String lv; // 'err' | 'warn' | 'info'
  final String t;
  final String d;
  final PomGo? go;
  const PomCheck(this.lv, this.t, this.d, [this.go]);
}

class AggRow {
  final Map<String, dynamic> mill;
  final double? v;
  final double? w;
  final bool ok;
  final String why;
  const AggRow(this.mill, this.v, this.w, this.ok, this.why);
}

class AggResult {
  final double? v;
  final List<AggRow> rows;
  const AggResult(this.v, this.rows);
}

/// Everything the dashboard and settings compute from a config. [value] reads
/// from [live] — the latest values fetched from SmartMill's own Influx/MySQL
/// via [PomLiveData] — never from a fixed number baked into the app.
class PomCalc {
  final Cfg s;
  final Map<String, double> live;
  PomCalc(this.s, [Map<String, double>? live]) : live = live ?? const {};

  /// Every (deviceId, "<measurement>|<field>") pair this config's mapping
  /// currently points at, for [PomLiveData.fetchValues].
  Iterable<(String, String)> mappedPoints() sync* {
    for (final m in mills) {
      final mid = m['id'] as String;
      final mp = getPath(s, 'map.$mid');
      if (mp is! Map) continue;
      for (final entry in mp.values) {
        if (entry is! Map) continue;
        final dev = (entry['dev'] ?? '').toString();
        final field = (entry['field'] ?? '').toString();
        if (dev.isNotEmpty && field.isNotEmpty) yield (dev, field);
      }
    }
  }

  List<Map<String, dynamic>> get mills => (s['mills'] as List).cast<Map<String, dynamic>>();
  List<Map<String, dynamic>> get catalog => (s['catalog'] as List).cast<Map<String, dynamic>>();
  Map<String, dynamic> get top => s['top'] as Map<String, dynamic>;
  Map<String, dynamic> get kpi => s['kpi'] as Map<String, dynamic>;
  Map<String, dynamic> get status => s['status'] as Map<String, dynamic>;
  Map<String, dynamic> get band => s['band'] as Map<String, dynamic>;
  Map<String, dynamic> get mapc => s['mapc'] as Map<String, dynamic>;
  Map<String, dynamic> get left => s['left'] as Map<String, dynamic>;
  Map<String, dynamic> get right => s['right'] as Map<String, dynamic>;
  Map<String, dynamic> get alerts => s['alerts'] as Map<String, dynamic>;
  List<Map<String, dynamic>> get stations => ((s['stations'] as List?) ?? const []).cast<Map<String, dynamic>>();
  Map<String, dynamic> get millCenter => (s['millCenter'] as Map<String, dynamic>?) ?? const {'progressMetrics': [], 'shiftMetrics': [], 'indicatorMetrics': [], 'mapBg': ''};
  List<Map<String, dynamic>> get cards => (kpi['cards'] as List).cast<Map<String, dynamic>>();

  Map<String, dynamic>? cat(String? k) {
    for (final c in catalog) {
      if (c['k'] == k) return c;
    }
    return null;
  }

  String lbl(String? k) => (cat(k)?['label'] ?? '—').toString();
  Map<String, dynamic>? mill(String? id) {
    for (final m in mills) {
      if (m['id'] == id) return m;
    }
    return null;
  }

  static String short(String n) => n.replaceAll(RegExp(r'\s*Sdn\.?\s*Bhd\.?', caseSensitive: false), '').trim();
  List<Map<String, dynamic>> activeMills() => mills.where((m) => m['active'] == true).toList();
  List<Map<String, dynamic>> groupMills() {
    final ex = (kpi['exclude'] as List).cast<String>();
    return activeMills().where((m) => !ex.contains(m['id'])).toList();
  }

  String names(Iterable<Map<String, dynamic>> l) => l.map((m) => short(m['name'].toString())).join(', ');
  List<String> enabledPeriods() {
    final p = top['periods'] as Map;
    return kPeriodLabel.keys.where((k) => p[k] == true).toList();
  }

  bool mapped(String mid, String k) {
    final mp = getPath(s, 'map.$mid.$k');
    return mp is Map && (mp['dev'] ?? '').toString().isNotEmpty && (mp['field'] ?? '').toString().isNotEmpty;
  }

  int mappedCount(String mid) => catalog.where((c) => mapped(mid, c['k'] as String)).length;

  String perFor(String panel, String uiPeriod, Map<String, String> panelPeriod) {
    final md = top['periodMode'];
    final pp = panelPeriod[panel] ?? '';
    if (md == 'global') return uiPeriod;
    if (md == 'panel') return pp.isEmpty ? top['defPeriod'].toString() : pp;
    return pp.isEmpty ? uiPeriod : pp;
  }

  /// The mill's own live value for a metric, or null when the field is not
  /// mapped, or SmartMill's database has no recent reading for it.
  ///
  /// Only 'today' (the latest reading) is real. MTD/Monthly have no live
  /// historical rollup wired up yet, so they return null rather than relabel
  /// today's reading as a period it doesn't actually represent.
  double? value(String mid, String k, [String per = 'today']) {
    if (per != 'today') return null;
    if (!mapped(mid, k)) return null;
    final mp = getPath(s, 'map.$mid.$k') as Map?;
    final dev = (mp?['dev'] ?? '').toString();
    final field = (mp?['field'] ?? '').toString();
    if (dev.isEmpty || field.isEmpty) return null;
    return live['$dev|$field'];
  }

  AggResult aggregate(String k, String method, String wk, List<Map<String, dynamic>> ms, String per) {
    final rows = ms.map((m) {
      final id = m['id'] as String;
      final v = value(id, k, per);
      final w = method == 'wavg' ? value(id, wk, per) : null;
      var why = '';
      if (v == null) {
        why = '${lbl(k)} not mapped';
      } else if (method == 'wavg' && (w == null || w <= 0)) {
        why = '${lbl(wk)} not mapped';
      }
      return AggRow(m, v, w, why.isEmpty, why);
    }).toList();
    final u = rows.where((r) => r.ok).toList();
    double? v;
    if (u.isNotEmpty) {
      final vs = u.map((r) => r.v!).toList();
      switch (method) {
        case 'sum':
          v = vs.fold<double>(0, (a, b) => a + b);
        case 'avg':
          v = vs.fold<double>(0, (a, b) => a + b) / vs.length;
        case 'max':
          v = vs.reduce((a, b) => a > b ? a : b);
        case 'min':
          v = vs.reduce((a, b) => a < b ? a : b);
        case 'wavg':
          final sw = u.fold<double>(0, (a, r) => a + r.w!);
          v = sw == 0 ? null : u.fold<double>(0, (a, r) => a + r.v! * r.w!) / sw;
      }
    }
    return AggResult(v, rows);
  }

  /// How a KPI card combines the mills: its own choice, or the metric's.
  (String method, String w) eff(Map<String, dynamic> card) {
    final c = cat(card['metric'] as String?);
    if (c == null) return ('sum', '');
    if (card['agg'] == 'inherit') return (c['agg'].toString(), c['w'].toString());
    final agg = card['agg'].toString();
    final w = (card['w'] ?? '').toString();
    return (agg, agg == 'wavg' ? (w.isNotEmpty ? w : c['w'].toString()) : '');
  }

  int statusIdx(String mid, String per) {
    final st = status;
    final c = cat(st['metric'] as String?);
    final v = value(mid, st['metric'] as String, per);
    if (v == null || c == null) return -1;
    final stable = (st['stable'] as num).toDouble();
    final watch = (st['watch'] as num).toDouble();
    if (c['better'] == 'lower') return v <= stable ? 0 : (v <= watch ? 1 : 2);
    return v >= stable ? 0 : (v >= watch ? 1 : 2);
  }

  Color statusColor(String mid, String per) {
    final i = statusIdx(mid, per);
    return i < 0 ? const Color(0xFF6B7FA3) : hexColor((status['colors'] as List)[i] as String);
  }

  int bandIdx(Map<String, dynamic> m, String per) {
    final b = band;
    final c = cat(b['metric'] as String?);
    final v = value(m['id'] as String, b['metric'] as String, per);
    if (v == null || c == null) return -1;
    double? ref;
    if (b['basis'] == 'target') {
      ref = (m['target'] as num?)?.toDouble();
    } else {
      ref = aggregate(b['metric'] as String, c['agg'].toString(), c['w'].toString(), groupMills(), per).v;
    }
    if (ref == null || !(ref > 0)) return -1;
    var d = (v - ref) / ref * 100;
    if (c['better'] == 'lower') d = -d;
    final width = (b['width'] as num).toDouble();
    return d > width ? 0 : (d < -width ? 2 : 1);
  }

  List<String> usedBy(String k) {
    final u = <String>[];
    if (cards.any((c) => c['metric'] == k || eff(c).$2 == k)) u.add('KPI cards');
    if ((left['metrics'] as List).contains(k) || (left['sort'] == 'metric' && left['sortMetric'] == k)) u.add('Left panel');
    if ((right['cols'] as List).any((c) => c['m'] == k) || right['sortMetric'] == k) u.add('Right panel');
    if ((mapc['popup'] as List).contains(k)) u.add('Map pop-up');
    if (status['metric'] == k) u.add('Status rule');
    if (band['metric'] == k) u.add('Performance band');
    for (final c in catalog) {
      if (c['w'] == k && c['agg'] == 'wavg') u.add('weight for ${c['label']}');
    }
    return u;
  }

  List<PomCheck> checks() {
    final out = <PomCheck>[];
    final act = activeMills();
    final un = <(Map<String, dynamic>, Map<String, dynamic>)>[];
    for (final m in act) {
      for (final c in catalog) {
        if (!mapped(m['id'] as String, c['k'] as String)) un.add((m, c));
      }
    }
    if (un.isNotEmpty) {
      out.add(PomCheck(
        'warn',
        '${un.length} field${un.length > 1 ? 's' : ''} not mapped yet',
        un.take(4).map((x) => '${short(x.$1['name'].toString())}: ${x.$2['label']}').join('; ') +
            (un.length > 4 ? '; and ${un.length - 4} more' : ''),
        PomGo(tab: 'data', step: 3, mill: un.first.$1['id'] as String),
      ));
    }
    for (final c in catalog) {
      if (c['kind'] == 'rate' && c['agg'] == 'sum') {
        out.add(PomCheck('err', '${c['label']} is set to Sum', 'A rate or score cannot be added across mills.', const PomGo(tab: 'data', step: 2)));
      }
      if (c['agg'] == 'wavg') {
        final w = (c['w'] ?? '').toString();
        if (w.isEmpty) {
          out.add(PomCheck('err', '${c['label']} uses a weighted average but has no weight', 'Pick a weight metric.', const PomGo(tab: 'data', step: 2)));
        } else {
          final miss = act.where((m) => mapped(m['id'] as String, c['k'] as String) && !mapped(m['id'] as String, w)).toList();
          if (miss.isNotEmpty) {
            out.add(PomCheck(
              'warn',
              '${c['label']} is weighted by ${lbl(w)}, which is not mapped at ${names(miss)}',
              'These mills are left out of the group figure until the weight is mapped.',
              PomGo(tab: 'data', step: 3, mill: miss.first['id'] as String),
            ));
          }
        }
      }
    }
    for (final card in cards) {
      final c = cat(card['metric'] as String?);
      final e = eff(card);
      if (c == null) continue;
      if (c['kind'] == 'rate' && e.$1 == 'sum') {
        out.add(PomCheck('err', 'KPI card “${card['title']}” sums ${c['label']}', 'Use weighted average for a rate or score.', const PomGo(tab: 'layout', region: 'kpi')));
      }
      if (c['kind'] == 'rate' && e.$1 == 'avg') {
        out.add(PomCheck('info', 'KPI card “${card['title']}” uses a simple average', 'Every mill counts the same regardless of size. Weighted average is usually the right group figure.', const PomGo(tab: 'layout', region: 'kpi')));
      }
    }
    final st = status;
    final sc = cat(st['metric'] as String?);
    if (sc != null) {
      final stable = (st['stable'] as num).toDouble();
      final watch = (st['watch'] as num).toDouble();
      final wrong = sc['better'] == 'higher' ? watch > stable : watch < stable;
      if (wrong) {
        out.add(PomCheck('err', 'Status thresholds are in the wrong order', 'For ${sc['label']}, the Watch threshold must sit between Stable and Attention.', const PomGo(tab: 'data', step: 4)));
      }
    }
    if (band['basis'] == 'target') {
      final miss = act.where((m) => !(((m['target'] as num?) ?? 0) > 0)).toList();
      if (miss.isNotEmpty) {
        out.add(PomCheck('warn', 'No target ${lbl(band['metric'] as String?)} for ${names(miss)}', 'Above, Average and Below cannot be decided for these mills.', const PomGo(tab: 'data', step: 1)));
      }
    }
    if (enabledPeriods().isEmpty) {
      out.add(PomCheck('err', 'No time period is enabled', 'Enable at least one of Today, MTD or Monthly.', const PomGo(tab: 'layout', region: 'top')));
    }
    if (groupMills().isEmpty) {
      out.add(PomCheck('err', 'The KPI cards include no mills', 'Tick at least one mill.', const PomGo(tab: 'layout', region: 'kpi')));
    }
    return out;
  }
}

/// Draft (what the settings page edits) and live (what the dashboard shows).
/// Kept in the browser's storage for now — SmartMill has no backend yet.
class PomConfigStore {
  PomConfigStore._();
  static const _draftKey = 'pomKanbanDraft';
  static const _liveKey = 'pomKanbanLive';

  static Cfg live = pomTemplate();
  static Cfg? draft;
  static bool _loaded = false;

  static Future<void> ensureLoaded() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final p = await SharedPreferences.getInstance();
      final l = p.getString(_liveKey);
      final d = p.getString(_draftKey);
      if (l != null) live = jsonDecode(l) as Cfg;
      if (d != null) draft = jsonDecode(d) as Cfg;
    } catch (_) {
      // Storage can be blocked (private window); the template is a fine start.
    }
  }

  static Cfg editable() => cloneCfg(draft ?? live);

  static Future<bool> saveDraft(Cfg c) async {
    draft = cloneCfg(c);
    try {
      final p = await SharedPreferences.getInstance();
      return p.setString(_draftKey, jsonEncode(c));
    } catch (_) {
      return false;
    }
  }

  static Future<bool> publish(Cfg c) async {
    live = cloneCfg(c);
    draft = cloneCfg(c);
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_draftKey, jsonEncode(c));
      return p.setString(_liveKey, jsonEncode(c));
    } catch (_) {
      return false;
    }
  }
}
