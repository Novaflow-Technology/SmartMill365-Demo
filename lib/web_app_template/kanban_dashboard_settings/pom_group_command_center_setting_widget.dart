import 'dart:convert';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/web_app_template/pom_command_center/pom_config.dart';
import 'package:smartmachine365/web_app_template/pom_command_center/pom_dashboard_view.dart';

/// Kanban Dashboard Setting for the Group POM Command Center.
///
/// Two tabs: Data setup (mills, metrics, mapping, rules — set once) and Layout
/// (click any part of the live preview to edit it). Edits go into a working
/// copy of the config; "Save draft" keeps it and "Publish to live" is what the
/// dashboard shows. SmartMill has no backend yet, so both live in the browser.
class PomGroupCommandCenterSettingWidget extends StatefulWidget {
  const PomGroupCommandCenterSettingWidget({super.key});

  @override
  State<PomGroupCommandCenterSettingWidget> createState() => _PomSettingState();
}

class _P {
  const _P({
    required this.bg,
    required this.panel,
    required this.panel2,
    required this.line,
    required this.ink,
    required this.dim,
    required this.faint,
    required this.accent,
    required this.accentInk,
    required this.ok,
    required this.warn,
    required this.bad,
    required this.violet,
    required this.field,
  });
  final Color bg, panel, panel2, line, ink, dim, faint, accent, accentInk, ok, warn, bad, violet, field;

  static const dark = _P(
    bg: Color(0xFF071126), panel: Color(0xFF0D1A33), panel2: Color(0xFF10203D), line: Color(0xFF1F3257),
    ink: Color(0xFFE3EBF9), dim: Color(0xFF95A8C9), faint: Color(0xFF5F7497), accent: Color(0xFF3EC6FF),
    accentInk: Color(0xFF04121F), ok: Color(0xFF2FD27A), warn: Color(0xFFF5B82E), bad: Color(0xFFF25555),
    violet: Color(0xFF8F82FF), field: Color(0xFF0A162D),
  );
  static const light = _P(
    bg: Color(0xFFEEF2F8), panel: Color(0xFFFFFFFF), panel2: Color(0xFFF5F8FC), line: Color(0xFFD7E0EC),
    ink: Color(0xFF0F1C33), dim: Color(0xFF4E5F7C), faint: Color(0xFF8190A8), accent: Color(0xFF0A7FC0),
    accentInk: Color(0xFFFFFFFF), ok: Color(0xFF15994F), warn: Color(0xFFB77D05), bad: Color(0xFFD23838),
    violet: Color(0xFF6B5CF0), field: Color(0xFFFFFFFF),
  );
}

const _regions = <(String, String)>[
  ('top', 'Top bar'),
  ('kpi', 'KPI cards'),
  ('left', 'Left panel'),
  ('mapc', 'Map'),
  ('right', 'Right panel'),
  ('alerts', 'Attention feed'),
];

const _swatches = <String>[
  '#ffffff', '#3ec6ff', '#46c3ff', '#2fd27a', '#22c55e', '#f5b82e', '#f59e0b', '#ef4444',
  '#f472b6', '#8f82ff', '#6b5cf0', '#0f7a3d', '#0c9d8a', '#2f7de1', '#94a3b8', '#0f1c33',
];

class _PomSettingState extends State<PomGroupCommandCenterSettingWidget> {
  bool _loading = true;
  late Cfg s;
  late Cfg saved;
  bool dirty = false;

  String tab = 'data';
  int step = 1;
  String region = 'kpi';
  bool chkOpen = false;
  String? mapMill;
  int explain = 0;
  String period = 'today';
  final Map<String, String> panelPeriod = {};
  int rev = 0;

  late _P p;
  late PomCalc c;
  Map<String, double> _live = {};

  @override
  void initState() {
    super.initState();
    PomConfigStore.ensureLoaded().then((_) async {
      if (!mounted) return;
      final calc = PomCalc(PomConfigStore.editable());
      await PomLiveData.ensureDevicesLoaded();
      final live = await PomLiveData.fetchValues(calc.mappedPoints());
      if (!mounted) return;
      setState(() {
        s = PomConfigStore.editable();
        saved = cloneCfg(s);
        mapMill = calc.mills.isEmpty ? null : calc.mills.first['id'] as String;
        period = calc.top['defPeriod'].toString();
        _live = live;
        _loading = false;
      });
    });
  }

  Future<void> _refreshLive() async {
    final live = await PomLiveData.fetchValues(PomCalc(s).mappedPoints());
    if (!mounted) return;
    setState(() => _live = live);
    _toast('Live values refreshed');
  }

  // ── helpers ────────────────────────────────────────────────────────────────

  TextStyle _f(double size, {FontWeight? w, Color? color, double? ls}) =>
      GoogleFonts.barlow(fontSize: size, fontWeight: w, color: color ?? p.ink, letterSpacing: ls);

  TextStyle _cond(double size, {FontWeight? w, Color? color}) =>
      GoogleFonts.barlowCondensed(fontSize: size, fontWeight: w, color: color ?? p.ink);

