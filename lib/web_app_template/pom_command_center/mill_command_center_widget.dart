import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'pom_config.dart';

/// One mill's own Command Center — reached from the sidebar or by clicking
/// the mill on the Group POM Command Center.
///
/// UI-first draft: laid out 1:1 on the agreed mockup (fixed 1672×941 design
/// canvas, scaled to fit), with the mockup's figures hardcoded in [_Demo]
/// below. The settings page that will drive these per mill is being drafted
/// separately; until then only the mill's name comes from the Group config.
class MillCommandCenterWidget extends StatefulWidget {
  const MillCommandCenterWidget({super.key, required this.millId});
  final String millId;

  @override
  State<MillCommandCenterWidget> createState() => _MillCommandCenterWidgetState();
}

// ── Hardcoded draft figures (swap for live data once the setting exists) ──
class _Demo {
  static const kpis = [
    (title: 'FFB Processed', value: '4,280', unit: 't', trend: '6%', img: 'assets/images/mill_card_ffb.png'),
    (title: 'CPO Produced', value: '872', unit: 't', trend: '5%', img: 'assets/images/mill_card_cpo.png'),
    (title: 'OER', value: '20.4', unit: '%', trend: '0.3%', img: ''),
    (title: 'Avg Throughput', value: '61.1', unit: 't/h', trend: '4%', img: ''),
  ];
  static const progress = [
    (label: 'FFB', pct: .72, sub: '4,280 / 5,900 t', teal: false),
    (label: 'CPO', pct: .70, sub: '872 / 1,250 t', teal: false),
    (label: 'Throughput', pct: .68, sub: '61.1 / 90 t/h', teal: true),
  ];
  static const shift = [
    (p: 'Sterilizer\nCycles Completed', m: '18', mu: 'cycles', c: '15', cu: 'cycles', hl: true),
    (p: 'Steam Header Pressure', m: '12.2', mu: 'barg', c: '12.5', cu: 'barg', hl: false),
    (p: 'Press Throughput', m: '27.6', mu: 't/h', c: '28.4', cu: 't/h', hl: false),
    (p: 'Clarification Oil Loss', m: '0.85', mu: '%', c: '0.72', cu: '%', hl: false),
  ];
  static const indicators = [
    (label: 'KER', value: '5.1', trend: '0.2%', dir: 1, icon: Icons.spa, color: Color(0xFFE8A06A)),
    (label: 'Pressing Loss', value: '2.8', trend: '0.3%', dir: -1, icon: Icons.settings_outlined, color: Color(0xFFCFD8E6)),
    (label: 'Clarification Loss', value: '0.72', trend: '0.1%', dir: -1, icon: Icons.water_drop, color: Color(0xFF4AA8FF)),
    (label: 'Shell Moisture', value: '6.8', trend: '0.0%', dir: 0, icon: Icons.grain, color: Color(0xFFD9B98A)),
  ];
  static const health = [
    (label: 'Sterilizer', v: 78),
    (label: 'Boiler & Steam', v: 85),
    (label: 'Pressing', v: 82),
    (label: 'Clarification', v: 88),
    (label: 'Kernel Recovery', v: 80),
  ];
  static const alerts = [
    (sev: 'High', title: 'Sterilizer S3', msg: 'Cycle quality < 75% for 3 consecutive cycles', time: '14:32'),
    (sev: 'Medium', title: 'Pressing', msg: 'Press motor load fluctuation', time: '12:18'),
    (sev: 'Medium', title: 'Clarification', msg: 'Oil in sludge slightly high (0.85%)', time: '11:06'),
    (sev: 'Info', title: 'Boiler', msg: 'Steam header pressure variation', time: '10:14'),
  ];
}

// Per-station tab drafts, same layout as Overview: 4 KPI cards + status,
// 3 progress rings, a Morning/Current parameter table, key indicators,
// equipment health bars and the station's own alerts.
typedef _Kpi = ({String title, String value, String unit, String trend, int dir});
typedef _Ring3 = ({String label, double pct, String sub, bool teal});
typedef _Row4 = ({String p, String m, String mu, String c, String cu, bool hl});
typedef _Ind = ({String label, String value, String unit, String trend, int dir});
typedef _Hl = ({String label, int v});
typedef _Al = ({String sev, String title, String msg, String time});

class _StationView {
  const _StationView({required this.kpis, required this.status, required this.statusNote, required this.rings,
      required this.params, required this.indicators, required this.units, required this.alerts});
  final List<_Kpi> kpis;
  final String status; // RUNNING | ATTENTION
  final String statusNote;
  final List<_Ring3> rings;
  final List<_Row4> params;
  final List<_Ind> indicators;
  final List<_Hl> units;
  final List<_Al> alerts;
}

