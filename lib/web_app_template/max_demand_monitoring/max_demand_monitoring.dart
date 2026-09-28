import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_theme.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/flutter_flow/nav/nav.dart';
import 'package:smartmachine365/web_app_template/energy_system_settings/energy_system_setting_service.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/daily_max_demand_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/equipment_load_correlation_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/equipment_md_ranking_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/max_demand_chart_config.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/widgets/max_demand_chart_config_dialog.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/max_demand_records_table_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/metric_card_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/power_load_distribution_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/power_load_trend_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/yearonyear_analaysis_chart_widget.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/tnb_meter/tnb_meter_models.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/tnb_meter/tnb_meter_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/models/facility_data.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:async';

class MaxDemandMonitoring extends StatefulWidget {
  const MaxDemandMonitoring({super.key});

  @override
  State<MaxDemandMonitoring> createState() => _MaxDemandMonitoringState();
}

class _MaxDemandMonitoringState extends State<MaxDemandMonitoring> {
  List<Map<String, dynamic>> _powerLoadData = [];
  bool _isLoadingPowerLoad = true;
  String? _powerLoadError;

  // null = no live reading available for the current selection (e.g. the
  // selected TNB meter isn't linked to any Influx device) — rendered as
  // "---" rather than a stale or unrelated power figure.
  double? _currentPowerKw = 0.0;
  double _monthlyMaxDemandKw = 0.0;
  // Cached across page navigations so the "vs Last Month" subtitle survives
  // alt-tab / sidebar navigation while year-on-year is re-fetching.
  static double _cachedLastMonthMaxDemandKw = 0.0;
  double _lastMonthMaxDemandKw = _cachedLastMonthMaxDemandKw;
  double _maxPowerKw = 0.0;
  double _minPowerKw = 0.0;

  String _selectedDeviceId = 'MSB';

  // Influx device_id tag values actually present in the tenant's bucket.
  // Used to decide whether Current Power can be scoped to the selected
  // meter: real DPM tags (e.g. "DPM047", "MSB") exist here, virtual meter
  // codes (e.g. "VDPM002") don't and would filter the query down to 0.
  // null = not fetched yet.
  Set<String>? _influxDeviceIds;

  List<Map<String, dynamic>> _maxDemandData = [];
  bool _isLoadingMaxDemand = true;
  String? _maxDemandError;

  List<Map<String, dynamic>> _avgPowerLoadDistribution = [];
  bool _isLoadingAvgPowerLoad = true;
  String? _avgPowerLoadError;

  List<Map<String, dynamic>> _yearOnYearData = [];
  List<Map<String, dynamic>> _yearOnYearComparisonData = [];
  bool _isLoadingYearOnYear = true;
  String? _yearOnYearError;

  List<Map<String, dynamic>> _maxDemandEvents = [];
  bool _isLoadingMaxDemandEvents = true;
  String? _maxDemandEventsError;
  String maxDemand = '0.0';

  bool _isLoading = false;
  double _contractCapacity = 0.0;

  double _highRiskMin = 80.0;
  double _mediumRiskMin = 60.0;
  double _mediumRiskMax = 80.0;
  double _lowRiskMin = 0.0;
  double _lowRiskMax = 60.0;

  Timer? _currentPowerTimer;

  double _mdCapacityCharge = 0.0;
  double _mdNetworkCharge = 0.0;
  bool _isLoadingBillingConfig = true;

  List<TnbMeter> _tnbMeters = [];
  List<Map<String, dynamic>> _tnbPlants = [];
  TnbMeter? _selectedTnbMeter;

  String _selectedEventDate = '';
  String _selectedEventStart = '';
  String _selectedEventEnd = '';

  // ── TOU times/days from settings (used as defaults for chart windows) ──────
  TimeOfDay? _touStartTime;
  TimeOfDay? _touEndTime;

  /// Back to the "HH:mm" form the charts take, so the shaded ToU band comes
  /// from the same setting the rest of this page already uses.
  String? _fmtTimeOfDay(TimeOfDay? t) => t == null
      ? null
      : '${t.hour.toString().padLeft(2, '0')}:'
          '${t.minute.toString().padLeft(2, '0')}';
  List<int> _touDays = [1, 2, 3, 4, 5]; // 1=Mon … 7=Sun, default Mon–Fri

  // ── Correlation chart state (owned by parent) ────────────────────────────
  Map<String, List<Map<String, dynamic>>> _correlationSeriesData = {};
  List<String> _correlationDeviceIds = [];
  double _correlationSystemPeak = 0.0;
  bool _isLoadingCorrelation = false;
  String? _correlationError;
  String _correlationInterval = '30m';

  // ── MD Ranking chart state (owned by parent) ─────────────────────────────
  List<Map<String, dynamic>> _mdRankingData = [];
  bool _isLoadingMdRanking = false;
  // Master Facilities meterIds with the "MD Ranking" analytics flag enabled;
  // only these devices are shown in the Equipment MD Ranking chart.
  Set<String>? _mdEnabledDeviceIds;
  // meterId -> meterName for every registered Master Facility, built
  // alongside _facilityMeterIds/_mdEnabledDeviceIds (whichever populates it
  // first) so both the correlation chart's legend/tooltip and the ranking
  // chart's bars can label devices with their human-readable name instead
  // of the raw meterId.
  Map<String, String>? _facilityNameByMeterId;
  // All registered Master Facilities meterIds — the Equipment Load Correlation
  // chart only shows devices registered here AND present in integration config.
  Set<String>? _facilityMeterIds;
  String? _mdRankingError;
  String _rankingEventDate = '';
  String _rankingEventStart = '';
  String _rankingEventEnd = '';
  // Bumped on every _fetchMdRankingData call so a response from a
  // superseded request (e.g. the initState race between _fetchTnbMeters and
  // _loadChartConfig, or a fast date-picker change) can't clobber a fresher
  // one that already landed.
  int _mdRankingRequestId = 0;

  // Equipment device ids bound to the selected TNB meter's production areas
  // (meter.boundAreaIds) — the scope for the two equipment-level charts once
  // a TNB meter is selected. Falls back to the tenant's integration-config
  // device list (Influx tags) when no meter is selected or it has no
  // equipment bound yet.
  List<String> _scopedMachineIds = [];

  // User-configured device exclusions for the two equipment-level charts —
  // narrows each chart's Master-Facilities-derived candidate pool. Loaded
  // once in initState via _loadChartConfig(); see max_demand_chart_config.dart.
  MaxDemandChartConfig _chartConfig = const MaxDemandChartConfig();

  // initState kicks off TNB-meter resolution (_fetchTnbMeters) and chart
  // config loading (_loadChartConfig) as two independent, un-awaited async
  // chains that both want to trigger the initial equipment-chart fetch.
  // Without gating, each one fires its own _refetchEquipmentCharts() call
  // whenever it happens to finish, so the initial load sent two overlapping
  // HTTP requests per chart. These flags make the initial refetch wait for
  // both to land, and fire exactly once. Manual TNB meter switches after
  // init (_onTnbMeterSelected with isInitial: false) bypass this gate and
  // refetch immediately, as before.
  bool _initialScopeReady = false;
  bool _initialChartConfigReady = false;

  void _onInitialEquipmentDataReady() {
    if (_initialScopeReady && _initialChartConfigReady) {
      _refetchEquipmentCharts();
    }
  }

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    // Set today's date/time window as default for both equipment charts.
    final today = _getTodayDate();
    _selectedEventDate = today;
    _selectedEventStart = '$today 00:00:00';
    _selectedEventEnd = '$today 23:59:59';
    _rankingEventDate = today;
    _rankingEventStart = '$today 00:00:00';
    _rankingEventEnd = '$today 23:59:59';

