import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'pom_config.dart';

const double kPomCanvasW = 1280;
const double kPomCanvasH = 720;

const Color _cyan = Color(0xFF46C3FF);
const Color _line = Color(0xFF1D4F9A);
const Color _line2 = Color(0xFF17366A);
const Color _dim = Color(0xFFA9BFE3);
const Color _ink = Color(0xFFE8F1FF);

TextStyle _t(double s, {FontWeight? w, Color? c, double? ls, FontStyle? st, double? h}) =>
    GoogleFonts.barlowCondensed(fontSize: s, fontWeight: w, color: c ?? _ink, letterSpacing: ls, fontStyle: st, height: h);

IconData pomIcon(String k) => switch (k) {
      'truck' => Icons.local_shipping_outlined,
      'drop' => Icons.water_drop_outlined,
      'gear' => Icons.settings_outlined,
      'shield' => Icons.health_and_safety_outlined,
      'leaf' => Icons.eco_outlined,
      'flame' => Icons.local_fire_department_outlined,
      'palm' => Icons.park_outlined,
      'chart' => Icons.bar_chart_rounded,
      _ => Icons.circle_outlined,
    };

const List<(String, String)> kPomIconChoices = [
  ('truck', 'Truck'),
  ('drop', 'Oil drop'),
  ('gear', 'Gear'),
  ('shield', 'Health shield'),
  ('leaf', 'Leaf'),
  ('flame', 'Flame'),
  ('palm', 'Palm'),
  ('chart', 'Chart'),
];

/// Fits the fixed 1280×720 dashboard into whatever space it is given, the way
/// the TV wall shows it, so every size and alignment stays exactly as designed.
class PomScaledCanvas extends StatelessWidget {
  const PomScaledCanvas({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(width: kPomCanvasW, height: kPomCanvasH, child: child),
      );
}

/// The Group POM Command Center, drawn from a config map. When [onRegionTap]
/// is set (the settings preview) each part can be clicked to edit it and pins
/// can be dragged; without it this is the plain live dashboard.
class PomDashboardView extends StatelessWidget {
  const PomDashboardView({
    super.key,
    required this.cfg,
    required this.period,
    required this.panelPeriod,
    required this.onPeriod,
    required this.onPanelPeriod,
    this.onRegionTap,
    this.selectedRegion,
    this.onPinMove,
    this.live,
    this.onMillTap,
  });

  final Cfg cfg;
  final String period;
  final Map<String, String> panelPeriod;
  final ValueChanged<String> onPeriod;
  final void Function(String panel, String period) onPanelPeriod;
  final ValueChanged<String>? onRegionTap;
  final String? selectedRegion;
  final void Function(int index, double x, double y)? onPinMove;
  /// Latest values fetched from SmartMill's own Influx/MySQL, keyed
  /// "<deviceId>|<measurement>|<field>". Omitted (or a field missing from
  /// it) reads as "no data" — never a guessed number.
  final Map<String, double>? live;
  /// Set on the live dashboard (never the settings preview) to make a mill's
  /// card and pin navigate to that mill's own Command Center on tap.
  final void Function(String millId)? onMillTap;

