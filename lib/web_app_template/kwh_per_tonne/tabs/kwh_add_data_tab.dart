import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/rbac.dart';
import '../../production_output_log/services/production_output_service.dart';
import '../kwh_theme.dart';
import '../widgets/kwh_shared_widgets.dart';

class KwhAddDataTab extends StatefulWidget {
  final List<String> machineNames;
  final List<String> productNames;
  final List<String> deptOptions;   // already filtered (no 'All')
  final String? selectedMachine;    // pre-selected from machine detail dialog
  final Map<String, String> machineMeterIds; // machine display name -> meterId, for energy lookup
  final double rate;
  final String currency;
  final Future<void> Function() onRefresh;
  final List<Map<String, dynamic>> enriched;
  final double criticalPct;
  final double warningPct;
  final Future<void> Function(Map<String, dynamic> entry) onDelete;
  final bool editingEnabled; // Thresholds dialog → "Enable editing entries"
  final Map<String, dynamic>? editEntry; // set by Data Log's Edit button; null = plain create mode
  final VoidCallback? onEditConsumed; // tells the parent it can clear editEntry once loaded into the form

  const KwhAddDataTab({
    super.key,
    required this.machineNames,
    required this.productNames,
    required this.deptOptions,
    required this.selectedMachine,
    required this.machineMeterIds,
    required this.rate,
    required this.currency,
    required this.onRefresh,
    required this.enriched,
    required this.criticalPct,
    required this.warningPct,
    required this.onDelete,
    required this.editingEnabled,
    this.editEntry,
    this.onEditConsumed,
  });

  @override
  State<KwhAddDataTab> createState() => _KwhAddDataTabState();
}

class _KwhAddDataTabState extends State<KwhAddDataTab> {
  static final _numFmt = NumberFormat('#,##0.00', 'en_US');
  static String _fmt(double v) => _numFmt.format(v);

  // Malaysia time (UTC+8, no DST) — matches the convention already used for
  // "today" elsewhere in this app (see energy_details_widget.dart), so the
  // TIME field and the saved 'date'/'time' payload reflect MYT regardless of
  // the operator's device timezone.
  static DateTime _nowMYT() => DateTime.now().toUtc().add(const Duration(hours: 8));
  static TimeOfDay _nowTimeMYT() { final n = _nowMYT(); return TimeOfDay(hour: n.hour, minute: n.minute); }

  DateTime  _date        = _nowMYT();
  TimeOfDay _time         = _nowTimeMYT();
  String?   _machine;
  String?   _dept;
  bool      _submitting  = false;
  String?   _error;
  String?   _success;

  // Shift — pulled from Shift Setting (Start Work Time). Shown locked (not
  // editable) per the new design: the day's batches all measure against the
  // shift's configured start, so letting it drift per-entry would break the
  // "today's anchor" story below.
  List<Map<String, dynamic>> _shifts       = [];
  String?                    _shift;
  TimeOfDay?                 _shiftStartTime;
  bool                       _shiftsLoading = false;

  // Meter-reading-delta model: each batch's kWh consumed = meterReadingNow -
  // previousReading. previousReading auto-carries from the prior entry's
  // meterReadingNow for this machine/date; for the very first entry of the
  // day it's pre-filled from a live DPM reading (see _autoFetchAnchorIfNeeded)
  // and becomes that day's locked "anchor" for every later batch. Operators
  // can still overwrite it before saving if the live fetch is unavailable or wrong.
  bool    _isFirstEntryToday   = true;
  double? _anchorReading;       // day's opening reading (first entry's previousReading)
  String? _anchorLockLabel;     // display label for when the anchor was set
  double? _lockedPreviousReading; // last entry's meterReadingNow, when not the first entry

  // Live DPM anchor fetch — one-shot GET to the same Influx realtime endpoint
  // Energy Details polls (energyDetailsInfluxDb/realtime/{deviceId}), keyed by
  // the machine's meterId. Only fires for today's date + first entry, and
  // only pre-fills (never overwrites something already typed/fetched).
  bool    _fetchingLiveReading = false;
  String? _liveReadingError;
  TimeOfDay? _liveReadingFetchedAt;

  // Live "Meter Reading Now" fetch — GET /energyDetails/reading/{meterId}
  // with no ?hour=, so the backend returns the latest MySQL energy_edel
  // reading available for the date instead of an hour-bucketed one (see
  // _autoFetchMeterNowIfNeeded). Only applies to today's date, since a
  // backfilled past entry has no "live" register value to fetch, and only
  // pre-fills an empty field — the operator can hit refresh or type over it.
  bool    _fetchingMeterNow = false;
  String? _meterNowError;
  TimeOfDay? _meterNowFetchedAt;

  // Non-null while editing an existing entry (set from widget.editEntry or a
  // tap on this tab's own Recent entries table); null means "creating new".
  String? _editId;

  final _previousReadingCtrl = TextEditingController();
  final _meterReadingNowCtrl = TextEditingController();
  final _tonnesCtrl          = TextEditingController();
  final _reportByCtrl      = TextEditingController();