    // Resolve the default device for this client first, then load all charts.
    _initWithDevice();
    _loadSettings();
    _fetchBillingConfig();
    _fetchCurrentPower();
    _startCurrentPowerTimer();
    _fetchTnbMeters();
    _loadChartConfig();
  }

  // ── Chart configuration (Equipment Load Correlation / Equipment MD Ranking) ─
  /// Loads the saved device exclusions and refetches both equipment charts
  /// once they land, since the initial fetch (triggered elsewhere in
  /// initState) may complete before this does.
  Future<void> _loadChartConfig() async {
    final config = await MaxDemandChartConfigService.getConfig(AppConfig.sharedConfigOwnerId);
    if (!mounted) return;
    setState(() => _chartConfig = config);
    _initialChartConfigReady = true;
    _onInitialEquipmentDataReady();
  }

  /// Opens the "Configure Chart" dialog scoped to just [target] — its own
  /// Master-Facilities-eligible candidates and its own excluded set — so
  /// clicking one chart's gear icon never shows the other chart's
  /// unrelated list. Saves the result and refetches both charts (the
  /// excluded sets are independent, but refetching only the changed chart
  /// isn't worth the extra branching).
  ///
  /// Candidates are further narrowed to `_scopedMachineIds` — the equipment
  /// bound to the currently-selected TNB meter's plant (see
  /// `_resolveScopedDeviceIds`) — so the checklist only ever offers devices
  /// that actually belong to the plant in view, same as what the charts
  /// themselves query. With no meter selected, `_scopedMachineIds` falls
  /// back to the tenant's full fleet, so the list is unrestricted.
  Future<void> _showChartConfigDialog(MaxDemandChartTarget target) async {
    try {
      final facilities = await FacilityService.getFacilities();
      final scopedIds = _scopedMachineIds.toSet();

      final List<FacilityData> candidates;
      final Set<String> initialExcluded;
      if (target == MaxDemandChartTarget.correlation) {
        await _ensureInfluxDeviceIds();
        final influxIds = _influxDeviceIds ?? {};
        candidates = facilities
            .where((f) => f.meterId.trim().isNotEmpty && influxIds.contains(f.meterId.trim()) && scopedIds.contains(f.meterId.trim()))
            .toList()
          ..sort((a, b) => a.meterId.compareTo(b.meterId));
        initialExcluded = _chartConfig.excludedCorrelationDeviceIds;
      } else {
        candidates = facilities
            .where((f) => f.includeMdRanking && f.meterId.trim().isNotEmpty && scopedIds.contains(f.meterId.trim()))
            .toList()
          ..sort((a, b) => a.meterId.compareTo(b.meterId));
        initialExcluded = _chartConfig.excludedMdRankingDeviceIds;
      }

      if (!mounted) return;
      final plantLabel = _selectedTnbMeter?.plantId.isNotEmpty == true ? _tnbPlantName(_selectedTnbMeter!.plantId) : null;
      final result = await MaxDemandChartConfigDialog.show(
        context,
        target: target,
        initialExcluded: initialExcluded,
        candidates: candidates,
        plantLabel: plantLabel,
      );
      if (result == null || !mounted) return;

      final updated = target == MaxDemandChartTarget.correlation
          ? _chartConfig.copyWith(excludedCorrelationDeviceIds: result)
          : _chartConfig.copyWith(excludedMdRankingDeviceIds: result);

      setState(() => _chartConfig = updated);
      _refetchEquipmentCharts();

      final saved = await MaxDemandChartConfigService.saveConfig(AppConfig.sharedConfigOwnerId, updated);
      if (!mounted) return;
      if (!saved) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Saved locally — could not reach the server, will retry next time.')),
        );
      }
    } catch (e) {
      debugPrint('Error configuring Max Demand chart: $e');
    }
  }

  @override
  void dispose() {
    _currentPowerTimer?.cancel();
    super.dispose();
  }

  void _startCurrentPowerTimer() {
    _currentPowerTimer = Timer.periodic(const Duration(seconds: 5), (_) => _fetchCurrentPower());
  }

  /// Ensures x-client-id is in headers, fetches /energyDetails/devices for this
  /// client (resolved dynamically from integration config on the backend), then
  /// sets _selectedDeviceId to the first result before loading all charts.
  Future<void> _initWithDevice() async {
    // Guarantee x-client-id is populated before any request goes out.
    if (AppConfig.clientId.isEmpty) await AppConfig.refresh();

    try {
      final response = await http.get(
        Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/devices'),
        headers: AppConfig.headers,
      );
      // A TNB meter may have already been selected (via _fetchTnbMeters, which
      // runs concurrently with this call) by the time this response lands —
      // that selection's influxDbTag is the authoritative device id (it's
      // what the TNB E3 Bill Simulator queries against for the same meter).
      // Bail out instead of clobbering it with this generic device-list guess,
      // which previously caused a race where whichever call finished last won,
      // sometimes overwriting a correct Monthly Max Demand reading with a
      // device id that has no matching row (showing as "no data").
      if (_selectedTnbMeter != null) return;

      if (response.statusCode == 200) {
        final List<dynamic> devices = json.decode(response.body);
        if (devices.isNotEmpty && mounted) {
          final ids = devices.map((d) => (d is Map ? d['device_id'] : null)?.toString() ?? '').where((s) => s.isNotEmpty).toList();
          // Prefer the contract master meter (MSB for Danapac, DPM047 for Thong
          // Guan) instead of just the first device, so Max Demand tracks the
          // right meter.
          String chosen = ids.first;
          for (final pref in const ['MSB', 'DPM047']) {
            if (ids.contains(pref)) {
              chosen = pref;
              break;
            }
          }
          setState(() => _selectedDeviceId = chosen);
        }
      }
    } catch (_) {}

    if (!mounted || _selectedTnbMeter != null) return;
    _fetchPowerLoadData();
    _fetchMaxDemandData();
    _fetchAveragePowerLoadDistribution();
    _fetchYearOnYearAnalysis();
    _fetchMaxDemandEvents();
    _fetchMonthlyMaxDemand();
  }

  Future<void> _fetchTnbMeters() async {
    try {
      final results = await Future.wait([
        TnbMeterService.fetchMeters(),
        TnbMeterService.fetchPlants(),
      ]);
      if (!mounted) return;
      setState(() {
        _tnbMeters = (results[0] as List<TnbMeter>).where((m) => m.isActive).toList();
        _tnbPlants = results[1] as List<Map<String, dynamic>>;
      });
      // Open on the first registered meter so every chart is already linked
      // to its DPM id (e.g. Lot 237 → VDPM002), matching MD Prediction and
      // the Bill Simulator.
      if (_tnbMeters.isNotEmpty && _selectedTnbMeter == null) {
        _onTnbMeterSelected(_tnbMeters.first, isInitial: true);
      } else {
        // No TNB meter to resolve scope from (or one was already selected) —
        // the initial scope step is done as far as this tenant is concerned.
        _initialScopeReady = true;
        _onInitialEquipmentDataReady();
      }
    } catch (e) {
      debugPrint('Error fetching TNB meters: $e');
      _initialScopeReady = true;
      _onInitialEquipmentDataReady();
    }
  }

  /// [isInitial] marks the automatic selection made during page load
  /// (_fetchTnbMeters), which gates the equipment-chart refetch behind
  /// _onInitialEquipmentDataReady() so it fires once, after chart config has
  /// also loaded, instead of racing it. A later user-driven meter switch
  /// (dropdown/onTap below) leaves it false and refetches immediately.
  void _onTnbMeterSelected(TnbMeter? meter, {bool isInitial = false}) {
    setState(() {
      _selectedTnbMeter = meter;
    });

    void onScopeResolved() {
      if (isInitial) {
        _initialScopeReady = true;
        _onInitialEquipmentDataReady();
      } else {
        _refetchEquipmentCharts();
      }
    }

    if (meter != null) {
      setState(() {
        if (meter.influxDbTag.isNotEmpty) {
          _selectedDeviceId = meter.influxDbTag;
        }
        if (meter.contractMdKw > 0) {
          _contractCapacity = meter.contractMdKw;
        }
      });
      _fetchPowerLoadData();
      _fetchMaxDemandData();
      _fetchAveragePowerLoadDistribution();
      _fetchYearOnYearAnalysis();
      _fetchMaxDemandEvents();
      _fetchMonthlyMaxDemand();
      _fetchBillingConfig();
      // Refresh immediately instead of waiting for the next 5s poll tick, so
      // switching to an unlinked meter shows "---" right away.
      _fetchCurrentPower();
      _resolveScopedDeviceIds().then((_) => onScopeResolved());
    } else {
      _initWithDevice();
      _loadSettings();
      _fetchBillingConfig();
      _resolveScopedDeviceIds().then((_) => onScopeResolved());
    }
  }

  /// Resolves which equipment device ids the Equipment Load Correlation / MD
  /// Ranking charts should query: the equipment bound to the selected TNB
  /// meter's production areas (meter.boundAreaIds), cross-referenced against
  /// Master Facilities to get each equipment's actual Influx device tag
  /// (same match-by-equipmentId/name/displayLabel pattern kwh_per_tonne uses).
  /// Falls back to the fleet-wide integration-config device list when no
  /// meter is selected or none of its bound equipment has a linked
  /// facility/meter tag yet.
  /// Fleet-wide fallback scope: the tenant's integration-config device tags
  /// (Influx). Empty when the list can't be loaded.
  Future<List<String>> _fleetDeviceIds() async {
    await _ensureInfluxDeviceIds();
    return _influxDeviceIds?.toList() ?? [];
  }

  Future<void> _resolveScopedDeviceIds() async {
    final meter = _selectedTnbMeter;
    if (meter == null || meter.boundAreaIds.isEmpty) {
      final fleet = await _fleetDeviceIds();
      if (!mounted) return;
      setState(() => _scopedMachineIds = fleet);
      return;
    }

    try {
      final results = await Future.wait([
        FacilityService.getEquipments(),
        FacilityService.getFacilities(),
      ]);
      if (!mounted) return;

      final equipments = results[0] as List<EquipmentItem>;
      final facilities = results[1] as List<FacilityData>;

      final facilityByKey = <String, FacilityData>{};
      for (final f in facilities) {
        for (final key in [f.meterId.trim(), f.meterName.trim(), f.equipmentNameId.trim()]) {
          if (key.isNotEmpty) facilityByKey[key] = f;
        }
      }

      final boundAreas = meter.boundAreaIds.toSet();
      final ids = <String>{};
      for (final e in equipments.where((e) => boundAreas.contains(e.productionArea))) {
        final match = facilityByKey[e.equipmentId.trim()] ?? facilityByKey[e.name.trim()] ?? facilityByKey[e.displayLabel.trim()];
        final tag = match?.meterId.trim() ?? '';
        if (tag.isNotEmpty) ids.add(tag);
      }

      final fallback = ids.isEmpty ? await _fleetDeviceIds() : null;
      if (!mounted) return;
      setState(() {
        _scopedMachineIds = ids.isNotEmpty ? ids.toList() : fallback!;
      });
    } catch (e) {
      debugPrint('Error resolving equipment scope for TNB meter: $e');
    }
  }

  void _refetchEquipmentCharts() {
    if (!mounted) return;
    _fetchCorrelationData(
      eventDate: _selectedEventDate,
      eventStart: _selectedEventStart,
      eventEnd: _selectedEventEnd,
      interval: _correlationInterval,
    );
    _fetchMdRankingData(
      eventDate: _rankingEventDate,
      eventStart: _rankingEventStart,
      eventEnd: _rankingEventEnd,
    );
  }

  String _tnbPlantName(String plantId) {
    final p = _tnbPlants.where((p) => p['id']?.toString() == plantId).firstOrNull;
    return p?['name']?.toString() ?? plantId;
  }

  /// Two charts side by side on desktop, stacked full-width on a phone —
  /// squeezed to half width each, these charts' axis labels and legends
  /// become unreadable, so below the tablet breakpoint they get their own
  /// full-width row instead.
  Widget _chartPairRow(double height, Widget left, Widget right) {
    return LayoutBuilder(builder: (context, constraints) {
      if (constraints.maxWidth < kBreakpointMedium) {
        return Column(
          children: [
            SizedBox(height: height, child: left),
            const SizedBox(height: 16),
            SizedBox(height: height, child: right),
          ],
        );
      }
      return SizedBox(
        height: height,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right),
          ],
        ),
      );
    });
  }

  Widget _buildCyberpunkDropdown({
    required BuildContext context,
    required String? value,
    required List<String> options,
    required String hint,
    required double width,
    required void Function(String?) onChanged,
    String Function(String)? labelBuilder,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    const cyan = Color(0xFF00D4FF);
    final safeValue = (value != null && options.contains(value)) ? value : null;
    return Container(
      width: width,
      height: 40,
      decoration: BoxDecoration(
        color: isLight ? theme.secondaryBackground : const Color(0xFF071A2E),
        border: Border.all(color: isLight ? theme.alternate : cyan.withOpacity(0.5), width: 1.2),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [BoxShadow(color: cyan.withOpacity(0.08), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: isLight ? theme.primary : cyan,
              borderRadius: const BorderRadius.only(topLeft: Radius.circular(6), bottomLeft: Radius.circular(6)),
              boxShadow: [BoxShadow(color: (isLight ? theme.primary : cyan).withOpacity(0.8), blurRadius: 6)],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: safeValue,
                  isExpanded: true,
                  dropdownColor: isLight ? theme.secondaryBackground : const Color(0xFF071A2E),
                  menuMaxHeight: 300,
                  hint: Text(hint,
                      style: GoogleFonts.poppins(
                          color: isLight ? theme.secondaryText : cyan.withOpacity(0.8), fontSize: 13, fontWeight: FontWeight.w600)),
                  style: GoogleFonts.poppins(color: isLight ? theme.txtPrimary : Colors.white, fontSize: 13, fontWeight: FontWeight.w600),
                  icon: Icon(Icons.keyboard_arrow_down_rounded, color: isLight ? theme.primary : cyan, size: 22),
                  items: options
                      .map((opt) => DropdownMenuItem<String>(
                            value: opt,
                            child: Text(labelBuilder?.call(opt) ?? opt,
                                style:
                                    GoogleFonts.poppins(color: isLight ? theme.txtPrimary : Colors.white, fontSize: 13, fontWeight: FontWeight.w500)),
                          ))
                      .toList(),
                  onChanged: onChanged,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Helper to get today's date ────────────────────────────────────────────

  /// Returns today's date in YYYY-MM-DD format, using Malaysia time
  /// (UTC+8, no DST) so "today" matches MYT regardless of the viewer's
  /// device timezone.
  String _getTodayDate() {
    final now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
  }

  // ── TOU helpers ───────────────────────────────────────────────────────────

  /// Builds a "YYYY-MM-DD HH:mm:ss" string for [date] using [tod].
  String _buildTouDateTime(String date, TimeOfDay tod) {
    final hh = tod.hour.toString().padLeft(2, '0');
    final mm = tod.minute.toString().padLeft(2, '0');
    return '$date $hh:$mm:00';
  }

  /// Returns true if [dateStr] ("YYYY-MM-DD") falls on one of the TOU peak
  /// days.  Dart's [DateTime.weekday] uses 1=Mon … 7=Sun, matching our
  /// `_touDays` convention.
  bool _isTouDay(String dateStr) {
    try {
      final p = dateStr.split('-');
      final d = DateTime(int.parse(p[0]), int.parse(p[1]), int.parse(p[2]));
      return _touDays.contains(d.weekday);
    } catch (_) {
      return true; // fail-open: apply TOU if date can't be parsed
    }
  }

  /// Returns the TOU-based start for [date] if TOU settings are loaded AND
  /// [date] is a TOU day, otherwise falls back to [fallback].
  String _resolveStart(String date, String fallback) {
    if (date.isEmpty || _touStartTime == null || !_isTouDay(date)) return fallback;
    return _buildTouDateTime(date, _touStartTime!);
  }

  /// Returns the TOU-based end for [date] if TOU settings are loaded AND
  /// [date] is a TOU day, otherwise falls back to [fallback].
  String _resolveEnd(String date, String fallback) {
    if (date.isEmpty || _touEndTime == null || !_isTouDay(date)) return fallback;
    return _buildTouDateTime(date, _touEndTime!);
  }

  /// Loads the tenant's Influx device_id tag values once (best-effort); used
  /// as the fleet-wide fallback scope for the Equipment Load Correlation / MD
  /// Ranking charts (see _fleetDeviceIds). On failure leaves _influxDeviceIds
  /// null and those charts fall back to an empty scope.
  Future<void> _ensureInfluxDeviceIds() async {
    if (_influxDeviceIds != null) return;
    // Same guard as _initWithDevice: make sure x-client-id is resolved before
    // fetching, otherwise the default tenant's device list gets cached here.
    if (AppConfig.clientId.isEmpty) await AppConfig.refresh();
    try {
      final res = await http.get(
        Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/devices'),
        headers: AppConfig.headers,
      );
      if (res.statusCode == 200) {
        final List<dynamic> devices = json.decode(res.body);
        _influxDeviceIds = devices
            .map((d) => (d is Map ? d['device_id'] : null)?.toString().trim() ?? '')
            .where((s) => s.isNotEmpty)
            .toSet();
      }
    } catch (_) {}
  }

  // Fixed set of Influx device_id tags summed for the "Current Power Load"
  // card on the F0004 tenant — its per-block meters (DPM046/047/048/052)
  // are what make up total incoming power for that plant. Demo (DEV) reads
  // the same Influx bucket, so it sums the same meters. Other tenants keep
  // the selected-device-or-unscoped-total behavior below.
  static const Set<String> _currentPowerFixedClientIds = {'F0004', 'DEV'};
  static const List<String> _currentPowerDeviceIds = ['DPM046', 'DPM047', 'DPM048', 'DPM052'];

  // True when a TNB meter is selected but has no Influx device linked at all
  // (distinct from a virtual meter that just isn't tagged in Influx yet).
  // Every metric card that depends on device telemetry (as opposed to the
  // meter's own static config, e.g. contract capacity) checks this and shows
  // "---" / "Not linked to any device ID" instead of stale or unrelated data.
  bool get _selectedMeterUnlinked => _selectedTnbMeter != null && _selectedTnbMeter!.influxDbTag.trim().isEmpty;

  // Current power (polling)
  Future<void> _fetchCurrentPower() async {
    // TEMP DEBUG — remove once Lot 48 / unlinked-meter behavior is confirmed.
    debugPrint('[CurrentPower] meter=${_selectedTnbMeter?.meterLabel} '
        'influxDbTag="${_selectedTnbMeter?.influxDbTag}" '
        'selectedDeviceId="$_selectedDeviceId"');
    if (_selectedMeterUnlinked) {
      debugPrint('[CurrentPower] unlinked meter -> forcing null/---');
      if (_currentPowerKw != null && mounted) setState(() => _currentPowerKw = null);
      return;
    }
    try {
      String query = '';
      if (_currentPowerFixedClientIds.contains(AppConfig.clientId)) {
        // Only sum whichever of the fixed meters actually have data in this
        // tenant's Influx bucket — a meter that isn't reporting yet (or was
        // renamed/retired) shouldn't silently zero out the whole card.
        await _ensureInfluxDeviceIds();
        if (!mounted) return;
        var presentIds = _currentPowerDeviceIds.where((id) => _influxDeviceIds?.contains(id) ?? false).toList();
        // These are the site's block incomers, so unnarrowed they report the
        // whole plant's power to whoever is looking — including someone granted
        // a single block.
        final allowed = await FacilityService.allowedDeviceIds();
        if (!mounted) return;
        if (allowed != null) {
          presentIds = presentIds.where(allowed.contains).toList();
          if (presentIds.isEmpty) {
            // None of them are theirs. A dash is the honest answer; the
            // plant-wide total is not.
            if (_currentPowerKw != null) setState(() => _currentPowerKw = null);
            return;
          }
        }
        query = presentIds.isNotEmpty ? '?deviceId=${Uri.encodeQueryComponent(presentIds.join(','))}' : '';
      } else {
        // This endpoint queries raw InfluxDB directly, where devices are keyed
        // by the Influx device tag — which only sometimes matches the meter id
        // the rest of this page uses (real DPM tags like "DPM047"/"MSB" exist
        // in Influx; virtual meter codes like "VDPM002" only exist in the
        // MySQL Overall_* tables). Blindly scoping by _selectedDeviceId made
        // this card silently read 0.0 for virtual meters, so only scope when
        // the id is confirmed present in the tenant's Influx bucket and fall
        // back to the unscoped plant-wide aggregate otherwise.
        await _ensureInfluxDeviceIds();
        if (!mounted) return;
        final deviceId = _selectedDeviceId.trim();
        final scoped = deviceId.isNotEmpty && (_influxDeviceIds?.contains(deviceId) ?? false);
        if (!scoped) {
          // The fallback here is the unscoped plant-wide aggregate, which a
          // restricted account must not be shown. It reads as a dash instead.
          final allowed = await FacilityService.allowedDeviceIds();
          if (!mounted) return;
          if (allowed != null) {
            if (_currentPowerKw != null) setState(() => _currentPowerKw = null);
            return;
          }
        }
        query = scoped ? '?deviceId=${Uri.encodeQueryComponent(deviceId)}' : '';
        // TEMP DEBUG — remove once Lot 48 / unlinked-meter behavior is confirmed.
        debugPrint('[CurrentPower] deviceId="$deviceId" scoped=$scoped '
            '(in influx bucket? ${_influxDeviceIds?.contains(deviceId)}) -> query="$query"');
      }
      final uri = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/power-load/current$query');
      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted) return;
      // The selected meter may have changed to an unlinked one while this
      // request was in flight (e.g. the initial default-device fetch racing
      // with auto-selecting an unlinked meter, or a 5s poll tick that was
      // already in flight when the dropdown changed) — don't let a late
      // response for the old device overwrite the "---" set for this one.
      if (_selectedMeterUnlinked) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (!mounted) return;
        if (_selectedMeterUnlinked) return;
        setState(() => _currentPowerKw = (data['power_kw'] ?? 0.0).toDouble());
      }
    } catch (e) {
      print('Error fetching current power: $e');
    }
  }

  Future<void> _fetchMonthlyMaxDemand() async {
    // No device linked for the selected lot — there's no MD reading to pull,
    // and _selectedDeviceId may still hold a stale value from a previous
    // selection, so don't fetch with it. Zero renders as "---" below.
    if (_selectedMeterUnlinked) {
      if (_monthlyMaxDemandKw != 0.0 && mounted) setState(() => _monthlyMaxDemandKw = 0.0);
      return;
    }
    try {
      // Same Overall_monthly_energy_consumption.max_demand_kW the TNB E3 Bill
      // Simulator reads (see tnb_e3_bill_simulator_widget.dart) — so this card
      // and the bill simulator never disagree on the figure that actually
      // drives MD billing. _lastMonthMaxDemandKw (for the "vs Last Month"
      // subtitle) comes from the year-on-year fetch instead; this endpoint
      // only reports the current month.
      final uri = Uri.parse('${AppConfig.dataApiBaseSafe}/energyComparison/tnb-bill-simulator/$_selectedDeviceId');
      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted || _selectedMeterUnlinked) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (!mounted || _selectedMeterUnlinked) return;
        setState(() {
          // This endpoint reads a MySQL DECIMAL column, which mysql2 can hand
          // back as a String depending on the client's pool config — parse
          // defensively instead of assuming a JSON number.
          _monthlyMaxDemandKw = double.tryParse(data['max_demand_kW'].toString()) ?? 0.0;
        });
      }
    } catch (e) {
      print('Error fetching monthly max demand: $e');
    }
  }

  // ── Billing config ────────────────────────────────────────────────────────
  Future<void> _fetchBillingConfig() async {
    try {
      setState(() => _isLoadingBillingConfig = true);
      // Billing config is shared across every user of this client, not
      // per-login — see AppConfig.sharedConfigOwnerId.
      const userUid = AppConfig.sharedConfigOwnerId;

      // Resolve MD Capacity Charge off the selected TNB meter: the meter is
      // already plant-scoped (picked via the TNB Meter dropdown), so its own
      // tariffCategoryId tells us which Master Billing Config category to
      // read the capacity rate from — same resolution order the TNB E3 Bill
      // Simulator uses (masterBillingConfig/:userId/:tariffCategoryId).
      // Falls back to whatever's globally "active" when the meter has no
      // tariff linked yet, or that category has no saved config.
      final meterCategoryId = _selectedTnbMeter?.tariffCategoryId.trim() ?? '';

      // NOTE: masterBillingConfig/electricityTariff live on the ui7 data API
      // (same host master_billing_config_widget.dart saves to), not the ic7
      // CRUD API — using ic7 here silently returns empty config forever.
      // The x-client-id header is required too: the backend resolves the
      // tenant Firestore from it, so an unheadered request always reports
      // "no config found" even when one exists for the active client.
      final results = await Future.wait([
        meterCategoryId.isNotEmpty
            ? http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/$meterCategoryId'), headers: AppConfig.headers)
            : http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/active'), headers: AppConfig.headers),
        http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/electricityTariff'), headers: AppConfig.headers),
      ]);
      if (!mounted) return;
      var response = results[0];
      final tariffResponse = results[1];

      if (meterCategoryId.isNotEmpty && response.statusCode != 200) {
        response = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/active'), headers: AppConfig.headers);
        if (!mounted) return;
      }

      double? capacityRate;
      if (tariffResponse.statusCode == 200) {
        final t = json.decode(tariffResponse.body) as Map<String, dynamic>;
        if (t['capacityRate'] != null) {
          capacityRate = double.tryParse(t['capacityRate'].toString());
        }
      }

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        final config = data['config'] as Map<String, dynamic>?;
        // Prefer the meter-linked tariff's mdCapacityCharge (the whole point
        // of resolving via the meter); fall back to the generic, non-tariff-
        // specific electricityTariff.capacityRate when the resolved category
        // has no rate saved.
        final rate = (config?['mdCapacityCharge'] != null ? double.tryParse(config!['mdCapacityCharge'].toString()) : null) ?? capacityRate;
        final networkRate = config?['mdNetworkCharge'] != null ? double.tryParse(config!['mdNetworkCharge'].toString()) : null;
        if (rate != null || networkRate != null) {
          setState(() {
            if (rate != null) _mdCapacityCharge = rate;
            if (networkRate != null) _mdNetworkCharge = networkRate;
          });
        }
      }
    } catch (e) {
      print('Error fetching billing config: $e');
    } finally {
      setState(() => _isLoadingBillingConfig = false);
    }
  }

  double _calculateMdSurcharge() => _monthlyMaxDemandKw * (_mdCapacityCharge + _mdNetworkCharge);

  // Max demand events
  Future<void> _fetchMaxDemandEvents() async {
    try {
      setState(() {
        _isLoadingMaxDemandEvents = true;
        _maxDemandEventsError = null;
      });

      final response = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/max-demand-events?device_id=$_selectedDeviceId'),
          headers: AppConfig.headers);
      if (!mounted) return;

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        if (!mounted) return;
        final events = (responseData['data'] as List<dynamic>)
            .map((item) => {
                  'date': (item['date'] ?? '').toString(),
                  'time': (item['time'] ?? '').toString(),
                  'duration': (item['duration'] ?? '').toString(),
                  'peakLoad': (item['maximum_demand_kw'] ?? '0').toString(),
                  'percentage': (item['contract_capacity_percent'] ?? '').toString(),
                  'status': (item['status'] ?? 'Normal').toString(),
                })
            .toList();

        setState(() {
          _maxDemandEvents = events;
          maxDemand = responseData['max_demand'] != null ? responseData['max_demand'].toString() : '0.0';
          _isLoadingMaxDemandEvents = false;
        });

        // Auto-select first event → triggers both chart fetches
        if (events.isNotEmpty) {
          _selectEventAndFetch(events.first);
        }
      } else {
        setState(() {
          _maxDemandEventsError = 'Failed to load data: ${response.statusCode}';
          _isLoadingMaxDemandEvents = false;
        });
      }
    } catch (e) {
      setState(() {
        _maxDemandEventsError = 'Error: $e';
        _isLoadingMaxDemandEvents = false;
      });
    }
  }

  /// Extracts date/start/end from a clicked event row and kicks off both
  /// the correlation chart fetch and the MD ranking fetch.
  ///
  /// If TOU start/end times have been loaded from settings, they are used as
  /// the default window for both charts instead of the raw event time window.
  void _selectEventAndFetch(Map<String, dynamic> event) {
    final rawDate = event['date'] as String? ?? '';
    if (rawDate.isEmpty) return;

    final date = rawDate.contains('T') ? rawDate.split('T').first : rawDate;

    // --- Build the raw event-derived window (1-hour around the peak time) ---
    String eventStartStr = '$date 00:00:00';
    String eventEndStr = '$date 23:59:59';

    final time = event['time'] as String? ?? '';
    if (time.isNotEmpty) {
      try {
        final parts = time.split(':');
        final hour = int.parse(parts[0]);
        final minute = parts.length > 1 ? int.parse(parts[1]) : 0;
        String pad(int n) => n.toString().padLeft(2, '0');
        final dateParts = date.split('-');
        final start = DateTime(
          int.parse(dateParts[0]),
          int.parse(dateParts[1]),
          int.parse(dateParts[2]),
          hour,
          minute,
        );
        final end = start.add(const Duration(hours: 1));
        eventStartStr = '$date ${pad(start.hour)}:${pad(start.minute)}:00';
        eventEndStr = '$date ${pad(end.hour)}:${pad(end.minute)}:00';
      } catch (_) {}
    }

    // --- Apply TOU defaults if available, otherwise keep event window --------
    final resolvedStart = _resolveStart(date, eventStartStr);
    final resolvedEnd = _resolveEnd(date, eventEndStr);

    setState(() {
      _selectedEventDate = date;
      _selectedEventStart = resolvedStart;
      _selectedEventEnd = resolvedEnd;
      // Keep ranking window in sync with the resolved window by default
      _rankingEventDate = date;
      _rankingEventStart = resolvedStart;
      _rankingEventEnd = resolvedEnd;
    });

    _fetchCorrelationData(
      eventDate: date,
      eventStart: resolvedStart,
      eventEnd: resolvedEnd,
      interval: _correlationInterval,
    );
    _fetchMdRankingData(
      eventDate: date,
      eventStart: resolvedStart,
      eventEnd: resolvedEnd,
    );
  }

  // ── Correlation chart fetch ───────────────────────────────────────────────
  /// Loads (and caches) the meterIds of all registered Master Facilities.
  Future<Set<String>> _getFacilityMeterIds() async {
    final cached = _facilityMeterIds;
    if (cached != null) return cached;
    final facilities = await FacilityService.getFacilities();
    final ids = facilities.map((f) => f.meterId.trim()).where((id) => id.isNotEmpty).toSet();
    _facilityMeterIds = ids;
    _facilityNameByMeterId ??= {
      for (final f in facilities)
        if (f.meterId.trim().isNotEmpty) f.meterId.trim(): f.meterName.trim(),
    };
    return ids;
  }

  /// Device ids the correlation chart is allowed to show: scoped ids that are
  /// both present in the tenant's integration config (Influx device tags) and
  /// registered in Master Facilities (by meterId/DPM ID), minus anything the
  /// user has excluded via the "Configure Charts" dialog.
  Future<List<String>> _getCorrelationDeviceIds() async {
    await _ensureInfluxDeviceIds();
    final facilityIds = await _getFacilityMeterIds();
    final influxIds = _influxDeviceIds;
    final excluded = _chartConfig.excludedCorrelationDeviceIds;
    final allowed = _scopedMachineIds
        .where((id) => (influxIds == null || influxIds.contains(id)) && facilityIds.contains(id) && !excluded.contains(id))
        .toList();
    debugPrint('[Correlation scope] scoped=$_scopedMachineIds influx=${influxIds?.toList()} facilities=${facilityIds.toList()} allowed=$allowed');
    return allowed;
  }

  Future<void> _fetchCorrelationData({
    required String eventDate,
    required String eventStart,
    required String eventEnd,
    required String interval,
  }) async {
    if (eventDate.isEmpty) return;

    setState(() {
      _isLoadingCorrelation = true;
      _correlationError = null;
    });

    try {
      final allowedIds = await _getCorrelationDeviceIds();
      if (!mounted) return;

      if (allowedIds.isEmpty) {
        setState(() {
          _correlationSeriesData = {};
          _correlationDeviceIds = [];
          _correlationSystemPeak = 0.0;
          _isLoadingCorrelation = false;
        });
        return;
      }

      final uri = Uri.parse(
        'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/equipment-load-correlation'
        '?device_id=${allowedIds.join(',')}'
        '&event_date=$eventDate'
        '&event_start=$eventStart'
        '&event_end=$eventEnd'
        '&interval=$interval',
      );

      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted) return;

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        if (!mounted) return;
        final Map<String, List<Map<String, dynamic>>> seriesMap = {};

        for (final id in allowedIds) {
          seriesMap[id] = [];
        }

        // Only keep series for devices in the allowed list (integration
        // config ∩ Master Facilities); anything else in the response is dropped.
        for (final item in (responseData['data'] as List<dynamic>? ?? [])) {
          final deviceId = item['device_id']?.toString() ?? 'Unknown';
          final time = item['time_label']?.toString() ?? '';
          final value = (item['power_kW'] ?? 0.0).toDouble();
          if (seriesMap.containsKey(deviceId)) {
            seriesMap[deviceId]!.add({'time': time, 'value': value});
          }
        }

        setState(() {
          _correlationSystemPeak = (responseData['system_peak_kW'] ?? 0.0).toDouble();
          _correlationSeriesData = seriesMap;
          _correlationDeviceIds = allowedIds;
          _isLoadingCorrelation = false;
        });
      } else {
        setState(() {
          _correlationError = 'Failed to load data: ${response.statusCode}';
          _isLoadingCorrelation = false;
        });
      }
    } catch (e) {
      setState(() {
        _correlationError = 'Error: $e';
        _isLoadingCorrelation = false;
      });
    }
  }

  // ── MD Ranking chart fetch ────────────────────────────────────────────────
  /// Loads (and caches) the meterIds of Master Facilities that have the
  /// per-device "MD Ranking" analytics checkbox enabled (includeMdRanking).
  /// Cached independently of _chartConfig (see _getVisibleMdEnabledDeviceIds
  /// for the user-narrowed view) so a config change doesn't need this
  /// Master-Facilities read to be invalidated too.
  Future<Set<String>> _getMdEnabledDeviceIds() async {
    final cached = _mdEnabledDeviceIds;
    if (cached != null) return cached;
    final facilities = await FacilityService.getFacilities();
    final ids = facilities
        .where((f) => f.includeMdRanking)
        .map((f) => f.meterId.trim())
        .where((id) => id.isNotEmpty)
        .toSet();
    _mdEnabledDeviceIds = ids;
    _facilityNameByMeterId ??= {
      for (final f in facilities)
        if (f.meterId.trim().isNotEmpty) f.meterId.trim(): f.meterName.trim(),
    };
    return ids;
  }

  /// [_getMdEnabledDeviceIds], minus anything the user has excluded via the
  /// "Configure Charts" dialog — the chart's actual display/query scope.
  Future<Set<String>> _getVisibleMdEnabledDeviceIds() async {
    final ids = await _getMdEnabledDeviceIds();
    return ids.difference(_chartConfig.excludedMdRankingDeviceIds);
  }

  Future<void> _fetchMdRankingData({
    required String eventDate,
    required String eventStart,
    required String eventEnd,
  }) async {
    if (eventDate.isEmpty) return;

    final requestId = ++_mdRankingRequestId;

    setState(() {
      _isLoadingMdRanking = true;
      _mdRankingError = null;
    });

    try {
      // Query the scoped devices plus every MD-enabled facility (this pulls
      // in virtual meters like VDPM003 that aren't Influx tags — the backend
      // resolves those from billing-level data when it can), minus anything
      // the user excluded via the "Configure Charts" dialog.
      final mdEnabledIds = await _getVisibleMdEnabledDeviceIds();
      if (!mounted || requestId != _mdRankingRequestId) return;
      final queryIds = {..._scopedMachineIds, ...mdEnabledIds}.toList();

      if (queryIds.isEmpty) {
        setState(() {
          _mdRankingData = [];
          _isLoadingMdRanking = false;
        });
        return;
      }

      final uri = Uri.parse(
        'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/equipment-md-ranking'
        '?device_id=${queryIds.join(',')}'
        '&event_date=$eventDate'
        '&event_start=$eventStart'
        '&event_end=$eventEnd',
      );

      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted || requestId != _mdRankingRequestId) return;

      if (response.statusCode == 200) {
        final responseData = json.decode(response.body) as Map<String, dynamic>;
        final rawData = responseData['data'] as List<dynamic>? ?? [];

        // Only show equipment whose Master Facility has MD Ranking enabled.
        final mdEnabled = mdEnabledIds;
        final namesById = _facilityNameByMeterId ?? {};

        final parsed = rawData
            .map((item) {
              final deviceId = item['device_id']?.toString() ?? 'Unknown';
              return {
                'device_id': deviceId,
                'device_name': namesById[deviceId.trim()] ?? '',
                'peak_demand_kW': (item['peak_demand_kW'] ?? 0.0).toDouble(),
                'percentage': (item['percentage'] ?? 0.0).toDouble(),
              };
            })
            .where((item) => mdEnabled.contains((item['device_id'] as String).trim()))
            .toList();

        debugPrint('[MD Ranking] mdEnabled=${mdEnabled.toList()} '
            'apiDevices=${rawData.map((i) => (i as Map)['device_id']).toList()} '
            'kept=${parsed.map((i) => i['device_id']).toList()}');

        parsed.sort((a, b) => (b['peak_demand_kW'] as double).compareTo(a['peak_demand_kW'] as double));

        setState(() {
          _mdRankingData = parsed;
          _isLoadingMdRanking = false;
        });
      } else {
        setState(() {
          _mdRankingError = 'Failed to load data: ${response.statusCode}';
          _isLoadingMdRanking = false;
        });
      }
    } catch (e) {
      if (!mounted || requestId != _mdRankingRequestId) return;
      setState(() {
        _mdRankingError = 'Error: $e';
        _isLoadingMdRanking = false;
      });
    }
  }

  // ── Callbacks from EquipmentLoadCorrelationChart ──────────────────────────
  void _onCorrelationIntervalChanged(String interval) {
    setState(() => _correlationInterval = interval);
    _fetchCorrelationData(
      eventDate: _selectedEventDate,
      eventStart: _selectedEventStart,
      eventEnd: _selectedEventEnd,
      interval: interval,
    );
  }

  void _onCorrelationDateChanged(String date, String start, String end) {
    if (date.isEmpty) {
      // Date cleared — restore to today's window.
      final today = _getTodayDate();
      setState(() {
        _selectedEventDate = today;
        _selectedEventStart = '$today 00:00:00';
        _selectedEventEnd = '$today 23:59:59';
      });
      _fetchCorrelationData(
        eventDate: today,
        eventStart: '$today 00:00:00',
        eventEnd: '$today 23:59:59',
        interval: _correlationInterval,
      );
    } else {
      setState(() {
        _selectedEventDate = date;
        _selectedEventStart = start;
        _selectedEventEnd = end;
      });
      _fetchCorrelationData(
        eventDate: date,
        eventStart: start,
        eventEnd: end,
        interval: _correlationInterval,
      );
    }
  }

  // ── Callback from EquipmentMdRankingChart ─────────────────────────────────
  void _onMdRankingDateChanged(String date, String start, String end) {
    if (date.isEmpty) {
      // Date cleared — restore to today's window.
      final today = _getTodayDate();
      setState(() {
        _rankingEventDate = today;
        _rankingEventStart = '$today 00:00:00';
        _rankingEventEnd = '$today 23:59:59';
      });
      _fetchMdRankingData(
        eventDate: today,
        eventStart: '$today 00:00:00',
        eventEnd: '$today 23:59:59',
      );
    } else {
      setState(() {
        _rankingEventDate = date;
        _rankingEventStart = start;
        _rankingEventEnd = end;
      });
      _fetchMdRankingData(
        eventDate: date,
        eventStart: start,
        eventEnd: end,
      );
    }
  }

  // ── Other data fetches ────────────────────────────────────────────────────
  Future<void> _fetchYearOnYearAnalysis() async {
    try {
      setState(() {
        _isLoadingYearOnYear = true;
        _yearOnYearError = null;
      });
      final response = await http.get(
          Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/year-on-year-analysis?device_id=$_selectedDeviceId'),
          headers: AppConfig.headers);
      print(response.body);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _yearOnYearData = (responseData['data'] as List<dynamic>)
              .map((item) => {
                    'month': (item['month'] as int?) ?? 0,
                    'month_label': (item['month_label'] as String?) ?? '',
                    'previous_period_max_demand_kW': ((item['previous_period_max_demand_kW'] ?? 0) as num).toDouble(),
                    'current_period_max_demand_kW': ((item['current_period_max_demand_kW'] ?? 0) as num).toDouble(),
                    'device_id': item['device_id'] ?? '',
                  })
              .toList();

          // Derive "last month" max demand for the Monthly Max Demand card
          // subtitle. The year-on-year series can come back ordered or
          // unordered, may or may not include the current month, and some
          // entries may legitimately be 0. Strategy:
          //   1. Try the calendar month immediately before "now".
          //   2. Otherwise walk the series backwards from the current month
          //      and pick the most recent non-zero `current_period_max_demand_kW`.
          //   3. As a final fallback, use the largest non-zero value in the
          //      series excluding the current month — guarantees we surface
          //      *something* meaningful instead of `---`.
          double pickLastMonthMax() {
            if (_yearOnYearData.isEmpty) return 0.0;
            // Malaysia time (UTC+8, no DST) so "current month" matches MYT
            // regardless of the viewer's device timezone.
            final nowMonth = DateTime.now().toUtc().add(const Duration(hours: 8)).month;
            final prevMonth = nowMonth == 1 ? 12 : nowMonth - 1;

            double readVal(Map<String, dynamic> m) => (m['current_period_max_demand_kW'] as num?)?.toDouble() ?? 0.0;

            // 1. Exact previous-month match.
            for (final m in _yearOnYearData) {
              if (m['month'] == prevMonth) {
                final v = readVal(m);
                if (v > 0) return v;
              }
            }
            // 2. Walk backwards from current month through the series.
            for (int step = 1; step <= 12; step++) {
              final target = ((nowMonth - 1 - step) % 12 + 12) % 12 + 1;
              for (final m in _yearOnYearData) {
                if (m['month'] == target) {
                  final v = readVal(m);
                  if (v > 0) return v;
                }
              }
            }
            // 3. Largest non-current-month value as a last resort.
            double best = 0.0;
            for (final m in _yearOnYearData) {
              if (m['month'] == nowMonth) continue;
              final v = readVal(m);
              if (v > best) best = v;
            }
            return best;
          }

          final picked = pickLastMonthMax();
          if (picked > 0) {
            _lastMonthMaxDemandKw = picked;
            _cachedLastMonthMaxDemandKw = picked;
          }
          if (responseData['comparison'] != null) {
            final c = responseData['comparison'] as Map<String, dynamic>;
            _yearOnYearComparisonData = [
              {
                'previous_period': c['previous_period'] ?? 'Previous Period',
                'current_period': c['current_period'] ?? 'Current Period',
                'description': c['description'] ?? '',
              }
            ];
          } else {
            _yearOnYearComparisonData = [];
          }
          _isLoadingYearOnYear = false;
        });
      } else {
        setState(() {
          _yearOnYearError = 'Failed to load data: ${response.statusCode}';
          _isLoadingYearOnYear = false;
        });
      }
    } catch (e) {
      setState(() {
        _yearOnYearError = 'Error: $e';
        _isLoadingYearOnYear = false;
      });
    }
  }

  Future<void> _fetchAveragePowerLoadDistribution() async {
    try {
      setState(() {
        _isLoadingAvgPowerLoad = true;
        _avgPowerLoadError = null;
      });
      // Bucket windows are configurable per meter (TNB Meter Setting →
      // "Max Demand Monitoring — Widget Channel Mapping" → Power Load
      // Distribution). Falls back to the backend's own Morning/Afternoon/
      // Evening/Night default when no meter is selected or it has none saved.
      final buckets = _selectedTnbMeter?.dashboardConfig.distributionBuckets ?? const [];
      final uri = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/average-power-load/$_selectedDeviceId').replace(
        queryParameters:
            buckets.isNotEmpty ? {'buckets': json.encode(buckets.map((b) => b.toJson()).toList())} : null,
      );
      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final responseData = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _avgPowerLoadDistribution = (responseData['data'] as List<dynamic>)
              .map((item) => {
                    'time_period': item['time_period'] as String,
                    'average_power_load_kW': (item['average_power_load_kW'] ?? 0.0).toDouble(),
                    'total_energy_kWh': (item['total_energy_kWh'] ?? 0.0).toDouble(),
                    'hours_count': item['hours_count'] as int,
                  })
              .toList();
          _isLoadingAvgPowerLoad = false;
        });
      } else {
        setState(() {
          _avgPowerLoadError = 'Failed to load data: ${response.statusCode}';
          _isLoadingAvgPowerLoad = false;
        });
      }
    } catch (e) {
      setState(() {
        _avgPowerLoadError = 'Error: $e';
        _isLoadingAvgPowerLoad = false;
      });
    }
  }

  Future<void> _fetchMaxDemandData() async {
    try {
      setState(() {
        _isLoadingMaxDemand = true;
        _maxDemandError = null;
      });
      final response = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/max-demand-chart?device_id=$_selectedDeviceId'),
          headers: AppConfig.headers);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final List<dynamic> data = json.decode(response.body);
        if (!mounted) return;
        setState(() {
          _maxDemandData = data
              .map((item) => {
                    'label': (item['label'] as String?) ?? '',
                    'value': (item['value'] ?? 0.0).toDouble(),
                    'date': (item['date'] as String?) ?? '',
                  })
              .toList();
          _isLoadingMaxDemand = false;
        });
      } else {
        setState(() {
          _maxDemandError = 'Failed to load data: ${response.statusCode}';
          _isLoadingMaxDemand = false;
        });
      }
    } catch (e) {
      setState(() {
        _maxDemandError = 'Error: $e';
        _isLoadingMaxDemand = false;
      });
    }
  }

  Future<void> _fetchPowerLoadData() async {
    try {
      setState(() {
        _isLoadingPowerLoad = true;
        _powerLoadError = null;
      });
      final response = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/power-load-24h/$_selectedDeviceId'),
          headers: AppConfig.headers);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if (!mounted) return;
        if (data['statistics'] != null) {
          _maxPowerKw = (data['statistics']['max_demand_kW'] ?? 0.0).toDouble();
          _minPowerKw = (data['statistics']['min_demand_kW'] ?? 0.0).toDouble();
        }
        setState(() {
          _powerLoadData = data['data'] != null
              ? (data['data'] as List<dynamic>)
                  .map((item) => {
                        'time_label': item['time_label'] as String,
                        'max_demand_kW': (item['max_demand_kW'] ?? 0.0).toDouble(),
                      })
                  .toList()
              : [];
          _isLoadingPowerLoad = false;
        });
      } else {
        setState(() {
          _powerLoadError = 'Failed to load data: ${response.statusCode}';
          _isLoadingPowerLoad = false;
        });
      }
    } catch (e) {
      setState(() {
        _powerLoadError = 'Error: $e';
        _isLoadingPowerLoad = false;
      });
    }
  }

  TimeOfDay _parseTimeOfDay(String timeStr) {
    try {
      final parts = timeStr.split(':');
      return TimeOfDay(hour: int.parse(parts[0]), minute: int.parse(parts[1]));
    } catch (_) {
      return const TimeOfDay(hour: 0, minute: 0);
    }
  }

  Future<void> _loadSettings() async {
    final userUid = AppStateNotifier.instance.uid ?? ' ';
    setState(() => _isLoading = true);
    try {
      final response = await EnergySystemSettingsService.getSettings(userUid);
      if (response['exists'] == true && response['settings'] != null) {
        final settings = response['settings'];
        if (settings['contractCapacity'] != null) {
          final cc = settings['contractCapacity'];
          setState(() {
            _contractCapacity = cc['contractCapacity']?.toDouble() ?? 0.0;
          });

          // ── Load TOU times/days and persist them for chart window defaults ─
          if (cc['peakHourToU'] != null) {
            final tou = cc['peakHourToU'] as Map<String, dynamic>;

            TimeOfDay? loadedStart;
            TimeOfDay? loadedEnd;

            if (tou['startTime'] != null) {
              loadedStart = _parseTimeOfDay(tou['startTime'] as String);
            }
            if (tou['endTime'] != null) {
              loadedEnd = _parseTimeOfDay(tou['endTime'] as String);
            }
            // Load days before calling _getTouWeekDates so the helper sees
            // the up-to-date list.
            if (tou['days'] != null) {
              _touDays = List<int>.from(tou['days'] as List);
            }

            // TOU settings are kept for event-row resolution helpers, but the
            // equipment charts keep their default today-window (set in
            // initState) instead of the TOU week range.
            setState(() {
              _touStartTime = loadedStart;
              _touEndTime = loadedEnd;
              // _touDays already assigned above; reassign for setState reactivity
              if (tou['days'] != null) {
                _touDays = List<int>.from(tou['days'] as List);
              }
            });
          }
        }
        if (settings['overloadRiskLevel'] != null) {
          final r = settings['overloadRiskLevel'];
          setState(() {
            _highRiskMin = r['highRiskMin']?.toDouble() ?? 80.0;
            _mediumRiskMin = r['mediumRiskMin']?.toDouble() ?? 60.0;
            _mediumRiskMax = r['mediumRiskMax']?.toDouble() ?? 80.0;
            _lowRiskMin = r['lowRiskMin']?.toDouble() ?? 0.0;
            _lowRiskMax = r['lowRiskMax']?.toDouble() ?? 60.0;
          });
        }
      }
    } catch (e) {
      print('Error loading settings: $e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // Month-over-month comparison for Monthly Max Demand card
  ({String text, Color color})? _monthlyMaxDemandComparison() {
    if (_lastMonthMaxDemandKw <= 0 || _monthlyMaxDemandKw <= 0) return null;
    final delta = _monthlyMaxDemandKw - _lastMonthMaxDemandKw;
    final pct = (delta / _lastMonthMaxDemandKw) * 100;
    final isDown = delta < 0;
    final arrow = isDown ? '↓' : '↑';
    final color = isDown ? Colors.green : Colors.red;
    return (text: '$arrow${pct.abs().toStringAsFixed(1)}% vs Last Month', color: color);
  }

  // Which day this month's max demand actually happened on — derived from
  // the same per-day series the Daily Maximum Demand chart plots
  // (_maxDemandData: {label, value, date} per day, populated by
  // _fetchMaxDemandData), so the two never disagree on the peak day.
  String? _monthlyMaxDemandPeakDayLabel() {
    if (_maxDemandData.isEmpty) return null;
    Map<String, dynamic>? peak;
    double peakValue = 0.0;
    for (final row in _maxDemandData) {
      final v = (row['value'] as num?)?.toDouble() ?? 0.0;
      if (peak == null || v > peakValue) {
        peak = row;
        peakValue = v;
      }
    }
    if (peak == null || peakValue <= 0) return null;
    final label = (peak['label'] as String?) ?? '';
    if (label.isEmpty) return null;
    return 'Peak: $label';
  }

  // Risk helpers 
  double _calculateOverloadRiskPercentage() {
    if (_contractCapacity <= 0) return 0.0;
    // Formula: (This Month Max Demand / Contract Capacity) × 100
    return (_monthlyMaxDemandKw / _contractCapacity) * 100;
  }

  String _getOverloadRiskLevel() {
    final p = _calculateOverloadRiskPercentage();
    if (p >= 100) return 'Critical';
    if (p >= _highRiskMin) return 'High';
    if (p >= _mediumRiskMin) return 'Medium';
    if (p >= _lowRiskMin) return 'Low';
    return 'Normal';
  }

  Color _getOverloadRiskColor() {
    switch (_getOverloadRiskLevel()) {
      case 'High':
        return Colors.orange;
      case 'Medium':
        return Colors.amber;
      case 'Low':
        return Colors.green;
      case 'Critical':
        return Colors.red;
      default:
        return Colors.blue;
    }
  }

  // UI
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
      body: SingleChildScrollView(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 24),
        child: Column(
          mainAxisSize: MainAxisSize.max,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 4),
              child: Text(
                'Dashboard/MaxDemandMonitoring',
                style: FlutterFlowTheme.of(context).titleLarge.override(
                      fontFamily: 'Poppins',
                      color: FlutterFlowTheme.of(context).primaryText,
                      fontSize: 12,
                      letterSpacing: 0.0,
                      font: GoogleFonts.poppins(),
                    ),
              ),
            ),
            Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 4),
              child: Text(
                'Max Demand Monitoring',
                style: FlutterFlowTheme.of(context).headlineMedium.override(
                      fontFamily: 'Poppins',
                      letterSpacing: 0.0,
                      font: GoogleFonts.poppins(),
                    ),
              ),
            ),
            // Title stays on its own line; the TNB meter selector always sits
            // on its own row underneath — same shape at every screen width,
            // instead of squeezing a 260px dropdown beside the title.
            if (_tnbMeters.isNotEmpty)
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 6, 0, 0),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildCyberpunkDropdown(
                      context: context,
                      value: _selectedTnbMeter?.id,
                      options: _tnbMeters.map((m) => m.id).toList(),
                      hint: 'TNB Meter',
                      width: 260,
                      labelBuilder: (id) {
                        final meter = _tnbMeters.where((m) => m.id == id).firstOrNull;
                        if (meter == null) return id;
                        final plantLabel = meter.plantId.isNotEmpty ? '${_tnbPlantName(meter.plantId)} — ' : '';
                        return '$plantLabel${meter.meterLabel.isNotEmpty ? meter.meterLabel : meter.meterCode}';
                      },
                      onChanged: (id) {
                        if (id == null) {
                          _onTnbMeterSelected(null);
                        } else {
                          final meter = _tnbMeters.where((m) => m.id == id).firstOrNull;
                          _onTnbMeterSelected(meter);
                        }
                      },
                    ),
                    if (_selectedTnbMeter != null) ...[
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () => _onTnbMeterSelected(null),
                        borderRadius: BorderRadius.circular(12),
                        child: Container(
                          padding: const EdgeInsets.all(4),
                          decoration: BoxDecoration(
                            color: FlutterFlowTheme.of(context).alternate.withOpacity(0.2),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(Icons.close, size: 14, color: FlutterFlowTheme.of(context).secondaryText),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            const SizedBox(height: 10.0),

            // ── Metric Cards ─────────────────────────────────────────────
            Padding(
              padding: const EdgeInsetsDirectional.only(bottom: 30),
              child: Builder(builder: (context) {
                final cards = [
                  MetricCardWidget(
                    title: 'Current Power Load',
                    value: _currentPowerKw != null ? '${_currentPowerKw!.toStringAsFixed(1)} kW' : '---',
                    subtitle: _selectedMeterUnlinked
                        ? 'Not linked to any device ID'
                        : (_minPowerKw > 0 ? 'Min: ${_minPowerKw.toStringAsFixed(1)} kW' : '---'),
                    subtitleColor: _selectedMeterUnlinked ? Colors.grey : Colors.green,
                    icon: Icons.arrow_upward,
                  ),
                  MetricCardWidget(
                    title: 'Monthly Max Demand',
                    value: _monthlyMaxDemandKw > 0 ? '${_monthlyMaxDemandKw.toStringAsFixed(1)} kW' : '---',
                    subtitle: _selectedMeterUnlinked ? 'Not linked to any device ID' : (_monthlyMaxDemandComparison()?.text ?? '---'),
                    subtitleColor: _selectedMeterUnlinked ? Colors.grey : (_monthlyMaxDemandComparison()?.color ?? Colors.orange),
                    trailingLabel: _selectedMeterUnlinked ? null : _monthlyMaxDemandPeakDayLabel(),
                  ),
                  MetricCardWidget(
                    title: 'Contract Capacity',
                    value: _contractCapacity.toStringAsFixed(1),
                    // Formula: 3 = (2) - (1) → Contract Capacity − Monthly Max Demand
                    // "Remaining" depends on Monthly Max Demand, which has no
                    // reading when unlinked — surface that instead of a
                    // remaining figure computed off a forced-zero value.
                    subtitle: _selectedMeterUnlinked
                        ? 'Not linked to any device ID'
                        : 'Remaining: ${(_contractCapacity - _monthlyMaxDemandKw).toStringAsFixed(1)} kW',
                    subtitleColor: _selectedMeterUnlinked ? Colors.grey : FlutterFlowTheme.of(context).secondaryText,
                    icon: Icons.info_outline,
                  ),
                  MetricCardWidget(
                    title: 'Overload Risk Prediction',
                    // Risk level derives from Monthly Max Demand — without a
                    // linked device that's a forced zero, which would read as
                    // a false "Normal" instead of "no data to assess".
                    value: _selectedMeterUnlinked ? '---' : _getOverloadRiskLevel(),
                    subtitle: _selectedMeterUnlinked
                        ? 'Not linked to any device ID'
                        : '${_calculateOverloadRiskPercentage().toStringAsFixed(1)}% of Contract Capacity',
                    subtitleColor: _selectedMeterUnlinked ? Colors.grey : _getOverloadRiskColor(),
                    icon: Icons.warning_amber_outlined,
                  ),
                  MetricCardWidget(
                    title: 'MD Surcharge',
                    // Surcharge derives from Monthly Max Demand too — same
                    // reasoning: a forced-zero reading would show "RM 0.00",
                    // which reads as "confirmed no charge" rather than
                    // "no data available".
                    value: _selectedMeterUnlinked
                        ? '---'
                        : (_isLoadingBillingConfig ? '---' : 'RM ${_calculateMdSurcharge().toStringAsFixed(2)}'),
                    subtitle: _selectedMeterUnlinked
                        ? 'Not linked to any device ID'
                        : (_isLoadingBillingConfig
                            ? 'Loading rate...'
                            : 'MD Rate: RM ${_mdCapacityCharge.toStringAsFixed(2)}/kW  •  Network: RM ${_mdNetworkCharge.toStringAsFixed(2)}/kW'),
                    icon: Icons.warning_amber_outlined,
                  ),
                ];

                return LayoutBuilder(builder: (context, constraints) {
                  // 5 Expanded columns squeeze into unreadable slivers below
                  // the tablet breakpoint — lay them out as a 2-column wrap
                  // instead, each card kept at a readable minimum width.
                  if (constraints.maxWidth < kBreakpointMedium) {
                    final cardWidth = (constraints.maxWidth - 10) / 2;
                    return Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [for (final c in cards) SizedBox(width: cardWidth, child: c)],
                    );
                  }
                  return Row(
                    children: [
                      for (int i = 0; i < cards.length; i++) ...[
                        if (i > 0) const SizedBox(width: 10),
                        Expanded(child: cards[i]),
                      ],
                    ],
                  );
                });
              }),
            ),

            // ── Row 1 ────────────────────────────────────────────────────
            _chartPairRow(
              420,
              PowerLoadTrendChart(
                title: _selectedTnbMeter?.dashboardConfig.powerLoadTrendLabel ?? '',
                powerLoadData: _powerLoadData,
                isLoading: _isLoadingPowerLoad,
                errorMessage: _powerLoadError,
                onRefresh: _fetchPowerLoadData,
                maxPowerKw: _maxPowerKw,
                contractCapacity: _contractCapacity,
                peakStart: _fmtTimeOfDay(_touStartTime),
                peakEnd: _fmtTimeOfDay(_touEndTime),
                peakDays: _touDays,
              ),
              DailyMaxDemandChart(
                title: _selectedTnbMeter?.dashboardConfig.dailyMaxDemandLabel ?? '',
                chartData: _maxDemandData,
                isLoading: _isLoadingMaxDemand,
                errorMessage: _maxDemandError,
                onRefresh: _fetchMaxDemandData,
                contractCapacity: _contractCapacity,
              ),
            ),
            const SizedBox(height: 16),

            // ── Row 2 ────────────────────────────────────────────────────
            _chartPairRow(
              450,
              PowerLoadDistributionChart(
                distributionData: _avgPowerLoadDistribution,
                isLoading: _isLoadingAvgPowerLoad,
                errorMessage: _avgPowerLoadError,
                onRefresh: _fetchAveragePowerLoadDistribution,
              ),
              YearOnYearAnalysisChart(
                chartData: _yearOnYearData,
                comparisonYearData: _yearOnYearComparisonData,
                isLoading: _isLoadingYearOnYear,
                errorMessage: _yearOnYearError,
                onRefresh: _fetchYearOnYearAnalysis,
                contractCapacity: _contractCapacity,
              ),
            ),
            const SizedBox(height: 16),

            // ── Row 3 — Equipment charts ─────────────────────────────────
            _chartPairRow(
              595, // 👈 IMPORTANT
              EquipmentLoadCorrelationChart(
                title: "Equipment Load Correlation",
                selectedEventDate: _selectedEventDate,
                selectedEventStart: _selectedEventStart,
                selectedEventEnd: _selectedEventEnd,
                seriesData: _correlationSeriesData,
                deviceIds: _correlationDeviceIds,
                deviceNames: _facilityNameByMeterId,
                systemPeak: _correlationSystemPeak,
                isLoading: _isLoadingCorrelation,
                errorMessage: _correlationError,
                selectedInterval: _correlationInterval,
                onIntervalChanged: _onCorrelationIntervalChanged,
                onDateChanged: _onCorrelationDateChanged,
                onRefresh: () {
                  // Re-read Master Facilities so registration changes apply.
                  _facilityMeterIds = null;
                  _facilityNameByMeterId = null;
                  _fetchCorrelationData(
                    eventDate: _selectedEventDate,
                    eventStart: _selectedEventStart,
                    eventEnd: _selectedEventEnd,
                    interval: _correlationInterval,
                  );
                },
                onConfigure: () => _showChartConfigDialog(MaxDemandChartTarget.correlation),
              ),
              EquipmentMdRankingChart(
                title: "Equipment MD Ranking",
                selectedEventDate: _rankingEventDate,
                selectedEventStart: _rankingEventStart,
                selectedEventEnd: _rankingEventEnd,
                rankingData: _mdRankingData,
                isLoading: _isLoadingMdRanking,
                errorMessage: _mdRankingError,
                onRefresh: () {
                  // Re-read Master Facilities so MD Ranking flag changes apply.
                  _mdEnabledDeviceIds = null;
                  _facilityNameByMeterId = null;
                  _fetchMdRankingData(
                    eventDate: _rankingEventDate,
                    eventStart: _rankingEventStart,
                    eventEnd: _rankingEventEnd,
                  );
                },
                onConfigure: () => _showChartConfigDialog(MaxDemandChartTarget.mdRanking),
                onDateChanged: _onMdRankingDateChanged,
              ),
            ),
            const SizedBox(height: 24),

            MaxDemandEventRecordsTable(
              events: _maxDemandEvents,
              isLoading: _isLoadingMaxDemandEvents,
              errorMessage: _maxDemandEventsError,
              onRefresh: _fetchMaxDemandEvents,
              contractCapacity: _contractCapacity,
              highRiskMin: _highRiskMin,
              mediumRiskMin: _mediumRiskMin,
              mediumRiskMax: _mediumRiskMax,
              lowRiskMin: _lowRiskMin,
              lowRiskMax: _lowRiskMax,
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
