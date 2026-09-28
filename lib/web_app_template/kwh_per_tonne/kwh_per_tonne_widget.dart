import 'dart:async';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'dart:convert';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '../../flutter_flow/nav/router_tracker.dart';
import '../master_facility_setting/services/facility_service.dart';
import '../master_facility_setting/models/facility_data.dart';
import '../production_output_log/services/production_output_service.dart';
import '../product_settings/firestore_service.dart';

import 'kwh_theme.dart';
import 'models/kwh_state_model.dart';
import 'widgets/kwh_shared_widgets.dart';
import 'widgets/machine_detail_dialog.dart';
import 'tabs/kwh_overview_tab.dart';
import 'tabs/kwh_charts_tab.dart';
import 'tabs/kwh_compare_tab.dart';
import 'tabs/kwh_sec_insight_tab.dart';
import 'tabs/kwh_add_data_tab.dart';
import 'tabs/kwh_data_log_tab.dart';
import 'package:smartmachine365/services/filter_memory.dart';

class KwhPerTonneWidget extends StatefulWidget {
  const KwhPerTonneWidget({super.key});

  @override
  State<KwhPerTonneWidget> createState() => _KwhPerTonneWidgetState();
}

class _KwhPerTonneWidgetState extends State<KwhPerTonneWidget> {
  // ── API ──────────────────────────────────────────────────────────────────
  static const _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

  // ── Raw data ────────────────────────────────────────────────────────────
  List<FacilityData> _facilities = [];
  List<Map<String, dynamic>> _entries = [];
  List<String> _machineNames = [];
  List<String> _productNames = [];
  final Map<String, double> _facilityEnergy = {};
  final Map<String, bool> _facilityLoaded = {};
  Timer? _timer;

  // ── UI state ────────────────────────────────────────────────────────────
  bool _isLoading = true;
  String _lastUpdate = '';
  int _tab = KwhTabs.overview;
  final ScrollController _filterScrollCtrl = ScrollController();

  // ── Thresholds ──────────────────────────────────────────────────────────
  double _targetKwh = 40.0;
  double _warningPct = 5.0;
  double _criticalPct = 15.0;
  double _rate = 0.45;
  String _currency = 'RM';

  // ── Time range ──────────────────────────────────────────────────────────
  String _period = 'Daily';
  DateTime _selectedDate = DateTime.now();

  // ── Overview filters (cascading: plant → production area → equipment) ──
  static const String _filterScreen = 'kwh_per_tonne';
  bool _filtersRestored = false;

  void _rememberFilters() => FilterMemory.save(_filterScreen, {
        'plant': _filterPlant,
        'area': _filterArea,
        'equipment': _filterEquipment,
      });

  /// Restores once the dropdowns have options to match against. A value that is
  /// no longer offered is skipped rather than forced back on.
  void _restoreFiltersOnce() {
    if (_filtersRestored || _plantOptions.length <= 1) return;
    _filtersRestored = true;
    FilterMemory.load(_filterScreen).then((saved) {
      if (saved.isEmpty || !mounted) return;
      setState(() {
        final p = saved['plant'];
        if (p != null && _plantOptions.contains(p)) _filterPlant = p;
        final a = saved['area'];
        if (a != null && _areaOptionsFor(_filterPlant).contains(a)) _filterArea = a;
        final e = saved['equipment'];
        if (e != null &&
            _equipmentOptionsFor(_filterPlant, _filterArea).contains(e)) {
          _filterEquipment = e;
        }
      });
    });
  }

  String _filterPlant = 'All';
  String _filterArea = 'All';
  String _filterEquipment = 'All';
  String _searchQuery = '';
  final TextEditingController _searchCtrl = TextEditingController();
  bool _sortByVariance = false;

  // ── Cross-tab selection (set by machine detail dialog) ─────────────────
  String _secLineA = '';
  String? _formMachine;

  // ── Edit entries feature (Thresholds dialog toggle) ────────────────────
  bool _editingEnabled = true;
  Map<String, dynamic>? _editEntry;