const Map<String, _StationView> _stations = {
  'Sterilizer': _StationView(
    kpis: [
      (title: 'Cycles Completed', value: '33', unit: 'cycles', trend: '4%', dir: 1),
      (title: 'Avg Cycle Time', value: '92', unit: 'min', trend: '2%', dir: -1),
      (title: 'Avg Peak Pressure', value: '2.9', unit: 'barg', trend: '0.1', dir: 1),
      (title: 'Steam Consumed', value: '18.6', unit: 't', trend: '3%', dir: -1),
    ],
    status: 'ATTENTION', statusNote: 'S3 quality low',
    rings: [
      (label: 'Cycles', pct: .83, sub: '33 / 40 cycles', teal: false),
      (label: 'Quality', pct: .78, sub: '78 / 100', teal: false),
      (label: 'Uptime', pct: .91, sub: '21.8 / 24 h', teal: true),
    ],
    params: [
      (p: 'Cycles Completed', m: '18', mu: 'cycles', c: '15', cu: 'cycles', hl: true),
      (p: 'Avg Holding Time', m: '45', mu: 'min', c: '43', cu: 'min', hl: false),
      (p: 'Peak Pressure', m: '2.9', mu: 'barg', c: '3.0', cu: 'barg', hl: false),
      (p: 'Condensate Temp', m: '98', mu: '°C', c: '96', cu: '°C', hl: false),
    ],
    indicators: [
      (label: 'Cycle Efficiency', value: '91', unit: '%', trend: '1.2%', dir: 1),
      (label: 'Steam per Cycle', value: '0.56', unit: 't', trend: '0.02', dir: -1),
      (label: 'Door Seal Leak', value: '0.4', unit: '%', trend: '0.1%', dir: -1),
      (label: 'Idle Time', value: '38', unit: 'min', trend: '0.0%', dir: 0),
    ],
    units: [(label: 'Sterilizer S1', v: 88), (label: 'Sterilizer S2', v: 84), (label: 'Sterilizer S3', v: 62), (label: 'Sterilizer S4', v: 79), (label: 'Condensate Pump', v: 86)],
    alerts: [
      (sev: 'High', title: 'Sterilizer S3', msg: 'Cycle quality < 75% for 3 consecutive cycles', time: '14:32'),
      (sev: 'Medium', title: 'Sterilizer S4', msg: 'Holding time 4 min below benchmark', time: '13:05'),
      (sev: 'Info', title: 'Sterilizer S1', msg: 'Door seal inspection due in 2 days', time: '09:40'),
    ],
  ),
  'Boiler & Steam': _StationView(
    kpis: [
      (title: 'Steam Generated', value: '142', unit: 't', trend: '3%', dir: 1),
      (title: 'Header Pressure', value: '12.5', unit: 'barg', trend: '0.3', dir: 1),
      (title: 'Feed Water Temp', value: '105', unit: '°C', trend: '1%', dir: 1),
      (title: 'Fuel Burned', value: '38', unit: 't', trend: '2%', dir: -1),
    ],
    status: 'RUNNING', statusNote: 'Normal Operation',
    rings: [
      (label: 'Steam', pct: .79, sub: '142 / 180 t', teal: false),
      (label: 'Efficiency', pct: .85, sub: '85 / 100', teal: false),
      (label: 'Load', pct: .72, sub: '11.8 / 16.4 t/h', teal: true),
    ],
    params: [
      (p: 'Steam Header Pressure', m: '12.2', mu: 'barg', c: '12.5', cu: 'barg', hl: true),
      (p: 'Steam Flow', m: '11.8', mu: 't/h', c: '12.1', cu: 't/h', hl: false),
      (p: 'Drum Water Level', m: '52', mu: '%', c: '49', cu: '%', hl: false),
      (p: 'Flue Gas Temp', m: '238', mu: '°C', c: '241', cu: '°C', hl: false),
    ],
    indicators: [
      (label: 'Steam / Fuel Ratio', value: '3.7', unit: '', trend: '0.1', dir: 1),
      (label: 'Blowdown', value: '2.1', unit: '%', trend: '0.2%', dir: -1),
      (label: 'Furnace Draft', value: '-6.2', unit: 'mmWG', trend: '0.0', dir: 0),
      (label: 'Turbine Output', value: '1.2', unit: 'MW', trend: '4%', dir: 1),
    ],
    units: [(label: 'Boiler B1', v: 87), (label: 'Boiler B2', v: 83), (label: 'Turbine T1', v: 90), (label: 'Feed Pump', v: 81), (label: 'ID Fan', v: 84)],
    alerts: [
      (sev: 'Info', title: 'Boiler', msg: 'Steam header pressure variation', time: '10:14'),
      (sev: 'Medium', title: 'Boiler B2', msg: 'Flue gas temperature trending up', time: '08:52'),
    ],
  ),
  'Pressing': _StationView(
    kpis: [
      (title: 'Press Throughput', value: '28.4', unit: 't/h', trend: '2%', dir: 1),
      (title: 'Pressing Loss', value: '2.8', unit: '%', trend: '0.3%', dir: -1),
      (title: 'Digester Temp', value: '95', unit: '°C', trend: '1%', dir: 1),
      (title: 'Press Motor Load', value: '78', unit: '%', trend: '5%', dir: 1),
    ],
    status: 'RUNNING', statusNote: 'P3 load fluctuating',
    rings: [
      (label: 'Throughput', pct: .79, sub: '28.4 / 36 t/h', teal: false),
      (label: 'Health', pct: .82, sub: '82 / 100', teal: false),
      (label: 'Uptime', pct: .93, sub: '22.3 / 24 h', teal: true),
    ],
    params: [
      (p: 'Press Throughput', m: '27.6', mu: 't/h', c: '28.4', cu: 't/h', hl: true),
      (p: 'Digester Temp', m: '94', mu: '°C', c: '95', cu: '°C', hl: false),
      (p: 'Press Motor Load', m: '74', mu: '%', c: '78', cu: '%', hl: false),
      (p: 'Cone Pressure', m: '42', mu: 'bar', c: '44', cu: 'bar', hl: false),
    ],
    indicators: [
      (label: 'Oil in Press Fibre', value: '5.4', unit: '%', trend: '0.2%', dir: -1),
      (label: 'Nut Breakage', value: '12', unit: '%', trend: '1%', dir: -1),
      (label: 'Digester Fill', value: '86', unit: '%', trend: '0.0%', dir: 0),
      (label: 'Screw Wear', value: '64', unit: '%', trend: '1%', dir: 1),
    ],
    units: [(label: 'Press P1', v: 88), (label: 'Press P2', v: 85), (label: 'Press P3', v: 71), (label: 'Digester D1', v: 84), (label: 'Digester D2', v: 82)],
    alerts: [
      (sev: 'Medium', title: 'Pressing', msg: 'Press motor load fluctuation', time: '12:18'),
      (sev: 'Info', title: 'Press P1', msg: 'Screw pressing wear at 64% of life', time: '07:30'),
    ],
  ),
  'Clarification': _StationView(
    kpis: [
      (title: 'Oil Recovered', value: '872', unit: 't', trend: '5%', dir: 1),
      (title: 'Oil Loss in Sludge', value: '0.72', unit: '%', trend: '0.1%', dir: -1),
      (title: 'Clarifier Temp', value: '90', unit: '°C', trend: '1%', dir: 1),
      (title: 'Decanter Flow', value: '25', unit: 'm³/h', trend: '3%', dir: 1),
    ],
    status: 'RUNNING', statusNote: 'Oil in sludge high',
    rings: [
      (label: 'Recovery', pct: .70, sub: '872 / 1,250 t', teal: false),
      (label: 'Health', pct: .88, sub: '88 / 100', teal: false),
      (label: 'Purity', pct: .96, sub: '99.1 / 99.5 %', teal: true),
    ],
    params: [
      (p: 'Oil Loss in Sludge', m: '0.85', mu: '%', c: '0.72', cu: '%', hl: true),
      (p: 'Clarifier Temp', m: '89', mu: '°C', c: '90', cu: '°C', hl: false),
      (p: 'Vacuum Dryer', m: '0.07', mu: 'bar', c: '0.06', cu: 'bar', hl: false),
      (p: 'Decanter Flow', m: '23', mu: 'm³/h', c: '25', cu: 'm³/h', hl: false),
    ],
    indicators: [
      (label: 'CPO Moisture', value: '0.14', unit: '%', trend: '0.01%', dir: -1),
      (label: 'CPO Dirt', value: '0.018', unit: '%', trend: '0.0%', dir: 0),
      (label: 'FFA', value: '3.4', unit: '%', trend: '0.1%', dir: -1),
      (label: 'Purifier Load', value: '12.4', unit: 'm³/h', trend: '2%', dir: 1),
    ],
    units: [(label: 'Clarifier Tank', v: 90), (label: 'Decanter D1', v: 87), (label: 'Decanter D2', v: 85), (label: 'Purifier', v: 89), (label: 'Vacuum Dryer', v: 86)],
    alerts: [
      (sev: 'Medium', title: 'Clarification', msg: 'Oil in sludge slightly high (0.85%)', time: '11:06'),
    ],
  ),
  'Kernel Recovery': _StationView(
    kpis: [
      (title: 'Kernel Produced', value: '218', unit: 't', trend: '3%', dir: 1),
      (title: 'KER', value: '5.1', unit: '%', trend: '0.2%', dir: 1),
      (title: 'Kernel Loss', value: '0.42', unit: '%', trend: '0.03%', dir: -1),
      (title: 'Shell Moisture', value: '6.8', unit: '%', trend: '0.0%', dir: 0),
    ],
    status: 'RUNNING', statusNote: 'Normal Operation',
    rings: [
      (label: 'Kernel', pct: .73, sub: '218 / 300 t', teal: false),
      (label: 'Health', pct: .80, sub: '80 / 100', teal: false),
      (label: 'Ripple Eff.', pct: .95, sub: '95 / 100 %', teal: true),
    ],
    params: [
      (p: 'Ripple Mill Efficiency', m: '96', mu: '%', c: '95', cu: '%', hl: true),
      (p: 'Kernel Loss', m: '0.45', mu: '%', c: '0.42', cu: '%', hl: false),
      (p: 'Hydrocyclone Pressure', m: '1.6', mu: 'bar', c: '1.7', cu: 'bar', hl: false),
      (p: 'Kernel Dryer Temp', m: '68', mu: '°C', c: '70', cu: '°C', hl: false),
    ],
    indicators: [
      (label: 'Kernel Moisture', value: '7.2', unit: '%', trend: '0.2%', dir: -1),
      (label: 'Broken Kernel', value: '14', unit: '%', trend: '1%', dir: -1),
      (label: 'Dirt in Kernel', value: '5.8', unit: '%', trend: '0.0%', dir: 0),
      (label: 'Silo Level', value: '72', unit: '%', trend: '6%', dir: 1),
    ],
    units: [(label: 'Ripple Mill R1', v: 84), (label: 'Ripple Mill R2', v: 79), (label: 'Hydrocyclone', v: 82), (label: 'Kernel Dryer', v: 77), (label: 'Kernel Silo', v: 85)],
    alerts: [
      (sev: 'Info', title: 'Ripple Mill R2', msg: 'Rotor vibration slightly above baseline', time: '10:48'),
    ],
  ),
  'Utilities': _StationView(
    kpis: [
      (title: 'Power Consumed', value: '18.4', unit: 'MWh', trend: '2%', dir: -1),
      (title: 'Water Usage', value: '1,240', unit: 'm³', trend: '4%', dir: -1),
      (title: 'Turbine Output', value: '1.2', unit: 'MW', trend: '4%', dir: 1),
      (title: 'Compressed Air', value: '7.1', unit: 'bar', trend: '0.0', dir: 0),
    ],
    status: 'RUNNING', statusNote: 'Normal Operation',
    rings: [
      (label: 'Self-Gen', pct: .81, sub: '14.9 / 18.4 MWh', teal: false),
      (label: 'Health', pct: .90, sub: '90 / 100', teal: false),
      (label: 'Water Reuse', pct: .64, sub: '794 / 1,240 m³', teal: true),
    ],
    params: [
      (p: 'Turbine Load', m: '72', mu: '%', c: '75', cu: '%', hl: true),
      (p: 'Power Factor', m: '0.91', mu: '', c: '0.93', cu: '', hl: false),
      (p: 'Raw Water Flow', m: '51', mu: 'm³/h', c: '53', cu: 'm³/h', hl: false),
      (p: 'Air Pressure', m: '7.0', mu: 'bar', c: '7.1', cu: 'bar', hl: false),
    ],
    indicators: [
      (label: 'kWh / t FFB', value: '19.8', unit: '', trend: '0.4', dir: -1),
      (label: 'Water / t FFB', value: '1.3', unit: 'm³', trend: '0.1', dir: -1),
      (label: 'Genset Hours', value: '0', unit: 'h', trend: '0.0', dir: 0),
      (label: 'Effluent Flow', value: '38', unit: 'm³/h', trend: '2%', dir: 1),
    ],
    units: [(label: 'Turbine T1', v: 91), (label: 'Genset G1', v: 93), (label: 'Water Treatment', v: 88), (label: 'Air Compressor', v: 90), (label: 'Effluent Pond', v: 86)],
    alerts: [
      (sev: 'Info', title: 'Genset G1', msg: 'Standby test run scheduled 16:00', time: '08:15'),
    ],
  ),
};

