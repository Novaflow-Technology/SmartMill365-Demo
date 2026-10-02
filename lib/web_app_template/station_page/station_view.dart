import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import 'station_models.dart';
import 'station_service.dart';

/// Our palette — the same navy panels, cyan accent and status colours as the
/// POM Energy Command Center, so the station pages sit in the same family.
class SC {
  static const panelTop = Color(0xFF0C2146);
  static const panelBottom = Color(0xFF081733);
  static const inner = Color(0xFF06122A);
  static const border = Color(0xFF1C3A6B);
  static const borderStrong = Color(0xFF24508F);
  static const text = Color(0xFFCFE0FF);
  static const dim = Color(0xFF7F97BF);
  static const faint = Color(0xFF6B7FA3);
  static const accent = Color(0xFF3EC6FF);
  static const run = Color(0xFF2FD27A);
  static const stop = Color(0xFFF25555);
  static const warn = Color(0xFFF5B82E);
  static const idle = Color(0xFF94A3B8);
  static const chart = [
    Color(0xFF2FD27A), Color(0xFFA78BFA), Color(0xFFF5B82E), Color(0xFF3EC6FF),
    Color(0xFFF472B6), Color(0xFF60A5FA), Color(0xFFFACC15), Color(0xFFFB7185),
  ];

  static BoxDecoration panel({Color? border, double radius = 12}) => BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [panelTop, panelBottom]),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: border ?? SC.border, width: border == null ? 1 : 1.5),
        boxShadow: [BoxShadow(color: (border ?? const Color(0xFF1E8CFF)).withOpacity(.12), blurRadius: 12)],
      );

  static const label = TextStyle(color: dim, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600);
}

enum LineStatus { running, partial, stopped, unmapped }

/// One line (equipment) with its live values worked out.
class StationLine {
  StationLine(this.equipment, this.setting, this.index, {this.isSample = false});
  final Map<String, dynamic> equipment;
  final LineSetting setting;
  final int index;

  /// A stand-in line shown while no equipment is in the category yet.
  final bool isSample;
  final Map<String, double?> values = {};

  /// Points whose value is a sample, not live data.
  final Set<String> sampled = {};
  LineStatus status = LineStatus.unmapped;
  String? alert;

  String get id => equipment['id']?.toString() ?? '';
  String get name => equipment['name']?.toString() ?? id;

  /// The number in the equipment name ("Digester 3" → 3), else its position.
  int get number {
    final m = RegExp(r'(\d+)(?!.*\d)').firstMatch(name);
    return int.tryParse(m?.group(1) ?? '') ?? index + 1;
  }

  String subName(StationDef st) {
    if (setting.subName.trim().isNotEmpty) return setting.subName.trim();
    final sub = st.subPart;
    if (sub == null) return (equipment['equipment_id'] ?? equipment['serialNo'] ?? '').toString();
    return '${sub.split(' ').last[0].toUpperCase()}${sub.split(' ').last.substring(1)} $number';
  }

  bool mapped(String key) => setting.sources[key]?.isSet == true;

  /// The line's own mapping, else the station's default live source.
  PointSource? source(StationDef st, String key) {
    final own = setting.sources[key];
    if (own != null && own.isSet) return own;
    return st.defaultSource(key, number);
  }

  bool has(String key) => values[key] != null;
  bool get anySample => isSample || sampled.isNotEmpty;
}

/// Lines of [equipment] in the settings' order, with only shown ones.
List<StationLine> buildLines(List<Map<String, dynamic>> equipment, StationSettings s, {bool includeHidden = false}) {
  if (equipment.isEmpty) {
    // Nothing in the category yet: stand-in lines on the live devices.
    return [
      for (var i = 0; i < s.station.sampleLines; i++)
        StationLine({'id': 'sample-${i + 1}', 'name': '${s.station.mainPart} ${i + 1}'}, LineSetting(), i, isSample: true),
    ];
  }
  final lines = [for (final (i, e) in equipment.indexed) StationLine(e, s.line(e['id'].toString()), i)];
  lines.sort((a, b) => (a.setting.order ?? a.index * 1000).compareTo(b.setting.order ?? b.index * 1000));
  return includeHidden ? lines : lines.where((l) => l.setting.shown).toList();
}