  @override
  Widget build(BuildContext context) {
    final c = PomCalc(cfg, live);
    return DefaultTextStyle(
      style: _t(14),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(0, -1),
            radius: 1.25,
            colors: [Color(0xFF0C2350), Color(0xFF061126), Color(0xFF040B1A)],
            stops: [0, .55, 1],
          ),
        ),
        child: Column(children: [
          SizedBox(height: 54, child: _region('top', _top(c))),
          const SizedBox(height: 10),
          SizedBox(height: 92, child: _region('kpi', _kpis(c))),
          const SizedBox(height: 10),
          Expanded(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              SizedBox(width: 288, child: _region('left', _left(c))),
              const SizedBox(width: 10),
              Expanded(child: _region('mapc', _center(c))),
              const SizedBox(width: 10),
              SizedBox(
                width: 300,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _region('right', _table(c)),
                  const SizedBox(height: 10),
                  Expanded(child: _region('alerts', _alerts(c))),
                ]),
              ),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _region(String id, Widget child) {
    if (onRegionTap == null) return child;
    final on = selectedRegion == id;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: () => onRegionTap!(id),
        child: Container(
          foregroundDecoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: on ? Border.all(color: _cyan, width: 3) : null,
          ),
          child: child,
        ),
      ),
    );
  }

  // ── Top bar ────────────────────────────────────────────────────────────────

  Widget _top(PomCalc c) {
    final t = c.top;
    final title = (t['title'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.only(bottom: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line2))),
      child: Row(children: [
        _logo(t),
        const SizedBox(width: 10),
        Text((t['product'] ?? '').toString(), style: _t(27, w: FontWeight.w700, ls: .2, c: Colors.white)),
        const SizedBox(width: 16),
        Container(width: 1, height: 38, color: const Color(0xFF2A4D86)),
        const SizedBox(width: 16),
        Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title.toUpperCase(), style: _t(21, w: FontWeight.w700, ls: .5, c: const Color(0xFFCFE6FF), h: 1.05)),
          Text((t['subtitle'] ?? '').toString(), style: _t(15, c: hexColor(t['titleColor']?.toString(), _cyan), h: 1.05)),
        ]),
        const Spacer(),
        if (t['periodMode'] != 'panel') _periodTabs(c),
        if (t['live'] == true) ...[
          const SizedBox(width: 16),
          Row(children: [
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                color: Color(0xFF2FD27A),
                shape: BoxShape.circle,
                boxShadow: [BoxShadow(color: Color(0xFF2FD27A), blurRadius: 8)],
              ),
            ),
            const SizedBox(width: 7),
            Text('LIVE', style: _t(17, w: FontWeight.w700, c: const Color(0xFF2FD27A))),
          ]),
        ],
        if (t['clock'] == true) ...[const SizedBox(width: 16), const _PomClock()],
      ]),
    );
  }

  Widget _logo(Map<String, dynamic> t) {
    final url = (t['logo'] ?? '').toString().trim();
    final badge = hexColor(t['badge']?.toString(), const Color(0xFF0F7A3D));
    Widget fallback() {
      if (t['fallback'] == 'initials') {
        return Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: badge, borderRadius: BorderRadius.circular(10)),
          child: Text((t['initials'] ?? '').toString(), style: _t(18, w: FontWeight.w700, c: Colors.white)),
        );
      }
      return Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(center: const Alignment(0, -.2), colors: [badge, const Color(0xFF062A1A)]),
        ),
        child: const Icon(Icons.park_rounded, color: Color(0xFFBFF5D4), size: 28),
      );
    }

    if (url.isEmpty) return fallback();
    return ClipOval(
      child: SizedBox(
        width: 44,
        height: 44,
        child: Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => fallback()),
      ),
    );
  }

  Widget _periodTabs(PomCalc c) {
    final en = c.enabledPeriods();
    return Container(
      decoration: BoxDecoration(border: Border.all(color: const Color(0xFF24508F)), borderRadius: BorderRadius.circular(6)),
      clipBehavior: Clip.antiAlias,
      child: Row(children: [
        for (var i = 0; i < en.length; i++)
          InkWell(
            onTap: () => onPeriod(en[i]),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5),
              decoration: BoxDecoration(
                color: period == en[i] ? const Color(0xFF123A78) : Colors.transparent,
                border: Border(left: i == 0 ? BorderSide.none : const BorderSide(color: Color(0xFF24508F))),
              ),
              child: Text(kPeriodLabel[en[i]]!, style: _t(15, c: period == en[i] ? Colors.white : const Color(0xFFCFE0FF))),
            ),
          ),
      ]),
    );
  }

  /// A panel's own period switch, shown only when panels may differ.
  Widget _pvPer(PomCalc c, String panel) {
    final md = c.top['periodMode'];
    if (md == 'global') return const SizedBox.shrink();
    final opts = <(String, String)>[
      if (md == 'both') ('', 'Follow top'),
      for (final p in c.enabledPeriods()) (p, kPeriodLabel[p]!),
    ];
    final cur = panelPeriod[panel] ?? '';
    final v = cur.isNotEmpty ? cur : (md == 'panel' ? c.top['defPeriod'].toString() : '');
    final label = opts.firstWhere((o) => o.$1 == v, orElse: () => opts.isNotEmpty ? opts.first : ('', '')).$2;
    return PopupMenuButton<String>(
      tooltip: 'Period',
      color: const Color(0xFF0B1F44),
      onSelected: (x) => onPanelPeriod(panel, x),
      itemBuilder: (_) => [for (final o in opts) PopupMenuItem<String>(value: o.$1, child: Text(o.$2, style: _t(14)))],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(color: const Color(0xFF0B1F44), border: Border.all(color: const Color(0xFF24508F)), borderRadius: BorderRadius.circular(5)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(label, style: _t(13, c: const Color(0xFFCFE0FF))),
          const Icon(Icons.keyboard_arrow_down, size: 14, color: Color(0xFFCFE0FF)),
        ]),
      ),
    );
  }

  // ── KPI row ────────────────────────────────────────────────────────────────

  Widget _kpis(PomCalc c) {
    final per = c.perFor('kpi', period, panelPeriod);
    final cards = c.cards;
    return Row(children: [
      for (var i = 0; i < cards.length; i++) ...[
        if (i > 0) const SizedBox(width: 10),
        Expanded(child: _kpiCard(c, cards[i], per)),
      ],
    ]);
  }

  Widget _kpiCard(PomCalc c, Map<String, dynamic> card, String per) {
    final cm = c.cat(card['metric'] as String?);
    final e = c.eff(card);
    final r = cm == null ? const AggResult(null, []) : c.aggregate(card['metric'] as String, e.$1, e.$2, c.groupMills(), per);
    final unit = ((card['unit'] ?? '').toString().isNotEmpty ? card['unit'] : cm?['unit'] ?? '').toString();
    final accent = hexColor(card['accent']?.toString(), _cyan);
    final size = ((card['size'] ?? 42) as num).toDouble();
    final valueColor = hexColor(card['color']?.toString(), Colors.white);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _line),
        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xFF0C2146), Color(0xFF081733)]),
      ),
      child: Row(children: [
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: accent, width: 2), color: const Color(0x4014468F)),
          child: Icon(pomIcon((card['icon'] ?? '').toString()), size: 30, color: accent),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((card['title'] ?? '').toString(), style: _t(16, c: const Color(0xFFD7E6FF)), maxLines: 1, overflow: TextOverflow.ellipsis),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text.rich(TextSpan(children: [
                TextSpan(text: r.v == null || cm == null ? '—' : fmtNum(r.v!, ((cm['dec'] ?? 0) as num).toInt()), style: _t(size, w: FontWeight.w700, c: valueColor, h: 1.05)),
                if (unit.isNotEmpty) TextSpan(text: ' $unit', style: _t(size * .62, w: FontWeight.w600, c: valueColor)),
              ])),
            ),
          ]),
        ),
        if (card['spark'] == true) _spark(r.v, accent),
      ]),
    );
  }

  Widget _spark(double? v, Color color) {
    final s = (v ?? 7).round();
    const base = [.35, .5, .45, .62, .58, .8, 1.0];
    return SizedBox(
      height: 44,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (var j = 0; j < base.length; j++)
          Container(
            width: 4,
            margin: const EdgeInsets.only(left: 2),
            height: (math.min(1.0, base[j] * (.86 + ((s + j * 13) % 7) / 40)) * 44).roundToDouble(),
            decoration: BoxDecoration(color: color.withOpacity(.35 + j * .1), borderRadius: BorderRadius.circular(1)),
          ),
      ]),
    );
  }

  // ── Shared panel chrome ────────────────────────────────────────────────────

  Widget _box({required Widget header, required Widget body, bool expand = true}) {
    return Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0xE60D2654), Color(0xEB071630)]),
        border: Border.all(color: const Color(0x662A6BC4)),
        borderRadius: BorderRadius.circular(10),
        boxShadow: const [BoxShadow(color: Color(0x381E8CFF), blurRadius: 14)],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        if (expand) Expanded(child: body) else body,
      ]),
    );
  }

  Widget _iconBadge(IconData icon, Color color) => Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: color.withOpacity(.14),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withOpacity(.45)),
          boxShadow: [BoxShadow(color: color.withOpacity(.28), blurRadius: 8)],
        ),
        child: Icon(icon, size: 20, color: color),
      );

  Widget _hdr(IconData icon, Color color, String title, Widget trailing) {
    return Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0x333EC6FF), Color(0x003EC6FF)]),
        border: Border(bottom: BorderSide(color: Color(0x803EC6FF))),
      ),
      child: Row(children: [
        _iconBadge(icon, color),
        const SizedBox(width: 10),
        Expanded(child: Text(title.toUpperCase(), style: _t(19, w: FontWeight.w700, ls: .4, h: 1.05))),
        trailing,
      ]),
    );
  }

  Widget _pill(String text, Color color, {double size = 13, double? width}) => Container(
        width: width,
        alignment: width == null ? null : Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 2),
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(999), boxShadow: [BoxShadow(color: color.withOpacity(.4), blurRadius: 7)]),
        child: Text(text, style: _t(size, w: FontWeight.w700, c: const Color(0xFF06122A))),
      );

  Widget _figure(PomCalc c, Map<String, dynamic>? cm, double? v, TextStyle valueStyle) {
    if (cm == null) return Text('—', style: valueStyle);
    final u = (cm['unit'] ?? '').toString();
    return Text.rich(TextSpan(children: [
      TextSpan(text: v == null ? '—' : fmtNum(v, ((cm['dec'] ?? 0) as num).toInt()), style: valueStyle),
      if (v != null && u.isNotEmpty)
        TextSpan(text: u == '%' ? u : ' $u', style: valueStyle.copyWith(fontSize: (valueStyle.fontSize ?? 18) * .7, fontWeight: FontWeight.w600)),
    ]));
  }

  // ── Left panel: mills ──────────────────────────────────────────────────────

  Widget _left(PomCalc c) {
    final L = c.left;
    final per = c.perFor('left', period, panelPeriod);
    var ms = c.activeMills();
    if (L['sort'] == 'metric') {
      final k = L['sortMetric'].toString();
      final dir = L['sortDir'] == 'desc' ? -1 : 1;
      ms.sort((a, b) {
        final va = c.value(a['id'] as String, k, per);
        final vb = c.value(b['id'] as String, k, per);
        if (va == null) return 1;
        if (vb == null) return -1;
        return (va - vb).sign.toInt() * dir;
      });
    }
    final st = c.status;
    final band = c.band;
    return _box(
      header: _hdr(Icons.bar_chart_rounded, _cyan, (L['title'] ?? '').toString(), _pvPer(c, 'left')),
      body: ms.isEmpty
          ? Padding(padding: const EdgeInsets.all(16), child: Text('No mills shown. Tick “Shown” in Mills.', style: _t(14, c: const Color(0xFF7F97BF))))
          : LayoutBuilder(builder: (context, box) {
              // Few enough mills to fit: stretch the cards to fill the panel instead of leaving it empty below.
              final fitH = (box.maxHeight - 8) / ms.length;
              final cardH = fitH >= 84 ? math.min(fitH, 124.0) : null;
              return ListView(
              physics: cardH != null ? const NeverScrollableScrollPhysics() : null,
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              children: [
                for (final m in ms)
                  () {
                    final id = m['id'] as String;
                    final si = c.statusIdx(id, per);
                    final bi = c.bandIdx(m, per);
                    final byStatus = L['border'] == 'status';
                    final bc = byStatus
                        ? (si < 0 ? const Color(0xFF6B7FA3) : hexColor((st['colors'] as List)[si] as String))
                        : (bi < 0 ? const Color(0xFF6B7FA3) : hexColor((band['colors'] as List)[bi] as String));
                    final figs = (L['metrics'] as List).where((k) => k != null && k.toString().isNotEmpty).map((k) => c.cat(k.toString())).whereType<Map<String, dynamic>>().toList();
                    return Container(
                      margin: const EdgeInsets.only(top: 7),
                      height: cardH == null ? null : cardH - 7,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        border: Border.all(color: bc.withOpacity(.35)),
                        gradient: LinearGradient(colors: [Color.alphaBlend(bc.withOpacity(.16), const Color(0xF2123064)), const Color(0xE60A1D3F)]),
                        boxShadow: [BoxShadow(color: bc.withOpacity(.18), blurRadius: 10)],
                      ),
                      child: Stack(children: [
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 6, 10, 7),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Expanded(child: Text((m['name'] ?? '').toString(), style: _t(16.5, w: FontWeight.w700, h: 1.05), maxLines: 2, overflow: TextOverflow.ellipsis)),
                          if (L['bars'] == true) SizedBox(width: 66, child: Center(child: CustomPaint(size: const Size(30, 24), painter: _SignalBars(bc, bi)))),
                        ]),
                        Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 5), decoration: const BoxDecoration(gradient: LinearGradient(colors: [Color(0x00FFFFFF), Color(0x40FFFFFF), Color(0x00FFFFFF)]))),
                        Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                          for (final cm in figs)
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.only(right: 4),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text((cm['label'] ?? '').toString(), style: _t(10.5, c: _dim), maxLines: 1)),
                                FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: _figure(c, cm, c.value(id, cm['k'] as String, per), _t(17, w: FontWeight.w700))),
                              ]),
                              ),
                            ),
                          if (L['band'] == true) SizedBox(width: 66, child: bi >= 0 ? _pill((band['labels'] as List)[bi].toString(), hexColor((band['colors'] as List)[bi] as String), width: 66) : const SizedBox.shrink()),
                        ]),
                          ]),
                        ),
                        Positioned(
                          left: 5,
                          right: 0,
                          top: 0,
                          height: 20,
                          child: Container(
                            decoration: const BoxDecoration(
                              borderRadius: BorderRadius.only(topRight: Radius.circular(7)),
                              gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color(0x14FFFFFF), Color(0x00FFFFFF)]),
                            ),
                          ),
                        ),
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: 5,
                          child: Container(
                            decoration: BoxDecoration(
                              color: bc,
                              borderRadius: const BorderRadius.horizontal(left: Radius.circular(7)),
                              boxShadow: [BoxShadow(color: bc.withOpacity(.55), blurRadius: 6)],
                            ),
                          ),
                        ),
                        if (onMillTap != null)
                          Positioned.fill(
                            child: Material(
                              color: Colors.transparent,
                              child: InkWell(
                                borderRadius: BorderRadius.circular(7),
                                onTap: () => onMillTap!(id),
                                child: const SizedBox.expand(),
                              ),
                            ),
                          ),
                      ]),
                    );
                  }(),
              ],
            );
            }),
    );
  }

  // ── Centre: map ────────────────────────────────────────────────────────────

  Widget _center(PomCalc c) {
    final M = c.mapc;
    final st = c.status;
    final per = c.perFor('map', period, panelPeriod);
    final showHeader = M['header'] != false;
    final legend = M['legend'] == true
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            for (var i = 0; i < (st['labels'] as List).length; i++)
              Padding(
                padding: const EdgeInsets.only(left: 12),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(width: 11, height: 11, decoration: BoxDecoration(color: hexColor((st['colors'] as List)[i] as String), shape: BoxShape.circle)),
                  const SizedBox(width: 5),
                  Text((st['labels'] as List)[i].toString(), style: _t(14, c: const Color(0xFFCFE0FF))),
                ]),
              ),
          ])
        : const SizedBox.shrink();
    final header = Container(
      constraints: const BoxConstraints(minHeight: 46),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: const BoxDecoration(
        gradient: LinearGradient(colors: [Color(0x333EC6FF), Color(0x003EC6FF)]),
        border: Border(bottom: BorderSide(color: Color(0x803EC6FF))),
      ),
      child: Row(children: [
        _iconBadge(Icons.place_outlined, _cyan),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text((M['title'] ?? '').toString(), style: _t(22, w: FontWeight.w700, ls: .2, h: 1.05)),
            Text((M['subtitle'] ?? '').toString(), style: _t(14, c: _dim, h: 1.05)),
          ]),
        ),
        legend,
        const SizedBox(width: 10),
        _pvPer(c, 'map'),
      ]),
    );
    return _box(
      header: showHeader ? header : const SizedBox.shrink(),
      body: LayoutBuilder(builder: (context, box) {
        final w = box.maxWidth, h = box.maxHeight;
        final act = c.activeMills();
        final pinLayer = <Widget>[];
        for (final m in act) {
          final idx = c.mills.indexOf(m);
          final id = m['id'] as String;
          final x = ((m['x'] ?? 50) as num).toDouble(), y = ((m['y'] ?? 50) as num).toDouble();
          final ax = x / 100 * w, ay = y / 100 * h;
          final si = c.statusIdx(id, per);
          final col = si < 0 ? const Color(0xFF6B7FA3) : hexColor((st['colors'] as List)[si] as String);
          final side = (m['side'] ?? 'top').toString();
          final figs = <InlineSpan>[];
          for (final k in (M['popup'] as List)) {
            final cm = c.cat(k?.toString());
            if (cm == null) continue;
            if (figs.isNotEmpty) figs.add(TextSpan(text: '  |  ', style: _t(13, c: const Color(0xFFCFE0FF))));
            final v = c.value(id, cm['k'] as String, per);
            final u = (cm['unit'] ?? '').toString();
            figs.add(TextSpan(text: '${cm['short'] ?? cm['label']} ', style: _t(13, c: const Color(0xFFCFE0FF))));
            figs.add(TextSpan(
              text: v == null ? '—' : '${fmtNum(v, ((cm['dec'] ?? 0) as num).toInt())}${u.isEmpty ? '' : (u == '%' ? u : ' $u')}',
              style: _t(13, w: FontWeight.w700, c: (cm['k'] == 'oer' || cm['k'] == st['metric']) ? col : Colors.white),
            ));
          }
          if (M['locLabels'] == true && (m['loc'] ?? '').toString().isNotEmpty) {
            final (fx, fy, px, py) = switch (side) {
              'top' => (-.5, 0.0, 0.0, 12.0),
              'bottom' => (-.5, -1.0, 0.0, -12.0),
              'left' => (0.0, -.5, 14.0, 0.0),
              _ => (-1.0, -.5, -14.0, 0.0),
            };
            pinLayer.add(Positioned(
              left: ax,
              top: ay,
              child: IgnorePointer(
                child: FractionalTranslation(
                  translation: Offset(fx, fy),
                  child: Transform.translate(
                    offset: Offset(px, py),
                    child: Text((m['loc'] ?? '').toString(),
                        style: _t(17, w: FontWeight.w700, c: Colors.white).copyWith(shadows: const [Shadow(color: Colors.black, blurRadius: 3)])),
                  ),
                ),
              ),
            ));
          }
          pinLayer.add(Positioned.fill(
            child: CustomSingleChildLayout(
              delegate: _PopLayout(Offset(ax, ay), side),
              // Clickable on the live dashboard (opens the mill's Command
              // Center, same as its pin); inert in the settings preview.
              child: IgnorePointer(
                ignoring: onMillTap == null,
                child: MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: onMillTap == null ? null : () => onMillTap!(m['id'] as String),
                    child: Container(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 5),
                      decoration: BoxDecoration(color: const Color(0xF0051128), border: Border.all(color: col, width: 1.5), borderRadius: BorderRadius.circular(6)),
                      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Text((m['name'] ?? '').toString(), style: _t(14, w: FontWeight.w700)),
                        if (figs.isNotEmpty) Text.rich(TextSpan(children: figs)),
                        if (M['popStatus'] == true && si >= 0)
                          Padding(padding: const EdgeInsets.only(top: 4), child: _pill((st['labels'] as List)[si].toString(), col, size: 12)),
                      ]),
                    ),
                  ),
                ),
              ),
            ),
          ));
          pinLayer.add(Positioned(
            left: ax - 10,
            top: ay - 10,
            child: GestureDetector(
              onPanUpdate: onPinMove == null
                  ? null
                  : (d) {
                      final nx = (((x + d.delta.dx / w * 100).clamp(0, 100)) * 2).round() / 2;
                      final ny = (((y + d.delta.dy / h * 100).clamp(0, 100)) * 2).round() / 2;
                      onPinMove!(idx, nx, ny);
                    },
              onTap: onMillTap == null ? null : () => onMillTap!(m['id'] as String),
              child: MouseRegion(
                cursor: onMillTap != null ? SystemMouseCursors.click : (onPinMove == null ? MouseCursor.defer : SystemMouseCursors.grab),
                child: Container(
                  width: 20,
                  height: 20,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF061126),
                    border: Border.all(color: col, width: 4),
                    boxShadow: [BoxShadow(color: col, blurRadius: 14)],
                  ),
                ),
              ),
            ),
          ));
        }
        final bgSrc = (M['bg'] ?? '').toString().trim();
        Widget bg;
        if (bgSrc.startsWith('http://') || bgSrc.startsWith('https://')) {
          bg = Image.network(bgSrc, fit: BoxFit.fill, width: w, height: h, errorBuilder: (_, __, ___) => Container(color: const Color(0xFF04112A)));
        } else if (bgSrc.isNotEmpty) {
          bg = Image.asset(bgSrc, fit: BoxFit.fill, width: w, height: h, errorBuilder: (_, __, ___) => Container(color: const Color(0xFF04112A)));
        } else {
          bg = Container(color: const Color(0xFF04112A));
        }
        return Stack(clipBehavior: Clip.hardEdge, children: [
          Positioned.fill(child: bg),
          if (!showHeader && c.top['periodMode'] != 'global') Positioned(right: 10, top: 8, child: _pvPer(c, 'map')),
          if ((M['sea'] ?? '').toString().isNotEmpty)
            Positioned(
              left: w * .30,
              top: h * .24,
              child: FractionalTranslation(
                translation: const Offset(-.5, -.5),
                child: Text((M['sea']).toString(), style: _t(18, ls: 4, st: FontStyle.italic, c: _cyan.withOpacity(.85))),
              ),
            ),
          if ((M['region'] ?? '').toString().isNotEmpty)
            Positioned(
              left: w * .64,
              top: h * .80,
              child: FractionalTranslation(
                translation: const Offset(-.5, -.5),
                child: Text((M['region']).toString(), style: _t(32, w: FontWeight.w700, ls: 12, c: const Color(0xD9E6F0FF))),
              ),
            ),
          if (M['compass'] == true) Positioned(left: w * .04, top: h * .05, child: const _Compass()),
          if (M['inset'] == true)
            Positioned(left: w * .02, bottom: h * .03, child: _inset((M['region'] ?? '').toString())),
          if (M['scale'] == true)
            Positioned(
              right: w * .03,
              bottom: h * .04,
              child: Column(children: [
                Text('0   50   100       200 km', style: _t(12, c: const Color(0xFFCFE0FF))),
                Container(
                  width: 170,
                  height: 6,
                  margin: const EdgeInsets.only(top: 2),
                  decoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFFCFE0FF), width: 1.5), right: BorderSide(color: Color(0xFFCFE0FF), width: 1.5), bottom: BorderSide(color: Color(0xFFCFE0FF), width: 1.5))),
                ),
              ]),
            ),
          ...pinLayer,
        ]);
      }),
    );
  }

  Widget _inset(String region) => Container(
        width: 130,
        height: 110,
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        decoration: BoxDecoration(color: const Color(0xD9061E2E), border: Border.all(color: const Color(0xFF2A5AA3)), borderRadius: BorderRadius.circular(6)),
        child: Stack(children: [
          const Positioned(right: 0, top: 2, child: SizedBox(width: 70, height: 60, child: CustomPaint(painter: _InsetPainter()))),
          Align(
            alignment: Alignment.bottomLeft,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('MALAYSIA', style: _t(12, ls: 1.5, c: const Color(0xFFCFE0FF))),
              Text(region, style: _t(11, ls: 1.5, c: const Color(0xFFCFE0FF))),
            ]),
          ),
        ]),
      );

  // ── Right: health table + attention ────────────────────────────────────────

  Widget _table(PomCalc c) {
    final R = c.right;
    final per = c.perFor('right', period, panelPeriod);
    final st = c.status;
    var ms = c.activeMills();
    final sm = (R['sortMetric'] ?? '').toString();
    if (sm.isNotEmpty) {
      final dir = R['sortDir'] == 'desc' ? -1 : 1;
      ms.sort((a, b) {
        final va = c.value(a['id'] as String, sm, per);
        final vb = c.value(b['id'] as String, sm, per);
        if (va == null) return 1;
        if (vb == null) return -1;
        return (va - vb).sign.toInt() * dir;
      });
    }
    final cols = (R['cols'] as List).cast<Map<String, dynamic>>();
    final colMax = cols.map((col) {
      final cc = c.cat(col['m'] as String?);
      final vs = ms.map((m) => c.value(m['id'] as String, col['m'] as String, per)).whereType<double>().toList();
      if (cc != null && cc['kind'] == 'rate' && (cc['unit'] ?? '').toString().isEmpty) return 100.0;
      return vs.isEmpty ? 1.0 : math.max(1.0, vs.reduce(math.max));
    }).toList();
    const valW = 54.0, stW = 70.0;
    Widget th(String s, double w) => SizedBox(width: w, child: Text(s, style: _t(13, w: FontWeight.w600, c: const Color(0xFFCFE0FF), h: 1.1)));
    return _box(
      expand: false,
      header: _hdr(Icons.settings_outlined, _cyan, (R['title'] ?? '').toString(), _pvPer(c, 'right')),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
        child: LayoutBuilder(builder: (context, box) {
          final nameW = math.max(80.0, box.maxWidth - cols.length * valW - (R['status'] == true ? stW : 0));
          return Column(children: [
          Container(
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: _line2))),
            child: Row(children: [
              SizedBox(width: nameW, child: Padding(padding: const EdgeInsets.only(left: 8), child: Text('Mill Name', style: _t(13, w: FontWeight.w600, c: const Color(0xFFCFE0FF))))),
              for (final col in cols) th(c.lbl(col['m'] as String?), valW),
              if (R['status'] == true) th('Status', stW),
            ]),
          ),
          for (final m in ms)
            () {
              final id = m['id'] as String;
              final si = c.statusIdx(id, per);
              final col = si < 0 ? const Color(0xFF6B7FA3) : hexColor((st['colors'] as List)[si] as String);
              return Container(
                padding: const EdgeInsets.symmetric(vertical: 5),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF102A55)))),
                child: Row(children: [
                  Container(
                    width: nameW,
                    padding: const EdgeInsets.only(left: 6),
                    decoration: BoxDecoration(border: Border(left: BorderSide(color: col, width: 4))),
                    child: Text((m['name'] ?? '').toString(), style: _t(14, h: 1.1), maxLines: 2, overflow: TextOverflow.ellipsis),
                  ),
                  for (var ci = 0; ci < cols.length; ci++)
                    SizedBox(
                      width: valW,
                      child: () {
                        final cc = c.cat(cols[ci]['m'] as String?);
                        final v = c.value(id, cols[ci]['m'] as String, per);
                        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Text(v == null ? '—' : fmtNum(v, ((cc?['dec'] ?? 0) as num).toInt()), style: _t(20, w: FontWeight.w700, c: cols[ci]['bar'] == true ? col : _ink)),
                          if (cols[ci]['bar'] == true && v != null)
                            Container(
                              width: valW - 8,
                              height: 6,
                              margin: const EdgeInsets.only(top: 2),
                              decoration: BoxDecoration(color: const Color(0xFF1A355F), borderRadius: BorderRadius.circular(3)),
                              alignment: Alignment.centerLeft,
                              child: FractionallySizedBox(widthFactor: math.min(1.0, v / colMax[ci]), child: Container(decoration: BoxDecoration(color: col, borderRadius: BorderRadius.circular(3)))),
                            ),
                        ]);
                      }(),
                    ),
                  if (R['status'] == true)
                    SizedBox(width: stW, child: si >= 0 ? Align(alignment: Alignment.centerLeft, child: _pill((st['labels'] as List)[si].toString(), col)) : Text('—', style: _t(14))),
                ]),
              );
            }(),
        ]);
        }),
      ),
    );
  }

  Widget _alerts(PomCalc c) {
    final A = c.alerts;
    final sev = (A['sev'] as List).cast<Map<String, dynamic>>();
    final order = sev.map((s) => s['k']).toList();
    final minI = order.indexOf(A['minSev']);
    final act = c.activeMills();
    final maxN = math.max(1, ((A['max'] ?? 1) as num).toInt());
    final evs = kEvents
        .where((ev) =>
            (A['source'] == 'both' || ev.src == A['source']) &&
            ev.ago <= ((A['window'] ?? 24) as num) &&
            order.indexOf(ev.sev) <= minI &&
            act.any((m) => m['id'] == ev.mill))
        .toList()
      ..sort((a, b) => a.ago.compareTo(b.ago));
    final shown = evs.take(maxN).toList();
    return _box(
      header: _hdr(Icons.warning_amber_rounded, const Color(0xFFEF4444), (A['title'] ?? '').toString(), _pvPer(c, 'alerts')),
      body: shown.isEmpty
          ? Padding(padding: const EdgeInsets.all(16), child: Text('Nothing needs attention in this window.', style: _t(14, c: const Color(0xFF7F97BF))))
          : ListView(padding: EdgeInsets.zero, children: [
              for (final ev in shown)
                () {
                  final s = sev.firstWhere((x) => x['k'] == ev.sev, orElse: () => sev.first);
                  final m = c.mill(ev.mill);
                  final col = hexColor(s['color']?.toString(), _cyan);
                  final when = A['rel'] == true
                      ? '${ev.ago}h ago'
                      : (() {
                          final d = DateTime.now().subtract(Duration(hours: ev.ago));
                          return '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}';
                        })();
                  return Container(
                    padding: const EdgeInsets.fromLTRB(12, 7, 12, 7),
                    decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF102A55)))),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Container(
                        width: 26,
                        height: 26,
                        margin: const EdgeInsets.only(top: 2),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: col, shape: BoxShape.circle),
                        child: Text('!', style: _t(16, w: FontWeight.w800, c: const Color(0xFF06122A))),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Row(children: [
                            Expanded(child: Text((m?['name'] ?? ev.mill).toString(), style: _t(15, w: FontWeight.w700), maxLines: 1, overflow: TextOverflow.ellipsis)),
                            const SizedBox(width: 8),
                            _pill((s['label'] ?? '').toString(), col),
                            const SizedBox(width: 8),
                            Text(when, style: _t(12, c: _dim)),
                          ]),
                          Text(ev.msg[A['lang']] ?? ev.msg['en'] ?? '', style: _t(13.5, c: const Color(0xFFCFE0FF))),
                        ]),
                      ),
                    ]),
                  );
                }(),
            ]),
    );
  }
}