// Station look, shared by the flow chain, health rows and tabs.
class _St {
  const _St(this.label, this.icon, this.color);
  final String label;
  final IconData icon;
  final Color color;
}

const _ffb = _St('FFB', Icons.local_shipping, Color(0xFF2FBF5A));
const _sterilizer = _St('Sterilizer', Icons.whatshot, Color(0xFFE5484D));
const _boiler = _St('Boiler & Steam', Icons.fireplace, Color(0xFF9B6BFF));
const _pressing = _St('Pressing', Icons.settings, Color(0xFFF5B82E));
const _clarification = _St('Clarification', Icons.water_drop, Color(0xFF3EA6FF));
const _kernel = _St('Kernel Recovery', Icons.spa, Color(0xFFE08A4E));

const _flow = [_ffb, _sterilizer, _pressing, _clarification, _kernel];
const _healthSt = [_sterilizer, _boiler, _pressing, _clarification, _kernel];
const _tabs = ['Overview', 'Sterilizer', 'Boiler & Steam', 'Pressing', 'Clarification', 'Kernel Recovery', 'Utilities'];

const double _cw = 1672, _ch = 941;
const Color _bg = Color(0xFF050D1E);
const Color _card = Color(0xE60A1830);
const Color _border = Color(0xFF1C3A68);
const Color _ink = Color(0xFFEAF1FF);
const Color _dim = Color(0xFFA9BCDD);
const Color _blue = Color(0xFF3B9BFF);
const Color _green = Color(0xFF2FD27A);
const Color _red = Color(0xFFF0575B);
const Color _amber = Color(0xFFF5A524);

