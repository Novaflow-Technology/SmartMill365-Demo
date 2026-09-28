import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import 'package:smartmachine365/flutter_flow/flutter_flow_theme.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/flutter_flow/nav/router_tracker.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Power Factor Monitoring — real-time monitoring, trending and issue detection.
// Layout mirrors the approved mockup 1:1 (gauge KPI + 6 cards, top-10 trend
// with threshold lines, and a Top-10 PF Culprits table). Data is live: per-
// device power factor is polled and accumulated into a rolling trend history.
// ─────────────────────────────────────────────────────────────────────────────

const _kRed = Color(0xFFEF4444);
const _kOrange = Color(0xFFF59E0B);
const _kYellow = Color(0xFFEAB308);
const _kGreen = Color(0xFF22C55E);
const _kBlue = Color(0xFF3B82F6);

const double _kTarget = 0.95;
const double _kWarning = 0.90;
const double _kAlarm = 0.85;

Color _pfColor(double v) {
  if (v <= 0) return const Color(0xFF64748B);
  if (v < _kAlarm) return _kRed;
  if (v < 0.88) return _kOrange;
  if (v < _kWarning) return _kYellow;
  return _kGreen;
}

class _Pf {
  final String id;
  final String name;
  final double pf;
  final Color color;
  final double kw;
  const _Pf(this.id, this.name, this.pf, this.color, {this.kw = 0});
}

class _PfMachine {
  final String id;
  final String name;
  final Color color;
  final String plant;
  final String zone;
  final String productionArea;
  final String equipmentNameId;
  final String equipmentType;
  const _PfMachine({
    required this.id,
    required this.name,
    required this.color,
    required this.plant,
    required this.zone,
    required this.productionArea,
    required this.equipmentNameId,
    this.equipmentType = '',
  });
}

class PowerFactorMonitoringWidget extends StatefulWidget {
  const PowerFactorMonitoringWidget({super.key});

  @override
  State<PowerFactorMonitoringWidget> createState() => _PowerFactorMonitoringWidgetState();
}

class _PowerFactorMonitoringWidgetState extends State<PowerFactorMonitoringWidget> {
  static const String _base = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static const List<Color> _palette = [
    Color(0xFFEF4444), Color(0xFFF97316), Color(0xFFF59E0B), Color(0xFFEAB308),
    Color(0xFF84CC16), Color(0xFF22C55E), Color(0xFF14B8A6), Color(0xFF06B6D4),
    Color(0xFF3B82F6), Color(0xFF8B5CF6), Color(0xFFEC4899), Color(0xFFF43F5E),
  ];

  List<_PfMachine> _allPfMachines = [];
  final Set<String> _selPlants = {};
  final Set<String> _selZones = {};
  final Set<String> _selProdAreas = {};
  final Set<String> _selEquipments = {};
  final Set<String> _selDevices = {};
  final Map<String, double> _pfById = {};
  final Map<String, double> _kwById = {}; // Influx active power (kW) per device

  String _reactiveKvar = '—';
  bool _loading = true;
  Timer? _timer;
  Timer? _trendTimer;
  DateTime _now = DateTime.now();

  static const List<String> _ranges = ['15m', '1h', '8h', '24h', '7d', '30d', '12M'];
  String _range = '24h';

  static const List<String> _windows = ['Last 1 Hour', 'Last 6 Hours', 'Last 24 Hours', 'Last 7 Days'];
  String _window = 'Last 24 Hours';

  // Real per-device PF time-series (from the pf-correlation endpoint) — this is
  // what the trend chart plots, so lines vary instead of being flat.
  Map<String, List<double>> _trendSeries = {};
  List<String> _trendLabels = [];
  bool _loadingTrend = true;

  // ── Theme-aware colors (reuse the app's CardWidget palette) ────────────────
  FlutterFlowTheme get _t => FlutterFlowTheme.of(context);
  bool get _isLight => Theme.of(context).brightness == Brightness.light;
  Color get _kBg => _t.primaryBackground;
  Color get _kCard => _isLight ? Colors.white : const Color(0xFF0E2040).withOpacity(0.55);
  Color get _kCardBorder => _isLight ? _t.alternate : const Color(0xFF17335C);
  Color get _kText => _t.primaryText;
  Color get _kMuted => _t.secondaryText;
  Color get _kMuted2 => _t.secondaryText.withOpacity(0.65);