// ── Small painters and helpers ───────────────────────────────────────────────

class _SignalBars extends CustomPainter {
  _SignalBars(this.color, this.bandIdx);
  final Color color;
  final int bandIdx;

  @override
  void paint(Canvas canvas, Size size) {
    final on = bandIdx < 0 ? 1.0 : 4 - bandIdx * 1.5;
    for (var j = 0; j < 5; j++) {
      final h = 4 + j * 4.5;
      final p = Paint()..color = color.withOpacity(j <= on ? 1 : .25);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(j * 6.0, 20 - j * 4.5, 4, h), const Radius.circular(1)), p);
    }
  }

  @override
  bool shouldRepaint(covariant _SignalBars old) => old.color != color || old.bandIdx != bandIdx;
}

class _InsetPainter extends CustomPainter {
  const _InsetPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final a = Path()
      ..moveTo(4, 20)
      ..lineTo(18, 10)
      ..lineTo(26, 22)
      ..lineTo(20, 36)
      ..lineTo(8, 32)
      ..close();
    canvas.drawPath(a, Paint()..color = const Color(0x998AA3C9));
    final b = Path()
      ..moveTo(34, 44)
      ..cubicTo(44, 38, 54, 30, 66, 18)
      ..lineTo(66, 50)
      ..lineTo(36, 56)
      ..close();
    canvas.drawPath(b, Paint()..color = _cyan);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _Compass extends StatelessWidget {
  const _Compass();
  @override
  Widget build(BuildContext context) {
    Widget l(String s, {double? left, double? right, double? top, double? bottom}) =>
        Positioned(left: left, right: right, top: top, bottom: bottom, child: Text(s, style: _t(12, c: const Color(0xFFCFE0FF))));
    return Opacity(
      opacity: .8,
      child: SizedBox(
        width: 70,
        height: 80,
        child: Stack(children: [
          const Positioned.fill(child: CustomPaint(painter: _CompassPainter())),
          l('N', left: 32, top: 0),
          l('S', left: 32, bottom: 0),
          l('W', left: 0, top: 30),
          l('E', right: 0, top: 30),
        ]),
      ),
    );
  }
}

class _CompassPainter extends CustomPainter {
  const _CompassPainter();
  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = _cyan.withOpacity(.85);
    canvas.drawPath(
        Path()
          ..moveTo(35, 18)
          ..lineTo(39, 40)
          ..lineTo(35, 62)
          ..lineTo(31, 40)
          ..close(),
        fill);
    canvas.drawPath(
        Path()
          ..moveTo(13, 40)
          ..lineTo(35, 36)
          ..lineTo(57, 40)
          ..lineTo(35, 44)
          ..close(),
        Paint()..color = _cyan.withOpacity(.5));
    canvas.drawCircle(const Offset(35, 40), 14, Paint()..color = _cyan.withOpacity(.5)..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

/// Puts a pin's pop-up on the chosen side of it, then slides it back inside
/// the map so it is never cut off at an edge.
class _PopLayout extends SingleChildLayoutDelegate {
  _PopLayout(this.anchor, this.side);
  final Offset anchor;
  final String side;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) => BoxConstraints.loose(constraints.biggest);

  @override
  Offset getPositionForChild(Size size, Size child) {
    double x, y;
    switch (side) {
      case 'top':
        x = anchor.dx - child.width / 2;
        y = anchor.dy - child.height - 16;
      case 'bottom':
        x = anchor.dx - child.width / 2;
        y = anchor.dy + 16;
      case 'left':
        x = anchor.dx - child.width - 16;
        y = anchor.dy - child.height / 2;
      default:
        x = anchor.dx + 16;
        y = anchor.dy - child.height / 2;
    }
    final maxX = math.max(4.0, size.width - child.width - 4);
    final maxY = math.max(4.0, size.height - child.height - 4);
    return Offset(x.clamp(4.0, maxX), y.clamp(4.0, maxY));
  }

  @override
  bool shouldRelayout(covariant _PopLayout old) => old.anchor != anchor || old.side != side;
}

class _PomClock extends StatefulWidget {
  const _PomClock();
  @override
  State<_PomClock> createState() => _PomClockState();
}

class _PomClockState extends State<_PomClock> {
  Timer? _t0;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    _t0 = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _t0?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    const mo = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    String two(int n) => n.toString().padLeft(2, '0');
    final d = _now;
    return Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
      Text('${wd[d.weekday - 1]}, ${d.day} ${mo[d.month - 1]} ${d.year}', style: _t(14, c: const Color(0xFFCFE0FF), h: 1.15)),
      Text('${two(d.hour)}:${two(d.minute)}:${two(d.second)}', style: _t(14, c: const Color(0xFFCFE0FF), h: 1.15)),
    ]);
  }
}