  void _onFormChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    if (widget.editEntry != null) {
      _loadEntryForEdit(widget.editEntry!);
      WidgetsBinding.instance.addPostFrameCallback((_) => widget.onEditConsumed?.call());
    } else {
      _syncFromProps();
    }
    _computeAnchor();
    _autoFetchAnchorIfNeeded();
    _autoFetchMeterNowIfNeeded();
    _fetchShifts();
    _previousReadingCtrl.addListener(_onFormChanged);
    _meterReadingNowCtrl.addListener(_onFormChanged);
    _tonnesCtrl.addListener(_onFormChanged);
  }

  @override
  void didUpdateWidget(KwhAddDataTab old) {
    super.didUpdateWidget(old);
    if (widget.selectedMachine != old.selectedMachine && widget.selectedMachine != null) {
      _machine = widget.selectedMachine;
    }
    // Ensure defaults remain valid when lists change.
    _syncDefaults();
    _computeAnchor();
    _autoFetchAnchorIfNeeded();
    _autoFetchMeterNowIfNeeded();
  }

  @override
  void dispose() {
    _previousReadingCtrl.removeListener(_onFormChanged);
    _meterReadingNowCtrl.removeListener(_onFormChanged);
    _tonnesCtrl.removeListener(_onFormChanged);
    _previousReadingCtrl.dispose();
    _meterReadingNowCtrl.dispose();
    _tonnesCtrl.dispose();
    _reportByCtrl.dispose();
    super.dispose();
  }

  void _syncFromProps() {
    _machine = widget.selectedMachine ?? (widget.machineNames.isNotEmpty ? widget.machineNames.first : null);
    _dept    = widget.deptOptions.isNotEmpty  ? widget.deptOptions.first  : null;
  }

  void _syncDefaults() {
    if (_machine == null || !widget.machineNames.contains(_machine)) {
      _machine = widget.machineNames.isNotEmpty ? widget.machineNames.first : null;
    }
    final depts = widget.deptOptions;
    if (_dept == null || !depts.contains(_dept)) {
      _dept = depts.isNotEmpty ? depts.first : null;
    }
  }

  // Populates the form from an existing entry (Data Log's Edit button, or a
  // tap on this tab's own Recent entries row) and switches _submit() into
  // update mode via _editId.
  void _loadEntryForEdit(Map<String, dynamic> e) {
    _editId = e['id']?.toString();
    _date = DateTime.tryParse(e['date']?.toString() ?? '') ?? _nowMYT();
    _time = _parseApiTime(e['time']?.toString()) ?? _nowTimeMYT();
    _machine = e['machine']?.toString();
    _dept = e['processDepartment']?.toString();
    _shift = e['shift']?.toString();
    _shiftStartTime = _parseApiTime(e['shiftStartTime']?.toString()) ?? _shiftStartTime;
    final prev = (e['previousReading'] as num?)?.toDouble();
    final now  = (e['meterReadingNow'] as num?)?.toDouble();
    _previousReadingCtrl.text = prev != null ? prev.toStringAsFixed(2) : '';
    _meterReadingNowCtrl.text = now  != null ? now.toStringAsFixed(2)  : '';
    _tonnesCtrl.text = (e['tonnes'] as num?)?.toString() ?? '';
    _reportByCtrl.text = e['reportBy']?.toString() ?? '';
  }

  // Parses both "HH:MM" (shiftStartTime) and "HH:MM:SS AM/PM" (time) — the
  // hour is always written 24-hour by _apiTime/_hhmm, so the AM/PM suffix
  // (if any) doesn't need to be re-applied on the way back in.
  TimeOfDay? _parseApiTime(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final match = RegExp(r'^(\d{1,2}):(\d{2})').firstMatch(raw.trim());
    if (match == null) return null;
    final h = int.tryParse(match.group(1) ?? '');
    final m = int.tryParse(match.group(2) ?? '');
    if (h == null || m == null) return null;
    return TimeOfDay(hour: h % 24, minute: m);
  }

  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';

  String _isoDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  // 12-hour display + the "time" field sent to the API — matches the format
  // already written by production_output_log/widgets/entry_dialog.dart so
  // both entry points populate the log's Time column consistently.
  String _fmtTimeOfDay(TimeOfDay t) {
    final h = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
    final period = t.period == DayPeriod.am ? 'AM' : 'PM';
    return '${h.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')} $period';
  }

  String _apiTime(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';

  // Shift Setting stores Start Work Time as "HH:MM" — reuse that shape when
  // sending shiftStartTime so it round-trips with Shift Setting values.
  String _hhmm(TimeOfDay t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  // Older entries created before Time/Shift were added won't carry these fields.
  String _orDash(dynamic v) => (v?.toString().isNotEmpty ?? false) ? v.toString() : '-';

  List<String> get _shiftNames =>
      _shifts.map((s) => s['name']?.toString() ?? '').where((n) => n.isNotEmpty).toList();

  void _applyShiftStartTime(Map<String, dynamic> shift) {
    final raw = shift['startWorkTime']?.toString() ?? '';
    final parts = raw.split(':');
    if (parts.length >= 2) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (h != null && m != null) _shiftStartTime = TimeOfDay(hour: h, minute: m);
    }
  }

  // Shift options come from Shift Setting (General Factory Setting → Shift),
  // same /shifts endpoint + userId/role scoping that page uses (see
  // shift_setting_widget.dart _fetch()) — non-admins only see their own
  // shifts, so without this filter the list (and Start Work Time) can come
  // back empty for them even though it works for a Super Admin/Admin.
  Future<void> _fetchShifts() async {
    setState(() => _shiftsLoading = true);
    try {
      final userId = AppStateNotifier.instance.uid ?? '';
      final userRole = AppStateNotifier.instance.userRole ?? '';
      final normalizedRole = AppRoles.normalizeRole(userRole);
      final isSuperAdminOrAdmin = normalizedRole == AppRoles.superAdmin || normalizedRole == AppRoles.admin;

      final uri = Uri.parse('${AppConfig.dataApiBaseSafe}/shifts')
          .replace(queryParameters: (!isSuperAdminOrAdmin && userId.isNotEmpty) ? {'userId': userId} : null);
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        final shifts = data.map((e) => Map<String, dynamic>.from(e as Map)).toList();
        setState(() {
          _shifts = shifts;
          if (shifts.isNotEmpty && (_shift == null || !shifts.any((s) => s['name']?.toString() == _shift))) {
            _shift = shifts.first['name']?.toString();
            _applyShiftStartTime(shifts.first);
          }
        });
        _onShiftStartResolved();
      }
    } catch (_) {
      // keep existing shift list on failure
    } finally {
      if (mounted) setState(() => _shiftsLoading = false);
    }
  }

  void _onShiftChanged(String? v) {
    if (v == null) return;
    final match = _shifts.firstWhere((s) => s['name']?.toString() == v, orElse: () => const {});
    setState(() {
      _shift = v;
      if (match.isNotEmpty) _applyShiftStartTime(match);
    });
    _onShiftStartResolved();
  }

  // The anchor fetch is keyed to the shift's start hour, so whenever that
  // hour changes (shift list loads for the first time, or the operator picks
  // a different shift) an auto-fetched (never a manually-typed) Previous
  // Reading value is stale and must be cleared so it re-fetches for the new hour.
  void _onShiftStartResolved() {
    if (_isFirstEntryToday && _liveReadingFetchedAt != null) {
      setState(() {
        _previousReadingCtrl.clear();
        _liveReadingFetchedAt = null;
      });
    }
    _autoFetchAnchorIfNeeded();
  }

  // Entries for the selected machine on the selected date, oldest first — the
  // basis for both the "today's anchor" box and previous-reading carry-over.
  List<Map<String, dynamic>> _entriesForMachineDate(String machine, DateTime date) {
    final iso = _isoDate(date);
    final list = widget.enriched.where((e) => e['machine']?.toString() == machine && e['date']?.toString() == iso).toList();
    list.sort((a, b) {
      final ta = _parseApiTime(a['time']?.toString());
      final tb = _parseApiTime(b['time']?.toString());
      final ma = ta == null ? 0 : ta.hour * 60 + ta.minute;
      final mb = tb == null ? 0 : tb.hour * 60 + tb.minute;
      return ma.compareTo(mb);
    });
    return list;
  }

  // Recomputes whether this is today's first entry for the selected
  // machine/date, and if not, carries the last entry's meter reading into
  // Previous Reading (locked). Pure field mutation — no setState, since both
  // call sites (initState/didUpdateWidget) are already followed by a build
  // in the same pass; _refreshAnchor() below wraps it for other call sites.
  void _computeAnchor() {
    if (_editId != null) {
      // Editing an existing entry: previous/now are whatever was loaded from
      // that entry, freely editable — not recomputed from the day's series.
      _isFirstEntryToday = true;
      _lockedPreviousReading = null;
      _anchorReading = null;
      _anchorLockLabel = null;
      _liveReadingFetchedAt = null;
      _liveReadingError = null;
      return;
    }
    final machine = _machine;
    if (machine == null) {
      _isFirstEntryToday = true;
      _lockedPreviousReading = null;
      _anchorReading = null;
      _anchorLockLabel = null;
      _liveReadingFetchedAt = null;
      _liveReadingError = null;
      return;
    }
    final entries = _entriesForMachineDate(machine, _date);
    if (entries.isEmpty) {
      _isFirstEntryToday = true;
      _lockedPreviousReading = null;
      _anchorReading = null;
      _anchorLockLabel = null;
      _previousReadingCtrl.clear();
      _liveReadingFetchedAt = null;
      _liveReadingError = null;
      return;
    }
    final first = entries.first;
    final last = entries.last;
    _isFirstEntryToday = false;
    _anchorReading = (first['previousReading'] as num?)?.toDouble();
    final firstShiftStart = first['shiftStartTime']?.toString() ?? '';
    _anchorLockLabel = _orDash(firstShiftStart.isNotEmpty ? firstShiftStart : first['time']);
    _lockedPreviousReading = (last['meterReadingNow'] as num?)?.toDouble();
    _previousReadingCtrl.text = _lockedPreviousReading != null ? _fmt(_lockedPreviousReading!) : '';
    _liveReadingFetchedAt = null;
    _liveReadingError = null;
  }

  void _refreshAnchor() {
    setState(_computeAnchor);
    _autoFetchAnchorIfNeeded();
    _autoFetchMeterNowIfNeeded();
  }

  // Rule: at shift start each day, the DPM's meter reading becomes that
  // machine's locked "daily anchor" for Previous Reading. There's no backend
  // job that captures this automatically, so we approximate it here: a
  // one-shot fetch of the actual meter reading (energy_edel, not a
  // consumption delta) at the selected date's shift-start hour via
  // GET /energyDetails/reading/{meterId}?date=&hour=, pre-filling Previous
  // Reading the moment this is recognized as the machine's first entry for
  // that date. Works for backfilled past dates too, since the endpoint takes
  // an explicit date/hour rather than always reading "right now". It only
  // ever pre-fills an empty field — never overwrites a value already typed
  // or already fetched — and operators can still edit it before saving if
  // the fetched reading is wrong or unavailable.
  Future<void> _autoFetchAnchorIfNeeded() async {
    if (_editId != null || !_isFirstEntryToday) return;
    final machine = _machine;
    if (machine == null) return;
    final meterId = widget.machineMeterIds[machine];
    if (meterId == null || meterId.isEmpty) return;
    final shiftHour = _shiftStartTime?.hour;
    if (shiftHour == null) return; // shifts still loading — retried once they load
    if (_previousReadingCtrl.text.trim().isNotEmpty) return;
    if (_fetchingLiveReading) return;

    final date = _date;
    setState(() { _fetchingLiveReading = true; _liveReadingError = null; });
    try {
      final uri = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/reading/$meterId?date=${_isoDate(date)}&hour=$shiftHour');
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      // Bail if the form moved on (machine/date/shift changed, or an entry landed) while the request was in flight.
      if (_machine != machine || !_isFirstEntryToday || _date != date || _shiftStartTime?.hour != shiftHour || _previousReadingCtrl.text.trim().isNotEmpty) {
        setState(() => _fetchingLiveReading = false);
        return;
      }
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final reading = decoded is Map ? decoded['reading'] : null;
        setState(() {
          _fetchingLiveReading = false;
          if (reading is num) {
            _previousReadingCtrl.text = _fmt(reading.toDouble());
            _liveReadingFetchedAt = _shiftStartTime;
          } else {
            _liveReadingError = 'No meter reading available for this date/shift — enter manually.';
          }
        });
      } else {
        setState(() { _fetchingLiveReading = false; _liveReadingError = 'Could not fetch the meter reading — enter manually.'; });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() { _fetchingLiveReading = false; _liveReadingError = 'Could not fetch the meter reading — enter manually.'; });
    }
  }

  // "Meter Reading Now" is per-batch (every entry, not just the day's first),
  // so unlike the anchor above it can't be keyed to a fixed shift-start hour —
  // it needs the DPM's current register value at the moment of weighing. Hits
  // the same GET /energyDetails/reading/{meterId} endpoint but with no
  // ?hour=, which tells the backend to return the latest MySQL reading for
  // the date instead of one pinned to an hour boundary. Only fires for
  // today's date (a backfilled past entry has no "live" value) and only
  // pre-fills an empty field — the refresh icon lets the operator re-pull it
  // right before weighing, or they can type over it if the DPM disagrees.
  Future<void> _autoFetchMeterNowIfNeeded() async {
    if (_editId != null) return;
    final machine = _machine;
    if (machine == null) return;
    final meterId = widget.machineMeterIds[machine];
    if (meterId == null || meterId.isEmpty) return;
    if (_isoDate(_date) != _isoDate(_nowMYT())) return; // only "now" for today's entries
    if (_meterReadingNowCtrl.text.trim().isNotEmpty) return;
    if (_fetchingMeterNow) return;

    final date = _date;
    setState(() { _fetchingMeterNow = true; _meterNowError = null; });
    try {
      final uri = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/reading/$meterId?date=${_isoDate(date)}');
      final res = await http.get(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      // Bail if the form moved on (machine/date changed, or an entry landed) while the request was in flight.
      if (_machine != machine || _date != date || _meterReadingNowCtrl.text.trim().isNotEmpty) {
        setState(() => _fetchingMeterNow = false);
        return;
      }
      if (res.statusCode == 200) {
        final decoded = jsonDecode(res.body);
        final reading = decoded is Map ? decoded['reading'] : null;
        setState(() {
          _fetchingMeterNow = false;
          if (reading is num) {
            _meterReadingNowCtrl.text = _fmt(reading.toDouble());
            _meterNowFetchedAt = _nowTimeMYT();
          } else {
            _meterNowError = 'No live meter reading available — enter manually.';
          }
        });
      } else {
        setState(() { _fetchingMeterNow = false; _meterNowError = 'Could not fetch the meter reading — enter manually.'; });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() { _fetchingMeterNow = false; _meterNowError = 'Could not fetch the meter reading — enter manually.'; });
    }
  }

  // Clears the field and re-runs the auto-fetch — lets the operator pull a
  // fresh reading right before weighing instead of relying on the value
  // fetched when the form first loaded.
  void _refetchMeterNow() {
    setState(() {
      _meterReadingNowCtrl.clear();
      _meterNowFetchedAt = null;
      _meterNowError = null;
    });
    _autoFetchMeterNowIfNeeded();
  }

  // Meter Reading Now is scoped to a specific machine/date's live DPM value —
  // _autoFetchMeterNowIfNeeded() only pre-fills an *empty* field, so without
  // this the previous machine's (or date's) reading lingers on screen after
  // switching and never gets replaced. Call before _refreshAnchor() whenever
  // machine or date actually changes (not on every rebuild — e.g. shift
  // changes and edit-row loads must leave an already-typed value alone).
  void _resetMeterNowForNewContext() {
    _meterReadingNowCtrl.clear();
    _meterNowFetchedAt = null;
    _meterNowError = null;
  }

  // Auto-fetched readings are written into the fields via _fmt (thousands
  // separators, e.g. "42,815.20"), so parsing must strip commas or the
  // derived kWh consumed silently becomes "-" for any reading ≥ 1,000.
  static double? _parseNum(String raw) => double.tryParse(raw.replaceAll(',', '').trim());

  double? get _meterReadingNow => _parseNum(_meterReadingNowCtrl.text);
  double? get _tonnesValue     => _parseNum(_tonnesCtrl.text);
  double? get _previousReadingValue =>
      _isFirstEntryToday ? _parseNum(_previousReadingCtrl.text) : _lockedPreviousReading;

  double? get _kwhConsumed {
    final now = _meterReadingNow;
    final prev = _previousReadingValue;
    if (now == null || prev == null) return null;
    return now - prev;
  }

  double? get _kwhPerTonne {
    final kwh = _kwhConsumed;
    final tonnes = _tonnesValue;
    if (kwh == null || tonnes == null || tonnes <= 0) return null;
    return kwh / tonnes;
  }

  Future<void> _submit() async {
    final meterNow    = _meterReadingNow;
    final prevReading = _previousReadingValue;
    final tonnes      = _tonnesValue;
    final reportBy    = _reportByCtrl.text.trim();

    if (_machine == null) { setState(() => _error = 'Please select a machine.'); return; }
    if (prevReading == null) {
      setState(() => _error = _isFirstEntryToday
          ? "Please enter today's opening meter reading."
          : 'Previous reading is unavailable — try refreshing.');
      return;
    }
    if (meterNow == null) { setState(() => _error = 'Please enter the current meter reading.'); return; }
    if (meterNow < prevReading) { setState(() => _error = 'Meter reading now must be greater than or equal to the previous reading.'); return; }
    if (tonnes == null || tonnes <= 0) { setState(() => _error = 'Please enter a valid tonnes value.'); return; }
    if (reportBy.isEmpty) { setState(() => _error = 'Please enter who is reporting this entry.'); return; }

    setState(() { _submitting = true; _error = null; _success = null; });
    final body = {
      'date': _isoDate(_date),
      'time': _apiTime(_time),
      'machine': _machine,
      'processDepartment': _dept ?? '',
      'shift': _shift ?? '',
      'shiftStartTime': _shiftStartTime != null ? _hhmm(_shiftStartTime!) : '',
      'previousReading': prevReading,
      'meterReadingNow': meterNow,
      'kwh': meterNow - prevReading,
      'tonnes': tonnes,
      'reportBy': reportBy,
    };
    try {
      if (_editId != null) {
        await ProductionOutputService.update(_editId!, body);
        setState(() {
          _submitting = false;
          _success = 'Entry updated successfully!';
          _editId = null;
          _meterReadingNowCtrl.clear();
          _tonnesCtrl.clear();
          _time = _nowTimeMYT();
          _syncFromProps();
        });
      } else {
        await ProductionOutputService.create(body);
        setState(() {
          _submitting = false;
          _success = 'Entry added successfully!';
          _meterReadingNowCtrl.clear();
          _tonnesCtrl.clear();
          _time = _nowTimeMYT();
        });
      }
      await widget.onRefresh();
      if (!mounted) return; // onRefresh() can tear this tab down (parent's loading spinner replaces it)
      _refreshAnchor();
    } catch (e) {
      if (!mounted) return;
      setState(() { _submitting = false; _error = 'Failed: $e'; });
    }
  }

  void _clear() {
    setState(() {
      _meterReadingNowCtrl.clear();
      _tonnesCtrl.clear();
      _reportByCtrl.clear();
      _date = _nowMYT();
      _time = _nowTimeMYT();
      _error = null; _success = null;
    });
    _refreshAnchor();
  }

  // Exits edit mode and returns the form to a blank "create" state.
  void _cancelEdit() {
    setState(() {
      _editId = null;
      _error = null; _success = null;
      _meterReadingNowCtrl.clear();
      _tonnesCtrl.clear();
      _reportByCtrl.clear();
      _date = _nowMYT();
      _time = _nowTimeMYT();
      _syncFromProps();
    });
    _refreshAnchor();
  }

  // Loads a row from this tab's own Recent entries table into the form above.
  void _startEditFromRow(Map<String, dynamic> e) {
    setState(() {
      _error = null; _success = null;
      _loadEntryForEdit(e);
    });
    _refreshAnchor();
  }

  // Scoped to the top filter bar's Plant → Production Area → Equipment cascade
  // (widget.machineNames already reflects that, see kwh_per_tonne_widget.dart's
  // addData case) — falls back to the unfiltered list if that scope is somehow
  // empty, so entries are never hidden by an edge case in the parent's fallback.
  List<Map<String, dynamic>> get _recentEntries {
    final scope = widget.machineNames.toSet();
    final scoped = scope.isEmpty
        ? widget.enriched
        : widget.enriched.where((e) => scope.contains(e['machine']?.toString())).toList();
    final list = List<Map<String, dynamic>>.from(scoped);
    list.sort((a, b) => (b['date']?.toString() ?? '').compareTo(a['date']?.toString() ?? ''));
    return list.take(10).toList();
  }

  Future<void> _confirmDelete(BuildContext context, Map<String, dynamic> e, bool isLight, FlutterFlowTheme theme) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: isLight ? theme.secondaryBackground : KwhColors.cardBg,
        title: Text('Delete entry?', style: GoogleFonts.poppins(color: isLight ? theme.primaryText : Colors.white, fontWeight: FontWeight.w700)),
        content: Text('Delete ${e['machine']} on ${e['date']}?', style: GoogleFonts.poppins(color: isLight ? theme.secondaryText : Colors.white54, fontSize: 18)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text('Cancel', style: GoogleFonts.poppins(color: isLight ? theme.secondaryText : Colors.white54))),
          TextButton(onPressed: () => Navigator.pop(context, true),  child: Text('Delete', style: GoogleFonts.poppins(color: KwhColors.red, fontWeight: FontWeight.w700))),
        ],
      ),
    );
    if (ok == true) await widget.onDelete(e);
  }

  Widget _hint(String text, bool isLight, FlutterFlowTheme theme) => Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text(text, style: GoogleFonts.poppins(fontSize: 13, color: isLight ? theme.secondaryText : Colors.white38)),
      );

  Widget _fieldReq(String label, bool isLight, FlutterFlowTheme theme, Widget child) =>
      Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(label, style: kwhLblStyle(isLight, theme)),
          Text(' *', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: KwhColors.red)),
        ]),
        const SizedBox(height: 6),
        child,
      ]);

  Widget _dropField(List<String> items, String value, void Function(String?) onChanged, bool isLight, FlutterFlowTheme theme) {
    final val = items.contains(value) ? value : (items.isNotEmpty ? items.first : null);
    return kwhCyberpunkDropdown(
      isLight: isLight,
      theme: theme,
      value: val,
      options: items,
      hint: 'Select',
      width: double.infinity,
      onChanged: onChanged,
    );
  }

  Widget _lockedBox(String display, bool isLight, FlutterFlowTheme theme) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: isLight ? theme.alternate : KwhColors.border.withOpacity(0.15),
          border: Border.all(color: KwhColors.cyan.withOpacity(0.4)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(display, style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w700, color: KwhColors.cyan)),
      );

  Widget _previousReadingField(bool isLight, FlutterFlowTheme theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _isFirstEntryToday
              ? kwhTextField(_previousReadingCtrl, "e.g. 39780.00", isLight, theme)
              : _lockedBox(_lockedPreviousReading != null ? _fmt(_lockedPreviousReading!) : '-', isLight, theme),
          _hint(
            _isFirstEntryToday && _fetchingLiveReading
                ? 'Fetching the meter reading at shift start…'
                : "Auto-set: the DPM's reading at shift start if this is the day's first entry, otherwise the last entry's meter reading.",
            isLight,
            theme,
          ),
        ],
      );

  Widget _meterNowField(bool isLight, FlutterFlowTheme theme) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          kwhTextField(
            _meterReadingNowCtrl,
            'e.g. 42815.20',
            isLight,
            theme,
            suffixIcon: IconButton(
              tooltip: 'Refresh from meter',
              onPressed: _fetchingMeterNow ? null : _refetchMeterNow,
              icon: _fetchingMeterNow
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2, color: KwhColors.cyan))
                  : const Icon(Icons.refresh, size: 18, color: KwhColors.cyan),
            ),
          ),
          _hint(
            _fetchingMeterNow
                ? 'Fetching the current meter reading…'
                : _meterNowError ??
                    (_meterNowFetchedAt != null
                        ? "Auto-fetched from the DPM at ${_fmtTimeOfDay(_meterNowFetchedAt!)} — tap refresh or overwrite if it doesn't match."
                        : 'Read off the DPM display at the moment of weighing.'),
            isLight,
            theme,
          ),
        ],
      );

  Widget _anchorBox(bool isLight, FlutterFlowTheme theme) {
    if (_editId != null || _machine == null) return const SizedBox.shrink();
    if (!_isFirstEntryToday && _anchorReading != null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KwhColors.cyan.withOpacity(0.08),
          border: Border.all(color: KwhColors.cyan.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.lock_outline, size: 16, color: KwhColors.cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(
                  text: "Initial kWh (today's anchor): ${_fmt(_anchorReading!)}",
                  style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: KwhColors.cyan)),
              TextSpan(
                  text: ' — locked at ${_anchorLockLabel ?? '--:--'} this morning. Every entry today measures against this until tomorrow\'s reading replaces it.',
                  style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white70)),
            ])),
          ),
        ]),
      );
    }
    if (_liveReadingFetchedAt != null) {
      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: KwhColors.cyan.withOpacity(0.08),
          border: Border.all(color: KwhColors.cyan.withOpacity(0.3)),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Icon(Icons.bolt, size: 16, color: KwhColors.cyan),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              "This is the first entry for $_machine on ${_fmtDate(_date)} — Previous Reading was pre-filled from the DPM's meter reading at shift start (${_fmtTimeOfDay(_liveReadingFetchedAt!)}) and becomes that day's locked anchor. Edit it if it doesn't match the meter.",
              style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white70),
            ),
          ),
        ]),
      );
    }
    final message = _liveReadingError ??
        "This is the first entry for $_machine on ${_fmtDate(_date)} — the Previous Reading you enter becomes that day's locked anchor.";
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: KwhColors.amber.withOpacity(0.08),
        border: Border.all(color: KwhColors.amber.withOpacity(0.3)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        const Icon(Icons.info_outline, size: 16, color: KwhColors.amber),
        const SizedBox(width: 8),
        Expanded(
          child: Text(message,
              style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white70)),
        ),
      ]),
    );
  }

  Widget _logRow(Map<String, dynamic> e, bool isLight, FlutterFlowTheme theme, BuildContext context) {
    final v  = e['variancePct'] as double;
    final vc = v > widget.criticalPct ? KwhColors.red : v > widget.warningPct ? KwhColors.amber : KwhColors.green;
    final prev = (e['previousReading'] as num?)?.toDouble();
    final now  = (e['meterReadingNow'] as num?)?.toDouble();
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 10),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: KwhColors.border.withOpacity(0.5)))),
      child: Row(children: [
        Expanded(child:          Text(e['date']?.toString()              ?? '',  style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(child:          Text(_orDash(e['time']),                        style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(flex: 2, child: Text(e['machine']?.toString()           ?? '',  style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: isLight ? theme.primaryText : Colors.white))),
        Expanded(child:          Text(_orDash(e['shift']),                       style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(child:          Text(prev != null ? _fmt(prev) : '-',           style: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.secondaryText : Colors.white54))),
        Expanded(child:          Text(now  != null ? _fmt(now)  : '-',           style: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.secondaryText : Colors.white54))),
        Expanded(child:          Text((e['kwh']    as num?)?.toStringAsFixed(2) ?? '0.00', style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(child:          Text((e['tonnes'] as num?)?.toStringAsFixed(1) ?? '0', style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(child:          Text((e['kwhT']   as double).toStringAsFixed(2),       style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w600, color: vc))),
        Expanded(child:          Text('${v >= 0 ? '+' : ''}${v.toStringAsFixed(1)}%',   style: GoogleFonts.poppins(fontSize: 15, fontWeight: FontWeight.w700, color: vc))),
        Expanded(child:          Text(_orDash(e['reportBy']),                        style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70))),
        Expanded(child: Align(
          alignment: Alignment.centerLeft,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(color: vc.withOpacity(0.12), borderRadius: BorderRadius.circular(3)),
            child: Text(e['statusLabel'] as String, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: vc)),
          ),
        )),
        Expanded(child: Align(
          alignment: Alignment.centerLeft,
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (widget.editingEnabled) ...[
              GestureDetector(
                onTap: () => _startEditFromRow(e),
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(color: KwhColors.cyan.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                  child: const Icon(Icons.edit_outlined, size: 15, color: KwhColors.cyan),
                ),
              ),
              const SizedBox(width: 6),
            ],
            GestureDetector(
              onTap: () => _confirmDelete(context, e, isLight, theme),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(color: KwhColors.red.withOpacity(0.1), borderRadius: BorderRadius.circular(4)),
                child: const Icon(Icons.delete_outline, size: 15, color: KwhColors.red),
              ),
            ),
          ]),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme   = FlutterFlowTheme.of(context);
    final depts   = widget.deptOptions.isNotEmpty ? widget.deptOptions : ['General'];
    final recent  = _recentEntries;
    final kwhConsumed  = _kwhConsumed;
    final kwhPerTonne  = _kwhPerTonne;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      kwhCard(isLight, theme, borderColor: _editId != null ? KwhColors.cyan : null, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Text(_editId != null ? 'Edit production output' : 'Add production output',
              style: GoogleFonts.poppins(fontSize: 19, fontWeight: FontWeight.w700, color: isLight ? theme.primaryText : Colors.white)),
          if (_editId != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(color: KwhColors.cyan.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
              child: Text('EDITING', style: GoogleFonts.poppins(fontSize: 13, fontWeight: FontWeight.w700, color: KwhColors.cyan)),
            ),
          ],
        ]),
        Text(_editId != null ? 'Update this entry\'s details, then save your changes.' : 'Each entry records the kWh used since the last reading for this machine. Tonnes is the batch weighed just now.',
            style: GoogleFonts.poppins(fontSize: 16, color: isLight ? theme.secondaryText : Colors.white38)),
        const SizedBox(height: 20),

        // ── Row 1: date, time, machine ───────────────────────────────────────
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: kwhField('DATE', isLight, theme,
            GestureDetector(
              onTap: () async {
                final d = await showDatePicker(context: context, initialDate: _date, firstDate: DateTime(2020), lastDate: DateTime(2030));
                if (d != null && mounted) {
                  setState(() { _date = d; _resetMeterNowForNewContext(); });
                  _refreshAnchor();
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: isLight ? theme.primaryBackground : KwhColors.darkInput,
                  border: Border.all(color: KwhColors.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_fmtDate(_date), style: GoogleFonts.poppins(fontSize: 17, color: isLight ? theme.primaryText : Colors.white)),
              ),
            ),
          )),
          const SizedBox(width: 16),
          // Defaults to the live current time; editable in case the entry is
          // logged after the fact and needs to reflect the actual reading time.
          Expanded(child: kwhField('TIME', isLight, theme,
            GestureDetector(
              onTap: () async {
                final t = await showTimePicker(context: context, initialTime: _time);
                if (t != null && mounted) setState(() => _time = t);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                decoration: BoxDecoration(
                  color: isLight ? theme.primaryBackground : KwhColors.darkInput,
                  border: Border.all(color: KwhColors.border),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(_fmtTimeOfDay(_time), style: GoogleFonts.poppins(fontSize: 17, color: isLight ? theme.primaryText : Colors.white)),
              ),
            ),
          )),
          const SizedBox(width: 16),
          Expanded(child: kwhField('MACHINE', isLight, theme,
            _dropField(widget.machineNames, _machine ?? (widget.machineNames.isNotEmpty ? widget.machineNames.first : ''),
              (v) { setState(() { _machine = v; _resetMeterNowForNewContext(); }); _refreshAnchor(); }, isLight, theme))),
        ]),
        const SizedBox(height: 16),

        // ── Row 2: shift, shift start (locked), department ───────────────────
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: kwhField('SHIFT', isLight, theme,
            _dropField(_shiftNames.isNotEmpty ? _shiftNames : ['General'], _shift ?? (_shiftNames.isNotEmpty ? _shiftNames.first : 'General'),
              _onShiftChanged, isLight, theme))),
          const SizedBox(width: 16),
          // Locked to the shift's configured "Start Work Time" (Shift Setting)
          // — every batch that day measures against the same opening anchor,
          // so this can no longer drift per-entry.
          Expanded(child: kwhField('SHIFT START (LOCKED)', isLight, theme,
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              decoration: BoxDecoration(
                color: isLight ? theme.alternate : KwhColors.border.withOpacity(0.15),
                border: Border.all(color: KwhColors.border),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                _shiftStartTime != null ? _fmtTimeOfDay(_shiftStartTime!) : (_shiftsLoading ? 'Loading…' : '--:--'),
                style: GoogleFonts.poppins(fontSize: 17, color: isLight ? theme.secondaryText : Colors.white54),
              ),
            ),
          )),
          const SizedBox(width: 16),
          Expanded(child: kwhField('DEPARTMENT', isLight, theme,
            _dropField(depts, _dept ?? depts.first,
              (v) => setState(() => _dept = v), isLight, theme))),
        ]),
        const SizedBox(height: 16),

        _anchorBox(isLight, theme),

        // ── Row 3: previous reading, meter reading now, kwh consumed ─────────
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: kwhField('PREVIOUS READING', isLight, theme, _previousReadingField(isLight, theme))),
          const SizedBox(width: 16),
          Expanded(child: _fieldReq('METER READING NOW', isLight, theme, _meterNowField(isLight, theme))),
          const SizedBox(width: 16),
          Expanded(child: kwhField('KWH CONSUMED (THIS BATCH)', isLight, theme, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _lockedBox(kwhConsumed != null ? _fmt(kwhConsumed) : '-', isLight, theme),
            _hint('= Meter reading now – Previous reading', isLight, theme),
          ]))),
        ]),
        const SizedBox(height: 16),

        // ── Row 4: tonnes, kwh/tonne, reported by ─────────────────────────────
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: _fieldReq('TONNES PRODUCED', isLight, theme, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            kwhTextField(_tonnesCtrl, 'e.g. 20', isLight, theme),
            _hint('This batch only — weighed just now, not cumulative.', isLight, theme),
          ]))),
          const SizedBox(width: 16),
          Expanded(child: kwhField('KWH / TONNE (THIS BATCH)', isLight, theme, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            _lockedBox(kwhPerTonne != null ? kwhPerTonne.toStringAsFixed(2) : '-', isLight, theme),
            _hint('= kWh consumed ÷ tonnes produced', isLight, theme),
          ]))),
          const SizedBox(width: 16),
          Expanded(child: _fieldReq('REPORT BY', isLight, theme, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            kwhTextField(_reportByCtrl, 'Operator name', isLight, theme, keyboardType: TextInputType.text),
            _hint('Required — entry cannot be saved without it.', isLight, theme),
          ]))),
        ]),
        const SizedBox(height: 20),

        if (_error   != null) kwhMsg(_error!,   KwhColors.amber, Icons.warning_amber),
        if (_success != null) kwhMsg(_success!, KwhColors.green, Icons.check_circle_outline),

        // ── Submit / Clear / Cancel edit ─────────────────────────────────────
        Row(children: [
          GestureDetector(
            onTap: _submitting ? null : _submit,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(color: KwhColors.cyan, borderRadius: BorderRadius.circular(4)),
              child: _submitting
                  ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                  : Text(_editId != null ? 'Save changes' : 'Add entry', style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w700, color: Colors.black)),
            ),
          ),
          const SizedBox(width: 12),
          GestureDetector(
            onTap: _editId != null ? _cancelEdit : _clear,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(border: Border.all(color: KwhColors.border), borderRadius: BorderRadius.circular(4)),
              child: Text(_editId != null ? 'Cancel edit' : 'Clear', style: GoogleFonts.poppins(fontSize: 17, fontWeight: FontWeight.w600, color: isLight ? theme.secondaryText : Colors.white54)),
            ),
          ),
        ]),
      ])),

      const SizedBox(height: 20),

      kwhCard(isLight, theme, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Recent entries', style: GoogleFonts.poppins(fontSize: 19, fontWeight: FontWeight.w700, color: isLight ? theme.primaryText : Colors.white)),
        Text('Every row is one batch. Previous Reading → Meter Reading Now are the readings used to derive kWh consumed.',
            style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white38)),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: KwhColors.border))),
          child: Row(children: ['DATE', 'TIME', 'MACHINE', 'SHIFT', 'PREVIOUS READING', 'METER READING NOW', 'KWH CONSUMED', 'TONNES', 'KWH/T', 'VARIANCE', 'REPORTED BY', 'STATUS', ''].map((h) {
            final flex = h == 'MACHINE' ? 2 : 1;
            return Expanded(flex: flex, child: Text(h, style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: isLight ? theme.secondaryText : Colors.white38, letterSpacing: 0.8)));
          }).toList()),
        ),
        if (recent.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(child: Text('No entries yet.', style: GoogleFonts.poppins(color: isLight ? theme.secondaryText : Colors.white38))),
          )
        else
          ...recent.map((e) => _logRow(e, isLight, theme, context)),
      ])),
      ]),
    );
  }
}