class _MillCommandCenterWidgetState extends State<MillCommandCenterWidget> {
  int _tab = 0;
  String _name = '';

  @override
  void initState() {
    super.initState();
    _name = widget.millId;
    PomConfigStore.ensureLoaded().then((_) {
      final m = PomCalc(PomConfigStore.live).mill(widget.millId);
      if (mounted && m != null) setState(() => _name = PomCalc.short((m['name'] ?? widget.millId).toString()));
    });
  }

  TextStyle _t(double s, {FontWeight w = FontWeight.w500, Color c = _ink, double? h}) =>
      GoogleFonts.inter(fontSize: s, fontWeight: w, color: c, height: h);

  @override
  Widget build(BuildContext context) {
    // Overview draws from _Demo; each station tab from its own _StationView,
    // laid out in exactly the same frame.
    final name = _tabs[_tab];
    final sv = _tab == 0 ? null : _stations[name];
    final look = _lookOf(name);
    final List<_Kpi> kpis = sv?.kpis ?? [for (final k in _Demo.kpis) (title: k.title, value: k.value, unit: k.unit, trend: k.trend, dir: 1)];
    final imgs = sv == null ? [for (final k in _Demo.kpis) k.img] : const <String>[];
    final List<_Ring3> rings = sv?.rings ?? _Demo.progress;
    final List<_Row4> params = sv?.params ?? _Demo.shift;
    final List<_Ind> inds = sv?.indicators ?? [for (final k in _Demo.indicators) (label: k.label, value: k.value, unit: '%', trend: k.trend, dir: k.dir)];
    final indIcons = sv == null ? [for (final k in _Demo.indicators) (k.icon, k.color)] : [for (final _ in sv.indicators) (look.icon, look.color)];
    final List<_Hl> health = sv?.units ?? _Demo.health;
    final healthIcons = sv == null ? [for (final s in _healthSt) (s.icon, s.color)] : [for (final _ in sv.units) (look.icon, look.color)];
    final List<_Al> alerts = sv?.alerts ?? _Demo.alerts;

    return Container(
      color: _bg,
      alignment: Alignment.topCenter,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topCenter,
        child: SizedBox(
          width: _cw,
          height: _ch,
          child: Stack(children: [
            // Aerial photo bleeds behind the centre, exactly like the mockup.
            Positioned(
              left: 446, top: 172, width: 734, height: 764,
              child: Image.asset('assets/images/mill_aerial.jpg', fit: BoxFit.cover,
                  errorBuilder: (_, __, ___) => Container(color: const Color(0xFF0B1830))),
            ),
            Positioned(left: 0, top: 0, right: 0, height: 66, child: _header(context)),
            ..._kpiRow(kpis, imgs, sv?.status ?? 'RUNNING', sv?.statusNote ?? 'Normal Operation'),
            Positioned(left: 22, top: 181, width: 416, height: 210,
                child: _progress(sv == null ? 'Today Production Progress' : '$name Progress', rings)),
            Positioned(left: 22, top: 405, width: 416, height: 258, child: _shiftTable(params)),
            Positioned(left: 22, top: 678, width: 416, height: 234, child: _indicators(inds, indIcons)),
            Positioned(left: 1186, top: 181, width: 466, height: 160, child: _flowCard(sv == null ? null : name)),
            Positioned(left: 1186, top: 355, width: 466, height: 276,
                child: _healthCard(sv == null ? 'Process Health' : 'Equipment Health', health, healthIcons)),
            Positioned(left: 1186, top: 647, width: 466, height: 265, child: _alertCard(alerts)),
          ]),
        ),
      ),
    );
  }

  _St _lookOf(String tab) => switch (tab) {
        'Sterilizer' => _sterilizer,
        'Boiler & Steam' => _boiler,
        'Pressing' => _pressing,
        'Clarification' => _clarification,
        'Kernel Recovery' => _kernel,
        _ => const _St('Utilities', Icons.bolt, Color(0xFF38C6D9)),
      };

  // ── Chrome ──────────────────────────────────────────────────────────────

  Widget _box({required Widget child, EdgeInsets pad = const EdgeInsets.fromLTRB(18, 14, 18, 14), Gradient? gradient, Color? borderColor}) =>
      Container(
        padding: pad,
        decoration: BoxDecoration(
          color: gradient == null ? _card : null,
          gradient: gradient,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(color: borderColor ?? _border),
          boxShadow: const [BoxShadow(color: Color(0x33143A7A), blurRadius: 12)],
        ),
        child: child,
      );

  Widget _title(String s, {Widget? trailing}) => Row(children: [
        Expanded(child: Text(s, style: _t(17, w: FontWeight.w700))),
        if (trailing != null) trailing,
      ]);

  Widget _roundIcon(IconData i, Color c, {double size = 38}) => Container(
        width: size, height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: c.withOpacity(.14),
          border: Border.all(color: c, width: 2),
          boxShadow: [BoxShadow(color: c.withOpacity(.45), blurRadius: 10)],
        ),
        child: Icon(i, color: c, size: size * .52),
      );

  // ── Header + tabs ───────────────────────────────────────────────────────

  Widget _header(BuildContext context) {
    final now = DateTime.now();
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return Stack(children: [
      Positioned(
        left: 22, top: 18,
        child: InkWell(
          onTap: () => context.goNamed('PomGroupCommandCenter'),
          child: Row(children: [
            const Icon(Icons.arrow_back, color: _blue, size: 20),
            const SizedBox(width: 12),
            Text('Group POM', style: _t(15, c: _dim)),
          ]),
        ),
      ),
      Positioned(left: 148, top: 14, child: Container(width: 1, height: 36, color: _border)),
      Positioned(
        left: 168, top: 12,
        child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
          Text(_name, style: _t(28, w: FontWeight.w800)),
          const SizedBox(width: 14),
          Padding(padding: const EdgeInsets.only(bottom: 4), child: Text('Command Center', style: _t(18, w: FontWeight.w600))),
        ]),
      ),
      Positioned(
        left: 643, top: 14, height: 36,
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: const Color(0xFF0A1830), borderRadius: BorderRadius.circular(6), border: Border.all(color: _border)),
          child: Row(children: [
            for (var i = 0; i < _tabs.length; i++)
              InkWell(
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: _tab == i ? const Color(0xFF1C5FD1) : Colors.transparent,
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: _tab == i ? const [BoxShadow(color: Color(0x663B9BFF), blurRadius: 10)] : null,
                  ),
                  child: Text(_tabs[i], style: _t(14.5, c: _tab == i ? Colors.white : _dim)),
                ),
              ),
          ]),
        ),
      ),
      Positioned(
        right: 20, top: 14, height: 36, width: 168,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(color: const Color(0xFF0A1830), borderRadius: BorderRadius.circular(6), border: Border.all(color: _border)),
          child: Row(children: [
            const Icon(Icons.calendar_month_outlined, color: _ink, size: 18),
            const SizedBox(width: 10),
            Expanded(child: Text('${now.day} ${months[now.month - 1]} ${now.year}', style: _t(14.5))),
            const Icon(Icons.keyboard_arrow_down, color: _ink, size: 20),
          ]),
        ),
      ),
    ]);
  }

  // ── KPI row ─────────────────────────────────────────────────────────────

  List<Widget> _kpiRow(List<_Kpi> kpis, List<String> imgs, String status, String note) {
    const lefts = [22.0, 371.0, 693.0, 1016.0];
    const widths = [333.0, 302.0, 303.0, 302.0];
    return [
      for (var i = 0; i < kpis.length && i < 4; i++)
        Positioned(left: lefts[i], top: 70, width: widths[i], height: 95,
            child: _kpiCard(kpis[i], i < imgs.length ? imgs[i] : '')),
      Positioned(left: 1333, top: 70, width: 319, height: 95, child: _statusCard(status, note)),
    ];
  }

  Widget _kpiCard(_Kpi k, String img) {
    final arrow = k.dir > 0 ? '↑' : (k.dir < 0 ? '↓' : '→');
    return _box(
      pad: const EdgeInsets.fromLTRB(16, 12, 12, 10),
      child: Stack(children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${k.title} - Today', style: _t(15, c: const Color(0xFFCFE0FF))),
          const SizedBox(height: 4),
          Padding(
            padding: EdgeInsets.only(right: img.isEmpty ? 72 : 136),
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
                Text(k.value, style: _t(34, w: FontWeight.w700, h: 1.05)),
                const SizedBox(width: 6),
                Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(k.unit, style: _t(22, w: FontWeight.w600))),
                const SizedBox(width: 16),
                Padding(
                  padding: const EdgeInsets.only(bottom: 5),
                  child: Text('$arrow ${k.trend}', style: _t(15, w: FontWeight.w600, c: k.dir == 0 ? _dim : _green)),
                ),
              ]),
            ),
          ),
        ]),
        Positioned(
          right: img.isEmpty ? 4 : 64, bottom: 2,
          child: CustomPaint(size: const Size(64, 42), painter: _Spark(seed: k.title.length)),
        ),
        if (img.isNotEmpty)
          Positioned(right: 0, top: 0, bottom: 0, child: Image.asset(img, fit: BoxFit.contain, errorBuilder: (_, __, ___) => const SizedBox())),
      ]),
    );
  }

  Widget _statusCard(String status, String note) {
    final ok = status == 'RUNNING';
    final c = ok ? _green : _amber;
    return _box(
      pad: const EdgeInsets.fromLTRB(18, 10, 16, 10),
      borderColor: ok ? const Color(0xFF1F6B45) : const Color(0xFF7A5A1A),
      gradient: LinearGradient(colors: ok ? const [Color(0xFF0C2A2A), Color(0xFF0E3A2A)] : const [Color(0xFF2A220C), Color(0xFF3A2C0E)]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(_tab == 0 ? 'Mill Status' : 'Station Status', style: _t(15, c: const Color(0xFFCFE0FF))),
        const SizedBox(height: 6),
        Row(children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(shape: BoxShape.circle, color: c, boxShadow: [BoxShadow(color: c.withOpacity(.55), blurRadius: 12)]),
            child: Icon(ok ? Icons.check : Icons.priority_high, color: const Color(0xFF06240F), size: 20),
          ),
          const SizedBox(width: 14),
          Text(status, style: _t(21, w: FontWeight.w800, c: c)),
          const Spacer(),
          Text(note, style: _t(12, c: c)),
        ]),
      ]),
    );
  }

  // ── Left column ─────────────────────────────────────────────────────────

  Widget _progress(String title, List<_Ring3> rings) {
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(title),
        const SizedBox(height: 16),
        Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
          for (final p in rings)
            Column(children: [
              Text(p.label, style: _t(13.5, w: FontWeight.w600)),
              const SizedBox(height: 8),
              SizedBox(
                width: 96, height: 96,
                child: CustomPaint(
                  painter: _Ring(p.pct, p.teal ? const [Color(0xFF2FB7A8), Color(0xFF6BE08F)] : const [Color(0xFF1E6FE0), Color(0xFF52B6FF)]),
                  child: Center(child: Text('${(p.pct * 100).round()}%', style: _t(22, w: FontWeight.w700))),
                ),
              ),
              const SizedBox(height: 10),
              Text(p.sub, style: _t(13.5, c: _dim)),
            ]),
        ]),
      ]),
    );
  }

  Widget _shiftTable(List<_Row4> rows) {
    Widget hdr(String s) => Text(s, style: _t(13.5, c: _dim));
    return _box(
      pad: EdgeInsets.zero,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(padding: const EdgeInsets.fromLTRB(18, 12, 18, 10), child: _title('Shift Parameter Summary')),
        Container(
          color: const Color(0xFF0E1F3C),
          padding: const EdgeInsets.fromLTRB(18, 9, 18, 9),
          child: Row(children: [
            Expanded(flex: 5, child: hdr('Parameter')),
            Expanded(flex: 3, child: hdr('Morning Shift')),
            Expanded(flex: 3, child: hdr('Current Shift')),
          ]),
        ),
        for (final r in rows)
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 18),
              decoration: const BoxDecoration(border: Border(top: BorderSide(color: Color(0xFF14284A)))),
              child: Row(children: [
                Expanded(flex: 5, child: Text(r.p, style: _t(r.hl ? 14.5 : 13.5, w: r.hl ? FontWeight.w700 : FontWeight.w500, h: 1.2))),
                Expanded(flex: 3, child: _val(r.m, r.mu, r.hl ? _blue : _ink)),
                Expanded(flex: 3, child: _val(r.c, r.cu, r.hl ? _red : _ink)),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _val(String v, String u, Color c) => FittedBox(
        fit: BoxFit.scaleDown,
        alignment: Alignment.centerLeft,
        child: Text.rich(TextSpan(children: [
          TextSpan(text: v, style: _t(20, w: FontWeight.w700, c: c)),
          if (u.isNotEmpty) TextSpan(text: ' $u', style: _t(14.5, w: FontWeight.w600, c: c)),
        ])),
      );

  Widget _indicators(List<_Ind> rows, List<(IconData, Color)> icons) {
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('Key Indicators (Today)'),
        const SizedBox(height: 6),
        for (var i = 0; i < rows.length; i++)
          Expanded(
            child: Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF14284A)))),
              child: Row(children: [
                SizedBox(width: 34, child: Icon(icons[i].$1, color: icons[i].$2, size: 22)),
                const SizedBox(width: 16),
                Expanded(child: Text(rows[i].label, style: _t(14.5))),
                SizedBox(
                  width: 96,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: rows[i].value, style: _t(17, w: FontWeight.w700)),
                      if (rows[i].unit.isNotEmpty) TextSpan(text: ' ${rows[i].unit}', style: _t(14, w: FontWeight.w600)),
                    ])),
                  ),
                ),
                SizedBox(
                  width: 76,
                  child: Text(
                    '${rows[i].dir > 0 ? '↑' : (rows[i].dir < 0 ? '↓' : '→')} ${rows[i].trend}',
                    textAlign: TextAlign.right,
                    style: _t(15, w: FontWeight.w600, c: rows[i].dir == 0 ? _dim : _green),
                  ),
                ),
              ]),
            ),
          ),
      ]),
    );
  }

  // ── Right column ────────────────────────────────────────────────────────

  /// [highlight] dims every other stage on a station tab.
  Widget _flowCard(String? highlight) {
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('Process Flow Overview'),
        const SizedBox(height: 18),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < _flow.length; i++) ...[
            Opacity(
              opacity: highlight == null || highlight == _flow[i].label ? 1 : .35,
              child: SizedBox(
                width: 72,
                child: Column(children: [
                  _roundIcon(_flow[i].icon, _flow[i].color, size: 48),
                  const SizedBox(height: 8),
                  Text(_flow[i].label, style: _t(13.5, h: 1.15), textAlign: TextAlign.center),
                ]),
              ),
            ),
            if (i < _flow.length - 1)
              const Padding(padding: EdgeInsets.only(top: 14), child: Icon(Icons.arrow_forward, color: _ink, size: 18)),
          ],
        ]),
      ]),
    );
  }

  Widget _healthCard(String title, List<_Hl> rows, List<(IconData, Color)> icons) {
    return _box(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title(title),
        const SizedBox(height: 6),
        for (var i = 0; i < rows.length; i++)
          Expanded(
            child: Container(
              decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: Color(0xFF14284A)))),
              child: Row(children: [
                _roundIcon(icons[i].$1, icons[i].$2, size: 34),
                const SizedBox(width: 22),
                SizedBox(
                  width: 124,
                  child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: Text(rows[i].label, style: _t(14))),
                ),
                Expanded(child: CustomPaint(size: const Size(double.infinity, 10), painter: _HealthBar(rows[i].v / 100))),
                SizedBox(width: 50, child: Text('${rows[i].v}', textAlign: TextAlign.right, style: _t(17, w: FontWeight.w700))),
              ]),
            ),
          ),
      ]),
    );
  }

  Widget _alertCard(List<_Al> alerts) {
    Color sevColor(String s) => s == 'High' ? _red : (s == 'Medium' ? _amber : _blue);
    return _box(
      pad: const EdgeInsets.fromLTRB(16, 12, 18, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        _title('Attention Required', trailing: Text('View All  ›', style: _t(13.5, c: _blue))),
        const SizedBox(height: 6),
        if (alerts.isEmpty) Padding(padding: const EdgeInsets.only(top: 20), child: Text('Nothing needs attention.', style: _t(14, c: _dim))),
        for (final a in alerts)
          SizedBox(
            height: 53,
            child: Row(children: [
              Container(
                width: 20, height: 20,
                decoration: BoxDecoration(shape: BoxShape.circle, color: sevColor(a.sev)),
                child: const Icon(Icons.priority_high, size: 14, color: Color(0xFF0A1830)),
              ),
              const SizedBox(width: 14),
              Container(
                width: 64, height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: sevColor(a.sev).withOpacity(.12),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: sevColor(a.sev).withOpacity(.6)),
                ),
                child: Text(a.sev, style: _t(13.5, c: sevColor(a.sev), w: FontWeight.w600)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(a.title, style: _t(14.5, w: FontWeight.w700)),
                  Text(a.msg, style: _t(12.5, c: _dim), maxLines: 1, overflow: TextOverflow.ellipsis),
                ]),
              ),
              Text(a.time, style: _t(13, c: _dim)),
            ]),
          ),
      ]),
    );
  }
}