  // Blue glossy-glass card (matches the Energy Details / CardWidget look).
  BoxDecoration get _glass => BoxDecoration(
        gradient: _isLight
            ? const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Colors.white, Color(0xFFF1F5FA)])
            : LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [const Color(0xFF0E2040).withOpacity(0.55), const Color(0xFF07101F).withOpacity(0.65)]),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _isLight ? _t.alternate : const Color(0xFF00E5FF).withOpacity(0.18), width: 1),
        boxShadow: [
          BoxShadow(
            color: (_isLight ? const Color(0xFF7A9CC0) : const Color(0xFF00E5FF)).withOpacity(_isLight ? 0.10 : 0.05),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      );

  // ── Lifecycle ──────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted) return;
      setState(() => _now = DateTime.now());
      _poll();
    });
    _trendTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted && !_loadingTrend) _fetchTrend();
    });
    routeTracker.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    if (routeTracker.currentRoute.toLowerCase().contains('powerfactormonitoring')) {
      _reloadFacilities();
    } else {
      // Navigated away — stop background polling timers immediately.
      _timer?.cancel();
      _trendTimer?.cancel();
    }
  }

  Future<void> _reloadFacilities() async {
    await _loadFacilities();
    await Future.wait([_poll(), _fetchTrend()]);
  }

  @override
  void dispose() {
    routeTracker.removeListener(_onRouteChanged);
    _timer?.cancel();
    _trendTimer?.cancel();
    super.dispose();
  }

  List<_PfMachine> get _visibleMachines => _allPfMachines.where((m) {
        if (_selPlants.isNotEmpty && m.plant.isNotEmpty && !_selPlants.contains(m.plant)) return false;
        if (_selZones.isNotEmpty && m.zone.isNotEmpty && !_selZones.contains(m.zone)) return false;
        if (_selProdAreas.isNotEmpty && m.productionArea.isNotEmpty && !_selProdAreas.contains(m.productionArea)) return false;
        if (_selEquipments.isNotEmpty && m.equipmentNameId.isNotEmpty && !_selEquipments.contains(m.equipmentNameId)) return false;
        if (_selDevices.isNotEmpty && !_selDevices.contains(m.id)) return false;
        return true;
      }).toList();

  Set<String> get _visibleIds => _visibleMachines.map((m) => m.id).toSet();

  bool get _hasActiveFilters =>
      _selPlants.isNotEmpty || _selZones.isNotEmpty || _selProdAreas.isNotEmpty || _selEquipments.isNotEmpty || _selDevices.isNotEmpty;

  List<String> get _plantOptions => _uniqueNonEmpty(_allPfMachines.map((m) => m.plant));
  List<String> get _zoneOptions {
    var list = _allPfMachines;
    if (_selPlants.isNotEmpty) list = list.where((m) => _selPlants.contains(m.plant)).toList();
    return _uniqueNonEmpty(list.map((m) => m.zone));
  }

  List<String> get _prodAreaOptions {
    var list = _allPfMachines;
    if (_selPlants.isNotEmpty) list = list.where((m) => _selPlants.contains(m.plant)).toList();
    if (_selZones.isNotEmpty) list = list.where((m) => _selZones.contains(m.zone)).toList();
    return _uniqueNonEmpty(list.map((m) => m.productionArea));
  }

  List<String> get _equipmentOptions {
    var list = _allPfMachines;
    if (_selPlants.isNotEmpty) list = list.where((m) => _selPlants.contains(m.plant)).toList();
    if (_selZones.isNotEmpty) list = list.where((m) => _selZones.contains(m.zone)).toList();
    if (_selProdAreas.isNotEmpty) list = list.where((m) => _selProdAreas.contains(m.productionArea)).toList();
    return _uniqueNonEmpty(list.map((m) => m.equipmentNameId));
  }

  List<String> get _deviceOptions {
    var list = _allPfMachines;
    if (_selPlants.isNotEmpty) list = list.where((m) => _selPlants.contains(m.plant)).toList();
    if (_selZones.isNotEmpty) list = list.where((m) => _selZones.contains(m.zone)).toList();
    if (_selProdAreas.isNotEmpty) list = list.where((m) => _selProdAreas.contains(m.productionArea)).toList();
    if (_selEquipments.isNotEmpty) list = list.where((m) => _selEquipments.contains(m.equipmentNameId)).toList();
    return list.map((m) => m.id).toList()..sort();
  }

  List<String> _uniqueNonEmpty(Iterable<String> values) {
    return values.where((v) => v.isNotEmpty && v != '-').toSet().toList()..sort();
  }

  void _clearFilters() => setState(() {
        _selPlants.clear();
        _selZones.clear();
        _selProdAreas.clear();
        _selEquipments.clear();
        _selDevices.clear();
      });

  Future<void> _load() async {
    await _loadFacilities();
    await Future.wait([_poll(), _fetchTrend()]);
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadFacilities() async {
    try {
      final facilities = await FacilityService.getFacilities();
      final loaded = <_PfMachine>[];
      var i = 0;
      for (final f in facilities) {
        if (!f.includePfAnalytics) continue;
        final status = f.status.trim().toLowerCase();
        if (status.isNotEmpty && status != 'active') continue;
        final id = f.meterId.trim();
        if (id.isEmpty || id == '-') continue;
        loaded.add(_PfMachine(
          id: id,
          name: f.meterName.isNotEmpty && f.meterName != '-' ? f.meterName : id,
          color: _palette[i % _palette.length],
          plant: f.plant,
          zone: f.zone,
          productionArea: f.productionArea,
          equipmentNameId: f.equipmentNameId,
          equipmentType: f.equipmentType,
        ));
        i++;
      }
      if (mounted) {
        setState(() {
          _allPfMachines = loaded;
          final allowed = loaded.map((m) => m.id).toSet();
          _pfById.removeWhere((id, _) => !allowed.contains(id));
          _kwById.removeWhere((id, _) => !allowed.contains(id));
          _trendSeries.removeWhere((id, _) => !allowed.contains(id));
        });
      }
    } catch (_) {}
  }

  Future<void> _fetchTrend() async {
    if (_allPfMachines.isEmpty) return;
    if (mounted) setState(() => _loadingTrend = true);
    try {
      final cfg = _trendRangeConfig(_range);
      final end = DateTime.now().toUtc();
      final start = end.subtract(cfg.lookback);
      final uri = Uri.parse('$_base/energyDetailsInfluxDb/equipment-pf-correlation').replace(queryParameters: {
        'event_start': _fmtApiTime(start),
        'event_end': _fmtApiTime(end),
        'interval': cfg.interval,
      });
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 45));
      if (res.statusCode != 200 || !mounted) {
        if (mounted) setState(() => _loadingTrend = false);
        return;
      }
      final body = json.decode(res.body);
      final List data = body is Map ? (body['data'] as List? ?? []) : (body is List ? body : []);
      if (data.isEmpty) {
        // Fallback: batched per-device timeseries when correlation returns nothing.
        await _fetchTrendBatched(cfg);
        return;
      }
      _applyTrendRows(data, useTimeLabel: true);
    } catch (_) {
      try {
        await _fetchTrendBatched(_trendRangeConfig(_range));
      } catch (_) {
        if (mounted) setState(() => _loadingTrend = false);
      }
    }
  }

  Future<void> _fetchTrendBatched(({Duration lookback, String interval, String window}) cfg) async {
    final end = DateTime.now().toUtc();
    final start = end.subtract(cfg.lookback);
    final known = {for (final m in _allPfMachines) m.id};
    final byDev = <String, Map<DateTime, double>>{};
    final times = <DateTime>{};
    const batchSize = 8;
    for (var i = 0; i < _allPfMachines.length; i += batchSize) {
      final batch = _allPfMachines.skip(i).take(batchSize).map((m) => m.id).join(',');
      final uri = Uri.parse('$_base/energyDetailsInfluxDb/timeseries/custom').replace(queryParameters: {
        'start': _fluxStart(cfg.lookback),
        'stop': 'now()',
        'window_period': cfg.window,
        'machine_ids': batch,
        'fields': 'PF,Power_Factor',
      });
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) continue;
      final decoded = json.decode(res.body);
      final List raw = decoded is List ? decoded : [];
      for (final it in raw) {
        if (it is! Map) continue;
        final rawId = (it['machine_id'] ?? it['device_id'])?.toString() ?? '';
        final tRaw = it['time']?.toString() ?? '';
        final pfRaw = it['value'];
        final dev = _resolveMachineId(rawId);
        if (dev == null || tRaw.isEmpty || pfRaw == null) continue;
        final t = DateTime.tryParse(tRaw)?.toUtc();
        final pf = double.tryParse(pfRaw.toString());
        if (t == null || pf == null || pf <= 0) continue;
        final norm = pf > 1.5 ? pf / 100 : pf;
        (byDev[dev] ??= {})[t] = norm;
        times.add(t);
      }
    }
    if (!mounted) return;
    if (times.isEmpty) {
      setState(() {
        _trendSeries = {};
        _trendLabels = [];
        _loadingTrend = false;
      });
      return;
    }
    final sorted = times.toList()..sort();
    final labels = [for (final t in sorted) _formatTrendLabel(t, _range)];
    final series = <String, List<double>>{};
    for (final id in known) {
      final map = byDev[id];
      if (map == null || map.isEmpty) continue;
      series[id] = [for (final t in sorted) map[t] ?? double.nan];
    }
    if (series.isEmpty) {
      if (!mounted) return;
      setState(() {
        _trendSeries = {};
        _trendLabels = labels;
        _loadingTrend = false;
      });
      return;
    }
    setState(() {
      _trendSeries = series;
      _trendLabels = labels;
      _loadingTrend = false;
      _syncPfFromTrend(series);
    });
  }

  void _applyTrendRows(List data, {required bool useTimeLabel}) {
    final known = {for (final m in _allPfMachines) m.id};
    final byDev = <String, Map<String, double>>{};
    final labels = <String>[];
    final labelSeen = <String>{};
    for (final it in data) {
      if (it is! Map) continue;
      final rawDev = it['device_id']?.toString() ?? '';
      final dev = _resolveMachineId(rawDev);
      if (dev == null) continue;
      final label = it['time_label']?.toString() ?? '';
      final pf = (it['power_factor'] as num?)?.toDouble();
      if (label.isEmpty || pf == null || pf <= 0) continue;
      final norm = pf > 1.5 ? pf / 100 : pf;
      (byDev[dev] ??= {})[label] = norm;
      if (labelSeen.add(label)) labels.add(label);
    }
    labels.sort((a, b) {
      int toMin(String s) {
        final p = s.split(':');
        if (p.length < 2) return 0;
        return (int.tryParse(p[0]) ?? 0) * 60 + (int.tryParse(p[1]) ?? 0);
      }
      return toMin(a).compareTo(toMin(b));
    });
    final series = <String, List<double>>{};
    for (final id in known) {
      final map = byDev[id];
      if (map == null || map.isEmpty) continue;
      series[id] = [for (final t in labels) map[t] ?? double.nan];
    }
    if (!mounted) return;
    setState(() {
      _trendSeries = series;
      _trendLabels = labels;
      _loadingTrend = false;
      _syncPfFromTrend(series);
    });
  }

  void _syncPfFromTrend(Map<String, List<double>> series) {
    final allowed = _allPfMachines.map((m) => m.id).toSet();
    for (final e in series.entries) {
      if (!allowed.contains(e.key)) continue;
      final vals = e.value.where((v) => !v.isNaN && v > 0).toList();
      if (vals.isEmpty) continue;
      _pfById[e.key] = vals.last;
    }
  }

  String? _resolveMachineId(String raw) {
    if (raw.isEmpty) return null;
    for (final m in _allPfMachines) {
      if (m.id == raw || m.id.toLowerCase() == raw.toLowerCase()) return m.id;
    }
    return null;
  }

  String _fmtApiTime(DateTime utc) {
    String two(int x) => x.toString().padLeft(2, '0');
    return '${utc.year}-${two(utc.month)}-${two(utc.day)} ${two(utc.hour)}:${two(utc.minute)}:${two(utc.second)}';
  }

  ({Duration lookback, String interval, String window}) _trendRangeConfig(String range) {
    switch (range) {
      case '15m':
        return (lookback: const Duration(minutes: 15), interval: '1m', window: '1m');
      case '1h':
        return (lookback: const Duration(hours: 1), interval: '5m', window: '5m');
      case '8h':
        return (lookback: const Duration(hours: 8), interval: '15m', window: '15m');
      case '7d':
        return (lookback: const Duration(days: 7), interval: '12h', window: '12h');
      case '30d':
        return (lookback: const Duration(days: 30), interval: '24h', window: '24h');
      case '12M':
        return (lookback: const Duration(days: 365), interval: '720h', window: '720h');
      case '24h':
      default:
        return (lookback: const Duration(hours: 24), interval: '1h', window: '1h');
    }
  }

  String _fluxStart(Duration d) {
    if (d.inDays >= 365) return '-365d';
    if (d.inDays >= 30) return '-30d';
    if (d.inDays >= 7) return '-7d';
    if (d.inHours >= 24) return '-24h';
    if (d.inHours >= 8) return '-8h';
    if (d.inHours >= 1) return '-${d.inHours}h';
    return '-${d.inMinutes}m';
  }

  String _formatTrendLabel(DateTime utc, String range) {
    final t = utc.add(const Duration(hours: 8)); // Malaysia (UTC+8)
    String two(int x) => x.toString().padLeft(2, '0');
    switch (range) {
      case '15m':
      case '1h':
        return '${two(t.hour)}:${two(t.minute)}';
      case '8h':
      case '24h':
        return '${two(t.hour)}:00';
      case '7d':
        return '${t.day}/${t.month}';
      case '30d':
        return '${t.day}/${t.month}';
      case '12M':
        return '${two(t.month)}/${t.year % 100}';
      default:
        return '${two(t.hour)}:${two(t.minute)}';
    }
  }

  double _trendBottomInterval(int len) {
    switch (_range) {
      case '15m':
        return (len / 5).ceilToDouble().clamp(1, 30);
      case '1h':
        return (len / 6).ceilToDouble().clamp(1, 30);
      case '8h':
        return (len / 8).ceilToDouble().clamp(1, 30);
      case '24h':
        return (len / 6).ceilToDouble().clamp(1, 30);
      case '7d':
        return (len / 7).ceilToDouble().clamp(1, 30);
      case '30d':
        return (len / 6).ceilToDouble().clamp(1, 30);
      case '12M':
        return (len / 6).ceilToDouble().clamp(1, 30);
      default:
        return (len / 6).ceilToDouble().clamp(1, 60);
    }
  }

  Color _colorFor(String id) {
    for (final m in _allPfMachines) {
      if (m.id == id) return m.color;
    }
    return _palette[id.hashCode.abs() % _palette.length];
  }

  String _nameFor(String id) {
    for (final m in _allPfMachines) {
      if (m.id == id) return m.name;
    }
    return id;
  }

  Future<void> _poll() async {
    if (_allPfMachines.isEmpty) return;
    await Future.wait([_pollPf(), _pollKw(), _pollReactive()]);
  }

  String get _windowDur {
    switch (_window) {
      case 'Last 1 Hour':
        return '1h';
      case 'Last 6 Hours':
        return '4h';
      case 'Last 7 Days':
        return '24h';
      default:
        return '24h';
    }
  }

  Future<void> _pollPf() async {
    try {
      final ids = _allPfMachines.map((m) => m.id).join(',');
      final dur = _windowDur;
      final res = await http.get(
        Uri.parse('$_base/energyDetailsInfluxDb/power-factor?machine_id=$ids&duration=$dur'),
        headers: AppConfig.headers,
      );
      if (res.statusCode != 200 || !mounted) return;
      final decoded = json.decode(res.body);
      final List raw = decoded is Map
          ? (decoded['data'] ?? decoded['results'] ?? decoded['devices'] ?? decoded['items'] ?? [])
          : decoded is List
              ? decoded
              : [];
      final next = <String, double>{};
      final nextKw = <String, double>{};
      for (final item in raw) {
        if (item is! Map) continue;
        final rawId = (item['machine_id'] ?? item['device_id'] ?? item['machineId'] ?? item['device'] ?? item['id'] ?? item['name'])?.toString();
        final id = rawId == null ? null : _resolveMachineId(rawId);
        final pfRaw = item['power_factor'] ?? item['powerFactor'] ?? item['pf'] ?? item['value'] ?? item['avg'] ?? item['mean'];
        if (id == null || pfRaw == null) continue;
        final pf = double.tryParse(pfRaw.toString());
        if (pf == null || pf <= 0) continue;
        next[id] = pf > 1.5 ? pf / 100 : pf;
        final kwRaw = item['power_kw'] ?? item['power_kW'] ?? item['kw'] ?? item['P_kW'] ?? item['Active_Power_kW'];
        final kw = kwRaw == null ? null : double.tryParse(kwRaw.toString());
        if (kw != null && kw >= 0) nextKw[id] = kw;
      }
      if (next.isEmpty) return;
      setState(() {
        _pfById
          ..clear()
          ..addAll(next);
        if (nextKw.isNotEmpty) {
          _kwById.addAll(nextKw);
        }
      });
    } catch (_) {}
  }

  /// Latest active power (kW) from Influx per device — used to exclude idle (&lt;1 kW) from culprits.
  Future<void> _pollKw() async {
    if (_allPfMachines.isEmpty) return;
    try {
      final next = <String, double>{};
      const batchSize = 10;
      for (var i = 0; i < _allPfMachines.length; i += batchSize) {
        final batch = _allPfMachines.skip(i).take(batchSize).map((m) => m.id).join(',');
        final uri = Uri.parse('$_base/energyDetailsInfluxDb/timeseries/custom').replace(queryParameters: {
          'start': '-15m',
          'stop': 'now()',
          'window_period': '5m',
          'machine_ids': batch,
          'fields': 'P_kW,P,Active_Power_kW',
        });
        final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 20));
        if (res.statusCode != 200) continue;
        final decoded = json.decode(res.body);
        final List raw = decoded is List ? decoded : [];
        // Keep latest sample per device.
        final latest = <String, ({DateTime t, double kw})>{};
        for (final it in raw) {
          if (it is! Map) continue;
          final rawId = (it['machine_id'] ?? it['device_id'])?.toString() ?? '';
          final id = _resolveMachineId(rawId);
          final kw = double.tryParse('${it['value'] ?? ''}');
          final t = DateTime.tryParse(it['time']?.toString() ?? '')?.toUtc();
          if (id == null || kw == null || t == null) continue;
          final prev = latest[id];
          if (prev == null || t.isAfter(prev.t)) latest[id] = (t: t, kw: kw.abs());
        }
        for (final e in latest.entries) {
          next[e.key] = e.value.kw;
        }
      }
      if (next.isEmpty || !mounted) return;
      setState(() {
        _kwById
          ..clear()
          ..addAll(next);
      });
    } catch (_) {}
  }

  Future<void> _pollReactive() async {
    try {
      final res = await http.get(
        Uri.parse('$_base/energyDetailsInfluxDb/power-load/current'),
        headers: AppConfig.headers,
      );
      if (res.statusCode != 200 || !mounted) return;
      final data = json.decode(res.body);
      final v = (data['power_kw'] as num?)?.toDouble() ?? (data['power_kW'] as num?)?.toDouble() ?? 0;
      if (v > 0) setState(() => _reactiveKvar = v.toStringAsFixed(0));
    } catch (_) {}
  }

  // ── Derived data ───────────────────────────────────────────────────────────
  List<_Pf> get _all {
    final out = <_Pf>[];
    for (final m in _visibleMachines) {
      final pf = _pfById[m.id] ?? 0;
      if (pf <= 0) continue;
      out.add(_Pf(m.id, m.name, pf, m.color, kw: _kwById[m.id] ?? 0));
    }
    return out;
  }

  double get _avgPf {
    final a = _all;
    if (a.isEmpty) return 0;
    return a.fold<double>(0, (s, p) => s + p.pf) / a.length;
  }

  /// Top 10 lowest PF among rankable machines (Influx kW ≥ 1).
  List<_Pf> get _culprits {
    final a = _rankable..sort((x, y) => x.pf.compareTo(y.pf));
    return a.take(10).toList();
  }

  /// Machines with known load ≥ 1 kW (or kW not yet sampled).
  List<_Pf> get _rankable => _all.where((p) {
        if (!_kwById.containsKey(p.id)) return true;
        if (_isAggregate(p)) return false;
        return p.kw >= 1.0;
      }).toList();

  /// Idle (&lt;1 kW) — shown grayed with IDLE badge, not ranked as culprits.
  List<_Pf> get _idleExcluded {
    final a = _all.where((p) {
      if (!_kwById.containsKey(p.id)) return false;
      if (_isAggregate(p)) return false;
      return p.kw < 1.0;
    }).toList()
      ..sort((x, y) => x.pf.compareTo(y.pf));
    return a;
  }

  List<_Pf> get _aggregateExcluded {
    final a = _all.where(_isAggregate).toList()
      ..sort((x, y) => x.pf.compareTo(y.pf));
    return a;
  }

  bool _isAggregate(_Pf p) {
    _PfMachine? m;
    for (final x in _allPfMachines) {
      if (x.id == p.id) {
        m = x;
        break;
      }
    }
    final type = (m?.equipmentType ?? '').toLowerCase();
    final name = p.name.toLowerCase();
    if (type.contains('aggregate') || type.contains('incomer') || type.contains('incoming')) {
      return true;
    }
    return name.contains('aggregate') ||
        name.contains('main incoming') ||
        name.contains('main incomer') ||
        RegExp(r'\bmsb\b').hasMatch(name);
  }

  int get _rankableCount => _rankable.length;

  /// Every configured machine — reporting devices first (lowest PF), then offline.
  List<_Pf> get _allSorted {
    final withPf = <_Pf>[];
    final offline = <_Pf>[];
    for (final m in _visibleMachines) {
      final pf = _pfById[m.id] ?? 0;
      final kw = _kwById[m.id] ?? 0;
      if (pf > 0) {
        withPf.add(_Pf(m.id, m.name, pf, m.color, kw: kw));
      } else {
        offline.add(_Pf(m.id, m.name, 0, m.color, kw: kw));
      }
    }
    withPf.sort((x, y) => x.pf.compareTo(y.pf));
    offline.sort((a, b) => a.name.compareTo(b.name));
    return [...withPf, ...offline];
  }

  int get _alertCount => _all.where((p) => p.pf < _kTarget).length;
  int get _total => _visibleMachines.length;
  _Pf? get _worst {
    if (_culprits.isNotEmpty) return _culprits.first;
    if (_all.isEmpty) return null;
    final a = [..._all]..sort((x, y) => x.pf.compareTo(y.pf));
    return a.first;
  }

  String _clock(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';
  String _date(DateTime t) {
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '${t.day.toString().padLeft(2, '0')} ${mo[t.month - 1]} ${t.year}';
  }

  void _showAllMachinesDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) {
        final list = _allSorted;
        return Dialog(
          backgroundColor: _kCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
            side: BorderSide(color: _kCardBorder),
          ),
          insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 820, maxHeight: 720),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text('All Machines',
                                style: GoogleFonts.poppins(fontSize: 18, fontWeight: FontWeight.w700, color: _kText)),
                            const SizedBox(height: 2),
                            Text('$_total machines · sorted by lowest PF',
                                style: GoogleFonts.poppins(fontSize: 12, color: _kMuted)),
                          ],
                        ),
                      ),
                      IconButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        icon: Icon(Icons.close_rounded, color: _kMuted, size: 22),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: _kCardBorder),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 6),
                  child: Row(
                    children: [
                      SizedBox(width: 36, child: Text('#', style: GoogleFonts.poppins(fontSize: 10, color: _kMuted2, fontWeight: FontWeight.w600))),
                      Expanded(child: Text('MACHINE', style: GoogleFonts.poppins(fontSize: 10, color: _kMuted2, fontWeight: FontWeight.w600))),
                      SizedBox(width: 70, child: Text('PF (AVG)', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 10, color: _kMuted2, fontWeight: FontWeight.w600))),
                      const SizedBox(width: 12),
                      SizedBox(width: 160, child: Text('TREND', textAlign: TextAlign.right, style: GoogleFonts.poppins(fontSize: 10, color: _kMuted2, fontWeight: FontWeight.w600))),
                    ],
                  ),
                ),
                Expanded(
                  child: _loading
                      ? _spinner()
                      : list.isEmpty
                          ? Center(child: Text('No machines configured', style: GoogleFonts.poppins(fontSize: 13, color: _kMuted)))
                          : ListView.separated(
                              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                              itemCount: list.length,
                              separatorBuilder: (_, __) => Divider(height: 1, color: _kCardBorder.withOpacity(0.5)),
                              itemBuilder: (_, i) {
                                final p = list[i];
                                final idle = _kwById.containsKey(p.id) && p.kw < 1.0 && !_isAggregate(p);
                                final agg = _isAggregate(p);
                                return _culpritRow(
                                  idle || agg ? null : (i + 1),
                                  p,
                                  idle: idle,
                                  aggregate: agg,
                                );
                              },
                            ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // This layout is built around a fixed viewport (percentages of the
    // available height, no scrolling) for a wide desktop/TV dashboard.
    // Below the tablet breakpoint that has nowhere to put 6 KPI cards plus
    // two full-height panels, so it switches to a scrollable, stacked
    // layout instead — same content, one column, each section given its
    // own reasonable height rather than a slice of the screen.
    return SizedBox.expand(
      child: ColoredBox(
        color: _kBg,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final bool narrow = constraints.maxWidth < kBreakpointMedium;

            if (narrow) {
              return SingleChildScrollView(
                padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(),
                    const SizedBox(height: 10),
                    _filterBar(),
                    const SizedBox(height: 12),
                    _kpiRow(),
                    const SizedBox(height: 12),
                    SizedBox(height: 420, child: _trendPanel()),
                    const SizedBox(height: 12),
                    SizedBox(height: 420, child: _culpritsPanel()),
                  ],
                ),
              );
            }

            final h = constraints.maxHeight;
            final kpiH = (h * 0.17).clamp(200.0, 240.0);
            return Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(16, 16, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _header(),
                  const SizedBox(height: 10),
                  _filterBar(),
                  const SizedBox(height: 12),
                  SizedBox(height: kpiH, child: _kpiRow()),
                  const SizedBox(height: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(flex: 11, child: _trendPanel()),
                        const SizedBox(width: 12),
                        Expanded(flex: 9, child: _culpritsPanel()),
                      ],
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // ── Header ─────────────────────────────────────────────────────────────────
  // Title/subtitle always sit on their own line, with the date/time, window
  // picker, icon buttons and customer pill always on a row underneath — that
  // toolbar alone demands ~450px, which left the title squeezed to nothing
  // (or the header overflowing outright) on a phone-width screen.
  Widget _header() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Power Factor Monitoring',
            style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: _kText)),
        const SizedBox(height: 2),
        Text('Real-time monitoring, trending and issue identification',
            style: GoogleFonts.poppins(fontSize: 12.5, color: _kMuted)),
        const SizedBox(height: 10),
        Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 10, runSpacing: 8, children: [
          Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 7, children: [
            Icon(Icons.calendar_today_outlined, size: 14, color: _kMuted),
            Text('${_date(_now)}   ${_clock(_now)}',
                style: GoogleFonts.poppins(fontSize: 13, color: _kText, fontWeight: FontWeight.w500)),
          ]),
          _menuPill<String>(
            value: _window,
            items: _windows,
            onSelected: (v) {
              setState(() => _window = v);
              _poll();
            },
          ),
          _iconBtn(Icons.refresh, onTap: () => _reloadFacilities()),
          Stack(clipBehavior: Clip.none, children: [
            _iconBtn(Icons.notifications_none_rounded),
            Positioned(
              right: -2, top: -2,
              child: Container(
                width: 15, height: 15,
                decoration: const BoxDecoration(color: _kRed, shape: BoxShape.circle),
                alignment: Alignment.center,
                child: Text('${math.min(_alertCount, 9)}',
                    style: GoogleFonts.poppins(fontSize: 9, color: Colors.white, fontWeight: FontWeight.w700)),
              ),
            ),
          ]),
          _customerPill(),
        ]),
      ],
    );
  }

  Widget _customerPill() => Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kCardBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.business_outlined, size: 15, color: _kMuted),
          const SizedBox(width: 6),
          Text(AppConfig.clientName.isNotEmpty ? AppConfig.clientName : 'Customer',
              style: GoogleFonts.poppins(fontSize: 12, color: _kText, fontWeight: FontWeight.w500)),
        ]),
      );

  Widget _filterBar() {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _multiFilterChip(
          label: 'Plant',
          options: _plantOptions,
          selected: _selPlants,
          onChanged: (s) => setState(() {
            _selPlants
              ..clear()
              ..addAll(s);
            _selZones.removeWhere((z) => !_zoneOptions.contains(z));
            _selProdAreas.removeWhere((p) => !_prodAreaOptions.contains(p));
            _selEquipments.removeWhere((e) => !_equipmentOptions.contains(e));
            _selDevices.removeWhere((d) => !_deviceOptions.contains(d));
          }),
        ),
        _multiFilterChip(
          label: 'Zone / Production Area',
          options: _zoneOptions,
          selected: _selZones,
          onChanged: (s) => setState(() {
            _selZones
              ..clear()
              ..addAll(s);
            _selProdAreas.removeWhere((p) => !_prodAreaOptions.contains(p));
            _selEquipments.removeWhere((e) => !_equipmentOptions.contains(e));
            _selDevices.removeWhere((d) => !_deviceOptions.contains(d));
          }),
        ),
        _multiFilterChip(
          label: 'Production Line',
          options: _prodAreaOptions,
          selected: _selProdAreas,
          onChanged: (s) => setState(() {
            _selProdAreas
              ..clear()
              ..addAll(s);
            _selEquipments.removeWhere((e) => !_equipmentOptions.contains(e));
            _selDevices.removeWhere((d) => !_deviceOptions.contains(d));
          }),
        ),
        _multiFilterChip(
          label: 'Equipment',
          options: _equipmentOptions,
          selected: _selEquipments,
          onChanged: (s) => setState(() {
            _selEquipments
              ..clear()
              ..addAll(s);
            _selDevices.removeWhere((d) => !_deviceOptions.contains(d));
          }),
        ),
        _multiFilterChip(
          label: 'Devices',
          options: _deviceOptions,
          selected: _selDevices,
          displayBuilder: (id) => _nameFor(id),
          onChanged: (s) => setState(() {
            _selDevices
              ..clear()
              ..addAll(s);
          }),
        ),
        if (_hasActiveFilters)
          InkWell(
            onTap: _clearFilters,
            borderRadius: BorderRadius.circular(6),
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: _kRed.withOpacity(0.1),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: _kRed.withOpacity(0.35)),
              ),
              child: Row(mainAxisSize: MainAxisSize.min, children: [
                Icon(Icons.filter_alt_off_rounded, size: 14, color: _kRed),
                const SizedBox(width: 5),
                Text('Clear', style: GoogleFonts.poppins(fontSize: 11, color: _kRed, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
        Text('${_visibleMachines.length} / ${_allPfMachines.length} in PF Analytics',
            style: GoogleFonts.poppins(fontSize: 11, color: _kMuted)),
      ],
    );
  }

  Widget _multiFilterChip({
    required String label,
    required List<String> options,
    required Set<String> selected,
    required ValueChanged<Set<String>> onChanged,
    String Function(String)? displayBuilder,
  }) {
    final count = selected.length;
    final caption = count == 0 ? '$label: All' : '$label ($count)';
    return PopupMenuButton<String>(
      tooltip: 'Select $label',
      color: _kCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: _kCardBorder)),
      onSelected: (val) {
        final next = Set<String>.from(selected);
        if (next.contains(val)) {
          next.remove(val);
        } else {
          next.add(val);
        }
        onChanged(next);
      },
      itemBuilder: (ctx) => [
        PopupMenuItem(
          enabled: false,
          height: 36,
          child: Text('Toggle $label', style: GoogleFonts.poppins(fontSize: 11, color: _kMuted, fontWeight: FontWeight.w600)),
        ),
        for (final opt in options)
          CheckedPopupMenuItem<String>(
            value: opt,
            checked: selected.contains(opt),
            child: Text(
              displayBuilder?.call(opt) ?? opt,
              style: GoogleFonts.poppins(fontSize: 12, color: _kText),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        if (options.isEmpty)
          PopupMenuItem(
            enabled: false,
            child: Text('No options', style: GoogleFonts.poppins(fontSize: 11, color: _kMuted)),
          ),
      ],
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(
          color: count > 0 ? const Color(0xFF2563EB).withOpacity(0.15) : _kCard,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: count > 0 ? const Color(0xFF2563EB).withOpacity(0.5) : _kCardBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(caption, style: GoogleFonts.poppins(fontSize: 11, color: count > 0 ? const Color(0xFF60A5FA) : _kText, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: _kMuted),
        ]),
      ),
    );
  }

  Widget _menuPill<T>({required T value, required List<T> items, required ValueChanged<T> onSelected}) {
    return PopupMenuButton<T>(
      onSelected: onSelected,
      color: _kCard,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: _kCardBorder)),
      itemBuilder: (_) => [
        for (final it in items)
          PopupMenuItem<T>(
            value: it,
            child: Text('$it', style: GoogleFonts.poppins(fontSize: 12.5, color: _kText)),
          ),
      ],
      child: Container(
        height: 36,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: _kCard,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _kCardBorder),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text('$value', style: GoogleFonts.poppins(fontSize: 12.5, color: _kText)),
          const SizedBox(width: 8),
          Icon(Icons.keyboard_arrow_down, size: 16, color: _kMuted),
        ]),
      ),
    );
  }

  Widget _iconBtn(IconData icon, {VoidCallback? onTap}) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 36, height: 36,
          decoration: BoxDecoration(
            color: _kCard,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _kCardBorder),
          ),
          child: Icon(icon, size: 18, color: _kMuted),
        ),
      );

  // ── KPI row ────────────────────────────────────────────────────────────────
  Widget _kpiRow() {
    final avg = _avgPf;
    final worst = _worst;
    final alertPct = _total > 0 ? _alertCount / _total * 100 : 0.0;
    final cards = [
      _cardShell(child: _avgCard(avg)),
      _cardShell(child: _reactiveCard()),
      _cardShell(child: _statusCard(avg)),
      _cardShell(child: _alertCard(alertPct)),
      _cardShell(child: _worstCard(worst)),
      _cardShell(child: _qualityCard()),
    ];
    // 6 Expanded columns squeeze into unreadable slivers below the tablet
    // breakpoint — lay them out as a 2-column wrap instead, each card kept
    // at a readable height rather than sharing a slice of the KPI strip.
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < kBreakpointMedium) {
        final cardWidth = (constraints.maxWidth - 12) / 2;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [for (final c in cards) SizedBox(width: cardWidth, height: 150, child: c)],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (int i = 0; i < cards.length; i++) ...[
            if (i > 0) const SizedBox(width: 12),
            Expanded(child: cards[i]),
          ],
        ],
      );
    });
  }

  Widget _cardShell({required Widget child}) => Container(
        clipBehavior: Clip.hardEdge,
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: _glass,
        child: child,
      );

  Widget _kpiTitle(String t) => Text(t,
      style: GoogleFonts.poppins(fontSize: 11, color: _kMuted, fontWeight: FontWeight.w600, letterSpacing: 0.4));

  Widget _avgCard(double avg) {
    final ok = avg >= _kTarget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _kpiTitle('AVERAGE POWER FACTOR')),
        const SizedBox(height: 2),
        Expanded(
          child: CustomPaint(
            painter: _GaugePainter(avg <= 0 ? 0.70 : avg.clamp(0.70, 1.0),
                trackColor: _kCardBorder, needleColor: _kText),
            child: Center(
              child: Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(avg > 0 ? avg.toStringAsFixed(2) : '—',
                    style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w700, color: _pfColor(avg))),
              ),
            ),
          ),
        ),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('0.70', style: GoogleFonts.poppins(fontSize: 8, color: _kMuted2)),
          Text('1.00', style: GoogleFonts.poppins(fontSize: 8, color: _kMuted2)),
        ]),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text('Target ≥ ${_kTarget.toStringAsFixed(2)}',
              style: GoogleFonts.poppins(fontSize: 9, color: _kMuted), maxLines: 1),
        ),
        const SizedBox(height: 2),
        Align(
          alignment: Alignment.centerRight,
          child: _tag(ok ? 'On Target' : 'Below Target', ok ? _kGreen : _kOrange),
        ),
      ],
    );
  }

  Widget _reactiveCard() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kpiTitle('REACTIVE POWER'),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text(_reactiveFmt, style: GoogleFonts.poppins(fontSize: 24, fontWeight: FontWeight.w700, color: _kBlue)),
            const SizedBox(width: 4),
            Text('kVAr', style: GoogleFonts.poppins(fontSize: 11, color: _kMuted, fontWeight: FontWeight.w500)),
          ]),
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.arrow_upward, size: 10, color: _kRed),
            const SizedBox(width: 3),
            Text('vs Yesterday', style: GoogleFonts.poppins(fontSize: 9, color: _kMuted)),
          ]),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: ClipRect(child: CustomPaint(painter: _SparkPainter(_reactiveSpark(), _kBlue))),
        ),
      ],
    );
  }

  String get _reactiveFmt {
    final v = double.tryParse(_reactiveKvar);
    if (v == null) return _reactiveKvar;
    return v.toStringAsFixed(0).replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]},');
  }

  List<double> _reactiveSpark() {
    final base = double.tryParse(_reactiveKvar) ?? 400;
    final r = math.Random(7);
    return List.generate(24, (i) => base * (0.85 + 0.3 * r.nextDouble()));
  }

  Widget _statusCard(double avg) {
    final ok = avg >= _kTarget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kpiTitle('PF STATUS'),
        const SizedBox(height: 8),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(ok ? Icons.check_circle : Icons.warning_amber_rounded, size: 32, color: ok ? _kGreen : _kOrange),
            const SizedBox(width: 8),
            Text(ok ? 'On Target' : 'Below Target',
                style: GoogleFonts.poppins(fontSize: 22, fontWeight: FontWeight.w800, color: ok ? _kGreen : _kOrange)),
          ]),
        ),
        const Spacer(),
        _kv('Machines', '$_alertCount below target'),
        const SizedBox(height: 4),
        _kv('Target', '≥ ${_kTarget.toStringAsFixed(2)} PF'),
      ],
    );
  }

  Widget _alertCard(double pct) {
    final g = _all.where((p) => p.pf >= _kWarning).length;
    final y = _all.where((p) => p.pf >= _kAlarm && p.pf < _kWarning).length;
    final r = _all.where((p) => p.pf < _kAlarm).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kpiTitle('MACHINES IN ALERT'),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
            Text('$_alertCount', style: GoogleFonts.poppins(fontSize: 36, fontWeight: FontWeight.w800, color: _kRed)),
            Text(' / $_total', style: GoogleFonts.poppins(fontSize: 20, color: _kMuted, fontWeight: FontWeight.w600)),
          ]),
        ),
        const SizedBox(height: 4),
        Text('${pct.toStringAsFixed(1)}% of monitored machines',
            style: GoogleFonts.poppins(fontSize: 12, color: _kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
        const Spacer(),
        ClipRRect(
          borderRadius: BorderRadius.circular(3),
          child: Row(children: [
            Expanded(flex: r, child: Container(height: 6, color: _kRed)),
            Expanded(flex: y, child: Container(height: 6, color: _kYellow)),
            Expanded(flex: g == 0 && y == 0 && r == 0 ? 1 : g, child: Container(height: 6, color: _kGreen)),
          ]),
        ),
      ],
    );
  }

  Widget _worstCard(_Pf? w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _kpiTitle('WORST PF (MACHINE)'),
        const SizedBox(height: 6),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(w != null ? w.pf.toStringAsFixed(2) : '—',
              style: GoogleFonts.poppins(fontSize: 36, fontWeight: FontWeight.w800, color: w != null ? _pfColor(w.pf) : _kMuted)),
        ),
        const SizedBox(height: 4),
        Text(w?.name ?? '—',
            maxLines: 1, overflow: TextOverflow.ellipsis,
            style: GoogleFonts.poppins(fontSize: 13, color: _kText, fontWeight: FontWeight.w600)),
        const Spacer(),
        _kv('Time', _clock(_now)),
      ],
    );
  }

  Widget _qualityCard() {
    final reporting = _all.length;
    final ok = reporting >= _total * 0.8 && _total > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(child: _kpiTitle('DATA QUALITY')),
        const SizedBox(height: 6),
        Expanded(
          child: Center(
            child: Icon(ok ? Icons.check_circle_outline : Icons.error_outline, size: 52, color: ok ? _kGreen : _kOrange),
          ),
        ),
        Center(
          child: Text(ok ? 'Good' : 'Degraded',
              style: GoogleFonts.poppins(fontSize: 20, fontWeight: FontWeight.w800, color: ok ? _kGreen : _kOrange)),
        ),
        const SizedBox(height: 4),
        Center(child: Text('$reporting / $_total online', style: GoogleFonts.poppins(fontSize: 12, color: _kMuted))),
        Center(
          child: Text(ok ? 'No data gap' : 'Some devices offline',
              style: GoogleFonts.poppins(fontSize: 11, color: _kMuted), maxLines: 1, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  Widget _kv(String k, String v) => Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Text('$k ', style: GoogleFonts.poppins(fontSize: 11, color: _kMuted)),
          Expanded(
            child: Text(v,
                maxLines: 1, overflow: TextOverflow.ellipsis,
                style: GoogleFonts.poppins(fontSize: 11.5, color: _kText, fontWeight: FontWeight.w600)),
          ),
        ],
      );

  Widget _tag(String t, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: c.withOpacity(0.14), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withOpacity(0.4))),
        child: Text(t, style: GoogleFonts.poppins(fontSize: 10, color: c, fontWeight: FontWeight.w600)),
      );

  // ── Trend panel ────────────────────────────────────────────────────────────
  Widget _trendPanel() {
    final visible = _visibleIds;
    final ids = _trendSeries.keys.where((id) {
      if (visible.contains(id)) return true;
      final resolved = _resolveMachineId(id);
      return resolved != null && visible.contains(resolved);
    }).toList()
      ..sort((a, b) => (_pfById[a] ?? _pfById[_resolveMachineId(a) ?? ''] ?? 1).compareTo(_pfById[b] ?? _pfById[_resolveMachineId(b) ?? ''] ?? 1));
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: _glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('POWER FACTOR TREND', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            const SizedBox(width: 6),
            Icon(Icons.info_outline, size: 14, color: _kMuted2),
            const Spacer(),
            Flexible(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: _rangeToggle())),
          ]),
          const SizedBox(height: 8),
          Expanded(
            child: (_loadingTrend && _trendSeries.isEmpty)
                ? _spinner()
                : Padding(
                    padding: const EdgeInsets.only(right: 4, bottom: 2),
                    child: _trendChart(ids),
                  ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 56,
            child: ids.isEmpty
                ? Align(alignment: Alignment.centerLeft, child: Text('No devices match filters.', style: GoogleFonts.poppins(fontSize: 11, color: _kMuted)))
                : Scrollbar(
                    thumbVisibility: true,
                    child: SingleChildScrollView(child: _legend(ids)),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _rangeToggle() => Container(
        padding: const EdgeInsets.all(3),
        decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(8), border: Border.all(color: _kCardBorder)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final r in _ranges)
            InkWell(
              onTap: _range == r
                  ? null
                  : () {
                      setState(() => _range = r);
                      _fetchTrend();
                    },
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: _range == r ? const Color(0xFF2563EB) : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(r, style: GoogleFonts.poppins(fontSize: 10.5, color: _range == r ? Colors.white : _kMuted, fontWeight: FontWeight.w600)),
              ),
            ),
        ]),
      );

  Widget _trendChart(List<String> ids) {
    final len = _trendLabels.length;
    if (len < 1 || ids.isEmpty) {
      return Center(child: Text('No trend data for this window.', style: GoogleFonts.poppins(fontSize: 12, color: _kMuted)));
    }
    const minY = 0.70;
    const maxY = 1.00;
    const step = 0.05;

    final bars = <LineChartBarData>[];
    for (final id in ids) {
      final h = _trendSeries[id];
      if (h == null || h.isEmpty) continue;
      final spots = <FlSpot>[];
      for (var i = 0; i < h.length; i++) {
        if (!h[i].isNaN) spots.add(FlSpot(i.toDouble(), h[i].clamp(minY, maxY)));
      }
      if (spots.isEmpty) continue;
      bars.add(LineChartBarData(
        spots: spots,
        isCurved: true,
        preventCurveOverShooting: true,
        color: _colorFor(id),
        barWidth: 1.4,
        dotData: const FlDotData(show: false),
      ));
    }
    if (bars.isEmpty) {
      return Center(child: Text('No trend data for this window.', style: GoogleFonts.poppins(fontSize: 12, color: _kMuted)));
    }
    return LineChart(LineChartData(
      minX: 0, maxX: (len - 1).clamp(0, 999).toDouble(), minY: minY, maxY: maxY,
      clipData: const FlClipData.all(),
      gridData: FlGridData(
        show: true, drawVerticalLine: false, horizontalInterval: step,
        getDrawingHorizontalLine: (_) => FlLine(color: _kCardBorder.withOpacity(0.6), strokeWidth: 1),
      ),
      borderData: FlBorderData(show: false),
      titlesData: FlTitlesData(
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true,
          reservedSize: 96,
          interval: step,
          getTitlesWidget: (v, _) {
            Widget label(String text, Color c) => Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        boxShadow: [BoxShadow(color: c.withOpacity(0.55), blurRadius: 6)],
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(text, style: GoogleFonts.poppins(fontSize: 11, color: c, fontWeight: FontWeight.w700)),
                  ],
                );
            if ((v - _kTarget).abs() < 0.001) {
              return label('${_kTarget.toStringAsFixed(2)} Target', _kGreen);
            }
            if ((v - _kWarning).abs() < 0.001) {
              return label('${_kWarning.toStringAsFixed(2)} Warning', _kYellow);
            }
            if ((v - _kAlarm).abs() < 0.001) {
              return label('${_kAlarm.toStringAsFixed(2)} Alarm', _kRed);
            }
            return const SizedBox.shrink();
          },
        )),
        leftTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 32, interval: step,
          getTitlesWidget: (v, _) => Text(v.toStringAsFixed(2), style: GoogleFonts.poppins(fontSize: 9, color: _kMuted2)),
        )),
        bottomTitles: AxisTitles(sideTitles: SideTitles(
          showTitles: true, reservedSize: 20, interval: _trendBottomInterval(len),
          getTitlesWidget: (v, _) {
            final i = v.round();
            if (i < 0 || i >= _trendLabels.length) return const SizedBox.shrink();
            return Padding(padding: const EdgeInsets.only(top: 2), child: Text(_trendLabels[i], style: GoogleFonts.poppins(fontSize: 8.5, color: _kMuted2)));
          },
        )),
      ),
      extraLinesData: ExtraLinesData(horizontalLines: [
        _thresh(_kTarget, _kGreen, ''),
        _thresh(_kWarning, _kYellow, ''),
        _thresh(_kAlarm, _kRed, ''),
      ]),
      lineBarsData: bars,
      lineTouchData: LineTouchData(
        enabled: true,
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (spots) => spots.map((s) {
            final i = s.x.round();
            final label = (i >= 0 && i < _trendLabels.length) ? _trendLabels[i] : '';
            return LineTooltipItem('${s.y.toStringAsFixed(3)}\n$label', GoogleFonts.poppins(fontSize: 10, color: Colors.white));
          }).toList(),
        ),
      ),
    ));
  }

  HorizontalLine _thresh(double y, Color c, String label) => HorizontalLine(
        y: y,
        color: c.withOpacity(0.85),
        strokeWidth: 1.6,
        dashArray: [6, 4],
        label: label.isEmpty
            ? null
            : HorizontalLineLabel(
                show: true,
                alignment: Alignment.centerRight,
                padding: const EdgeInsets.only(right: 2),
                style: GoogleFonts.poppins(fontSize: 11, color: c, fontWeight: FontWeight.w700),
                labelResolver: (_) => label,
              ),
      );

  Widget _legend(List<String> ids) => Wrap(
        spacing: 12, runSpacing: 6,
        children: [
          for (final id in ids)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _colorFor(id),
                  borderRadius: BorderRadius.circular(3),
                  boxShadow: [BoxShadow(color: _colorFor(id).withOpacity(0.45), blurRadius: 4)],
                ),
              ),
              const SizedBox(width: 5),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(_nameFor(id),
                    maxLines: 1, overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 11, color: _kMuted)),
              ),
            ]),
        ],
      );

  // ── Culprits panel ─────────────────────────────────────────────────────────
  Widget _culpritsPanel() {
    final ranked = _culprits;
    final idle = _idleExcluded;
    final aggregates = _aggregateExcluded;
    // Ranked first, then idle (gray IDLE badge), then aggregates (AGGREGATE badge).
    final rows = <({int? rank, _Pf p, bool idle, bool aggregate})>[
      for (var i = 0; i < ranked.length; i++)
        (rank: i + 1, p: ranked[i], idle: false, aggregate: false),
      for (final p in idle) (rank: null, p: p, idle: true, aggregate: false),
      for (final p in aggregates) (rank: null, p: p, idle: false, aggregate: true),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
      decoration: _glass,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Text('TOP 10 PF CULPRITS ', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: _kText)),
            Expanded(
              child: Text('(LOWEST PF · idle <1 kW excluded from rank)',
                  style: GoogleFonts.poppins(fontSize: 11, color: _kMuted),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
            ),
          ]),
          const SizedBox(height: 10),
          Row(children: [
            const SizedBox(width: 26),
            const Expanded(child: SizedBox.shrink()),
            SizedBox(width: 56, child: Text('PF', textAlign: TextAlign.center, style: GoogleFonts.poppins(fontSize: 9.5, color: _kMuted2, fontWeight: FontWeight.w600))),
            SizedBox(width: 64, child: Text('INFLUX kW', textAlign: TextAlign.right, style: GoogleFonts.poppins(fontSize: 9.5, color: _kMuted2, fontWeight: FontWeight.w600))),
            const SizedBox(width: 8),
            SizedBox(
              width: 110,
              child: Text('TREND', textAlign: TextAlign.right, style: GoogleFonts.poppins(fontSize: 9.5, color: _kMuted2, fontWeight: FontWeight.w600)),
            ),
          ]),
          const SizedBox(height: 4),
          Expanded(
            child: _loading
                ? _spinner()
                : rows.isEmpty
                    ? Center(child: Text('No data', style: GoogleFonts.poppins(fontSize: 12, color: _kMuted)))
                    : Scrollbar(
                        thumbVisibility: true,
                        child: ListView.separated(
                          padding: EdgeInsets.zero,
                          itemCount: rows.length,
                          separatorBuilder: (_, __) => Divider(height: 1, color: _kCardBorder.withOpacity(0.5)),
                          itemBuilder: (_, i) {
                            final r = rows[i];
                            return _culpritRow(
                              r.rank,
                              r.p,
                              idle: r.idle,
                              aggregate: r.aggregate,
                            );
                          },
                        ),
                      ),
          ),
          const SizedBox(height: 6),
          Center(
            child: InkWell(
              onTap: _showAllMachinesDialog,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                child: Text('View All $_rankableCount Rankable Machines  →',
                    style: GoogleFonts.poppins(fontSize: 11, color: _kBlue, fontWeight: FontWeight.w600)),
              ),
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _statusChip(String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: const Color(0xFF334155).withOpacity(0.85),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: _kMuted2.withOpacity(0.35)),
        ),
        child: Text(
          text,
          style: GoogleFonts.poppins(fontSize: 9.5, color: _kMuted, fontWeight: FontWeight.w600, letterSpacing: 0.2),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      );

  Widget _culpritRow(int? rank, _Pf p, {bool idle = false, bool aggregate = false}) {
    final muted = idle || aggregate;
    final nameColor = muted ? _kMuted2 : _kText;
    final pfColor = muted ? _kMuted2 : (p.pf > 0 ? _pfColor(p.pf) : _kMuted);
    final kwTxt = p.kw > 0 ? p.kw.toStringAsFixed(p.kw >= 100 ? 0 : 1) : '—';
    final idleKw = p.kw > 0 ? p.kw.toStringAsFixed(1) : '0';
    return Opacity(
      opacity: muted ? 0.72 : 1,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Row(children: [
          SizedBox(
            width: 20,
            child: Text(rank != null ? '$rank' : '—',
                style: GoogleFonts.poppins(fontSize: 11, color: _kMuted2, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Row(
              children: [
                Flexible(
                  child: Text(
                    p.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.poppins(fontSize: 12, color: nameColor, fontWeight: FontWeight.w500),
                  ),
                ),
                if (idle) ...[
                  const SizedBox(width: 6),
                  _statusChip('IDLE · ${idleKw}kW'),
                ],
                if (aggregate) ...[
                  const SizedBox(width: 6),
                  _statusChip('AGGREGATE'),
                ],
              ],
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(p.pf > 0 ? p.pf.toStringAsFixed(2) : '—', textAlign: TextAlign.center,
                style: GoogleFonts.poppins(fontSize: 12.5, color: pfColor, fontWeight: FontWeight.w700)),
          ),
          SizedBox(
            width: 64,
            child: Text(kwTxt, textAlign: TextAlign.right,
                style: GoogleFonts.poppins(fontSize: 11.5, color: _kMuted, fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 8),
          SizedBox(
            width: 110,
            child: (!muted && p.pf > 0) ? _culpritTrend(p.id, p.pf) : const SizedBox.shrink(),
          ),
        ]),
      ),
    );
  }

  Widget _culpritTrend(String id, double pf) {
    final series = _trendSeries[id];
    if (series != null && series.where((v) => !v.isNaN).length >= 2) {
      final vals = [for (final v in series) v.isNaN ? pf : v];
      return SizedBox(height: 16, child: CustomPaint(painter: _PfSparkPainter(vals, _pfColor(pf))));
    }
    return _trendBar(pf);
  }

  Widget _trendBar(double pf) {
    // Bar spans PF 0.70→1.00; fill proportional, colored by threshold, with a
    // dashed target marker at 0.95 (matches the mockup).
    const lo = 0.70, hi = 1.00;
    final frac = ((pf - lo) / (hi - lo)).clamp(0.0, 1.0);
    final targetFrac = (_kTarget - lo) / (hi - lo);
    return LayoutBuilder(builder: (_, c) {
      final w = c.maxWidth;
      return SizedBox(
        height: 16,
        child: Stack(children: [
          Container(decoration: BoxDecoration(color: _kBg, borderRadius: BorderRadius.circular(3))),
          FractionallySizedBox(
            widthFactor: frac,
            child: Container(decoration: BoxDecoration(color: _pfColor(pf), borderRadius: BorderRadius.circular(3))),
          ),
          Positioned(
            left: w * targetFrac, top: 0, bottom: 0,
            child: Container(width: 1.4, color: _kMuted),
          ),
        ]),
      );
    });
  }

  Widget _spinner() => const Center(child: SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2, color: _kBlue)));
}

// ── PF sparkline (culprit row) ─────────────────────────────────────────────
class _PfSparkPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _PfSparkPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final vals = data.where((v) => v > 0).toList();
    if (vals.length < 2) return;
    const lo = 0.70, hi = 1.00;
    final dx = size.width / (vals.length - 1);
    final path = Path();
    for (var i = 0; i < vals.length; i++) {
      final x = dx * i;
      final y = size.height - ((vals[i].clamp(lo, hi) - lo) / (hi - lo)) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = color);
  }

  @override
  bool shouldRepaint(covariant _PfSparkPainter old) => old.data != data;
}

