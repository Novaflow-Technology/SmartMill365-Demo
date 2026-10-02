import 'dart:async';

import 'package:flutter/material.dart';

import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/nav/nav.dart';
import '/flutter_flow/rbac.dart';
import 'station_models.dart';
import 'station_service.dart';
import 'station_view.dart';

/// Equipment Monitoring → Sterilizer / Digester. One card per equipment in
/// the station's category, with live readings, an overview and a trend.
class StationPageWidget extends StatefulWidget {
  const StationPageWidget({super.key, required this.stationKey});
  final String stationKey;

  @override
  State<StationPageWidget> createState() => _StationPageWidgetState();
}

class _StationPageWidgetState extends State<StationPageWidget> {
  late final StationDef _st = stationByKey(widget.stationKey) ?? kSterilizerStation;
  StationSettings? _s;
  List<Map<String, dynamic>> _equipment = [];
  List<StationLine> _lines = [];
  final Map<String, List<TrendPoint>> _trend = {};
  DateTime? _updated;
  String _range = '6h';
  bool _combined = true;
  bool _loading = true;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    final r = await Future.wait([StationService.equipmentFor(_st), StationService.loadSettings(_st)]);
    if (!mounted) return;
    _equipment = r[0] as List<Map<String, dynamic>>;
    final s = r[1] as StationSettings;
    setState(() {
      _s = s;
      _range = s.defaultRange;
      _lines = buildLines(_equipment, s);
    });
    _restartTimer();
    await _refresh();
    await _loadTrend();
    if (mounted) setState(() => _loading = false);
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(Duration(seconds: _s?.refreshSec ?? 10), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final s = _s;
    if (s == null) return;
    final devices = devicesOf(_lines, _st);
    final latest = <String, Map<String, double>>{};
    await Future.wait(devices.map((d) async => latest[d] = await StationService.latest(d)));
    if (!mounted) return;
    setState(() {
      evaluateLines(_lines, s, latest);
      _updated = DateTime.now();
    });
  }

  Future<void> _loadTrend() async {
    final window = _range == '1h' ? '1m' : _range == '6h' ? '5m' : '15m';
    final out = <String, List<TrendPoint>>{};
    await Future.wait(_lines.map((l) async {
      final src = l.source(_st, _st.mainPoint);
      if (src != null && src.isSet) out[l.id] = await StationService.history(src, start: '-$_range', window: window);
    }));
    if (mounted) {
      setState(() => _trend
        ..clear()
        ..addAll(out));
    }
  }

  String get _site {
    for (final l in _lines) {
      final src = l.source(_st, _st.mainPoint);
      if (src != null && src.isSet) return src.device;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final s = _s;
    final canSet = AppRoles.canAccess(AppStateNotifier.instance.userRole, AppRoles.kModuleKanbanDashboardSettings);
    return Container(
      color: const Color(0xFF061126),
      child: s == null || _loading
          ? const Center(child: CircularProgressIndicator(color: SC.accent))
          : SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 32),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (_lines.any((l) => l.isSample))
                  Container(
                    margin: const EdgeInsets.only(bottom: 10),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: BoxDecoration(
                      color: SC.accent.withOpacity(.08),
                      borderRadius: BorderRadius.circular(9),
                      border: Border.all(color: SC.accent.withOpacity(.35)),
                    ),
                    child: Text(
                      'Showing sample lines on the live ${_st.mainPart.toLowerCase()} devices. Add equipment with the '
                      '"${_st.mainPart}" category in Equipment Settings to show your own lines.',
                      style: const TextStyle(color: SC.text, fontSize: 12.5),
                    ),
                  ),
                StationView(
                settings: s,
                lines: _lines,
                trend: _trend,
                updated: _updated,
                range: _range,
                combined: _combined,
                siteName: _site,
                onRange: (r) {
                  setState(() => _range = r);
                  _loadTrend();
                },
                onCombined: (c) => setState(() => _combined = c),
                onRefreshSec: (sec) {
                  setState(() => s.refreshSec = sec);
                  _restartTimer();
                },
                onStation: (k) {
                  if (k != _st.key) context.goNamed(k == 'digester' ? 'DigesterStation' : 'SterilizerStation');
                },
                onSettings: canSet
                    ? () => context.pushNamed('StationPageSetting', queryParameters: {'station': _st.key}).then((_) => _load())
                    : null,
              ),
              ]),
            ),
    );
  }
}