// ── Painters ────────────────────────────────────────────────────────────

class _Ring extends CustomPainter {
  _Ring(this.pct, this.colors);
  final double pct;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 9.0;
    final rect = Rect.fromLTWH(stroke / 2, stroke / 2, size.width - stroke, size.height - stroke);
    canvas.drawArc(rect, 0, math.pi * 2, false, Paint()..color = const Color(0xFF16284A)..style = PaintingStyle.stroke..strokeWidth = stroke);
    final sweep = math.pi * 2 * pct;
    final shader = SweepGradient(startAngle: 0, endAngle: sweep, colors: colors, transform: const GradientRotation(-math.pi / 2)).createShader(rect);
    canvas.drawArc(rect, -math.pi / 2, sweep, false,
        Paint()..shader = shader..style = PaintingStyle.stroke..strokeWidth = stroke..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _Ring old) => old.pct != pct;
}

class _Spark extends CustomPainter {
  _Spark({required this.seed});
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    const n = 14;
    final w = size.width / n;
    for (var i = 0; i < n; i++) {
      final h = size.height * (.25 + .75 * ((math.sin(i * 1.3 + seed) + 1) / 2) * (0.55 + i / n * .45));
      final paint = Paint()..color = Color.lerp(const Color(0xFF1F5FC8), const Color(0xFF58B4FF), i / n)!;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(i * w + 1, size.height - h, w - 2.2, h), const Radius.circular(1)), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _Spark old) => false;
}

class _HealthBar extends CustomPainter {
  _HealthBar(this.pct);
  final double pct;

  @override
  void paint(Canvas canvas, Size size) {
    final h = 10.0;
    final top = (size.height - h) / 2;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, top, size.width, h), const Radius.circular(3)), Paint()..color = const Color(0xFF1A2C4E));
    // Green segments, then an orange tail up to the score, as in the mockup.
    final end = size.width * pct;
    final greenEnd = end - size.width * .14;
    const segs = 4;
    final segW = greenEnd / segs;
    for (var i = 0; i < segs; i++) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(i * segW, top, segW - 2, h), const Radius.circular(2)), Paint()..color = const Color(0xFF34C77B));
    }
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(greenEnd, top, end - greenEnd, h), const Radius.circular(2)), Paint()..color = const Color(0xFFF08A3C));
  }

  @override
  bool shouldRepaint(covariant _HealthBar old) => old.pct != pct;
}