  // ── Lifecycle ───────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _lastUpdate = _nowStr();
    _fetchAll();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      if (mounted) _fetchAll();
    });
    routeTracker.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    if (routeTracker.currentRoute != '/kwhTone') {
      _timer?.cancel();
      routeTracker.removeListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    routeTracker.removeListener(_onRouteChanged);
    _filterScrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Data fetching ───────────────────────────────────────────────────────
  Future<void> _fetchAll() async {
    if (!mounted) return;
    setState(() => _isLoading = true);
    try {
      final results = await Future.wait([
        FacilityService.getFacilities(),
        ProductionOutputService.getAll(),
        ProductionOutputService.getMachineNames(),
        FirestoreService().fetchProduct(),
        FacilityService.getEquipments(forceRefresh: true),
      ]);
      if (!mounted) return;
      final facilities = (results[0] as List<FacilityData>).where((f) => f.status.toLowerCase() == 'active').toList();
      final entries = results[1] as List<Map<String, dynamic>>;
      final mNames = results[2] as List<String>;
      final prods = results[3] as List<Map<String, dynamic>>;
      final equipments = results[4] as List<EquipmentItem>;

      // The kWh/Tonne machine list is driven by Equipment Settings — only
      // equipment with the Energy module enabled is shown. A matching
      // Facility record (by equipment id/name) is used to enrich the row
      // with its meterId for real-time energy readings, when one exists.
      final facilityByKey = <String, FacilityData>{};
      for (final f in facilities) {
        for (final key in [f.meterId.trim(), f.meterName.trim(), f.equipmentNameId.trim()]) {
          if (key.isNotEmpty) facilityByKey[key] = f;
        }
      }
      final energyEquipments = equipments.where((e) => e.enableEnergy).map((e) {
        final match = facilityByKey[e.equipmentId.trim()] ??
            facilityByKey[e.name.trim()] ??
            facilityByKey[e.displayLabel.trim()];
        if (match != null) return match.copyWith(targetKwhPerTonne: e.targetKwhPerTonne);
        return FacilityData(
          id: e.id,
          plant: e.factory,
          factory: e.factory,
          zone: '',
          productionArea: e.productionLine.isNotEmpty ? e.productionLine : e.productionArea,
          equipmentType: e.deviceType,
          equipmentNameId: e.displayLabel,
          meterName: e.name,
          meterId: '',
          gatewayId: '',
          status: 'Active',
          gridType: '',
          maintenanceDate: '',
          lastMaintenanceDate: '',
          nextMaintenanceDate: '',
          registrationDate: '',
          targetKwhPerTonne: e.targetKwhPerTonne,
        );
      }).toList();

      setState(() {
        _facilities = energyEquipments;
        _entries = entries;
        _machineNames = mNames.isNotEmpty ? mNames : ['MSB', 'CM12'];
        _productNames = prods.map((p) => p['name']?.toString() ?? '').where((n) => n.isNotEmpty).toSet().toList();
        _isLoading = false;
        _lastUpdate = _nowStr();
        _initDefaults();
      });
      _fetchEnergyForAll();
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _fetchEnergyForAll() async {
    for (final f in _facilities) {
      final id = f.meterId.trim();
      if (id.isNotEmpty) _fetchEnergyForDevice(id);
    }
  }

  Future<void> _fetchEnergyForDevice(String meterId) async {
    try {
      final res =
          await http.get(Uri.parse('$_baseUrl/energyDetails/total/$meterId'), headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as List<dynamic>;
        double daily = 0;
        for (final row in data) {
          if (row['period'] == 'daily') {
            daily = (row['total_energy'] as num?)?.toDouble() ?? 0.0;
            break;
          }
        }
        setState(() {
          _facilityEnergy[meterId] = daily.abs();
          _facilityLoaded[meterId] = true;
        });
      } else {
        setState(() => _facilityLoaded[meterId] = true);
      }
    } catch (_) {
      if (mounted) setState(() => _facilityLoaded[meterId] = true);
    }
  }

  // ── Computed properties ─────────────────────────────────────────────────
  void _initDefaults() {
    final ms = _machineOptions.where((m) => m != 'All').toList();
    if (_secLineA.isEmpty && ms.isNotEmpty) _secLineA = ms.first;
  }

  // _facilities is already scoped to Equipment Settings records with the
  // Energy module enabled (built in _fetchAll), so these all read it directly.
  List<String> get _machineOptions {
    final seen = <String>{};
    return ['All', ..._facilities.map((f) => f.meterName.isNotEmpty ? f.meterName : f.meterId).where((v) => v.isNotEmpty && seen.add(v))];
  }

  // Machine names scoped by the active Plant → Production Area → Equipment
  // (→ Search) cascade — mirrors _filteredFacilities so the Add Data tab's
  // Machine dropdown and Recent entries table follow the top filter bar
  // instead of always showing every machine regardless of what's filtered.
  List<String> get _filteredMachineNames {
    final seen = <String>{};
    return _filteredFacilities
        .map((f) => f.meterName.isNotEmpty ? f.meterName : f.meterId)
        .where((v) => v.isNotEmpty && seen.add(v))
        .toList();
  }

  List<String> get _typeOptions {
    final seen = <String>{};
    return ['All', ..._facilities.map((f) => f.equipmentType.isNotEmpty ? f.equipmentType : 'General').where((v) => seen.add(v))];
  }

  List<String> get _deptOptions {
    final seen = <String>{};
    return ['All', ..._facilities.map((f) => f.productionArea.isNotEmpty ? f.productionArea : 'Unassigned').where((v) => seen.add(v))];
  }

  // ── Cascading filter options (plant → production area → equipment) ─────
  List<String> get _plantOptions {
    final seen = <String>{};
    return ['All', ..._facilities.map((f) => f.plant.isNotEmpty ? f.plant : 'Unassigned').where((v) => seen.add(v))];
  }

  List<String> _areaOptionsFor(String plant) {
    final seen = <String>{};
    return [
      'All',
      ..._facilities
          .where((f) => plant == 'All' || (f.plant.isNotEmpty ? f.plant : 'Unassigned') == plant)
          .map((f) => f.productionArea.isNotEmpty ? f.productionArea : 'Unassigned')
          .where((v) => seen.add(v))
    ];
  }

  List<String> _equipmentOptionsFor(String plant, String area) {
    final seen = <String>{};
    return [
      'All',
      ..._facilities
          .where((f) =>
              (plant == 'All' || (f.plant.isNotEmpty ? f.plant : 'Unassigned') == plant) &&
              (area == 'All' || (f.productionArea.isNotEmpty ? f.productionArea : 'Unassigned') == area))
          .map((f) => f.meterName.isNotEmpty ? f.meterName : f.meterId)
          .where((v) => v.isNotEmpty && seen.add(v))
    ];
  }

  Map<String, String> get _machineMeterIds {
    final map = <String, String>{};
    for (final f in _facilities) {
      final name = f.meterName.isNotEmpty ? f.meterName : f.meterId;
      if (name.isNotEmpty) map[name] = f.meterId.trim();
    }
    return map;
  }

  List<FacilityData> get _filteredFacilities {
    var list = _facilities.where((f) {
      final p = f.plant.isNotEmpty ? f.plant : 'Unassigned';
      final a = f.productionArea.isNotEmpty ? f.productionArea : 'Unassigned';
      final e = f.meterName.isNotEmpty ? f.meterName : f.meterId;
      if (_filterPlant != 'All' && p != _filterPlant) return false;
      if (_filterArea != 'All' && a != _filterArea) return false;
      if (_filterEquipment != 'All' && e != _filterEquipment) return false;
      if (_searchQuery.isNotEmpty) {
        final q = _searchQuery.toLowerCase();
        final haystack = [p, a, e, f.equipmentType, f.equipmentNameId].join(' ').toLowerCase();
        if (!haystack.contains(q)) return false;
      }
      return true;
    }).toList();
    if (_sortByVariance) {
      list.sort((a, b) => (_secFor(b) - _targetKwh).compareTo(_secFor(a) - _targetKwh));
    }
    return list;
  }

  List<FacilityData> get _topConsumers =>
      (_facilities.where((f) => _secFor(f) > 0).toList())..sort((a, b) => _secFor(b).compareTo(_secFor(a)));

  Map<String, Map<String, dynamic>> get _polAgg {
    final map = <String, Map<String, dynamic>>{};
    for (final e in _entries) {
      final m = e['machine']?.toString() ?? '';
      if (m.isEmpty) continue;
      map.putIfAbsent(m, () => {'sumKwh': 0.0, 'sumTonnes': 0.0});
      map[m]!['sumKwh'] = (map[m]!['sumKwh'] as double) + ((e['kwh'] as num?)?.toDouble() ?? 0);
      map[m]!['sumTonnes'] = (map[m]!['sumTonnes'] as double) + ((e['tonnes'] as num?)?.toDouble() ?? 0);
    }
    map.forEach((k, v) {
      final kwhT = (v['sumTonnes'] as double) > 0 ? (v['sumKwh'] as double) / (v['sumTonnes'] as double) : 0.0;
      v['kwhT'] = kwhT;
      v['variancePct'] = _targetKwh > 0 ? (kwhT - _targetKwh) / _targetKwh * 100 : 0.0;
      v['cost'] = (v['sumKwh'] as double) * _rate;
    });
    return map;
  }

  List<Map<String, dynamic>> get _enriched => _entries.map((e) {
        final kwh = (e['kwh'] as num?)?.toDouble() ?? 0;
        final t = (e['tonnes'] as num?)?.toDouble() ?? 0;
        final kwhT = t > 0 ? kwh / t : 0.0;
        final v = _targetKwh > 0 ? (kwhT - _targetKwh) / _targetKwh * 100 : 0.0;
        return {...e, 'kwhT': kwhT, 'variancePct': v, 'cost': kwh * _rate, 'statusLabel': _statusLabel(v)};
      }).toList();

  // Real SEC only: kWh ÷ tonnes from logged production entries. Machines
  // without log data return 0 and are excluded from fleet KPIs — daily meter
  // kWh is an energy total, not a per-tonne figure, so it must not stand in.
  double _secFor(FacilityData f) {
    final name = f.meterName.isNotEmpty ? f.meterName : f.meterId;
    final match = _polAgg[name];
    if (match != null && (match['kwhT'] as double) > 0) return match['kwhT'] as double;
    return 0.0;
  }

  String _statusLabel(double v) => v > _criticalPct
      ? 'Critical'
      : v > _warningPct
          ? 'Warning'
          : 'On target';

  double get _fleetAvgKwhT {
    final vals = _filteredFacilities.map(_secFor).where((v) => v > 0).toList();
    return vals.isEmpty ? 0 : vals.reduce((a, b) => a + b) / vals.length;
  }

  double get _fleetVariance =>
      _targetKwh > 0 && _fleetAvgKwhT > 0 ? (_fleetAvgKwhT - _targetKwh) / _targetKwh * 100 : 0;
  int get _onTargetCount => _filteredFacilities.where((f) {
        final s = _secFor(f);
        return s > 0 && s <= _targetKwh * (1 + _warningPct / 100);
      }).length;
  double get _totalCost => _entries.fold(0.0, (s, e) => s + ((e['kwh'] as num?)?.toDouble() ?? 0) * _rate);

  // Malaysia time (UTC+8, no DST) — matches the convention used across the
  // kWh/Tonne module (see kwh_add_data_tab.dart's _nowMYT()) so "Updated"
  // reflects MYT regardless of the operator's device timezone.
  String _nowStr() => DateTime.now().toUtc().add(const Duration(hours: 8)).toString().substring(0, 16);
  String _fmtDate(DateTime d) => '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
  String _isoDate(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Machine names with at least one kWh/Tonne log entry dated today — used to
  /// distinguish "no production logged yet today" from the all-time `_polAgg`.
  Set<String> get _machinesWithDataToday {
    final today = _isoDate(DateTime.now());
    return _entries
        .where((e) => e['date']?.toString() == today)
        .map((e) => e['machine']?.toString() ?? '')
        .where((m) => m.isNotEmpty)
        .toSet();
  }

  // ── State model builder ─────────────────────────────────────────────────
  KwhStateModel _buildStateModel() => KwhStateModel(
        filteredFacilities: _filteredFacilities,
        topConsumers: _topConsumers,
        enriched: _enriched,
        polAgg: _polAgg,
        machinesWithDataToday: _machinesWithDataToday,
        facilityEnergy: Map.unmodifiable(_facilityEnergy),
        facilityLoaded: Map.unmodifiable(_facilityLoaded),
        machineOptions: _machineOptions,
        typeOptions: _typeOptions,
        deptOptions: _deptOptions,
        machineNames: _machineNames,
        productNames: _productNames,
        targetKwh: _targetKwh,
        warningPct: _warningPct,
        criticalPct: _criticalPct,
        rate: _rate,
        currency: _currency,
        fleetAvgKwhT: _fleetAvgKwhT,
        fleetVariance: _fleetVariance,
        onTargetCount: _onTargetCount,
        totalCost: _totalCost,
      );

  // ── Build ───────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final stateModel = _buildStateModel();

    return Container(
      width: double.infinity,
      height: double.infinity,
      decoration: BoxDecoration(
        color: theme.primaryBackground,
        image: DecorationImage(fit: BoxFit.cover, image: Image.asset('assets/images/backgroundanimated.gif').image),
      ),
      child: Column(children: [
        _topSection(context, isLight, theme, stateModel),
        Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator(color: KwhColors.cyan))
                : _tabContent(context, isLight, theme, stateModel)),
      ]),
    );
  }

  //Top section (header + filters + tab bar)
  Widget _topSection(BuildContext context, bool isLight, FlutterFlowTheme theme, KwhStateModel data) {
    return Container(
      decoration: BoxDecoration(
        color: isLight ? theme.secondaryBackground : KwhColors.cardBg.withOpacity(0.85),
        border: Border(bottom: BorderSide(color: isLight ? theme.alternate : KwhColors.border)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Header — title/subtitle always on their own line, with the period
        // tabs, action buttons and export status always on a toolbar row
        // underneath. A Row+Spacer here overflowed badly on a phone: it was
        // trying to fit the title, 3 period tabs, 2 buttons and an
        // updated/export column all on one line.
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Text('kWh / Tonne',
                  style: GoogleFonts.poppins(fontSize: 21, fontWeight: FontWeight.w700, color: isLight ? theme.primaryText : Colors.white)),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(color: KwhColors.cyan.withOpacity(0.15), borderRadius: BorderRadius.circular(4)),
                child: Text('v2', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w700, color: KwhColors.cyan)),
              ),
            ]),
            Text('Energy intensity monitoring system',
                style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white38)),
            const SizedBox(height: 12),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 10,
              runSpacing: 8,
              children: [
                _periodTabs(isLight, theme),
                kwhBtn('Apply', onTap: _fetchAll, bg: KwhColors.cyan, tc: Colors.black),
                kwhBtn('Thresholds',
                    onTap: () => _showThresholds(context, isLight, theme),
                    bg: isLight ? theme.alternate : KwhColors.border,
                    tc: isLight ? theme.primaryText : Colors.white70),
                Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Updated $_lastUpdate', style: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.secondaryText : Colors.white38)),
                  const SizedBox(height: 2),
                  GestureDetector(
                      onTap: _fetchAll,
                      child: Text('Export CSV', style: GoogleFonts.poppins(fontSize: 14, fontWeight: FontWeight.w600, color: KwhColors.cyan))),
                ]),
              ],
            ),
          ]),
        ),
        const SizedBox(height: 10),

        // Filter chips
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
          child: Row(children: [
            Expanded(
              child: ShaderMask(
                shaderCallback: (rect) => const LinearGradient(
                  begin: Alignment.centerRight,
                  end: Alignment.centerLeft,
                  colors: [Colors.transparent, Colors.white, Colors.white],
                  stops: [0.0, 0.06, 1.0],
                ).createShader(rect),
                blendMode: BlendMode.dstIn,
                child: Scrollbar(
                  controller: _filterScrollCtrl,
                  thumbVisibility: true,
                  trackVisibility: true,
                  thickness: 5,
                  radius: const Radius.circular(3),
                  child: SingleChildScrollView(
                    controller: _filterScrollCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Row(children: [
                      kwhCyberpunkDropdown(
                        isLight: isLight,
                        theme: theme,
                        value: _filterPlant == 'All' ? null : _filterPlant,
                        options: (() {
                          _restoreFiltersOnce();
                          return _plantOptions.where((o) => o != 'All').toList();
                        })(),
                        hint: 'Plant',
                        width: 170,
                        onChanged: (v) {
                          final val = v ?? 'All';
                          setState(() {
                            _filterPlant = val;
                            if (!_areaOptionsFor(val).contains(_filterArea)) _filterArea = 'All';
                            if (!_equipmentOptionsFor(val, _filterArea).contains(_filterEquipment)) _filterEquipment = 'All';
                          });
                          _rememberFilters();
                        },
                      ),
                      const SizedBox(width: 16),
                      kwhCyberpunkDropdown(
                        isLight: isLight,
                        theme: theme,
                        value: _filterArea == 'All' ? null : _filterArea,
                        options: _areaOptionsFor(_filterPlant).where((o) => o != 'All').toList(),
                        hint: 'Production Area',
                        width: 190,
                        onChanged: (v) {
                          final val = v ?? 'All';
                          setState(() {
                            _filterArea = val;
                            if (!_equipmentOptionsFor(_filterPlant, val).contains(_filterEquipment)) _filterEquipment = 'All';
                          });
                          _rememberFilters();
                        },
                      ),
                      const SizedBox(width: 16),
                      kwhCyberpunkDropdown(
                        isLight: isLight,
                        theme: theme,
                        value: _filterEquipment == 'All' ? null : _filterEquipment,
                        options: _equipmentOptionsFor(_filterPlant, _filterArea).where((o) => o != 'All').toList(),
                        hint: 'Equipment',
                        width: 180,
                        onChanged: (v) {
                          setState(() => _filterEquipment = v ?? 'All');
                          _rememberFilters();
                        },
                      ),
                      const SizedBox(width: 16),
                      _searchField(isLight, theme),
                      const SizedBox(width: 16),
                      _dateRangePicker(context, isLight, theme),
                      // Trailing padding so the fade mask doesn't clip the last item.
                      const SizedBox(width: 16),
                    ]),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Text('${data.filteredFacilities.length} entries in view',
                style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.secondaryText : Colors.white38)),
          ]),
        ),
        const SizedBox(height: 10),

        // Tab bar
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 0),
            child: Row(
                children: List.generate(KwhTabs.labels.length, (i) {
              final sel = _tab == i;
              return GestureDetector(
                onTap: () => setState(() => _tab = i),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(border: Border(bottom: BorderSide(color: sel ? KwhColors.cyan : Colors.transparent, width: 2))),
                  child: Text(KwhTabs.labels[i],
                      style: GoogleFonts.poppins(
                          fontSize: 17,
                          fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                          color: sel ? KwhColors.cyan : (isLight ? theme.secondaryText : Colors.white54))),
                ),
              );
            })),
          ),
        ),
      ]),
    );
  }

  Widget _periodTabs(bool isLight, FlutterFlowTheme theme) => Row(
        children: ['Daily', 'Weekly', 'Monthly'].map((p) {
          final sel = _period == p;
          return GestureDetector(
            onTap: () => setState(() => _period = p),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
              decoration: BoxDecoration(
                color: sel ? KwhColors.cyan : (isLight ? theme.primaryBackground : KwhColors.darkInput),
                border: Border.all(color: isLight ? theme.alternate : KwhColors.border),
              ),
              child: Text(p,
                  style: GoogleFonts.poppins(
                      fontSize: 16, fontWeight: FontWeight.w600, color: sel ? Colors.black : (isLight ? theme.secondaryText : Colors.white54))),
            ),
          );
        }).toList(),
      );

  Widget _dateRangePicker(BuildContext context, bool isLight, FlutterFlowTheme theme) => GestureDetector(
        onTap: () async {
          final p = await showDatePicker(
              context: context,
              firstDate: DateTime(2024),
              lastDate: DateTime.now(),
              initialDate: _selectedDate);
          if (p != null && mounted) setState(() => _selectedDate = p);
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isLight ? theme.primaryBackground : KwhColors.darkInput,
            border: Border.all(color: isLight ? theme.alternate : KwhColors.border),
          ),
          child: Row(children: [
            Icon(Icons.calendar_today_outlined, size: 12, color: isLight ? theme.secondaryText : Colors.white38),
            const SizedBox(width: 6),
            Text(_fmtDate(_selectedDate),
                style: GoogleFonts.poppins(fontSize: 15, color: isLight ? theme.primaryText : Colors.white70)),
          ]),
        ),
      );

  Widget _searchField(bool isLight, FlutterFlowTheme theme) => Container(
        width: 220,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        decoration: BoxDecoration(
          color: isLight ? theme.primaryBackground : KwhColors.darkInput,
          border: Border.all(color: _searchQuery.isNotEmpty ? KwhColors.cyan : (isLight ? theme.alternate : KwhColors.border)),
          borderRadius: BorderRadius.circular(3),
        ),
        child: Row(children: [
          Icon(Icons.search, size: 14, color: isLight ? theme.secondaryText : Colors.white54),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _searchCtrl,
              onChanged: (v) => setState(() => _searchQuery = v.trim()),
              style: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.primaryText : Colors.white),
              decoration: InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                hintText: 'Search…',
                hintStyle: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.secondaryText : Colors.white38),
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty)
            GestureDetector(
              onTap: () => setState(() {
                _searchCtrl.clear();
                _searchQuery = '';
              }),
              child: Icon(Icons.close, size: 14, color: isLight ? theme.secondaryText : Colors.white54),
            ),
        ]),
      );

  // ── Tab content router ──────────────────────────────────────────────────
  Widget _tabContent(BuildContext context, bool isLight, FlutterFlowTheme theme, KwhStateModel data) {
    switch (_tab) {
      case KwhTabs.overview:
        return KwhOverviewTab(
          data: data,
          sortByVariance: _sortByVariance,
          onMachineDetail: (f) => showMachineDetailDialog(
            context: context,
            isLight: isLight,
            theme: theme,
            facility: f,
            data: data,
            onNavigate: (t) => setState(() => _tab = t),
            onSetFormMachine: (m) => setState(() => _formMachine = m),
            onSetSecLineA: (m) => setState(() => _secLineA = m),
          ),
          onAddData: () => setState(() => _tab = KwhTabs.addData),
          onSecInsight: () => setState(() => _tab = KwhTabs.secInsight),
          onToggleSort: () => setState(() => _sortByVariance = !_sortByVariance),
        );

      case KwhTabs.charts:
        return KwhChartsTab(data: data);

      case KwhTabs.compare:
        return KwhCompareTab(data: data);

      case KwhTabs.secInsight:
        return KwhSecInsightTab(data: data, secLineA: _secLineA);

      case KwhTabs.addData:
        // Machines come from facilities (e.g. MSB), scoped by the top filter bar's
        // Plant → Production Area → Equipment (→ Search) cascade; falls back to every
        // machine when that cascade matches none (e.g. a Search with no results),
        // so the form's Machine dropdown is never left with zero options.
        final scopedMachines = _filteredMachineNames;
        final addDataMachines = scopedMachines.isNotEmpty ? scopedMachines : data.machineOptions.where((m) => m != 'All').toList();
        // Product types come from facility equipment types (e.g. Digital Power Meter).
        final addDataTypes = data.typeOptions.where((t) => t != 'All').toList();
        return KwhAddDataTab(
          machineNames: addDataMachines,
          productNames: addDataTypes,
          deptOptions: data.deptOptions.where((d) => d != 'All').toList(),
          selectedMachine: _formMachine ?? (_filterEquipment != 'All' ? _filterEquipment : null),
          machineMeterIds: _machineMeterIds,
          rate: _rate,
          currency: _currency,
          onRefresh: _fetchAll,
          enriched: data.enriched,
          criticalPct: _criticalPct,
          warningPct: _warningPct,
          onDelete: (e) async {
            await ProductionOutputService.delete(e['id']?.toString() ?? '');
            await _fetchAll();
          },
          editingEnabled: _editingEnabled,
          editEntry: _editEntry,
          onEditConsumed: () => setState(() => _editEntry = null),
        );

      case KwhTabs.dataLog:
        return KwhDataLogTab(
          enriched: data.enriched,
          criticalPct: _criticalPct,
          warningPct: _warningPct,
          currency: _currency,
          onDelete: (e) async {
            await ProductionOutputService.delete(e['id']?.toString() ?? '');
            await _fetchAll();
          },
          editingEnabled: _editingEnabled,
          onEdit: (e) => setState(() { _editEntry = e; _tab = KwhTabs.addData; }),
        );

      default:
        return const SizedBox.shrink(); // unreachable
    }
  }

  // ── Thresholds dialog ───────────────────────────────────────────────────
  void _showThresholds(BuildContext context, bool isLight, FlutterFlowTheme theme) {
    final tc = TextEditingController(text: _targetKwh.toStringAsFixed(0));
    final wc = TextEditingController(text: _warningPct.toStringAsFixed(0));
    final cc = TextEditingController(text: _criticalPct.toStringAsFixed(0));
    final rc = TextEditingController(text: _rate.toStringAsFixed(2));
    final cu = TextEditingController(text: _currency);
    bool editingEnabledDraft = _editingEnabled;

    showDialog(
        context: context,
        builder: (_) => StatefulBuilder(
              builder: (dialogContext, setDialogState) => AlertDialog(
              backgroundColor: isLight ? theme.secondaryBackground : KwhColors.cardBg,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              title: Row(children: [
                Text('Thresholds & rate',
                    style: GoogleFonts.poppins(color: isLight ? theme.primaryText : Colors.white, fontWeight: FontWeight.w700, fontSize: 21)),
                const Spacer(),
                GestureDetector(
                    onTap: () => Navigator.pop(context), child: Icon(Icons.close, color: isLight ? theme.secondaryText : Colors.white54, size: 20)),
              ]),
              content: SizedBox(
                  width: responsiveDialogWidth(dialogContext, 400),
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Divider(color: KwhColors.border),
                    const SizedBox(height: 12),
                    kwhTField('TARGET KWH / TONNE', tc, isLight, theme),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: kwhTField('WARNING %', wc, isLight, theme)),
                      const SizedBox(width: 16),
                      Expanded(child: kwhTField('CRITICAL %', cc, isLight, theme)),
                    ]),
                    const SizedBox(height: 12),
                    Row(children: [
                      Expanded(child: kwhTField('RATE (\$/KWH)', rc, isLight, theme)),
                      const SizedBox(width: 16),
                      Expanded(child: kwhTField('CURRENCY', cu, isLight, theme)),
                    ]),
                    const SizedBox(height: 12),
                    Container(
                        padding: const EdgeInsets.all(12),
                        decoration:
                            BoxDecoration(color: isLight ? theme.primaryBackground : KwhColors.darkInput, borderRadius: BorderRadius.circular(6)),
                        child: Text(
                            'Machines exceeding the target by more than the warning % are flagged amber; those exceeding by the critical % are flagged red.',
                            style: GoogleFonts.poppins(fontSize: 16, color: isLight ? theme.secondaryText : Colors.white54))),
                    const SizedBox(height: 12),
                    Container(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        decoration: BoxDecoration(
                            color: isLight ? theme.primaryBackground : KwhColors.darkInput, borderRadius: BorderRadius.circular(6)),
                        child: SwitchListTile(
                          value: editingEnabledDraft,
                          onChanged: (v) => setDialogState(() => editingEnabledDraft = v),
                          activeColor: KwhColors.cyan,
                          dense: true,
                          title: Text('Enable editing entries',
                              style: GoogleFonts.poppins(fontSize: 16, fontWeight: FontWeight.w600, color: isLight ? theme.primaryText : Colors.white)),
                          subtitle: Text('Show the Edit button on Add Data / Data Log rows.',
                              style: GoogleFonts.poppins(fontSize: 14, color: isLight ? theme.secondaryText : Colors.white38)),
                        )),
                  ])),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text('Cancel', style: GoogleFonts.poppins(color: isLight ? theme.secondaryText : Colors.white54))),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: KwhColors.cyan, foregroundColor: Colors.black),
                  onPressed: () {
                    setState(() {
                      _targetKwh = double.tryParse(tc.text) ?? _targetKwh;
                      _warningPct = double.tryParse(wc.text) ?? _warningPct;
                      _criticalPct = double.tryParse(cc.text) ?? _criticalPct;
                      _rate = double.tryParse(rc.text) ?? _rate;
                      _currency = cu.text.isNotEmpty ? cu.text : _currency;
                      _editingEnabled = editingEnabledDraft;
                    });
                    Navigator.pop(context);
                  },
                  child: Text('Apply', style: GoogleFonts.poppins(fontWeight: FontWeight.w700)),
                ),
              ],
            )));
  }
}