// ── Gauge painter ──────────────────────────────────────────────────────────
class _GaugePainter extends CustomPainter {
  final double value; // 0.70..1.00
  final Color trackColor;
  final Color needleColor;
  _GaugePainter(this.value, {required this.trackColor, required this.needleColor});

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height - 6);
    final r = math.min(size.width / 2 - 6, size.height - 14);
    const start = math.pi; // 180°
    const sweep = math.pi; // half circle
    final t = ((value - 0.70) / 0.30).clamp(0.0, 1.0);

    // Track
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep, false,
        Paint()..style = PaintingStyle.stroke..strokeWidth = 9..strokeCap = StrokeCap.round..color = trackColor);

    // Gradient value arc (red→amber→green)
    final grad = SweepGradient(
      startAngle: start, endAngle: start + sweep,
      colors: const [_kRed, _kOrange, _kYellow, _kGreen],
      stops: const [0.0, 0.4, 0.6, 1.0],
    );
    canvas.drawArc(Rect.fromCircle(center: c, radius: r), start, sweep * t, false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 9
          ..strokeCap = StrokeCap.round
          ..shader = grad.createShader(Rect.fromCircle(center: c, radius: r)));

    // Needle
    final ang = start + sweep * t;
    final tip = Offset(c.dx + (r - 4) * math.cos(ang), c.dy + (r - 4) * math.sin(ang));
    canvas.drawLine(c, tip, Paint()..color = needleColor..strokeWidth = 2..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, 3.5, Paint()..color = needleColor);
  }

  @override
  bool shouldRepaint(covariant _GaugePainter old) => old.value != value;
}

// ── Sparkline painter ──────────────────────────────────────────────────────
class _SparkPainter extends CustomPainter {
  final List<double> data;
  final Color color;
  _SparkPainter(this.data, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    if (data.length < 2) return;
    final lo = data.reduce(math.min), hi = data.reduce(math.max);
    final span = (hi - lo).abs() < 1e-6 ? 1.0 : hi - lo;
    final dx = size.width / (data.length - 1);
    final path = Path();
    for (var i = 0; i < data.length; i++) {
      final x = dx * i;
      final y = size.height - ((data[i] - lo) / span) * size.height;
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    canvas.drawPath(path, Paint()..style = PaintingStyle.stroke..strokeWidth = 1.6..color = color..strokeJoin = StrokeJoin.round);
    final fill = Path.from(path)..lineTo(size.width, size.height)..lineTo(0, size.height)..close();
    canvas.drawPath(fill, Paint()..color = color.withOpacity(0.12));
  }

  @override
  bool shouldRepaint(covariant _SparkPainter old) => old.data != data;
}
