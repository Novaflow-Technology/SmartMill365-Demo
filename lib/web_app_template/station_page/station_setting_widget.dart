import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '/flutter_flow/flutter_flow_util.dart';
import 'station_models.dart';
import 'station_service.dart';
import 'station_view.dart';

/// Station Page Setting — one template per station type (Sterilizer,
/// Digester), shared by every account.
///
/// ① Data setup: the lines (equipment in the station's category, managed in
/// Equipment Settings), the points every line has, each line's data mapping,
/// and the rules. ② Layout: what the page shows, edited next to a live
/// preview that is the real station page, with clickable parts.
class StationSettingWidget extends StatefulWidget {
  const StationSettingWidget({super.key, this.initialStation});
  final String? initialStation;

  @override
  State<StationSettingWidget> createState() => _StationSettingWidgetState();
}

class _Check {
  const _Check(this.level, this.title, {this.detail, this.step, this.region, this.lineId});
  final String level; // err | warn | info
  final String title;
  final String? detail;
  final int? step;
  final String? region;
  final String? lineId;
}

class _StationSettingWidgetState extends State<StationSettingWidget> {
  late StationDef _st = stationByKey(widget.initialStation) ?? kSterilizerStation;
  StationSettings? _s;
  String _savedJson = '';
  List<Map<String, dynamic>> _equipment = [];
  List<String> _devices = [];
  final Map<String, List<DeviceField>> _fields = {};
  Map<String, Map<String, double>> _latest = {};
  bool _loading = true;
  bool _saving = false;

  String _tab = 'data';
  int _step = 1;
  String _region = 'cards';
  String? _mapLine;
  bool _checksOpen = false;

  /// Field-name patterns per point, `#` = the line's number (Auto-map).
  static const Map<String, List<(String, String)>> _patterns = {
    'pressure': [('PSTR_bar', 'stp#')],
    'temperature': [('PSTR_temp', 'stp#')],
    'digCurrent': [('PDIG_ma_A', 'dig#'), ('PDIG_motor_amp', 'dga#')],
    'pressCurrent': [('PDIG_ma_A', 'press#'), ('PDIG_motor_amp', 'spa#')],
    'pressHours': [('PDIG_rh_hr', 'press#'), ('PDIG_HourRun', 'sp#hr')],
  };