  void _toast(String t) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 2)));
  }

  Future<bool> _confirm(String msg) async {
    final r = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        content: Text(msg, style: _f(14)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text('Cancel', style: _f(13, color: p.dim))),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text('Remove', style: _f(13, w: FontWeight.w700, color: p.bad))),
        ],
      ),
    );
    return r == true;
  }

  /// Sets a field by its path, applies the follow-on rules, and repaints.
  void _set(String path, dynamic v) {
    setState(() {
      final old = getPath(s, path);
      setPath(s, path, v);
      _hook(path, v, old);
      dirty = true;
    });
  }

  void _hook(String pth, dynamic v, dynamic old) {
    final calc = PomCalc(s);
    RegExpMatch? m;
    if ((m = RegExp(r'^map\.([^.]+)\.([^.]+)\.dev$').firstMatch(pth)) != null) {
      final mid = m!.group(1)!, k = m.group(2)!;
      final mp = getPath(s, 'map.$mid') as Map;
      if (v == null || v.toString().isEmpty) {
        mp.remove(k);
        return;
      }
      final code = calc.mill(mid)?['code']?.toString() ?? '';
      final dev = devicesFor(code).where((x) => x.id == v).toList();
      (mp[k] as Map)['field'] = dev.isNotEmpty && dev.first.fields.isNotEmpty ? dev.first.fields.first.key : '';
      return;
    }
    if ((m = RegExp(r'^mills\.(\d+)\.code$').firstMatch(pth)) != null) {
      final mi = calc.mills[int.parse(m!.group(1)!)];
      final map = (s['map'] as Map)[mi['id']];
      if (map is Map && old != null && old.toString().isNotEmpty) {
        for (final mp in map.values) {
          final d = (mp as Map)['dev']?.toString() ?? '';
          if (d.startsWith('${old}_')) mp['dev'] = '${v}_${d.substring(old.toString().length + 1)}';
        }
      }
      return;
    }
    if ((m = RegExp(r'^catalog\.(\d+)\.kind$').firstMatch(pth)) != null) {
      final cm = calc.catalog[int.parse(m!.group(1)!)];
      if (v == 'rate' && cm['agg'] == 'sum') {
        cm['agg'] = 'wavg';
        _toast('${cm['label']} switched to weighted average, rates cannot be summed');
      }
      return;
    }
    if ((m = RegExp(r'^catalog\.(\d+)\.agg$').firstMatch(pth)) != null) {
      final cm = calc.catalog[int.parse(m!.group(1)!)];
      if (v != 'wavg') cm['w'] = '';
      return;
    }
    if ((m = RegExp(r'^kpi\.cards\.(\d+)\.metric$').firstMatch(pth)) != null) {
      final card = calc.cards[int.parse(m!.group(1)!)];
      final cm = calc.cat(v?.toString());
      if (cm != null) {
        if (card['agg'] == 'sum' && cm['kind'] == 'rate') card['agg'] = 'inherit';
        card['w'] = '';
      }
      return;
    }
    if (pth.startsWith('top.periods') || pth == 'top.defPeriod') {
      final en = calc.enabledPeriods();
      if (en.isNotEmpty && !en.contains(calc.top['defPeriod'])) calc.top['defPeriod'] = en.first;
      if (pth == 'top.defPeriod' || !en.contains(period)) period = calc.top['defPeriod'].toString();
      return;
    }
    if (pth == 'top.periodMode') panelPeriod.clear();
  }

  void _go(PomGo g) {
    chkOpen = false;
    if (g.tab == 'data') {
      tab = 'data';
      step = g.step ?? 1;
      if (g.mill != null) mapMill = g.mill;
    } else {
      tab = 'layout';
      region = g.region ?? 'kpi';
    }
  }

  // ── actions ────────────────────────────────────────────────────────────────

  Future<void> _saveDraft() async {
    final ok = await PomConfigStore.saveDraft(s);
    if (!mounted) return;
    setState(() {
      saved = cloneCfg(s);
      dirty = false;
    });
    _toast(ok ? 'Draft saved' : 'Kept for this visit only: this browser blocked saving.');
  }

  Future<void> _publish() async {
    final errs = c.checks().where((x) => x.lv == 'err').toList();
    if (errs.isNotEmpty) {
      setState(() => chkOpen = true);
      _toast('Fix ${errs.length} error${errs.length > 1 ? 's' : ''} before publishing');
      return;
    }
    final ok = await PomConfigStore.publish(s);
    if (!mounted) return;
    setState(() {
      saved = cloneCfg(s);
      dirty = false;
    });
    _toast(ok ? 'Published to live' : 'Published for this visit only: this browser blocked saving.');
  }

  void _discard() {
    if (!dirty) {
      _toast('No changes to discard');
      return;
    }
    setState(() {
      s = cloneCfg(saved);
      dirty = false;
      rev++;
      final calc = PomCalc(s);
      mapMill = calc.mills.isEmpty ? null : calc.mills.first['id'] as String;
      period = calc.top['defPeriod'].toString();
    });
    _toast('Changes discarded');
  }

  void _export() {
    final json = const JsonEncoder.withIndent('  ').convert(s);
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: p.panel,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760, maxHeight: 640),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 14, 12, 10),
              child: Row(children: [
                Expanded(child: Text('Dashboard config (for programmers)', style: _f(16, w: FontWeight.w700))),
                _btn('Copy', () async {
                  await Clipboard.setData(ClipboardData(text: json));
                  if (ctx.mounted) _toast('Config copied');
                }, small: true),
                const SizedBox(width: 8),
                _btn('Close', () => Navigator.pop(ctx), small: true, ghost: true),
              ]),
            ),
            Divider(height: 1, color: p.line),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(16),
                child: SelectableText(json, style: GoogleFonts.robotoMono(fontSize: 12, color: p.ink)),
              ),
            ),
          ]),
        ),
      ),
    );
  }

  void _bigPreview() {
    showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => Dialog(
          insetPadding: const EdgeInsets.all(16),
          backgroundColor: p.bg,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(children: [
              Row(children: [
                Expanded(child: Text('Preview', style: _f(15, w: FontWeight.w700))),
                _btn('Close', () => Navigator.pop(ctx), small: true),
              ]),
              const SizedBox(height: 8),
              Expanded(
                child: PomScaledCanvas(
                  child: PomDashboardView(
                    cfg: s,
                    period: period,
                    panelPeriod: panelPeriod,
                    live: _live,
                    onPeriod: (v) => setD(() => period = v),
                    onPanelPeriod: (panel, v) => setD(() => panelPeriod[panel] = v),
                  ),
                ),
              ),
            ]),
          ),
        ),
      ),
    );
  }

  // ── shared widgets ─────────────────────────────────────────────────────────

  Widget _btn(String label, VoidCallback? onTap, {bool primary = false, bool small = false, bool ghost = false, Color? color}) {
    final bg = primary ? p.accent : Colors.transparent;
    final fg = primary ? p.accentInk : (ghost ? p.dim : (color ?? p.ink));
    return MouseRegion(
      cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Opacity(
          opacity: onTap == null ? .45 : 1,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: small ? 10 : 13, vertical: small ? 5 : 7),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: primary ? p.accent : p.line),
            ),
            child: Text(label, style: _f(small ? 12 : 13, w: FontWeight.w600, color: fg)),
          ),
        ),
      ),
    );
  }

  Widget _iconBtn(String glyph, VoidCallback? onTap, {Color? hover}) => MouseRegion(
        cursor: onTap == null ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: onTap,
          child: Opacity(
            opacity: onTap == null ? .4 : 1,
            child: Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(6)),
              child: Text(glyph, style: _f(13, color: hover ?? p.dim)),
            ),
          ),
        ),
      );

  Widget _badge(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(999), border: Border.all(color: color.withOpacity(.45))),
        child: Text(text, style: _f(11, w: FontWeight.w600, color: color)),
      );

  Widget _panel({required Widget head, required List<Widget> children}) => Container(
        margin: const EdgeInsets.only(bottom: 16),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: p.panel, borderRadius: BorderRadius.circular(12), border: Border.all(color: p.line)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [head, ...children]),
      );

  Widget _head(IconData icon, Color color, String title, String desc, {String? tag}) => Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: p.line))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(color: color.withOpacity(.12), borderRadius: BorderRadius.circular(9), border: Border.all(color: color.withOpacity(.33))),
            child: Icon(icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: _f(16, w: FontWeight.w700)),
              const SizedBox(height: 2),
              Text(desc, style: _f(12.5, color: p.dim)),
            ]),
          ),
          if (tag != null) Padding(padding: const EdgeInsets.only(left: 10), child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(999)),
            child: Text(tag, style: _f(11.5, color: p.dim)),
          )),
        ]),
      );

  Widget _pb(Widget child, {bool first = false}) => Container(
        padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
        decoration: BoxDecoration(border: first ? null : Border(top: BorderSide(color: p.line))),
        child: child,
      );

  Widget _subH(String t) => Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(t, style: _f(13.5, w: FontWeight.w700)));
  Widget _note(String t) => Padding(padding: const EdgeInsets.only(top: 8), child: Text(t, style: _f(12, color: p.faint)));

  Widget _fld(String label, Widget child) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [Text(label, style: _f(12, color: p.dim, w: FontWeight.w500)), const SizedBox(height: 4), child],
      );

  Widget _grid(List<Widget> kids, {double min = 170}) => LayoutBuilder(builder: (context, box) {
        final cols = math.max(1, ((box.maxWidth + 12) / (min + 12)).floor());
        final w = (box.maxWidth - 12 * (cols - 1)) / cols;
        return Wrap(spacing: 12, runSpacing: 12, children: [for (final k in kids) SizedBox(width: w, child: k)]);
      });

  Widget _shell(Widget child, {double? width}) => Container(
        width: width,
        height: 36,
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(color: p.field, borderRadius: BorderRadius.circular(7), border: Border.all(color: p.line)),
        child: child,
      );

  Widget _txt(String path, {String hint = '', bool enabled = true, int? maxLen, double? width}) => _shell(
        TextFormField(
          key: ValueKey('$path#$rev'),
          initialValue: getPath(s, path)?.toString() ?? '',
          enabled: enabled,
          maxLength: maxLen,
          onChanged: (v) => _set(path, v),
          style: _f(13),
          decoration: InputDecoration(isDense: true, border: InputBorder.none, counterText: '', hintText: hint, hintStyle: _f(13, color: p.faint)),
        ),
        width: width,
      );

  Widget _numF(String path, {String hint = '', double? width}) {
    final cur = getPath(s, path);
    final txt = cur == null ? '' : (cur is num && cur == cur.roundToDouble() ? cur.toInt().toString() : cur.toString());
    return _shell(
      TextFormField(
        key: ValueKey('$path#$rev'),
        initialValue: txt,
        keyboardType: const TextInputType.numberWithOptions(decimal: true, signed: true),
        onChanged: (v) {
          if (v.trim().isEmpty) {
            _set(path, null);
            return;
          }
          final n = double.tryParse(v);
          if (n == null) return;
          _set(path, n == n.roundToDouble() ? n.toInt() : n);
        },
        style: _f(13),
        decoration: InputDecoration(isDense: true, border: InputBorder.none, hintText: hint, hintStyle: _f(13, color: p.faint)),
      ),
      width: width,
    );
  }

  Widget _sel(String path, List<(String, String, bool)> opts, {bool numeric = false, bool enabled = true, double? width}) {
    final cur = getPath(s, path)?.toString() ?? '';
    final has = opts.any((o) => o.$1 == cur);
    return _shell(
      DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          isExpanded: true,
          isDense: true,
          value: has ? cur : null,
          dropdownColor: p.panel,
          iconEnabledColor: p.dim,
          style: _f(13),
          items: [
            for (final o in opts)
              DropdownMenuItem<String>(value: o.$1, enabled: !o.$3, child: Text(o.$2, overflow: TextOverflow.ellipsis, style: _f(13, color: o.$3 ? p.faint : p.ink))),
          ],
          onChanged: enabled
              ? (v) {
                  if (v == null) return;
                  _set(path, numeric ? num.tryParse(v) : v);
                }
              : null,
        ),
      ),
      width: width,
    );
  }

  Widget _chk(String path, String label) => InkWell(
        onTap: () => _set(path, !(getPath(s, path) == true)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 22,
            height: 22,
            child: Checkbox(value: getPath(s, path) == true, activeColor: p.accent, checkColor: p.accentInk, onChanged: (b) => _set(path, b == true)),
          ),
          const SizedBox(width: 4),
          Text(label, style: _f(13)),
        ]),
      );

  Widget _clr(String path) {
    final cur = hexColor(getPath(s, path)?.toString(), Colors.grey);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => _pickColor(path),
        child: Container(
          width: 38,
          height: 32,
          decoration: BoxDecoration(color: cur, borderRadius: BorderRadius.circular(7), border: Border.all(color: p.line, width: 2)),
        ),
      ),
    );
  }

  void _pickColor(String path) {
    final ctrl = TextEditingController(text: getPath(s, path)?.toString() ?? '');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        title: Text('Pick a colour', style: _f(15, w: FontWeight.w700)),
        content: SizedBox(
          width: 300,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 8, children: [
              for (final h in _swatches)
                GestureDetector(
                  onTap: () {
                    _set(path, h);
                    Navigator.pop(ctx);
                  },
                  child: Container(width: 30, height: 30, decoration: BoxDecoration(color: hexColor(h), borderRadius: BorderRadius.circular(6), border: Border.all(color: p.line))),
                ),
            ]),
            const SizedBox(height: 14),
            Text('Or type a hex colour', style: _f(12, color: p.dim)),
            const SizedBox(height: 4),
            TextField(
              controller: ctrl,
              style: _f(13),
              decoration: InputDecoration(isDense: true, hintText: '#3ec6ff', hintStyle: _f(13, color: p.faint), enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: p.line)), focusedBorder: OutlineInputBorder(borderSide: BorderSide(color: p.accent))),
            ),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel', style: _f(13, color: p.dim))),
          TextButton(
            onPressed: () {
              final v = ctrl.text.trim();
              final h = v.startsWith('#') ? v : '#$v';
              if (RegExp(r'^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$').hasMatch(h)) _set(path, h.toLowerCase());
              Navigator.pop(ctx);
            },
            child: Text('Use', style: _f(13, w: FontWeight.w700, color: p.accent)),
          ),
        ],
      ),
    );
  }

  Widget _range(String path, double min, double max) => SliderTheme(
        data: SliderTheme.of(context).copyWith(activeTrackColor: p.accent, thumbColor: p.accent, inactiveTrackColor: p.line, trackHeight: 3),
        child: Slider(
          min: min,
          max: max,
          divisions: (max - min).round(),
          value: ((getPath(s, path) as num?) ?? min).toDouble().clamp(min, max),
          onChanged: (v) => _set(path, v.round()),
        ),
      );

  Widget _row(List<Widget> kids, {double gap = 14}) => Wrap(spacing: gap, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: kids);

  /// A table with fixed column widths; scrolls sideways when it is wider than
  /// the space it is given, the way the design does.
  Widget _table(List<double> widths, List<String> heads, List<List<Widget>> rows) {
    final total = widths.fold<double>(0, (a, b) => a + b);
    return LayoutBuilder(builder: (context, box) {
      final w = math.max(total, box.maxWidth);
      final scale = w / total;
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SizedBox(
          width: w,
          child: Table(
            columnWidths: {for (var i = 0; i < widths.length; i++) i: FixedColumnWidth(widths[i] * scale)},
            defaultVerticalAlignment: TableCellVerticalAlignment.middle,
            border: TableBorder(horizontalInside: BorderSide(color: p.line)),
            children: [
              TableRow(
                decoration: BoxDecoration(color: p.panel2),
                children: [for (final h in heads) Padding(padding: const EdgeInsets.fromLTRB(10, 9, 8, 9), child: Text(h, style: _f(12, w: FontWeight.w600, color: p.dim)))],
              ),
              for (final r in rows) TableRow(children: [for (final cell in r) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 8, 6), child: cell)]),
            ],
          ),
        ),
      );
    });
  }

  // ── page ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    p = Theme.of(context).brightness == Brightness.dark ? _P.dark : _P.light;
    if (_loading) {
      return Scaffold(backgroundColor: p.bg, body: const Center(child: CircularProgressIndicator()));
    }
    c = PomCalc(s, _live);
    final wide = MediaQuery.of(context).size.width;
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Stack(children: [
          Column(children: [
            _header(),
            _tabs(),
            Expanded(
              child: SingleChildScrollView(
                child: tab == 'data' ? _dataTab() : _layTab(wide),
              ),
            ),
            _footer(),
          ]),
          if (chkOpen) Positioned(left: 24, bottom: 62, width: math.min(560, wide - 48), child: _checksPop()),
        ]),
      ),
    );
  }

  // ── header, tabs, footer ───────────────────────────────────────────────────

  Widget _header() {
    final act = c.activeMills();
    final tot = act.length * c.catalog.length;
    final ok = act.fold<int>(0, (a, m) => a + c.mappedCount(m['id'] as String));
    final pct = tot == 0 ? 0.0 : ok / tot;
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 14, 24, 14),
      decoration: BoxDecoration(color: p.panel, border: Border(bottom: BorderSide(color: p.line))),
      child: Wrap(spacing: 18, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Kanban Dashboard Setting', style: _cond(26, w: FontWeight.w700)),
          Text('Template: Group POM Command Center, SmartMill 365 preset', style: _f(13, color: p.dim)),
        ]),
        _shell(
          DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              isDense: true,
              value: 'all',
              dropdownColor: p.panel,
              style: _f(13),
              items: const [DropdownMenuItem(value: 'all', child: Text('Scope: Sarawak Operations (all mills)'))],
              onChanged: (_) {},
            ),
          ),
          width: 290,
        ),
        Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(
            width: 44,
            height: 44,
            child: CustomPaint(painter: _RingPainter(pct, pct >= 1 ? p.ok : p.warn, p.line)),
          ),
          const SizedBox(width: 10),
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$ok / $tot', style: _f(15, w: FontWeight.w700)),
            Text('fields mapped', style: _f(12.5, color: p.dim)),
          ]),
        ]),
        _btn('Export config (JSON)', _export),
      ]),
    );
  }

  Widget _tabs() {
    Widget t(String id, String title, String sub) {
      final on = tab == id;
      return InkWell(
        onTap: () => setState(() {
          tab = id;
          chkOpen = false;
        }),
        child: Container(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 11),
          decoration: BoxDecoration(border: Border(bottom: BorderSide(color: on ? p.accent : Colors.transparent, width: 3))),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            Text(title, style: _f(15, w: FontWeight.w700, color: on ? p.ink : p.dim)),
            Text(sub, style: _f(12, color: p.faint)),
          ]),
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
      decoration: BoxDecoration(color: p.panel, border: Border(bottom: BorderSide(color: p.line))),
      child: Row(children: [
        t('data', '① Data setup', 'Mills, metrics, mapping and rules. Set once.'),
        const SizedBox(width: 4),
        t('layout', '② Layout', 'Click any part of the dashboard to edit it'),
      ]),
    );
  }

  Widget _footer() {
    final cs = c.checks();
    final e = cs.where((x) => x.lv == 'err').length;
    final w = cs.where((x) => x.lv == 'warn').length;
    final color = e > 0 ? p.bad : (w > 0 ? p.warn : p.ok);
    final label = e > 0
        ? '✕ $e error${e > 1 ? 's' : ''}${w > 0 ? ', $w warning${w > 1 ? 's' : ''}' : ''}'
        : (w > 0 ? '! $w warning${w > 1 ? 's' : ''}' : '✓ All checks pass');
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 10, 24, 10),
      decoration: BoxDecoration(color: p.panel, border: Border(top: BorderSide(color: p.line))),
      child: Row(children: [
        GestureDetector(
          onTap: () => setState(() => chkOpen = !chkOpen),
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(8), border: Border.all(color: color.withOpacity(.45))),
              child: Text(label, style: _f(13, w: FontWeight.w700, color: color)),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(dirty ? 'Unsaved changes' : 'All changes saved as draft', style: _f(12.5, color: dirty ? p.ink : p.dim, w: dirty ? FontWeight.w700 : FontWeight.w400)),
        ),
        _btn('Refresh live values', _refreshLive, small: true),
        const SizedBox(width: 10),
        if (tab == 'data') ...[_btn('Preview', _bigPreview), const SizedBox(width: 10)],
        _btn('Discard changes', _discard, ghost: true),
        const SizedBox(width: 10),
        _btn('Save draft', _saveDraft),
        const SizedBox(width: 10),
        _btn('Publish to live', _publish, primary: true),
      ]),
    );
  }

  Widget _checksPop() {
    final cs = c.checks();
    final e = cs.where((x) => x.lv == 'err').length;
    final w = cs.where((x) => x.lv == 'warn').length;
    Widget alert(PomCheck k) {
      final col = k.lv == 'err' ? p.bad : (k.lv == 'warn' ? p.warn : p.accent);
      return Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.fromLTRB(12, 9, 12, 9),
        decoration: BoxDecoration(color: col.withOpacity(.09), borderRadius: BorderRadius.circular(9), border: Border.all(color: col.withOpacity(.4))),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 16, child: Text(k.lv == 'err' ? '✕' : (k.lv == 'warn' ? '!' : 'i'), style: _f(13, w: FontWeight.w700, color: col))),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(k.t, style: _f(12.5, w: FontWeight.w600)),
              if (k.d.isNotEmpty) Text(k.d, style: _f(12.5, color: p.dim)),
            ]),
          ),
          if (k.go != null) ...[const SizedBox(width: 8), _btn('Fix', () => setState(() => _go(k.go!)), small: true)],
        ]),
      );
    }

    return Material(
      color: p.panel,
      elevation: 12,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 460),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(12), border: Border.all(color: p.line)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _head(e > 0 || w > 0 ? Icons.warning_amber_rounded : Icons.check_circle_outline, e > 0 ? p.bad : (w > 0 ? p.warn : p.ok), 'Checks',
              'Problems that would show a wrong or empty number on the live dashboard. Errors block publishing.'),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(14),
              child: cs.isEmpty
                  ? Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(color: p.ok.withOpacity(.09), borderRadius: BorderRadius.circular(9), border: Border.all(color: p.ok.withOpacity(.4))),
                      child: Text('Every check passes. This configuration is ready to publish.', style: _f(13, w: FontWeight.w600)),
                    )
                  : Column(children: [for (final k in cs) alert(k)]),
            ),
          ),
        ]),
      ),
    );
  }

  // ── DATA tab ───────────────────────────────────────────────────────────────

  Widget _dataTab() {
    const stepDefs = <(int, String)>[(1, 'Mills'), (2, 'Metrics'), (3, 'Data mapping'), (4, 'Status rules')];
    final act = c.activeMills();
    String sub(int n) => switch (n) {
          1 => '${c.mills.length} mills, ${act.length} shown',
          2 => '${c.catalog.length} metrics defined',
          3 => '${act.fold<int>(0, (a, m) => a + c.mappedCount(m['id'] as String))} of ${act.length * c.catalog.length} fields mapped',
          _ => 'Stable, Watch, Attention and bands',
        };
    final cs = c.checks();
    Widget stepBtn((int, String) d) {
      final mine = cs.where((k) => k.go?.tab == 'data' && k.go?.step == d.$1 && k.lv != 'info').toList();
      final flag = mine.any((k) => k.lv == 'err') ? p.bad : (mine.isNotEmpty ? p.warn : null);
      final on = step == d.$1;
      return InkWell(
        onTap: () => setState(() => step = d.$1),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: on ? p.accent : p.line, width: on ? 1.6 : 1),
          ),
          child: Row(children: [
            Container(
              width: 28,
              height: 28,
              alignment: Alignment.center,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? p.accent : p.panel2, border: Border.all(color: on ? p.accent : p.line)),
              child: Text('${d.$1}', style: _f(13, w: FontWeight.w700, color: on ? p.accentInk : p.ink)),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(d.$2, style: _f(14, w: FontWeight.w700)),
                Text(sub(d.$1), style: _f(12, color: p.dim), maxLines: 1, overflow: TextOverflow.ellipsis),
              ]),
            ),
            if (flag != null) Container(width: 9, height: 9, decoration: BoxDecoration(color: flag, shape: BoxShape.circle)),
          ]),
        ),
      );
    }

    final prev = step > 1 ? stepDefs[step - 2] : null;
    final next = step < stepDefs.length ? stepDefs[step] : null;
    return Align(
      alignment: Alignment.topLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1320),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 18, 24, 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            LayoutBuilder(builder: (context, box) {
              final cols = box.maxWidth < 900 ? 2 : 4;
              final w = (box.maxWidth - 8 * (cols - 1)) / cols;
              return Wrap(spacing: 8, runSpacing: 8, children: [for (final d in stepDefs) SizedBox(width: w, child: stepBtn(d))]);
            }),
            const SizedBox(height: 16),
            switch (step) {
              1 => _secMills(),
              2 => _secCatalog(),
              3 => _secMapping(),
              _ => _secRules(),
            },
            Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
              prev == null ? const SizedBox.shrink() : _btn('Back: ${prev.$2}', () => setState(() => step = prev.$1)),
              next == null ? _btn('Next: arrange the layout', () => setState(() => tab = 'layout'), primary: true) : _btn('Next: ${next.$2}', () => setState(() => step = next.$1), primary: true),
            ]),
          ]),
        ),
      ),
    );
  }

  // 1 · Mills
  Widget _secMills() {
    final bu = (c.cat(c.band['metric'] as String?)?['unit'] ?? '').toString();
    final rows = <List<Widget>>[];
    for (var i = 0; i < c.mills.length; i++) {
      final m = c.mills[i];
      rows.add([
        Container(width: 10, height: 10, decoration: BoxDecoration(color: c.statusColor(m['id'] as String, 'today'), shape: BoxShape.circle)),
        _txt('mills.$i.name', hint: 'Mill name'),
        _txt('mills.$i.code', hint: 'Code'),
        _numF('mills.$i.target', hint: 'Target'),
        Align(alignment: Alignment.centerLeft, child: Checkbox(value: m['active'] == true, activeColor: p.accent, checkColor: p.accentInk, onChanged: (b) => _set('mills.$i.active', b == true))),
        Align(alignment: Alignment.centerLeft, child: _iconBtn('✕', () => _delMill(i), hover: p.bad)),
      ]);
    }
    return _panel(
      head: _head(Icons.place_outlined, p.violet, 'Mills',
          'The single source of truth. Every panel, pin, table row and total reads from this list, so adding a mill here adds it everywhere. Where it sits on the map is set in Layout, under Map.',
          tag: '${c.activeMills().length} of ${c.mills.length} shown'),
      children: [
        _table(const [34, 270, 100, 100, 150, 56], ['', 'Mill name', 'Tag code', 'Target $bu', 'Shown on dashboard', ''], rows),
        _pb(
          Row(children: [
            _btn('+ Add mill', _addMill, small: true),
            const SizedBox(width: 12),
            Expanded(child: Text("Tag code prefixes every device tag for the mill. Changing it re-points the mill's mapping. Target feeds the Above / Average / Below band.", style: _f(12, color: p.faint))),
          ]),
        ),
      ],
    );
  }

  void _addMill() {
    setState(() {
      final id = 'm${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      final n = c.mills.length + 1;
      c.mills.add({'id': id, 'code': 'MILL$n', 'name': 'New mill', 'loc': '', 'target': null, 'x': 55, 'y': 78, 'side': 'top', 'active': true});
      (s['map'] as Map)[id] = <String, dynamic>{};
      mapMill = id;
      if (c.kpi['autoInclude'] != true) (c.kpi['exclude'] as List).add(id);
      dirty = true;
      rev++;
    });
    _toast('Mill added to every panel');
  }

  Future<void> _delMill(int i) async {
    final m = c.mills[i];
    if (!await _confirm('Remove ${m['name']}? Its mapping is removed too.')) return;
    setState(() {
      c.mills.removeAt(i);
      (s['map'] as Map).remove(m['id']);
      (c.kpi['exclude'] as List).remove(m['id']);
      if (mapMill == m['id']) mapMill = c.mills.isEmpty ? null : c.mills.first['id'] as String;
      dirty = true;
      rev++;
    });
  }

  // 2 · Metrics
  Widget _secCatalog() {
    final rows = <List<Widget>>[];
    for (var i = 0; i < c.catalog.length; i++) {
      final m = c.catalog[i];
      final u = c.usedBy(m['k'] as String);
      final core = kCoreMetrics.contains(m['k']);
      final isRate = m['kind'] == 'rate';
      rows.add([
        Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          _txt('catalog.$i.label'),
          Padding(padding: const EdgeInsets.only(top: 3), child: Text(u.isEmpty ? 'Not used on the dashboard' : 'Used in ${u.join(', ')}', style: _f(11.5, color: p.faint))),
        ]),
        _txt('catalog.$i.short'),
        _txt('catalog.$i.unit'),
        _numF('catalog.$i.dec'),
        _sel('catalog.$i.kind', const [('amount', 'Amount (adds up)', false), ('rate', 'Rate or score', false)]),
        _sel('catalog.$i.agg', [for (final e in kAggLabel.entries) (e.key, e.value, isRate && e.key == 'sum')]),
        m['agg'] == 'wavg'
            ? _sel('catalog.$i.w', [('', '— weight —', false), for (final x in c.catalog.where((x) => x['k'] != m['k'] && x['kind'] == 'amount')) (x['k'].toString(), x['label'].toString(), false)])
            : Text('—', style: _f(13, color: p.faint)),
        _sel('catalog.$i.better', const [('higher', 'Higher', false), ('lower', 'Lower', false)]),
        core ? Align(alignment: Alignment.centerLeft, child: _badge('Core', p.faint)) : Align(alignment: Alignment.centerLeft, child: _iconBtn('✕', () => _delMetric(i), hover: p.bad)),
      ]);
    }
    return _panel(
      head: _head(Icons.storage_outlined, p.accent, 'Metrics',
          'Define each number once: its label, unit and how the group total is formed. Every panel picks from this list, so a rename here updates every card, table and pop-up.',
          tag: '${c.catalog.length} metrics'),
      children: [
        _table(const [220, 110, 80, 70, 170, 170, 170, 110, 60], ['Display label', 'Short label', 'Unit', 'Dec.', 'Type', 'Group total', 'Weighted by', 'Better when', ''], rows),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _btn('+ Add metric', _addMetric, small: true),
          _note("Rates and scores cannot be summed, the same lesson as Max Demand in the EMS kanban. Throughput is weighted by processing hours (ΣFFB ÷ Σhours), OER by FFB processed, and health scores by sterilizer cycles. Each mill's own value still comes from the DB, the kanban only combines them. Short labels are used where space is tight, such as map pop-ups."),
        ])),
      ],
    );
  }

  void _addMetric() => setState(() {
        c.catalog.add({'k': 'c_${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}', 'label': 'New metric', 'short': '', 'unit': '', 'dec': 1, 'kind': 'amount', 'agg': 'sum', 'w': '', 'better': 'higher'});
        dirty = true;
        rev++;
      });

  void _delMetric(int i) {
    final m = c.catalog[i];
    final u = c.usedBy(m['k'] as String);
    if (u.isNotEmpty) {
      _toast('Remove it from ${u.first} first');
      return;
    }
    setState(() {
      c.catalog.removeAt(i);
      for (final mp in (s['map'] as Map).values) {
        (mp as Map).remove(m['k']);
      }
      dirty = true;
      rev++;
    });
  }

  // 3 · Mapping
  Future<void> _retryDevices() async {
    await PomLiveData.ensureDevicesLoaded(retry: true);
    if (!mounted) return;
    setState(() {});
    _toast(PomLiveData.devices.isEmpty ? 'Still no devices — ${PomLiveData.lastDevicesError ?? "check the connection"}' : 'Device catalog loaded');
  }

  Widget _secMapping() {
    final m = c.mill(mapMill) ?? (c.mills.isEmpty ? null : c.mills.first);
    if (m == null) return _panel(head: _head(Icons.link, p.accent, 'Data mapping', 'Add a mill first.'), children: const []);
    final mid = m['id'] as String;
    mapMill = mid;
    final devs = devicesFor(m['code'].toString());
    if (PomLiveData.devices.isEmpty) {
      return _panel(
        head: _head(Icons.link, p.accent, 'Data mapping', 'Point each metric at a device and field for one mill at a time.'),
        children: [
          _pb(
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: p.bad.withOpacity(.08), borderRadius: BorderRadius.circular(9), border: Border.all(color: p.bad.withOpacity(.4))),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('Could not load SmartMill’s device catalog', style: _f(13, w: FontWeight.w700)),
                    const SizedBox(height: 4),
                    Text(
                      PomLiveData.lastDevicesError ?? 'No devices came back. This can happen right after a deploy while the function is still cold.',
                      style: _f(12, color: p.dim),
                    ),
                  ]),
                ),
                const SizedBox(width: 10),
                _btn('Retry', _retryDevices, small: true, primary: true),
              ]),
            ),
            first: true,
          ),
        ],
      );
    }
    final rows = <List<Widget>>[];
    for (final cm in c.catalog) {
      final k = cm['k'] as String;
      final dev = getPath(s, 'map.$mid.$k.dev')?.toString() ?? '';
      final d = devs.where((x) => x.id == dev).toList();
      final src = d.isEmpty
          ? Text('—', style: _f(12, color: p.faint))
          : _badge(d.first.src, d.first.src == 'Device' ? const Color(0xFF2F7DE1) : (d.first.src == 'RCA engine' ? const Color(0xFF0C9D8A) : p.violet));
      rows.add([
        Text.rich(TextSpan(children: [
          TextSpan(text: cm['label'].toString(), style: _f(13, w: FontWeight.w700)),
          if ((cm['unit'] ?? '').toString().isNotEmpty) TextSpan(text: '  ${cm['unit']}', style: _f(12, color: p.faint)),
        ])),
        _sel('map.$mid.$k.dev', [('', '— Select device —', false), for (final x in devs) (x.id, x.id, false)]),
        _sel('map.$mid.$k.field', [('', '— Field —', false), for (final f in (d.isEmpty ? const <PomFieldDef>[] : d.first.fields)) (f.key, f.label, false)], enabled: d.isNotEmpty),
        Align(alignment: Alignment.centerLeft, child: src),
        Align(alignment: Alignment.centerLeft, child: c.mapped(mid, k) ? _badge('Mapped', p.ok) : _badge('Not mapped', p.warn)),
      ]);
    }
    return _panel(
      head: _head(Icons.link, const Color(0xFF2F7DE1), 'Data mapping',
          'Point each metric at a device and field for one mill at a time. Tags follow <MILL>_<EQUIP>. Values arrive already computed by the DB for the active period, so there is one mapping per field, not one per period.',
          tag: '${PomCalc.short(m['name'].toString())}: ${c.mappedCount(mid)}/${c.catalog.length}'),
      children: [
        _pb(
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final mm in c.mills)
              InkWell(
                onTap: () => setState(() => mapMill = mm['id'] as String),
                child: Opacity(
                  opacity: mm['active'] == true ? 1 : .55,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: mm['id'] == mid ? p.accent : p.panel2,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: mm['id'] == mid ? p.accent : p.line),
                    ),
                    child: Text.rich(TextSpan(children: [
                      TextSpan(text: PomCalc.short(mm['name'].toString()), style: _f(12.5, w: FontWeight.w600, color: mm['id'] == mid ? p.accentInk : p.ink)),
                      TextSpan(text: '  ${c.mappedCount(mm['id'] as String)}/${c.catalog.length}', style: _f(12, color: mm['id'] == mid ? p.accentInk : p.dim)),
                    ])),
                  ),
                ),
              ),
          ]),
          first: true,
        ),
        _table(const [210, 320, 200, 120, 130], ['Metric', 'Device', 'Field', 'Source', 'State'], rows),
        _pb(Row(children: [
          _btn("Apply ${PomCalc.short(m['name'].toString())}'s mapping to all mills", _copyPattern, small: true),
          const SizedBox(width: 12),
          Expanded(child: Text('Copies the device and field choices, swapping the tag code for each mill. Map one mill, reuse for the rest.', style: _f(12, color: p.faint))),
        ])),
      ],
    );
  }

  void _copyPattern() {
    final src = c.mill(mapMill);
    if (src == null) return;
    final srcCode = src['code'].toString();
    final srcMap = getPath(s, 'map.${src['id']}');
    if (srcMap is! Map) return;
    setState(() {
      for (final m in c.mills) {
        if (m['id'] == src['id']) continue;
        final dst = ((s['map'] as Map)[m['id']] ??= <String, dynamic>{}) as Map;
        srcMap.forEach((k, mp) {
          final dev = (mp as Map)['dev']?.toString() ?? '';
          if (dev.isEmpty) return;
          dst[k] = {'dev': '${m['code']}${dev.substring(srcCode.length)}', 'field': mp['field']};
        });
      }
      dirty = true;
      rev++;
    });
    _toast('Applied to ${c.mills.length - 1} mills');
  }

  // 4 · Rules
  Widget _strip(Widget Function(Map<String, dynamic>) fn) => Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Wrap(spacing: 6, runSpacing: 6, children: [for (final m in c.activeMills()) fn(m)]),
      );

  Widget _stripChip(Color col, String text) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(color: p.panel2, borderRadius: BorderRadius.circular(6), border: Border.all(color: p.line)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: col, shape: BoxShape.circle)),
          const SizedBox(width: 6),
          Text(text, style: _f(12)),
        ]),
      );

  Widget _secRules() {
    final st = c.status, b = c.band;
    final sc = c.cat(st['metric'] as String?);
    final op = sc?['better'] == 'lower' ? '≤' : '≥';
    final bu = (c.cat(b['metric'] as String?)?['unit'] ?? '').toString();
    final metricAll = [for (final x in c.catalog) (x['k'].toString(), x['label'].toString(), false)];
    final metricRate = [for (final x in c.catalog.where((x) => x['kind'] == 'rate')) (x['k'].toString(), x['label'].toString(), false)];
    return _panel(
      head: _head(Icons.rule, p.warn, 'Status rules', 'Colour rules shared by every panel. Change a threshold once and the map, tables and borders follow.', tag: 'Map once, reuse everywhere'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _subH('Status rule (Stable, Watch, Attention)'),
          _grid([
            _fld('Based on', _sel('status.metric', metricRate)),
            _fld('${(st['labels'] as List)[0]} when $op', _numF('status.stable')),
            _fld('${(st['labels'] as List)[1]} when $op', _numF('status.watch')),
            _fld('${(st['labels'] as List)[2]}', _shell(Text('otherwise', style: _f(13, color: p.faint)))),
          ]),
          const SizedBox(height: 10),
          _grid([
            for (var i = 0; i < 3; i++)
              _fld('Level ${i + 1} label and colour', Row(children: [Expanded(child: _txt('status.labels.$i')), const SizedBox(width: 6), _clr('status.colors.$i')])),
          ]),
          _strip((m) {
            final i = c.statusIdx(m['id'] as String, 'today');
            return _stripChip(i < 0 ? const Color(0xFF6B7FA3) : hexColor((st['colors'] as List)[i] as String), '${PomCalc.short(m['name'].toString())}: ${i < 0 ? 'no data' : (st['labels'] as List)[i]}');
          }),
          _note('Defined once, used by the map legend, pin colours, the right-panel status column and, if chosen, the left-panel card borders.'),
        ]), first: true),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _subH('Performance band (Above, Average, Below)'),
          _grid([
            _fld('Based on', _sel('band.metric', metricAll)),
            _fld('Compared with', _sel('band.basis', const [('target', "Each mill's own target", false), ('group', 'Group figure', false)])),
            _fld('Average band ± %', _numF('band.width')),
          ]),
          const SizedBox(height: 10),
          _grid([
            for (var i = 0; i < 3; i++)
              _fld('Band ${i + 1} label and colour', Row(children: [Expanded(child: _txt('band.labels.$i')), const SizedBox(width: 6), _clr('band.colors.$i')])),
          ]),
          _strip((m) {
            final i = c.bandIdx(m, 'today');
            final v = c.value(m['id'] as String, b['metric'] as String, 'today');
            final dec = ((c.cat(b['metric'] as String?)?['dec'] ?? 0) as num).toInt();
            final txt = i < 0
                ? 'no data'
                : '${(b['labels'] as List)[i]} (${fmtNum(v ?? 0, dec)}${bu.isNotEmpty && bu != '%' ? ' ' : ''}$bu vs ${b['basis'] == 'target' ? (m['target'] ?? '—') : 'group'})';
            return _stripChip(i < 0 ? const Color(0xFF6B7FA3) : hexColor((b['colors'] as List)[i] as String), '${PomCalc.short(m['name'].toString())}: $txt');
          }),
        ])),
      ],
    );
  }

  // ── LAYOUT tab ─────────────────────────────────────────────────────────────

  Widget _layTab(double width) {
    final preview = _previewCol();
    final settings = _regionPanel();
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
      child: width >= 1100
          ? Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: preview),
              const SizedBox(width: 20),
              SizedBox(width: 450, child: settings),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [preview, const SizedBox(height: 16), settings]),
    );
  }

  Widget _previewCol() {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text('Live preview', style: _f(15, w: FontWeight.w700)),
        const SizedBox(width: 10),
        Expanded(child: Text('Click a part to edit it. Drag pins to move them.', style: _f(12, color: p.dim))),
        _btn('Enlarge', _bigPreview, small: true),
      ]),
      const SizedBox(height: 8),
      Wrap(spacing: 6, runSpacing: 6, children: [
        for (final r in _regions)
          InkWell(
            onTap: () => setState(() => region = r.$1),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
              decoration: BoxDecoration(
                color: region == r.$1 ? p.accent : p.panel,
                borderRadius: BorderRadius.circular(999),
                border: Border.all(color: region == r.$1 ? p.accent : p.line),
              ),
              child: Text(r.$2, style: _f(12.5, w: FontWeight.w600, color: region == r.$1 ? p.accentInk : p.ink)),
            ),
          ),
      ]),
      const SizedBox(height: 10),
      Container(
        decoration: BoxDecoration(border: Border.all(color: p.line), borderRadius: BorderRadius.circular(12), color: const Color(0xFF040B1A)),
        clipBehavior: Clip.antiAlias,
        child: AspectRatio(
          aspectRatio: kPomCanvasW / kPomCanvasH,
          child: PomScaledCanvas(
            child: PomDashboardView(
              cfg: s,
              period: period,
              panelPeriod: panelPeriod,
              live: _live,
              onPeriod: (v) => setState(() => period = v),
              onPanelPeriod: (panel, v) => setState(() => panelPeriod[panel] = v),
              onRegionTap: (r) => setState(() => region = r),
              selectedRegion: region,
              onPinMove: (i, x, y) => setState(() {
                c.mills[i]['x'] = x;
                c.mills[i]['y'] = y;
                dirty = true;
              }),
            ),
          ),
        ),
      ),
    ]);
  }

  Widget _regionPanel() => switch (region) {
        'top' => _rTop(),
        'left' => _rLeft(),
        'mapc' => _rMapc(),
        'right' => _rRight(),
        'alerts' => _rAlerts(),
        _ => _rKpi(),
      };

  List<(String, String, bool)> _metricOpts({bool Function(Map<String, dynamic>)? where, String? blank}) => [
        if (blank != null) ('', blank, false),
        for (final x in c.catalog.where(where ?? (_) => true)) (x['k'].toString(), x['label'].toString(), false),
      ];

  // Top bar
  Widget _rTop() {
    final t = c.top;
    return _panel(
      head: _head(Icons.view_stream_outlined, const Color(0xFF3D7FE0), 'Top bar', 'Everything across the top of the dashboard, including which time periods viewers can switch between.'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _grid([
            _fld('Logo image address', _txt('top.logo', hint: 'https://…')),
            _fld('Without a logo, show', _sel('top.fallback', const [('icon', 'Palm icon', false), ('initials', 'Initials', false)])),
            _fld('Initials and badge colour', Row(children: [Expanded(child: _txt('top.initials', maxLen: 3)), const SizedBox(width: 6), _clr('top.badge')])),
            _fld('Product name', _txt('top.product')),
            _fld('Dashboard title', _txt('top.title')),
            _fld('Subtitle', _txt('top.subtitle')),
            _fld('Subtitle colour', Align(alignment: Alignment.centerLeft, child: _clr('top.titleColor'))),
          ]),
          const SizedBox(height: 12),
          _row([_chk('top.live', 'Show LIVE indicator'), _chk('top.clock', 'Show date and clock')]),
        ]), first: true),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _subH('Time periods'),
          _row([for (final e in kPeriodLabel.entries) _chk('top.periods.${e.key}', e.value)]),
          const SizedBox(height: 10),
          _grid([
            _fld('Opens on', _sel('top.defPeriod', [for (final k in c.enabledPeriods()) (k, kPeriodLabel[k]!, false)])),
            _fld('Who controls the period', _sel('top.periodMode', const [('global', 'One switch in the top bar', false), ('panel', 'Each panel on its own', false), ('both', 'Top switch, panels can override', false)])),
          ]),
          _note('The mock-up shows both a top switch and a "Today" menu on each panel, which lets two panels show different periods side by side. "One switch in the top bar" avoids that mismatch and is the default here.'),
          if (t['periodMode'] == null) const SizedBox.shrink(),
        ])),
      ],
    );
  }

  // KPI cards
  Widget _rKpi() {
    final K = c.kpi;
    final excl = (K['exclude'] as List).cast<String>();
    final cards = c.cards;
    Widget card(int i) {
      final cd = cards[i];
      final cm = c.cat(cd['metric'] as String?);
      final aggOpts = <(String, String, bool)>[
        ('inherit', 'Same as metric (${kAggLabel[cm?['agg']] ?? '—'})', false),
        for (final e in kAggLabel.entries) (e.key, e.value, cm?['kind'] == 'rate' && e.key == 'sum'),
      ];
      return Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: p.panel2,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: explain == i ? p.accent : p.line),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: hexColor(cd['accent']?.toString(), p.accent), shape: BoxShape.circle)),
            const SizedBox(width: 8),
            Expanded(child: Text((cd['title'] ?? '').toString(), style: _f(14, w: FontWeight.w700), overflow: TextOverflow.ellipsis)),
            _btn('Show the maths', () => setState(() => explain = i), small: true, primary: explain == i),
            const SizedBox(width: 6),
            _iconBtn('↑', i == 0 ? null : () => _moveCard(i, -1)),
            const SizedBox(width: 4),
            _iconBtn('↓', i == cards.length - 1 ? null : () => _moveCard(i, 1)),
            const SizedBox(width: 4),
            _iconBtn('✕', () => _delCard(i), hover: p.bad),
          ]),
          const SizedBox(height: 10),
          _grid([
            _fld('Card title', _txt('kpi.cards.$i.title')),
            _fld('Metric', _sel('kpi.cards.$i.metric', _metricOpts())),
            _fld('Group total', _sel('kpi.cards.$i.agg', aggOpts)),
            if (cd['agg'] == 'wavg') _fld('Weighted by', _sel('kpi.cards.$i.w', _metricOpts(where: (x) => x['kind'] == 'amount' && x['k'] != cd['metric'], blank: 'Same as metric'))),
            _fld('Unit shown', _txt('kpi.cards.$i.unit', hint: (cm?['unit'] ?? 'none').toString())),
            _fld('Icon', _sel('kpi.cards.$i.icon', [for (final e in kPomIconChoices) (e.$1, e.$2, false)])),
            _fld('Icon and value colours', Row(children: [_clr('kpi.cards.$i.accent'), const SizedBox(width: 8), _clr('kpi.cards.$i.color')])),
            _fld('Value size ${cd['size']}px', _range('kpi.cards.$i.size', 24, 56)),
          ]),
          const SizedBox(height: 8),
          _chk('kpi.cards.$i.spark', 'Show trend bars'),
        ]),
      );
    }

    return _panel(
      head: _head(Icons.bar_chart_rounded, p.accent, 'KPI cards', 'The group headline row. Cards never map their own device; they combine the values already mapped for each mill.', tag: '${cards.length} cards'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          for (var i = 0; i < cards.length; i++) card(i),
          _btn('+ Add card', cards.length >= 6 ? null : _addCard, small: true),
        ]), first: true),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _subH('Mills counted in the group'),
          Wrap(spacing: 6, runSpacing: 6, children: [
            for (final m in c.mills.where((m) => m['active'] == true))
              InkWell(
                onTap: () => setState(() {
                  final id = m['id'] as String;
                  excl.contains(id) ? excl.remove(id) : excl.add(id);
                  dirty = true;
                }),
                child: Opacity(
                  opacity: excl.contains(m['id']) ? .55 : 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
                    decoration: BoxDecoration(
                      color: excl.contains(m['id']) ? p.panel2 : p.accent,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: excl.contains(m['id']) ? p.line : p.accent),
                    ),
                    child: Text(PomCalc.short(m['name'].toString()),
                        style: _f(12.5, w: FontWeight.w600, color: excl.contains(m['id']) ? p.ink : p.accentInk).copyWith(decoration: excl.contains(m['id']) ? TextDecoration.lineThrough : null)),
                  ),
                ),
              ),
          ]),
          const SizedBox(height: 10),
          _chk('kpi.autoInclude', 'Count new mills automatically'),
        ])),
        _pb(_explainBox()),
      ],
    );
  }

  void _addCard() => setState(() {
        c.cards.add({'title': 'New card', 'metric': 'oer', 'agg': 'inherit', 'w': '', 'unit': '', 'icon': 'leaf', 'accent': '#3ec6ff', 'color': '#ffffff', 'size': 36, 'spark': true});
        explain = c.cards.length - 1;
        dirty = true;
        rev++;
      });

  void _delCard(int i) => setState(() {
        c.cards.removeAt(i);
        explain = math.max(0, math.min(explain, c.cards.length - 1));
        dirty = true;
        rev++;
      });

  void _moveCard(int i, int d) => setState(() {
        final l = c.cards;
        final t = l[i];
        l[i] = l[i + d];
        l[i + d] = t;
        explain = i + d;
        dirty = true;
        rev++;
      });

  Widget _explainBox() {
    if (explain >= c.cards.length) return const SizedBox.shrink();
    final card = c.cards[explain];
    final cm = c.cat(card['metric'] as String?);
    if (cm == null) return const SizedBox.shrink();
    final e = c.eff(card);
    final per = c.perFor('kpi', period, panelPeriod);
    final r = c.aggregate(card['metric'] as String, e.$1, e.$2, c.groupMills(), per);
    final u = r.rows.where((x) => x.ok).toList();
    final dec = ((cm['dec'] ?? 0) as num).toInt();
    String f;
    if (e.$1 == 'wavg') {
      f = 'Σ(${cm['label']} × ${c.lbl(e.$2)}) ÷ Σ ${c.lbl(e.$2)} = ${fmtNum(u.fold<double>(0, (a, x) => a + x.v! * x.w!), 1)} ÷ ${fmtNum(u.fold<double>(0, (a, x) => a + x.w!), 1)}';
    } else if (e.$1 == 'sum') {
      f = u.isEmpty ? '—' : u.map((x) => fmtNum(x.v!, dec)).join(' + ');
    } else if (e.$1 == 'avg') {
      f = '(${u.map((x) => fmtNum(x.v!, dec)).join(' + ')}) ÷ ${u.length}';
    } else {
      f = '${e.$1}(${u.map((x) => fmtNum(x.v!, dec)).join(', ')})';
    }
    final simple = u.isEmpty ? null : u.fold<double>(0, (a, x) => a + x.v!) / u.length;
    final showW = e.$1 == 'wavg';
    final unit = ((card['unit'] ?? '').toString().isNotEmpty ? card['unit'] : cm['unit'] ?? '').toString();
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: p.accent.withOpacity(.06), borderRadius: BorderRadius.circular(10), border: Border.all(color: p.accent.withOpacity(.4))),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('How “${card['title']}” is worked out (${kPeriodLabel[per]})', style: _f(13.5, w: FontWeight.w700)),
        const SizedBox(height: 8),
        Text('${kAggLabel[e.$1]}: $f', style: GoogleFonts.robotoMono(fontSize: 12, color: p.ink)),
        const SizedBox(height: 8),
        _table(
          showW ? const [140, 90, 90, 160] : const [140, 90, 160],
          ['Mill', cm['label'].toString(), if (showW) c.lbl(e.$2), 'In the total'],
          [
            for (final x in r.rows)
              [
                Text(PomCalc.short(x.mill['name'].toString()), style: _f(12.5)),
                Text(x.v == null ? '—' : fmtNum(x.v!, dec), style: _f(12.5)),
                if (showW) Text(x.w == null ? '—' : fmtNum(x.w!, ((c.cat(e.$2)?['dec'] ?? 1) as num).toInt()), style: _f(12.5)),
                Align(alignment: Alignment.centerLeft, child: x.ok ? _badge('Counted', p.ok) : _badge(x.why, p.warn)),
              ],
          ],
        ),
        const SizedBox(height: 10),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('Result', style: _f(13)),
          Text('${r.v == null ? '—' : fmtNum(r.v!, dec)} $unit', style: _cond(20, w: FontWeight.w700)),
        ]),
        if (showW && simple != null && r.v != null && fmtNum(simple, dec) != fmtNum(r.v!, dec))
          _note('A simple average of the same mills would show ${fmtNum(simple, dec)}. The difference is the size of each mill.'),
      ]),
    );
  }

  // Map
  Widget _rMapc() {
    final rows = <List<Widget>>[];
    for (var i = 0; i < c.mills.length; i++) {
      final m = c.mills[i];
      rows.add([
        Opacity(
          opacity: m['active'] == true ? 1 : .5,
          child: Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: c.statusColor(m['id'] as String, 'today'), shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Expanded(child: Text(PomCalc.short(m['name'].toString()), style: _f(12.5), overflow: TextOverflow.ellipsis)),
          ]),
        ),
        _txt('mills.$i.loc', hint: 'Label'),
        _numF('mills.$i.x', hint: 'X %'),
        _numF('mills.$i.y', hint: 'Y %'),
        _sel('mills.$i.side', const [('top', 'Above', false), ('bottom', 'Below', false), ('left', 'Left', false), ('right', 'Right', false)]),
      ]);
    }
    return _panel(
      head: _head(Icons.place_outlined, const Color(0xFF0C9D8A), 'Map', 'The centre map. Drag pins on the preview, or type exact positions below.'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [_subH('Pins  · one row per mill, follows Mills')]), first: true),
        _table(const [140, 96, 70, 70, 100], ['Mill', 'Label', 'X %', 'Y %', 'Pop-up'], rows),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _grid([
            _fld('Panel title', _txt('mapc.title')),
            _fld('Panel subtitle', _txt('mapc.subtitle')),
            _fld('Map image (asset path or https address)', _txt('mapc.bg')),
            _fld('Sea label', _txt('mapc.sea')),
            _fld('Region label', _txt('mapc.region')),
          ]),
          const SizedBox(height: 12),
          _row([
            _chk('mapc.header', 'Panel title bar'),
            _chk('mapc.locLabels', 'Town labels'),
            _chk('mapc.legend', 'Status legend'),
            _chk('mapc.compass', 'Compass'),
            _chk('mapc.inset', 'Locator inset'),
            _chk('mapc.scale', 'Scale bar'),
          ]),
          _note('The default Sarawak picture already has its own title, legend, compass, scale, inset and town names, so those are off. Switch them on when a plain map image is used. Pins are placed as a percentage of the image, and the image stretches to fill the panel, so pins stay on their mill if the image is swapped for one of the same area.'),
        ])),
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _subH('Pin pop-up'),
          _grid([
            _fld('First figure', _sel('mapc.popup.0', _metricOpts(blank: 'None'))),
            _fld('Second figure', _sel('mapc.popup.1', _metricOpts(blank: 'None'))),
          ]),
          const SizedBox(height: 10),
          _chk('mapc.popStatus', 'Show status pill'),
          _note('The mock-up\'s pop-ups show a "Health" figure that matches Sterilizer Health for some mills and Overall Process Health for others. Picking the figure here keeps every pop-up reading the same field.'),
        ])),
      ],
    );
  }

  // Left panel
  Widget _rLeft() {
    final L = c.left;
    return _panel(
      head: _head(Icons.view_list_outlined, const Color(0xFF22C55E), 'Left panel', 'One card per mill with up to three figures.'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _grid([
            _fld('Panel title', _txt('left.title')),
            for (var i = 0; i < 3; i++) _fld('Figure ${i + 1}', _sel('left.metrics.$i', _metricOpts(blank: 'None'))),
            _fld('Card border colour follows', _sel('left.border', const [('status', 'Status rule', false), ('band', 'Performance band', false)])),
            _fld('Order', _sel('left.sort', const [('registry', 'Same as Mills list', false), ('metric', 'By a figure', false)])),
            if (L['sort'] == 'metric') _fld('Sort by', _sel('left.sortMetric', _metricOpts())),
            if (L['sort'] == 'metric') _fld('Direction', _sel('left.sortDir', const [('desc', 'Highest first', false), ('asc', 'Lowest first', false)])),
          ]),
          const SizedBox(height: 12),
          _row([_chk('left.band', 'Show performance pill'), _chk('left.bars', 'Show signal bars')]),
        ]), first: true),
      ],
    );
  }

  // Right panel
  Widget _rRight() {
    final R = c.right;
    final cols = (R['cols'] as List).cast<Map<String, dynamic>>();
    return _panel(
      head: _head(Icons.table_chart_outlined, const Color(0xFFF5B82E), 'Right panel', "Mill health table. Bars and figures take the mill's status colour."),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _grid([
            _fld('Panel title', _txt('right.title')),
            _fld('Order', _sel('right.sortMetric', _metricOpts(blank: 'Same as Mills list'))),
            if ((R['sortMetric'] ?? '').toString().isNotEmpty) _fld('Direction', _sel('right.sortDir', const [('desc', 'Highest first', false), ('asc', 'Lowest first', false)])),
          ]),
          const SizedBox(height: 14),
          _subH('Columns'),
          for (var i = 0; i < cols.length; i++)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(children: [
                Expanded(child: _sel('right.cols.$i.m', _metricOpts())),
                const SizedBox(width: 10),
                _chk('right.cols.$i.bar', 'Bar'),
                const SizedBox(width: 8),
                _iconBtn('✕', () => setState(() {
                      cols.removeAt(i);
                      dirty = true;
                      rev++;
                    }), hover: p.bad),
              ]),
            ),
          _row([
            _btn('+ Add column', cols.length >= 3 ? null : () => setState(() {
                  cols.add({'m': 'oer', 'bar': false});
                  dirty = true;
                  rev++;
                }), small: true),
            _chk('right.status', 'Status column'),
          ]),
        ]), first: true),
      ],
    );
  }

  // Attention feed
  Widget _rAlerts() {
    final A = c.alerts;
    final sev = (A['sev'] as List).cast<Map<String, dynamic>>();
    return _panel(
      head: _head(Icons.warning_amber_rounded, p.bad, 'Attention feed', 'Recent events worth a look. The RCA engine already writes plain-language messages in three languages.'),
      children: [
        _pb(Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          _grid([
            _fld('Panel title', _txt('alerts.title')),
            _fld('Source', _sel('alerts.source', const [('rca', 'Sterilizer RCA engine', false), ('alarm', 'Alarm table', false), ('both', 'Both', false)])),
            _fld('Look back', _sel('alerts.window', const [('6', '6 hours', false), ('12', '12 hours', false), ('24', '24 hours', false), ('72', '3 days', false)], numeric: true)),
            _fld('Lowest level shown', _sel('alerts.minSev', [for (final x in sev) (x['k'].toString(), x['label'].toString(), false)])),
            _fld('Items shown', _numF('alerts.max')),
            _fld('Message language', _sel('alerts.lang', const [('en', 'English', false), ('bm', 'Bahasa Melayu', false), ('zh', '中文', false)])),
          ]),
          const SizedBox(height: 10),
          _grid([
            for (var i = 0; i < sev.length; i++)
              _fld('Level ${i + 1} label and colour', Row(children: [Expanded(child: _txt('alerts.sev.$i.label')), const SizedBox(width: 6), _clr('alerts.sev.$i.color')])),
          ]),
          const SizedBox(height: 10),
          _chk('alerts.rel', 'Show time as "2h ago"'),
        ]), first: true),
      ],
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.pct, this.color, this.track);
  final double pct;
  final Color color;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(center: size.center(Offset.zero), radius: 18);
    canvas.drawArc(rect, 0, math.pi * 2, false, Paint()..color = track..style = PaintingStyle.stroke..strokeWidth = 5);
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2 * pct, false, Paint()..color = color..style = PaintingStyle.stroke..strokeWidth = 5..strokeCap = StrokeCap.round);
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) => old.pct != pct || old.color != color || old.track != track;
}