/// Fills each line's values from [latest] (device → "measurement|field" →
/// value) and works out status and alert.
void evaluateLines(List<StationLine> lines, StationSettings s, Map<String, Map<String, double>> latest) {
  final st = s.station;
  for (final l in lines) {
    l.sampled.clear();
    for (final p in st.points) {
      final src = l.source(st, p.key);
      final live = src == null ? null : (latest[src.device]?['${src.measurement}|${src.field}']);
      if (live != null) {
        l.values[p.key] = live;
      } else {
        // No device gives this reading: fall back to the sample, marked.
        final sample = st.sample(p.key, l.index);
        l.values[p.key] = sample;
        if (sample != null) l.sampled.add(p.key);
      }
    }
    if (!l.has(st.mainPoint)) {
      l.status = LineStatus.unmapped;
      l.alert = null;
      continue;
    }
    final main = l.values[st.mainPoint];
    final mainOn = main != null && main > s.mainOnAbove;
    if (st.subOnPoint != null && l.has(st.subOnPoint!)) {
      final sub = l.values[st.subOnPoint];
      final subOn = sub != null && sub > s.subOnAbove;
      l.status = mainOn && subOn ? LineStatus.running : (mainOn || subOn) ? LineStatus.partial : LineStatus.stopped;
    } else {
      l.status = mainOn ? LineStatus.running : LineStatus.stopped;
    }
    l.alert = null;
    final tp = st.tempPoint;
    if (s.alertTemp && tp != null && l.status == LineStatus.running && s.alertMax > s.alertMin) {
      final t = l.values[tp];
      if (t != null && (t < s.alertMin || t > s.alertMax)) l.alert = s.alertTempText;
    }
    final hp = st.hoursPoint;
    if (s.alertSvc && hp != null && l.alert == null) {
      final h = l.values[hp];
      if (h != null && l.setting.serviceHours > 0 && h / l.setting.serviceHours * 100 >= s.servicePct) l.alert = s.alertSvcText;
    }
  }
}

/// Every device the lines read from (own mapping or the station default).
Set<String> devicesOf(List<StationLine> lines, StationDef st) => {
      for (final l in lines)
        for (final p in st.points)
          if (l.source(st, p.key) case final src?) src.device,
    };

/// The page regions the layout editor can select.
const kStationRegions = [('head', 'Title and toolbar'), ('kpi', 'Station overview'), ('cards', 'Line cards'), ('chart', 'Trend chart')];

/// The whole station page, drawn from data. Used by the real page and by the
/// live preview in Station Page Setting (where regions are clickable).
class StationView extends StatelessWidget {
  const StationView({
    super.key,
    required this.settings,
    required this.lines,
    required this.trend,
    required this.updated,
    required this.range,
    required this.combined,
    this.siteName = '',
    this.onRange,
    this.onCombined,
    this.onRefreshSec,
    this.onStation,
    this.onSettings,
    this.selectedRegion,
    this.onRegion,
  });

  final StationSettings settings;
  final List<StationLine> lines;
  final Map<String, List<TrendPoint>> trend;
  final DateTime? updated;
  final String range;
  final bool combined;
  final String siteName;
  final ValueChanged<String>? onRange;
  final ValueChanged<bool>? onCombined;
  final ValueChanged<int>? onRefreshSec;
  final ValueChanged<String>? onStation;
  final VoidCallback? onSettings;

  /// Preview mode: highlight and report clicks on page regions.
  final String? selectedRegion;
  final ValueChanged<String>? onRegion;

  StationDef get st => settings.station;
  String _fmt(double? v, int d) => v == null ? '—' : NumberFormat.decimalPatternDigits(decimalDigits: d).format(v);

  Color statusColor(LineStatus s) => switch (s) {
        LineStatus.running => SC.run,
        LineStatus.partial => SC.warn,
        LineStatus.stopped => SC.stop,
        LineStatus.unmapped => SC.idle,
      };
  String statusLabel(LineStatus s) => switch (s) {
        LineStatus.running => settings.runLabel,
        LineStatus.partial => settings.partLabel,
        LineStatus.stopped => settings.stopLabel,
        LineStatus.unmapped => 'Not mapped',
      };