  bool get _dirty => _s != null && jsonEncode(_s!.toJson()) != _savedJson;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final r = await Future.wait([
      StationService.equipmentFor(_st),
      StationService.loadSettings(_st),
      if (_devices.isEmpty) StationService.devices(),
    ]);
    _equipment = r[0] as List<Map<String, dynamic>>;
    final s = r[1] as StationSettings;
    if (r.length > 2) _devices = r[2] as List<String>;
    final used = devicesOf(buildLines(_equipment, s, includeHidden: true), _st);
    await Future.wait(used.map(_ensureFields));
    await _refreshLatest(s, used);
    if (!mounted) return;
    setState(() {
      _s = s;
      _savedJson = jsonEncode(s.toJson());
      _mapLine = _equipment.isNotEmpty ? _equipment.first['id'].toString() : null;
      _loading = false;
    });
  }

  Future<void> _refreshLatest(StationSettings s, Set<String> devices) async {
    final out = <String, Map<String, double>>{..._latest};
    await Future.wait(devices.where((d) => !out.containsKey(d)).map((d) async => out[d] = await StationService.latest(d)));
    _latest = out;
  }

  Future<void> _ensureFields(String device) async {
    if (device.isEmpty || _fields.containsKey(device)) return;
    final f = await StationService.fields(device);
    if (mounted) setState(() => _fields[device] = f);
  }

  void _edit(VoidCallback f) => setState(f);

  /// Picks each point's field on [device] from line number [n].
  Future<int> _autoMap(String equipmentId, int n, String device) async {
    await _ensureFields(device);
    final fields = _fields[device] ?? [];
    final line = _s!.line(equipmentId);
    var got = 0;
    for (final p in _st.points) {
      for (final (meas, pattern) in _patterns[p.key] ?? const <(String, String)>[]) {
        final want = pattern.replaceAll('#', '$n');
        if (fields.any((f) => f.measurement == meas && f.field == want)) {
          line.sources[p.key] = PointSource(device: device, measurement: meas, field: want);
          got++;
          break;
        }
      }
    }
    await _refreshLatest(_s!, {device});
    return got;
  }

  void _toast(String msg, {bool ok = true}) => ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: ok ? const Color(0xFF14365F) : const Color(0xFF7A1F1F)));

  Future<void> _publish() async {
    final errs = _checks().where((c) => c.level == 'err').length;
    if (errs > 0) {
      setState(() => _checksOpen = true);
      _toast('Fix $errs error${errs > 1 ? 's' : ''} before publishing', ok: false);
      return;
    }
    setState(() => _saving = true);
    final ok = await StationService.saveSettings(_st, _s!);
    if (!mounted) return;
    setState(() {
      _saving = false;
      if (ok) _savedJson = jsonEncode(_s!.toJson());
    });
    _toast(ok ? 'Published to the ${_st.name} station page' : 'Could not publish — try again', ok: ok);
  }

  void _discard() {
    if (!_dirty) return _toast('No changes to discard');
    setState(() => _s = StationSettings.fromJson(_st, jsonDecode(_savedJson) as Map<String, dynamic>));
    _toast('Changes discarded');
  }

  // ── derived ─────────────────────────────────────────────────────────────
  List<StationLine> get _allLines => buildLines(_equipment, _s!, includeHidden: true);

  List<String> get _required => [for (final p in _st.points) if (!p.optional) p.key];

  /// Lines with their values worked out from live data (samples marked).
  List<StationLine> get _evaluated {
    final lines = _allLines;
    evaluateLines(lines, _s!, _latest);
    return lines;
  }

  /// Readings (every point of every shown line) that come from live data.
  (int, int) get _mapCount {
    var ok = 0, tot = 0;
    for (final l in _evaluated.where((l) => l.setting.shown)) {
      for (final p in _st.points) {
        tot++;
        if (l.has(p.key) && !l.sampled.contains(p.key)) ok++;
      }
    }
    return (ok, tot);
  }

  List<_Check> _checks() {
    final s = _s!;
    final out = <_Check>[];
    final lines = _allLines.where((l) => l.setting.shown).toList();
    if (_equipment.isEmpty) {
      out.add(_Check('warn', 'Showing sample lines',
          detail: 'No equipment has the "${_st.mainPart}" category yet. Add it in Equipment Settings; sample lines read the live devices meanwhile.', step: 1));
    }
    final evaluated = _evaluated.where((l) => l.setting.shown).toList();
    final un = [
      for (final l in evaluated)
        for (final k in l.sampled)
          if (!(_st.point(k)?.optional ?? false)) (l, k),
    ];
    final optSample = evaluated.fold<int>(0, (n, l) => n + l.sampled.where((k) => _st.point(k)?.optional ?? false).length);
    if (optSample > 0) {
      out.add(_Check('info', '$optSample optional reading${optSample > 1 ? 's' : ''} use sample values',
          detail: 'No device measures them yet (e.g. ${_st.points.where((p) => p.optional).map((p) => p.label.toLowerCase()).join(', ')}). Map a field in Data mapping when one exists.',
          step: 3));
    }
    if (un.isNotEmpty) {
      out.add(_Check('warn', '${un.length} reading${un.length > 1 ? 's' : ''} have no live data and use sample values',
          detail: un.take(3).map((x) => '${x.$1.name}: ${_st.point(x.$2)!.label}').join('; ') + (un.length > 3 ? '; and ${un.length - 3} more' : ''),
          step: 3,
          lineId: un.first.$1.id));
    }
    if (_st.hoursPoint != null) {
      final miss = lines.where((l) => !(l.setting.serviceHours > 0)).toList();
      if (miss.isNotEmpty && s.alertSvc) {
        out.add(_Check('warn', 'No service interval for ${miss.map((l) => l.name).join(', ')}',
            detail: 'The service bar and the Service due alert need it.', step: 1));
      }
    }
    if (_st.tempPoint != null && s.alertTemp && s.alertMin >= s.alertMax) {
      out.add(const _Check('err', 'Temperature range is back to front', detail: 'The lowest temperature must be below the highest.', step: 4));
    }
    for (final p in _st.points) {
      if (s.minOf(p) >= s.maxOf(p)) out.add(_Check('err', 'Gauge range of ${p.label} is back to front', step: 2));
    }
    if (s.kpiShown.isEmpty) out.add(const _Check('info', 'The station overview has no tiles', region: 'kpi'));
    return out;
  }

  // ── small UI pieces (our palette) ───────────────────────────────────────
  static const _h1 = TextStyle(color: SC.text, fontSize: 24, fontWeight: FontWeight.w700);
  static const _body = TextStyle(color: SC.text, fontSize: 13);
  static const _muted = TextStyle(color: SC.dim, fontSize: 12.5);

  InputDecoration _deco([String? label]) => InputDecoration(
        labelText: label,
        isDense: true,
        labelStyle: const TextStyle(color: SC.dim, fontSize: 12),
        filled: true,
        fillColor: SC.inner,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: SC.border)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: const BorderSide(color: SC.accent)),
        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(7), borderSide: BorderSide(color: SC.border.withOpacity(.5))),
      );

  Widget _txt(String key, String value, ValueChanged<String> on, {String? label, double width = 200, String? hint}) => SizedBox(
        width: width,
        child: TextFormField(
          key: ValueKey('${_st.key}-$key'),
          initialValue: value,
          style: _body,
          decoration: _deco(label).copyWith(hintText: hint, hintStyle: const TextStyle(color: SC.faint, fontSize: 12)),
          onChanged: (v) => _edit(() => on(v)),
        ),
      );

  Widget _num(String key, double value, ValueChanged<double> on, {String? label, double width = 110}) => SizedBox(
        width: width,
        child: TextFormField(
          key: ValueKey('${_st.key}-$key'),
          initialValue: value % 1 == 0 ? value.toStringAsFixed(0) : '$value',
          style: _body,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: _deco(label),
          onChanged: (v) {
            final n = double.tryParse(v);
            if (n != null) _edit(() => on(n));
          },
        ),
      );

  Widget _drop<T>(T? value, List<(T, String)> items, ValueChanged<T?>? on, {String? label, double width = 220}) => SizedBox(
        width: width,
        child: DropdownButtonFormField<T>(
          value: items.any((i) => i.$1 == value) ? value : null,
          isExpanded: true,
          isDense: true,
          dropdownColor: SC.panelTop,
          style: _body,
          iconEnabledColor: SC.dim,
          decoration: _deco(label),
          items: [for (final (v, l) in items) DropdownMenuItem(value: v, child: Text(l, overflow: TextOverflow.ellipsis))],
          onChanged: on,
        ),
      );

  Widget _check(String label, bool value, ValueChanged<bool> on) => InkWell(
        onTap: () => _edit(() => on(!value)),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(value ? Icons.check_box : Icons.check_box_outline_blank, size: 18, color: value ? SC.accent : SC.dim),
            const SizedBox(width: 6),
            Text(label, style: _body),
          ]),
        ),
      );

  Widget _btn(String label, VoidCallback? on, {bool primary = false, bool ghost = false, IconData? icon, bool small = false}) {
    final fg = primary ? const Color(0xFF04121F) : ghost ? SC.dim : SC.text;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: on,
      child: Opacity(
        opacity: on == null ? .45 : 1,
        child: Container(
          padding: EdgeInsets.symmetric(horizontal: small ? 10 : 14, vertical: small ? 6 : 9),
          decoration: BoxDecoration(
            color: primary ? SC.accent : ghost ? Colors.transparent : SC.inner,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: primary ? SC.accent : SC.border),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 15, color: fg), const SizedBox(width: 6)],
            Text(label, style: TextStyle(color: fg, fontSize: small ? 12 : 13, fontWeight: FontWeight.w600)),
          ]),
        ),
      ),
    );
  }

  Widget _badge(String text, Color c) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(color: c.withOpacity(.1), borderRadius: BorderRadius.circular(999), border: Border.all(color: c.withOpacity(.45))),
        child: Text(text, style: TextStyle(color: c, fontSize: 11, fontWeight: FontWeight.w600)),
      );

  Widget _panel(IconData icon, Color color, String title, String desc, List<Widget> body, {String? tag}) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: SC.panel(),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(9), border: Border.all(color: color.withOpacity(.35))),
                child: Icon(icon, size: 18, color: color),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(title, style: const TextStyle(color: SC.text, fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(desc, style: _muted),
                ]),
              ),
              if (tag != null) _badge(tag, SC.dim),
            ]),
          ),
          const Divider(height: 1, color: SC.border),
          ...body,
        ]),
      );

  Widget _pb(List<Widget> children, {String? heading}) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (heading != null) Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(heading, style: const TextStyle(color: SC.text, fontSize: 13.5, fontWeight: FontWeight.w700))),
          ...children,
        ]),
      );

  Widget _table(List<String> head, List<List<Widget>> rows, {List<double?>? widths}) => SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DataTable(
          headingRowHeight: 38,
          dataRowMinHeight: 50,
          dataRowMaxHeight: 62,
          columnSpacing: 18,
          headingRowColor: WidgetStateProperty.all(SC.inner),
          dividerThickness: .5,
          headingTextStyle: const TextStyle(color: SC.dim, fontSize: 12, fontWeight: FontWeight.w600),
          dataTextStyle: _body,
          columns: [for (final h in head) DataColumn(label: Text(h))],
          rows: [for (final r in rows) DataRow(cells: [for (final c in r) DataCell(c)])],
        ),
      );

  // ── page ────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final s = _s;
    return Container(
      color: const Color(0xFF061126),
      child: Stack(children: [
        Column(children: [
          _header(),
          _tabs(),
          Expanded(
            child: _loading || s == null
                ? const Center(child: CircularProgressIndicator(color: SC.accent))
                : _tab == 'data'
                    ? _dataTab(s)
                    : _layoutTab(s),
          ),
          if (s != null) _footer(),
        ]),
        if (_checksOpen && s != null) _checksPopover(),
      ]),
    );
  }

  Widget _header() {
    final (ok, tot) = _s == null ? (0, 0) : _mapCount;
    final pct = tot == 0 ? 0.0 : ok / tot;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 14),
      decoration: const BoxDecoration(color: SC.panelTop, border: Border(bottom: BorderSide(color: SC.border))),
      child: Wrap(spacing: 18, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.center, alignment: WrapAlignment.spaceBetween, children: [
        const Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Station Page Setting', style: _h1),
          Text('Template: Station page (equipment details). One template per station type, shared by every account.', style: _muted),
        ]),
        Row(mainAxisSize: MainAxisSize.min, children: [
          const Text('Station  ', style: _muted),
          _drop<String>(_st.key, [for (final st in kStations) (st.key, st.name)], (k) async {
            if (k == null || k == _st.key) return;
            if (_dirty && !await _confirm('Discard unsaved changes?')) return;
            setState(() => _st = stationByKey(k)!);
            _load();
          }, width: 190),
          const SizedBox(width: 18),
          SizedBox(
            width: 44,
            height: 44,
            child: Stack(alignment: Alignment.center, children: [
              CircularProgressIndicator(value: pct, strokeWidth: 5, backgroundColor: SC.border, color: pct == 1 ? SC.run : SC.warn),
            ]),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text('$ok / $tot', style: const TextStyle(color: SC.text, fontSize: 15, fontWeight: FontWeight.w700)),
            const Text('readings live', style: _muted),
          ]),
          const SizedBox(width: 18),
          _btn('Export config (JSON)', _s == null ? null : _export),
        ]),
      ]),
    );
  }

  Widget _tabs() {
    Widget tab(String id, String title, String sub) {
      final on = _tab == id;
      return InkWell(
        onTap: () => setState(() => _tab = id),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 11),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? SC.accent : Colors.transparent, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(color: on ? SC.text : SC.dim, fontSize: 15, fontWeight: FontWeight.w700)),
            Text(sub, style: const TextStyle(color: SC.faint, fontSize: 12)),
          ]),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.only(left: 24, top: 6),
      decoration: const BoxDecoration(color: SC.panelTop, border: Border(bottom: BorderSide(color: SC.border))),
      child: Wrap(children: [
        tab('data', '① Data setup', 'Lines, points, mapping and rules. Set once.'),
        tab('layout', '② Layout', 'Click any part of the page to edit it'),
      ]),
    );
  }

  // ── ① data setup ────────────────────────────────────────────────────────
  Widget _dataTab(StationSettings s) {
    final checks = _checks();
    final (ok, tot) = _mapCount;
    final steps = [
      (1, 'Lines', '${_allLines.where((l) => l.setting.shown).length} of ${_equipment.length} lines shown'),
      (2, 'Points', '${_st.points.length} points on each line'),
      (3, 'Data mapping', '$ok of $tot mapped'),
      (4, 'Rules', 'Status, alerts'),
    ];
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        LayoutBuilder(builder: (context, c) {
          final per = c.maxWidth > 900 ? 4 : 2;
          final w = (c.maxWidth - 8 * (per - 1)) / per;
          return Wrap(spacing: 8, runSpacing: 8, children: [
            for (final (n, name, sub) in steps)
              SizedBox(
                width: w,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () => setState(() => _step = n),
                  child: Builder(builder: (_) {
                    final on = _step == n;
                    final mine = checks.where((x) => x.step == n && x.level != 'info');
                    final lv = mine.any((x) => x.level == 'err') ? SC.stop : mine.isNotEmpty ? SC.warn : null;
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                      decoration: BoxDecoration(
                        color: SC.panelTop,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: on ? SC.accent : SC.border, width: on ? 2 : 1),
                      ),
                      child: Row(children: [
                        Container(
                          width: 28,
                          height: 28,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(shape: BoxShape.circle, color: on ? SC.accent : SC.inner, border: Border.all(color: on ? SC.accent : SC.border)),
                          child: Text('$n', style: TextStyle(color: on ? const Color(0xFF04121F) : SC.text, fontWeight: FontWeight.w700, fontSize: 13)),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(name, style: const TextStyle(color: SC.text, fontSize: 14, fontWeight: FontWeight.w700)),
                            Text(sub, style: _muted, maxLines: 1, overflow: TextOverflow.ellipsis),
                          ]),
                        ),
                        if (lv != null) Container(width: 9, height: 9, decoration: BoxDecoration(color: lv, shape: BoxShape.circle)),
                      ]),
                    );
                  }),
                ),
              ),
          ]);
        }),
        const SizedBox(height: 16),
        switch (_step) {
          1 => _linesPanel(s),
          2 => _pointsPanel(s),
          3 => _mappingPanel(s),
          _ => _rulesPanel(s),
        },
        Row(children: [
          if (_step > 1) _btn('Back: ${steps[_step - 2].$2}', () => setState(() => _step--)),
          const Spacer(),
          if (_step < 4)
            _btn('Next: ${steps[_step].$2}', () => setState(() => _step++), primary: true)
          else
            _btn('Next: arrange the layout', () => setState(() => _tab = 'layout'), primary: true),
        ]),
      ]),
    );
  }

  Widget _linesPanel(StationSettings s) {
    final lines = _allLines;
    void move(int i, int d) {
      final j = i + d;
      if (j < 0 || j >= lines.length) return;
      final list = [...lines];
      final x = list.removeAt(i);
      list.insert(j, x);
      _edit(() {
        for (final (k, l) in list.indexed) {
          l.setting.order = k;
        }
      });
    }

    return _panel(
      Icons.view_column_outlined,
      const Color(0xFF8F82FF),
      'Lines',
      'Each equipment with the "${_st.mainPart}" category in Equipment Settings is one line: one card, one set of mapped points and one chart line. '
          'Add or remove lines in Equipment Settings; here you order them, name the second part and set the service interval.',
      [
        if (_equipment.isEmpty)
          _pb([
            Text(
                'No equipment has the "${st.mainPart}" category yet, so the page shows ${lines.length} sample lines on the live devices. '
                'Add your ${st.mainPart.toLowerCase()}s in Equipment Settings (device type "${st.key == 'digester' ? 'Digester & Screw Press' : 'Sterilizer'}") '
                'and name them with a number, e.g. "${st.mainPart} 1".',
                style: _muted),
          ])
        else
          _table([
            'Order',
            'Code',
            st.mainPart,
            if (st.subPart != null) st.subPart!,
            if (st.hoursPoint != null) 'Service every (hrs)',
            'Shown',
          ], [
            for (final (i, l) in lines.indexed)
              [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton(icon: const Icon(Icons.arrow_upward, size: 16, color: SC.dim), onPressed: i == 0 ? null : () => move(i, -1)),
                  IconButton(icon: const Icon(Icons.arrow_downward, size: 16, color: SC.dim), onPressed: i == lines.length - 1 ? null : () => move(i, 1)),
                ]),
                Text('${l.number}', style: _body),
                Text(l.name, style: const TextStyle(color: SC.text, fontWeight: FontWeight.w600)),
                if (st.subPart != null) _txt('sub-${l.id}', l.setting.subName, (v) => l.setting.subName = v, width: 150, hint: l.subName(st)),
                if (st.hoursPoint != null) _num('svc-${l.id}', l.setting.serviceHours, (v) => l.setting.serviceHours = v, width: 100),
                Checkbox(
                  value: l.setting.shown,
                  activeColor: SC.accent,
                  side: const BorderSide(color: SC.border, width: 1.5),
                  onChanged: (v) => _edit(() => l.setting.shown = v ?? true),
                ),
              ],
          ]),
        _pb([
          Wrap(spacing: 12, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _btn('+ Add line in Equipment Settings', () => context.pushNamed('EquipmentSettings').then((_) => _load()), small: true),
            Text('The code is the number in the equipment name; Auto-map uses it to find the device fields.', style: _muted),
          ]),
        ]),
      ],
      tag: '${lines.length} lines',
    );
  }

  StationDef get st => _st;

  Widget _pointsPanel(StationSettings s) => _panel(
        Icons.adjust,
        SC.accent,
        'Points',
        'What every line measures, defined once for all lines. Cards, overview, rules and the chart all pick from this list.',
        [
          _table(['Point', 'Short label', 'Belongs to', 'Type', 'Unit', 'Gauge range', ''], [
            for (final p in st.points)
              [
                Text(p.label, style: const TextStyle(color: SC.text, fontWeight: FontWeight.w600)),
                Text(p.short, style: _body),
                Text(p.part == 'main' ? st.mainPart : (st.subPart ?? '—'), style: _body),
                Text(p.kind == PointKind.counter ? 'Counter' : 'Analog value', style: _body),
                Text(p.unit, style: _body),
                p.kind == PointKind.analog
                    ? Row(mainAxisSize: MainAxisSize.min, children: [
                        _num('min-${p.key}', s.minOf(p), (v) => s.ranges[p.key] = [v, s.maxOf(p)], width: 70),
                        const Text('  to  ', style: _muted),
                        _num('max-${p.key}', s.maxOf(p), (v) => s.ranges[p.key] = [s.minOf(p), v], width: 74),
                      ])
                    : const Text('—', style: _muted),
                p.optional ? _badge('Optional', SC.warn) : _badge('Core', SC.dim),
              ],
          ]),
          _pb([
            Text(
              st.key == 'digester'
                  ? 'Temperature and level switches are not measured on SmartMill digesters today, so they are not points. Optional points are left off a card when not mapped.'
                  : 'Temperature is optional: only some sterilizers report it. It shows on a card, and in the alert, only where it is mapped.',
              style: _muted,
            ),
          ]),
        ],
        tag: '${st.points.length} points',
      );

  Widget _mappingPanel(StationSettings s) {
    final lines = _allLines;
    if (lines.isEmpty) {
      return _panel(Icons.link, const Color(0xFF2F7DE1), 'Data mapping', 'Add a line first, in Equipment Settings.', const []);
    }
    evaluateLines(lines, s, _latest);
    final l = lines.firstWhere((x) => x.id == _mapLine, orElse: () => lines.first);
    final readOnly = l.isSample;
    final own = l.setting.sources.values.map((x) => x.device).firstWhere((d) => d.isNotEmpty, orElse: () => '');
    final device = own.isNotEmpty ? own : (l.source(st, st.mainPoint)?.device ?? '');
    return _panel(
      Icons.link,
      const Color(0xFF2F7DE1),
      'Data mapping',
      'Map one line, then copy the pattern to the other lines. Picking a device auto-maps the fields from the line number.',
      [
        _pb([
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final x in lines)
              ChoiceChip(
                selected: x.id == l.id,
                selectedColor: SC.accent,
                backgroundColor: SC.inner,
                side: BorderSide(color: x.id == l.id ? SC.accent : SC.border),
                label: Text('${x.name}   ${st.points.where((p) => x.has(p.key) && !x.sampled.contains(p.key)).length}/${st.points.length} live',
                    style: TextStyle(color: x.id == l.id ? const Color(0xFF04121F) : SC.text, fontSize: 12.5, fontWeight: FontWeight.w600)),
                onSelected: (_) => setState(() => _mapLine = x.id),
              ),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (readOnly)
              const Text('Sample line: add equipment to map it.', style: _muted)
            else
            _drop<String>(device.isEmpty ? null : device, [for (final d in _devices) (d, d)], (v) async {
              if (v == null) return;
              final got = await _autoMap(l.id, l.number, v);
              _edit(() {
                for (final p in st.points) {
                  final cur = l.setting.sources[p.key];
                  if (cur != null && cur.device != v) l.setting.sources.remove(p.key);
                }
              });
              _toast(got > 0 ? 'Device set · $got field(s) auto-mapped for line ${l.number}' : 'Device set. No field matched line ${l.number} — pick them below.');
            }, label: own.isEmpty ? 'Device for ${l.name} (default)' : 'Device for ${l.name}', width: 300),
          ]),
        ]),
        _table(['Point', 'Field', 'Source', 'Live value', 'State'], [
          for (final p in st.points)
            () {
              final src = l.source(st, p.key);
              final ownSrc = l.setting.sources[p.key];
              final dev = src?.device.isNotEmpty == true ? src!.device : device;
              final options = _fields[dev] ?? const <DeviceField>[];
              final value = l.values[p.key];
              final isSample = l.sampled.contains(p.key);
              return <Widget>[
                Text(p.label + (p.optional ? '  (optional)' : ''), style: const TextStyle(color: SC.text, fontWeight: FontWeight.w600)),
                _drop<String>(
                  src != null && src.isSet ? '${src.measurement}|${src.field}' : '',
                  [('', '— not mapped —'), for (final f in options) ('${f.measurement}|${f.field}', f.label)],
                  dev.isEmpty || readOnly
                      ? null
                      : (v) => _edit(() {
                            if (v == null || v.isEmpty) {
                              l.setting.sources.remove(p.key);
                            } else {
                              final parts = v.split('|');
                              l.setting.sources[p.key] = PointSource(device: dev, measurement: parts[0], field: parts.length > 1 ? parts[1] : '');
                            }
                          }),
                  width: 230,
                ),
                isSample ? _badge('Sample', SC.faint) : _badge(dev.isEmpty ? '—' : dev, const Color(0xFF2F7DE1)),
                Text(value == null ? '—' : '${value.toStringAsFixed(p.decimals)} ${p.unit}', style: TextStyle(color: isSample ? SC.faint : SC.text, fontSize: 13)),
                isSample
                    ? _badge('Sample value', SC.warn)
                    : ownSrc != null && ownSrc.isSet
                        ? _badge('Mapped · live', SC.run)
                        : _badge('Default · live', SC.accent),
              ];
            }(),
        ]),
        _pb([
          Wrap(spacing: 10, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _btn('Auto-map ${l.name}', device.isEmpty || readOnly
                ? null
                : () async {
                    final got = await _autoMap(l.id, l.number, device);
                    _edit(() {});
                    _toast('Auto-mapped $got field(s) for ${l.name}');
                  }, small: true, icon: Icons.auto_fix_high),
            _btn("Apply ${l.name}'s device to every line", device.isEmpty || lines.length < 2 || readOnly
                ? null
                : () async {
                    var got = 0;
                    for (final x in lines) {
                      got += await _autoMap(x.id, x.number, device);
                    }
                    _edit(() {});
                    _toast('$got field(s) mapped across ${lines.length} lines');
                  }, small: true),
            const Text('Fields swap to each line\'s number (dig1 → dig2 …).', style: _muted),
          ]),
        ]),
      ],
      tag: '${l.name}',
    );
  }

  Widget _rulesPanel(StationSettings s) {
    final main = st.point(st.mainPoint)!;
    final sub = st.point(st.subOnPoint);
    final lines = buildLines(_equipment, s);
    evaluateLines(lines, s, _latest);
    Widget strip() => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final l in lines)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(color: SC.inner, borderRadius: BorderRadius.circular(6), border: Border.all(color: SC.border)),
                child: Row(mainAxisSize: MainAxisSize.min, children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: switch (l.status) {
                        LineStatus.running => SC.run,
                        LineStatus.partial => SC.warn,
                        LineStatus.stopped => SC.stop,
                        LineStatus.unmapped => SC.idle,
                      },
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text('${l.name}: ${switch (l.status) {
                    LineStatus.running => s.runLabel,
                    LineStatus.partial => s.partLabel,
                    LineStatus.stopped => s.stopLabel,
                    LineStatus.unmapped => 'not mapped',
                  }}${l.alert != null ? ' · ${l.alert}' : ''}', style: const TextStyle(color: SC.text, fontSize: 12)),
                ]),
              ),
          ]),
        );
    return _panel(Icons.rule, SC.warn, 'Rules', 'How status and alerts are worked out from the points. Defined once for every line.', [
      _pb(heading: 'Line status', [
        Wrap(spacing: 12, runSpacing: 12, children: [
          _num('mainOn', s.mainOnAbove, (v) => s.mainOnAbove = v, label: '${st.mainPart} counts as on above (${main.unit})', width: 240),
          if (sub != null) _num('subOn', s.subOnAbove, (v) => s.subOnAbove = v, label: '${st.subPart} counts as on above (${sub.unit})', width: 240),
        ]),
        const SizedBox(height: 10),
        Text(
          sub != null
              ? 'Checked in order: both on is ${s.runLabel}; only one on is ${s.partLabel}; both off is ${s.stopLabel}.'
              : 'Above the threshold is ${s.runLabel}; otherwise ${s.stopLabel}.',
          style: _muted,
        ),
        const SizedBox(height: 10),
        Wrap(spacing: 12, runSpacing: 12, children: [
          _txt('runLabel', s.runLabel, (v) => s.runLabel = v, label: 'Running label', width: 170),
          _txt('stopLabel', s.stopLabel, (v) => s.stopLabel = v, label: 'Stopped label', width: 170),
          if (sub != null) _txt('partLabel', s.partLabel, (v) => s.partLabel = v, label: 'One-part-on label', width: 170),
        ]),
        strip(),
      ]),
      const Divider(height: 1, color: SC.border),
      _pb(heading: 'Alerts on a card', [
        _table(['Alert', 'When', 'Banner text'], [
          if (st.tempPoint != null)
            [
              _check('Temperature', s.alertTemp, (v) => s.alertTemp = v),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Running and outside  ', style: _muted),
                _num('tMin', s.alertMin, (v) => s.alertMin = v, width: 70),
                const Text('  to  ', style: _muted),
                _num('tMax', s.alertMax, (v) => s.alertMax = v, width: 70),
                const Text('  °C', style: _muted),
              ]),
              _txt('tempText', s.alertTempText, (v) => s.alertTempText = v, width: 220),
            ],
          if (st.hoursPoint != null)
            [
              _check('Service due', s.alertSvc, (v) => s.alertSvc = v),
              Row(mainAxisSize: MainAxisSize.min, children: [
                const Text('Running hours reach  ', style: _muted),
                _num('svcPct', s.servicePct, (v) => s.servicePct = v, width: 70),
                const Text('  % of interval', style: _muted),
              ]),
              _txt('svcText', s.alertSvcText, (v) => s.alertSvcText = v, width: 220),
            ],
        ]),
        const SizedBox(height: 8),
        const Text('A card shows the first alert that applies. Active alarms on the overview counts cards with an alert.', style: _muted),
      ]),
    ]);
  }

  // ── ② layout ────────────────────────────────────────────────────────────
  Widget _layoutTab(StationSettings s) {
    final lines = buildLines(_equipment, s);
    evaluateLines(lines, s, _latest);
    String site = '';
    for (final l in lines) {
      final src = l.setting.sources[st.mainPoint];
      if (src != null && src.isSet) {
        site = src.device;
        break;
      }
    }
    final preview = Container(
      decoration: SC.panel(),
      padding: const EdgeInsets.all(12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          const Text('Live preview', style: TextStyle(color: SC.text, fontSize: 15, fontWeight: FontWeight.w700)),
          const Spacer(),
          Text('Click a part to edit it', style: _muted.copyWith(fontSize: 12)),
        ]),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final (k, label) in kStationRegions)
            ChoiceChip(
              selected: _region == k,
              selectedColor: SC.accent,
              backgroundColor: SC.inner,
              side: BorderSide(color: _region == k ? SC.accent : SC.border),
              label: Text(label, style: TextStyle(color: _region == k ? const Color(0xFF04121F) : SC.text, fontSize: 12.5, fontWeight: FontWeight.w600)),
              onSelected: (_) => setState(() => _region = k),
            ),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Container(
            color: const Color(0xFF061126),
            child: FittedBox(
              fit: BoxFit.fitWidth,
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 1280,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: StationView(
                    settings: s,
                    lines: lines,
                    trend: const {},
                    updated: DateTime.now(),
                    range: s.defaultRange,
                    combined: true,
                    siteName: site,
                    selectedRegion: _region,
                    onRegion: (r) => setState(() => _region = r),
                  ),
                ),
              ),
            ),
          ),
        ),
      ]),
    );
    final editor = switch (_region) {
      'head' => _headPanel(s),
      'kpi' => _kpiPanel(s),
      'chart' => _chartPanel(s),
      _ => _cardsPanel(s),
    };
    return LayoutBuilder(builder: (context, c) {
      if (c.maxWidth < 1100) {
        return SingleChildScrollView(padding: const EdgeInsets.all(24), child: Column(children: [editor, preview]));
      }
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(flex: 5, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(24, 16, 10, 24), child: editor)),
        Expanded(flex: 6, child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(10, 16, 24, 24), child: preview)),
      ]);
    });
  }

  Widget _headPanel(StationSettings s) => _panel(Icons.title, const Color(0xFF3D7FE0), 'Title and toolbar', 'The title and the toolbar above the page.', [
        _pb([
          Wrap(spacing: 12, runSpacing: 12, children: [
            _txt('prefix', s.prefix, (v) => s.prefix = v, label: 'Code before the name', width: 150),
            _txt('title', s.title, (v) => s.title = v, label: 'Station name', width: 220),
            _txt('suffix', s.suffix, (v) => s.suffix = v, label: 'Text after the name', width: 150),
          ]),
          const SizedBox(height: 8),
          Text('Title now: ${s.fullTitle}', style: _muted),
          const SizedBox(height: 8),
          Wrap(spacing: 16, children: [
            _check('Mill site', s.showSite, (v) => s.showSite = v),
            _check('Last updated time', s.showUpdated, (v) => s.showUpdated = v),
          ]),
        ]),
        const Divider(height: 1, color: SC.border),
        _pb(heading: 'Toolbar', [
          Wrap(spacing: 16, children: [
            _check('Device count', s.tbDevices, (v) => s.tbDevices = v),
            _check('Individual / Combined', s.tbMode, (v) => s.tbMode = v),
            _check('Time range', s.tbRange, (v) => s.tbRange = v),
            _check('Refresh rate', s.tbRefresh, (v) => s.tbRefresh = v),
            _check('AI analysis', s.tbAi, (v) => s.tbAi = v),
          ]),
          const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 12, children: [
            _drop<String>(s.defaultRange, const [('1h', '1 Hour'), ('6h', '6 Hours'), ('24h', '24 Hours')], (v) => _edit(() => s.defaultRange = v ?? '6h'),
                label: 'Opens on', width: 160),
            _drop<int>(s.refreshSec, const [(5, '5s'), (10, '10s'), (30, '30s'), (60, '60s')], (v) => _edit(() => s.refreshSec = v ?? 10),
                label: 'Default refresh', width: 160),
          ]),
        ]),
      ]);

  Widget _kpiPanel(StationSettings s) => _panel(Icons.insights, SC.run, 'Station overview', 'Headline figures worked out across the lines. Nothing here is mapped again.', [
        _pb([
          _txt('ovTitle', s.overviewTitle, (v) => s.overviewTitle = v, label: 'Section title', width: 280),
          const SizedBox(height: 12),
          for (final k in st.kpis) _check(k.title, s.kpiShown.contains(k.key), (v) => v ? s.kpiShown.add(k.key) : s.kpiShown.remove(k.key)),
          const SizedBox(height: 6),
          const Text('Averages use running lines only, so stopped and cold lines do not drag them down.', style: _muted),
        ]),
      ], tag: '${s.kpiShown.length} tiles');

  Widget _cardsPanel(StationSettings s) => _panel(Icons.dashboard_outlined, SC.warn, 'Line cards', 'One template, drawn once per line.', [
        _pb([
          Wrap(spacing: 12, runSpacing: 12, children: [
            _txt('cardsTitle', s.cardsTitle, (v) => s.cardsTitle = v, label: 'Section title', width: 280),
            _drop<int>(s.perRow, const [(0, 'Fit all lines'), (3, '3'), (4, '4'), (5, '5'), (6, '6')], (v) => _edit(() => s.perRow = v ?? 0),
                label: 'Cards per row', width: 160),
          ]),
          const SizedBox(height: 10),
          Wrap(spacing: 16, children: [
            _check('Count chips next to the title', s.cardChips, (v) => s.cardChips = v),
            _check('Legend under the cards', s.cardLegend, (v) => s.cardLegend = v),
          ]),
        ]),
        const Divider(height: 1, color: SC.border),
        _pb(heading: 'Picture', [
          Wrap(spacing: 16, children: [
            _check('Show picture', s.cardPicture, (v) => s.cardPicture = v),
            _check('On / off tags', s.cardTags, (v) => s.cardTags = v),
          ]),
          const SizedBox(height: 6),
          Text('The picture dims when the ${st.mainPart.toLowerCase()} is off. Temperature shows in its corner where it is mapped.', style: _muted),
        ]),
      ]);

  Widget _chartPanel(StationSettings s) => _panel(Icons.show_chart, const Color(0xFFA78BFA), 'Trend chart', 'One line per line, from the ${st.point(st.mainPoint)!.label.toLowerCase()}.', [
        _pb([
          _check('Show this chart', s.chartShow, (v) => s.chartShow = v),
          const SizedBox(height: 10),
          _txt('chartTitle', s.chartTitle, (v) => s.chartTitle = v, label: 'Title', width: 360),
          const SizedBox(height: 8),
          const Text('The time range comes from the toolbar. Individual draws one small chart per line; Combined puts them together.', style: _muted),
        ]),
      ]);

  // ── footer, checks, export ──────────────────────────────────────────────
  Widget _footer() {
    final cs = _checks();
    final e = cs.where((c) => c.level == 'err').length, w = cs.where((c) => c.level == 'warn').length;
    final col = e > 0 ? SC.stop : w > 0 ? SC.warn : SC.run;
    final label = e > 0 ? '✕ $e error${e > 1 ? 's' : ''}${w > 0 ? ', $w warning${w > 1 ? 's' : ''}' : ''}' : w > 0 ? '! $w warning${w > 1 ? 's' : ''}' : '✓ All checks pass';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: const BoxDecoration(color: SC.panelTop, border: Border(top: BorderSide(color: SC.border))),
      child: Row(children: [
        InkWell(
          onTap: () => setState(() => _checksOpen = !_checksOpen),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: col.withOpacity(.5)), color: SC.inner),
            child: Text(label, style: TextStyle(color: col, fontWeight: FontWeight.w700, fontSize: 13)),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(child: Text(_dirty ? 'Unsaved changes' : 'All changes published', style: TextStyle(color: _dirty ? SC.warn : SC.dim, fontSize: 12.5, fontWeight: FontWeight.w600))),
        _btn('Preview', () => setState(() => _tab = 'layout')),
        const SizedBox(width: 8),
        _btn('Discard changes', _discard, ghost: true),
        const SizedBox(width: 8),
        _btn(_saving ? 'Publishing…' : 'Publish to live', _saving ? null : _publish, primary: true),
      ]),
    );
  }

  Widget _checksPopover() {
    final cs = _checks();
    return Positioned(
      left: 24,
      bottom: 66,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: math.min(560, MediaQuery.of(context).size.width - 48),
          constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .6),
          decoration: SC.panel().copyWith(boxShadow: const [BoxShadow(color: Color(0x88000000), blurRadius: 40)]),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(14),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Checks', style: TextStyle(color: SC.text, fontSize: 16, fontWeight: FontWeight.w700)),
              const Text("Problems that would show a wrong or empty value on the station page. Errors block publishing.", style: _muted),
              const SizedBox(height: 10),
              if (cs.isEmpty)
                _alertRow(const _Check('ok', 'Every check passes.', detail: 'This template is ready to publish.'))
              else
                for (final c in cs) _alertRow(c),
            ]),
          ),
        ),
      ),
    );
  }

  Widget _alertRow(_Check c) {
    final col = switch (c.level) { 'err' => SC.stop, 'warn' => SC.warn, 'ok' => SC.run, _ => SC.accent };
    final go = c.step != null || c.region != null;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(color: col.withOpacity(.08), borderRadius: BorderRadius.circular(9), border: Border.all(color: col.withOpacity(.4))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 18, child: Text(switch (c.level) { 'err' => '✕', 'warn' => '!', 'ok' => '✓', _ => 'i' }, style: TextStyle(color: col, fontWeight: FontWeight.w800))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(c.title, style: const TextStyle(color: SC.text, fontWeight: FontWeight.w600, fontSize: 12.5)),
            if (c.detail != null) Text(c.detail!, style: _muted.copyWith(fontSize: 12)),
          ]),
        ),
        if (go)
          _btn('Fix', () => setState(() {
                _checksOpen = false;
                if (c.step != null) {
                  _tab = 'data';
                  _step = c.step!;
                  if (c.lineId != null) _mapLine = c.lineId;
                } else {
                  _tab = 'layout';
                  _region = c.region!;
                }
              }), small: true),
      ]),
    );
  }

  Future<bool> _confirm(String q) async =>
      await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          backgroundColor: SC.panelTop,
          title: Text(q, style: const TextStyle(color: SC.text, fontSize: 16)),
          actions: [
            TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Keep editing')),
            TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Discard')),
          ],
        ),
      ) ==
      true;

  void _export() {
    final json = const JsonEncoder.withIndent('  ').convert(_s!.toJson());
    showDialog(
      context: context,
      builder: (c) => Dialog(
        backgroundColor: SC.panelTop,
        child: SizedBox(
          width: 760,
          height: MediaQuery.of(context).size.height * .7,
          child: Column(children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 14),
              child: Row(children: [
                const Expanded(child: Text('Station template config (for programmers)', style: TextStyle(color: SC.text, fontSize: 16, fontWeight: FontWeight.w700))),
                _btn('Copy', () {
                  Clipboard.setData(ClipboardData(text: json));
                  _toast('Config copied');
                }, small: true),
                const SizedBox(width: 8),
                _btn('Close', () => Navigator.pop(c), small: true, ghost: true),
              ]),
            ),
            const Divider(height: 1, color: SC.border),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(json, style: const TextStyle(color: SC.text, fontFamily: 'monospace', fontSize: 12)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