  Widget _region(String key, Widget child) {
    if (onRegion == null) return child;
    final on = selectedRegion == key;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => onRegion!(key),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? SC.accent : Colors.transparent, width: 2.5),
          ),
          padding: const EdgeInsets.all(3),
          child: AbsorbPointer(child: child),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _region('head', _head()),
      if (settings.kpiShown.isNotEmpty) _region('kpi', _overview()),
      _region('cards', _cards()),
      if (settings.chartShow) _region('chart', _chart()),
    ]);
  }

  // ── title & toolbar ──────────────────────────────────────────────────────
  Widget _head() {
    final sub = [
      if (settings.showSite && siteName.isNotEmpty) 'Mill Site - $siteName',
      if (settings.showUpdated) updated == null ? 'Loading…' : 'Updated ${DateFormat('h:mm:ss a').format(updated!)}',
    ].join(' · ');
    Widget pill(String text, {bool on = false, bool outline = false, VoidCallback? tap, Widget? menu}) {
      final w = Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        decoration: BoxDecoration(
          color: on ? SC.accent : outline ? Colors.transparent : SC.inner,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: on || outline ? SC.accent : SC.border),
        ),
        child: Text(text,
            style: TextStyle(color: on ? const Color(0xFF04121F) : outline ? SC.accent : SC.text, fontSize: 13, fontWeight: FontWeight.w600)),
      );
      if (menu != null) return menu;
      return tap == null ? w : InkWell(borderRadius: BorderRadius.circular(8), onTap: tap, child: w);
    }

    Widget menu<T>(String text, List<(T, String)> items, ValueChanged<T>? on) => PopupMenuButton<T>(
          tooltip: '',
          enabled: on != null,
          color: SC.panelTop,
          onSelected: on,
          itemBuilder: (_) => [for (final (v, l) in items) PopupMenuItem(value: v, child: Text(l, style: const TextStyle(color: SC.text)))],
          child: pill('$text ▾'),
        );

    final shown = lines.length;
    final mapped = lines.where((l) => l.status != LineStatus.unmapped).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(settings.fullTitle, style: const TextStyle(color: SC.text, fontSize: 30, fontWeight: FontWeight.w700)),
        if (sub.isNotEmpty) Text(sub, style: const TextStyle(color: SC.dim, fontSize: 13)),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: SC.panel(radius: 10),
          child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            menu<String>('${settings.prefix.isEmpty ? '' : '${settings.prefix} - '}${st.name} Station',
                [for (final s in kStations) (s.key, s.name)], onStation),
            if (settings.tbDevices) pill('Devices ($mapped/$shown)'),
            if (settings.tbMode) ...[
              pill('Individual', on: !combined, tap: onCombined == null ? null : () => onCombined!(false)),
              pill('Combined', on: combined, tap: onCombined == null ? null : () => onCombined!(true)),
            ],
            if (settings.tbRange)
              menu<String>({'1h': '1 Hour', '6h': '6 Hours', '24h': '24 Hours'}[range] ?? range,
                  const [('1h', '1 Hour'), ('6h', '6 Hours'), ('24h', '24 Hours')], onRange),
            if (settings.tbRefresh)
              menu<int>('${settings.refreshSec}s', const [(5, '5s'), (10, '10s'), (30, '30s'), (60, '60s')], onRefreshSec),
            if (settings.tbAi) ...[pill('AI Analysis ▾', outline: true), pill('Analyze', outline: true)],
            if (onSettings != null) pill('⚙ Settings', outline: true, tap: onSettings),
          ]),
        ),
      ]),
    );
  }

  Widget _sectionTitle(String title, {Widget? trailing}) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 10),
        child: Row(children: [
          Text(title.toUpperCase(), style: const TextStyle(color: SC.text, fontSize: 15, fontWeight: FontWeight.w700, letterSpacing: .6)),
          const Spacer(),
          if (trailing != null) Flexible(child: trailing),
        ]),
      );

  // ── overview ─────────────────────────────────────────────────────────────
  Widget _overview() {
    final running = lines.where((l) => l.status == LineStatus.running).toList();
    final alerts = lines.where((l) => l.alert != null).length;
    double? agg(Iterable<double?> v, String how) {
      final xs = v.whereType<double>().toList();
      if (xs.isEmpty) return null;
      return switch (how) {
        'sum' => xs.reduce((a, b) => a + b),
        'max' => xs.reduce(math.max),
        _ => xs.reduce((a, b) => a + b) / xs.length,
      };
    }

    final mainP = st.point(st.mainPoint)!;
    (String, String, Color) tile(String key) => switch (key) {
          'running' => ('${running.length}', '/ ${lines.length}', SC.run),
          'avgMain' => (_fmt(agg(running.map((l) => l.values[st.mainPoint]), 'avg'), mainP.decimals), mainP.unit, SC.run),
          'maxMain' => (_fmt(agg(lines.map((l) => l.values[st.mainPoint]), 'max'), mainP.decimals), mainP.unit, SC.run),
          'avgTemp' => (_fmt(agg(running.map((l) => l.values[st.tempPoint]), 'avg'), 0), '°C', SC.run),
          'sumMain' => (_fmt(agg(lines.map((l) => l.values[st.mainPoint]), 'sum'), 1), mainP.unit, SC.run),
          'sumSub' => (_fmt(agg(lines.map((l) => l.values[st.subOnPoint]), 'sum'), 1), 'A', SC.run),
          'sumHours' => (_fmt(agg(lines.map((l) => l.values[st.hoursPoint]), 'sum'), 1), 'hrs', SC.run),
          'levelFull' => ('${lines.where((l) => (l.values['levelFull'] ?? 0) >= 1).length}', '/ ${lines.length}', SC.run),
          'alerts' => ('$alerts', '', alerts > 0 ? SC.warn : SC.run),
          _ => ('—', '', SC.run),
        };
    final shown = st.kpis.where((k) => settings.kpiShown.contains(k.key)).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(settings.overviewTitle),
      LayoutBuilder(builder: (context, c) {
        final per = c.maxWidth > 900 ? shown.length : math.min(shown.length, 3);
        final w = (c.maxWidth - 10 * (per - 1)) / per;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final k in shown)
            Container(
              width: w,
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
              decoration: SC.panel(radius: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(k.title.toUpperCase(), style: SC.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                const SizedBox(height: 6),
                Builder(builder: (_) {
                  final (v, u, col) = tile(k.key);
                  return Text.rich(TextSpan(children: [
                    TextSpan(text: v, style: TextStyle(color: col, fontSize: 28, fontWeight: FontWeight.w700)),
                    TextSpan(text: '  $u', style: const TextStyle(color: SC.dim, fontSize: 13, fontWeight: FontWeight.w600)),
                  ]));
                }),
              ]),
            ),
        ]);
      }),
    ]);
  }

  // ── cards ────────────────────────────────────────────────────────────────
  Widget _cards() {
    int n(LineStatus s) => lines.where((l) => l.status == s).length;
    Widget chip(String t, [Color c = SC.text]) => Container(
          margin: const EdgeInsets.only(left: 6),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: SC.border), color: SC.inner),
          child: Text(t, style: TextStyle(color: c, fontSize: 11.5, fontWeight: FontWeight.w600)),
        );
    final chips = settings.cardChips
        ? Wrap(alignment: WrapAlignment.end, runSpacing: 6, children: [
            chip('● Live', SC.run),
            chip('${lines.length} Lines'),
            chip('${n(LineStatus.running)} ${settings.runLabel}', SC.run),
            chip('${n(LineStatus.stopped)} ${settings.stopLabel}', SC.stop),
            if (st.subPart != null) chip('${n(LineStatus.partial)} ${settings.partLabel}', SC.warn),
            if (updated != null) chip('Last update ${DateFormat('HH:mm:ss').format(updated!)}', SC.dim),
          ])
        : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      _sectionTitle(settings.cardsTitle, trailing: chips),
      if (lines.isEmpty)
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(22),
          decoration: SC.panel(),
          child: Text(
            'No ${st.mainPart.toLowerCase()} equipment yet. Add an equipment in Equipment Settings with the '
            '"${st.mainPart}" category and it appears here as a card.',
            style: const TextStyle(color: SC.dim, fontSize: 14),
          ),
        )
      else
        LayoutBuilder(builder: (context, c) {
          final per = settings.perRow > 0
              ? settings.perRow
              : math.max(1, math.min(lines.length, math.min(6, (c.maxWidth / 230).floor())));
          final w = (c.maxWidth - 10 * (per - 1)) / per;
          return Wrap(spacing: 10, runSpacing: 10, children: [
            for (final l in lines) SizedBox(width: w, child: _lineCard(l)),
          ]);
        }),
      if (settings.cardLegend) _legend(),
    ]);
  }

  Widget _legend() {
    Widget item(String t, Color c) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text(t, style: const TextStyle(color: SC.dim, fontSize: 11.5)),
          ]),
        );
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
      child: Wrap(runSpacing: 6, children: [
        const Padding(padding: EdgeInsets.only(right: 8), child: Text('Status:', style: TextStyle(color: SC.text, fontSize: 11.5, fontWeight: FontWeight.w700))),
        item(settings.runLabel, SC.run),
        item(settings.stopLabel, SC.stop),
        if (st.subPart != null) item(settings.partLabel, SC.warn),
        item('Not mapped', SC.idle),
      ]),
    );
  }

  Widget _lineCard(StationLine l) {
    final sc = statusColor(l.status);
    final mainOn = l.status == LineStatus.running || (l.status == LineStatus.partial && (l.values[st.mainPoint] ?? 0) > settings.mainOnAbove);
    final subOn = st.subOnPoint != null && (l.values[st.subOnPoint] ?? 0) > settings.subOnAbove;
    final temp = st.tempPoint == null ? null : l.values[st.tempPoint];
    final tempOut = temp != null && settings.alertMax > settings.alertMin && (temp < settings.alertMin || temp > settings.alertMax);
    Widget tag(String part, bool on) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(color: const Color(0xD90A0E14), borderRadius: BorderRadius.circular(4), border: Border.all(color: const Color(0xFF3A4453))),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '${part.toUpperCase()} ', style: const TextStyle(color: SC.text, fontSize: 10, fontWeight: FontWeight.w700)),
            TextSpan(text: on ? 'ON' : 'OFF', style: TextStyle(color: on ? SC.run : SC.stop, fontSize: 10, fontWeight: FontWeight.w800)),
          ])),
        );
    final mainPoints = st.points.where((p) => p.part == 'main' && p.kind == PointKind.analog && (l.has(p.key) || !p.optional)).toList();
    final subPoints = st.points.where((p) => p.part == 'sub' && p.kind == PointKind.analog && (l.has(p.key) || !p.optional)).toList();
    final hasLevel = l.has('levelFull') || l.has('level70');
    final hp = st.point(st.hoursPoint);
    final hours = hp == null ? null : l.values[hp.key];

    return Container(
      padding: const EdgeInsets.all(10),
      decoration: SC.panel(border: sc.withOpacity(.6), radius: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('${l.name.toUpperCase()}${st.subPart != null ? ' +' : ''}',
                  maxLines: 1, overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: SC.text, fontSize: 14, fontWeight: FontWeight.w700, letterSpacing: .3)),
              Text(l.subName(st).toUpperCase(), style: const TextStyle(color: SC.dim, fontSize: 11, letterSpacing: .3)),
            ]),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
              decoration: BoxDecoration(color: sc.withOpacity(.12), borderRadius: BorderRadius.circular(999), border: Border.all(color: sc.withOpacity(.6))),
              child: Text('● ${statusLabel(l.status).toUpperCase()}', style: TextStyle(color: sc, fontSize: 10, fontWeight: FontWeight.w800, letterSpacing: .5)),
            ),
            if (l.anySample)
              Tooltip(
                message: l.isSample
                    ? 'Sample line: add equipment with this category in Equipment Settings'
                    : 'Sample values (no live data): ${l.sampled.map((k) => st.point(k)?.label ?? k).join(', ')}',
                child: Container(
                  margin: const EdgeInsets.only(top: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), border: Border.all(color: SC.faint)),
                  child: const Text('SAMPLE', style: TextStyle(color: SC.faint, fontSize: 9, fontWeight: FontWeight.w700, letterSpacing: .6)),
                ),
              ),
          ]),
        ]),
        if (settings.cardPicture)
          Container(
            height: 220,
            margin: const EdgeInsets.only(top: 10),
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              gradient: const RadialGradient(center: Alignment(0, -.3), radius: 1.1, colors: [Color(0xFF0F2140), Color(0xFF060D1D)]),
            ),
            child: Stack(children: [
              Positioned.fill(
                child: ColorFiltered(
                  colorFilter: mainOn
                      ? const ColorFilter.mode(Colors.transparent, BlendMode.dst)
                      : const ColorFilter.matrix([.3, .3, .3, 0, 0, .3, .3, .3, 0, 0, .3, .3, .3, 0, 0, 0, 0, 0, .75, 0]),
                  child: Image.asset(
                    st.key == 'digester' ? 'assets/images/station_digester.jpg' : 'assets/images/station_sterilizer.jpg',
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                  ),
                ),
              ),
              if (settings.cardTags) ...[
                Positioned(left: 8, top: 8, child: tag(st.mainPart, mainOn)),
                if (st.subPart != null) Positioned(left: 8, bottom: l.alert != null ? 30 : 8, child: tag(st.subPart!.split(' ').last, subOn)),
              ],
              if (temp != null)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                    decoration: BoxDecoration(
                        color: const Color(0xD90A0E14),
                        borderRadius: BorderRadius.circular(5),
                        border: Border.all(color: tempOut ? SC.warn : SC.run, width: 1.5)),
                    child: Text('${_fmt(temp, 0)}°C', style: TextStyle(color: tempOut ? SC.warn : SC.run, fontSize: 15, fontWeight: FontWeight.w700)),
                  ),
                ),
              if (l.alert != null)
                Positioned(
                  left: 0, right: 0, bottom: 0,
                  child: Container(
                    color: SC.warn,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Text('⚠ ${l.alert!.toUpperCase()}',
                        textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF1C1300), fontSize: 11, fontWeight: FontWeight.w800)),
                  ),
                ),
            ]),
          )
        else if (l.alert != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.symmetric(vertical: 4),
            width: double.infinity,
            decoration: BoxDecoration(color: SC.warn, borderRadius: BorderRadius.circular(6)),
            child: Text('⚠ ${l.alert!.toUpperCase()}',
                textAlign: TextAlign.center, style: const TextStyle(color: Color(0xFF1C1300), fontSize: 11, fontWeight: FontWeight.w800)),
          ),
        if (l.status == LineStatus.unmapped)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 22),
            child: Center(
              child: Text('Readings not mapped yet.\nMap them in Station Page Setting.',
                  textAlign: TextAlign.center, style: TextStyle(color: SC.dim, fontSize: 12, height: 1.4)),
            ),
          )
        else ...[
          _part(st.mainPart),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [for (final p in mainPoints) _gauge(p, l.values[p.key])]),
          if (hasLevel) _level(l),
          if (st.subPart != null) ...[
            const SizedBox(height: 4),
            Container(height: 1, color: SC.border),
            _part(st.subPart!),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              for (final p in subPoints) _gauge(p, l.values[p.key]),
              const SizedBox(width: 10),
              if (hp != null && l.has(hp.key))
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(hp.short.toUpperCase(), style: const TextStyle(color: SC.dim, fontSize: 10, letterSpacing: .6)),
                    Text.rich(TextSpan(children: [
                      TextSpan(text: _fmt(hours, hp.decimals), style: const TextStyle(color: SC.run, fontSize: 20, fontWeight: FontWeight.w700)),
                      TextSpan(text: ' ${hp.unit}', style: const TextStyle(color: SC.dim, fontSize: 11)),
                    ])),
                    if (l.setting.serviceHours > 0) ...[
                      const SizedBox(height: 5),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(3),
                        child: LinearProgressIndicator(
                          minHeight: 5,
                          value: ((hours ?? 0) / l.setting.serviceHours).clamp(0, 1).toDouble(),
                          backgroundColor: SC.border,
                          color: (hours ?? 0) / l.setting.serviceHours * 100 >= settings.servicePct ? SC.warn : SC.run,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text('Service due at ${_fmt(l.setting.serviceHours, 0)} hrs', style: const TextStyle(color: SC.dim, fontSize: 10)),
                    ],
                  ]),
                ),
            ]),
          ],
        ],
      ]),
    );
  }

  /// Level block from the full / 70% switches: Full, Above 70%, Low, or
  /// Empty when the digester is also cold.
  Widget _level(StationLine l) {
    final full = (l.values['levelFull'] ?? 0) >= 1, s70 = (l.values['level70'] ?? 0) >= 1;
    final temp = l.values[st.tempPoint];
    final (label, fill, col) = full
        ? ('FULL', .92, SC.run)
        : s70
            ? ('70%', .7, SC.accent)
            : (temp != null && temp < 50)
                ? ('EMPTY', .04, SC.idle)
                : ('LOW', .32, SC.warn);
    Widget sw(String t, bool on) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 7, height: 7, decoration: BoxDecoration(shape: BoxShape.circle, color: on ? SC.run : SC.idle)),
          const SizedBox(width: 4),
          Text(t, style: const TextStyle(color: SC.dim, fontSize: 10)),
        ]);
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(color: SC.inner, borderRadius: BorderRadius.circular(8), border: Border.all(color: SC.border)),
      child: Row(children: [
        Container(
          width: 40,
          height: 62,
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(5), border: Border.all(color: const Color(0xFF3A4453), width: 1.5)),
          clipBehavior: Clip.antiAlias,
          child: Stack(children: [
            Align(alignment: Alignment.bottomCenter, child: FractionallySizedBox(heightFactor: fill, widthFactor: 1, child: Container(color: col))),
            const Positioned(left: 0, right: 0, top: 18, child: Divider(height: 1, color: Color(0xFF6B7686))),
          ]),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${st.mainPart.toUpperCase()} LEVEL', style: const TextStyle(color: SC.dim, fontSize: 10, letterSpacing: .6)),
            Text(label, style: TextStyle(color: col, fontSize: 20, fontWeight: FontWeight.w800)),
            sw('Full switch', full),
            sw('70% switch', s70),
          ]),
        ),
      ]),
    );
  }

  Widget _part(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
        child: Text(t.toUpperCase(), style: const TextStyle(color: SC.dim, fontSize: 11, letterSpacing: 1, fontWeight: FontWeight.w600)),
      );

  Widget _gauge(StationPoint p, double? v) {
    final mn = settings.minOf(p), mx = settings.maxOf(p);
    final f = v == null || mx <= mn ? 0.0 : ((v - mn) / (mx - mn)).clamp(0, 1).toDouble();
    final col = v == null ? SC.idle : (f > .2 ? SC.run : SC.warn);
    return Column(mainAxisSize: MainAxisSize.min, children: [
      SizedBox(width: 82, height: 48, child: CustomPaint(painter: _GaugePainter(f, col))),
      Text(p.short.toUpperCase(), style: const TextStyle(color: SC.dim, fontSize: 9.5, letterSpacing: .6)),
      Text.rich(TextSpan(children: [
        TextSpan(text: _fmt(v, p.decimals), style: TextStyle(color: col, fontSize: 19, fontWeight: FontWeight.w700)),
        TextSpan(text: ' ${p.unit}', style: const TextStyle(color: SC.dim, fontSize: 11)),
      ])),
    ]);
  }

  // ── trend chart ──────────────────────────────────────────────────────────
  Widget _chart() {
    final p = st.point(st.mainPoint)!;
    DateTime? t0;
    for (final l in lines) {
      final pts = trend[l.id];
      if (pts == null || pts.isEmpty) continue;
      if (t0 == null || pts.first.time.isBefore(t0)) t0 = pts.first.time;
    }
    final series = <(StationLine, Color, List<TrendPoint>)>[];
    final hours = range == '1h' ? 1 : range == '6h' ? 6 : 24;
    t0 ??= DateTime.now().subtract(Duration(hours: hours));
    for (final l in lines) {
      var pts = trend[l.id];
      if (pts == null || pts.isEmpty) {
        // No history for this line: a gentle sample curve around its value.
        final base = l.values[st.mainPoint] ?? st.sample(st.mainPoint, l.index);
        if (base == null) continue;
        const n = 72;
        pts = [
          for (var j = 0; j < n; j++)
            TrendPoint(t0.add(Duration(minutes: hours * 60 * j ~/ (n - 1))),
                math.max(0, base + math.sin(j * 1.7 + l.index) * (base * .03 + .2)).toDouble()),
        ];
      }
      series.add((l, SC.chart[l.index % SC.chart.length], pts));
    }
    LineChartBarData bar((StationLine, Color, List<TrendPoint>) s) => LineChartBarData(
          spots: [for (final x in s.$3) FlSpot(x.time.difference(t0!).inMinutes.toDouble(), x.value)],
          color: s.$2,
          barWidth: 1.6,
          dotData: const FlDotData(show: false),
        );
    Widget chart(List<LineChartBarData> bars, {double height = 250}) => SizedBox(
          height: height,
          child: LineChart(LineChartData(
            lineBarsData: bars,
            minY: settings.minOf(p),
            gridData: FlGridData(drawVerticalLine: false, getDrawingHorizontalLine: (_) => const FlLine(color: SC.border, strokeWidth: 1)),
            borderData: FlBorderData(show: false),
            lineTouchData: const LineTouchData(enabled: true),
            titlesData: FlTitlesData(
              topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
              leftTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 40,
                  getTitlesWidget: (v, m) => Text(v.toStringAsFixed(p.decimals > 1 ? 1 : 0), style: const TextStyle(color: SC.dim, fontSize: 10)),
                ),
              ),
              bottomTitles: AxisTitles(
                sideTitles: SideTitles(
                  showTitles: true,
                  reservedSize: 22,
                  interval: range == '1h' ? 15 : range == '6h' ? 90 : 360,
                  getTitlesWidget: (v, m) => Text(t0 == null ? '' : DateFormat('h:mm a').format(t0.add(Duration(minutes: v.toInt()))),
                      style: const TextStyle(color: SC.dim, fontSize: 10)),
                ),
              ),
            ),
          )),
        );
    Widget empty() => const SizedBox(
        height: 200, child: Center(child: Text('No history for this range yet.', style: TextStyle(color: SC.dim, fontSize: 12))));
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
        decoration: SC.panel(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text.rich(TextSpan(children: [
            TextSpan(text: settings.chartTitle, style: const TextStyle(color: SC.text, fontSize: 16, fontWeight: FontWeight.w700)),
            TextSpan(text: '   ${p.label} (${p.unit}) · last $range', style: const TextStyle(color: SC.dim, fontSize: 11.5)),
          ])),
          const SizedBox(height: 12),
          if (series.isEmpty || t0 == null)
            empty()
          else if (combined) ...[
            chart([for (final s in series) bar(s)]),
            const SizedBox(height: 8),
            Wrap(alignment: WrapAlignment.center, spacing: 14, runSpacing: 4, children: [
              for (final (l, c, _) in series)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 9, height: 9, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text('${l.name} (${p.unit})', style: const TextStyle(color: SC.dim, fontSize: 11.5)),
                ]),
            ]),
          ] else
            LayoutBuilder(builder: (context, c) {
              final per = c.maxWidth > 900 ? 3 : c.maxWidth > 560 ? 2 : 1;
              final w = (c.maxWidth - 12 * (per - 1)) / per;
              return Wrap(spacing: 12, runSpacing: 12, children: [
                for (final s in series)
                  SizedBox(
                    width: w,
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(s.$1.name, style: TextStyle(color: s.$2, fontSize: 12, fontWeight: FontWeight.w700)),
                      chart([bar(s)], height: 150),
                    ]),
                  ),
              ]);
            }),
        ]),
      ),
    );
  }
}

/// Half-circle gauge with a needle.
class _GaugePainter extends CustomPainter {
  _GaugePainter(this.fraction, this.color);
  final double fraction;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width / 2, size.height) - 6;
    final c = Offset(size.width / 2, size.height - 4);
    final rect = Rect.fromCircle(center: c, radius: r);
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 7
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect, math.pi, math.pi, false, p..color = SC.border);
    canvas.drawArc(rect, math.pi, math.pi * fraction, false, p..color = color);
    final a = math.pi * (1 - fraction);
    canvas.drawLine(c, Offset(c.dx + (r - 4) * math.cos(a), c.dy - (r - 4) * math.sin(a)), Paint()
      ..color = SC.text
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round);
    canvas.drawCircle(c, 3.5, Paint()..color = SC.text);
  }

  @override
  bool shouldRepaint(_GaugePainter o) => o.fraction != fraction || o.color != color;
}
