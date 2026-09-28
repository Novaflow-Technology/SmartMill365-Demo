import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/auth/firebase_auth/auth_util.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_theme.dart';
import 'package:smartmachine365/flutter_flow/nav/nav.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/energy_system_settings/energy_system_setting_service.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/tnb_meter/tnb_meter_models.dart';
import 'package:smartmachine365/web_app_template/general_factory_setting/tnb_meter/tnb_meter_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/models/facility_data.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';

import 'md_insight_report_colors.dart';
import 'md_insight_report_image_config.dart';
import 'md_insight_report_models.dart';
import 'md_insight_report_pdf_exporter.dart';
import 'md_insight_report_service.dart';
import 'models/equipment_candidate.dart';
import 'models/equipment_row.dart';
import 'models/executive_bullet.dart';
import 'models/report_stat.dart';
import 'widgets/capacity_analysis_section_widget.dart';
import 'widgets/cost_analysis_section_widget.dart';
import 'widgets/equipment_analysis_section_widget.dart';
import 'widgets/executive_summary_section_widget.dart';
import 'widgets/load_analysis_section_widget.dart';
import 'widgets/report_footer_bar_widget.dart';
import 'widgets/report_header_widget.dart';
import 'widgets/report_image_config_dialog.dart';
import 'widgets/report_log_dialog.dart';
import 'widgets/summary_card_widget.dart';
import 'widgets/summary_cards_row_widget.dart';
import 'widgets/trend_analysis_section_widget.dart';

/// MD Insight Report page.
///
/// The top 5 summary cards (Current/Monthly Max Demand, Contract Capacity,
/// MD Status, Estimated MD Surcharge) and the plant/TNB-meter filter are
/// wired to live data using the exact same endpoints/formulas as
/// max_demand_monitoring.dart, so the two pages never disagree. The rest of
/// the report (executive summary bullets, load/trend charts, equipment
/// ranking) comes from [MdInsightReportService.fetchReport] — the computed
/// MD001-404 rule lines from functions/api/mdInsightRulesFunction.js.
/// Equipment attribution (MD401-404) needs `equipment_device_ids` to be
/// passed through once this plant's equipment-to-Influx-device mapping is
/// available; until then it renders as "insufficient data" per spec §5.
class MdInsightReportWidget extends StatefulWidget {
  const MdInsightReportWidget({super.key});

  @override
  State<MdInsightReportWidget> createState() => _MdInsightReportWidgetState();
}

class _MdInsightReportWidgetState extends State<MdInsightReportWidget> {
  bool _isGenerating = false;
  String _generatingStatus = 'Capturing report…';
  // Flutter Web can't run the capture/encode/PDF-build work off the UI
  // thread, so an indeterminate spinner just stutters instead of animating
  // smoothly through it. A determinate bar that jumps between fixed steps
  // reads as "on track" even when it only updates a few times, instead of
  // looking broken.
  double _generatingProgress = 0.0;

  /// Wraps the report body so [_downloadReport] can capture exactly what's
  /// on screen (the full scrollable content, not just the visible viewport)
  /// as an image for the PDF export.
  final GlobalKey _reportBoundaryKey = GlobalKey();

  // ── Live data (mirrors max_demand_monitoring.dart's fetch/formula shape) ──
  List<TnbMeter> _tnbMeters = [];
  List<Map<String, dynamic>> _tnbPlants = [];
  TnbMeter? _selectedTnbMeter;
  String _selectedDeviceId = '';

  // Historical report month ('YYYY-MM'); defaults to the current month.
  // Drives the /md-insight-rules `period` param plus the Monthly Maximum
  // Demand card, so browsing a past month keeps the whole report consistent
  // instead of just the trend chart.
  String _selectedPeriod = _periodStr(DateTime.now());

  double _currentMaxDemandKw = 0.0;
  double _monthlyMaxDemandKw = 0.0;
  double _contractCapacity = 0.0;

  double _mdCapacityCharge = 0.0;
  double _mdNetworkCharge = 0.0;

  double _highRiskMin = 80.0;
  double _mediumRiskMin = 60.0;
  double _lowRiskMin = 0.0;

  // Peak Hour ToU window (contractCapacity.peakHourToU) — same source as
  // Max Demand Monitoring's TOU settings; used to restrict MD301's "first
  // exceeded" scan to peak-hour readings.
  String? _peakStart;
  String? _peakEnd;
  List<int> _peakDays = const [];

  // True once a closed month's canonical `source='auto'` log row has been
  // loaded into the fields above instead of recomputing them live — see
  // _tryLoadLockedSnapshot. The fields below are the *current live*
  // settings (kept in sync every time the fields above are set from a real
  // live fetch) so a locked period's frozen numbers can be restored back to
  // live the moment the user picks an unlocked period again — without this
  // shadow copy, a locked month's contract capacity/tariff/thresholds would
  // otherwise leak into later live views, since those fields aren't
  // normally re-fetched on every period switch (only _monthlyMaxDemandKw
  // and _report are).
  bool _isLockedSnapshot = false;
  double _liveContractCapacity = 0.0;
  double _liveMdCapacityCharge = 0.0;
  double _liveMdNetworkCharge = 0.0;
  double _liveHighRiskMin = 80.0;
  double _liveMediumRiskMin = 60.0;
  double _liveLowRiskMin = 0.0;
  String? _livePeakStart;
  String? _livePeakEnd;
  List<int> _livePeakDays = const [];

  MdInsightReportImageConfig _imageConfig = const MdInsightReportImageConfig();

  // ── Computed MD001-404 rules + supporting chart/table data ───────────────
  MdInsightReport _report = MdInsightReport.empty;
  int _reportRequestSeq = 0;
  bool _isLoadingReport = false;
  String _loadingOverlayMessage = 'Loading report…';

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _fetchTnbMeters();
    _loadImageConfig();
  }

  Future<void> _loadImageConfig() async {
    // Shared across every user of this client, not per-login — see
    // AppConfig.sharedConfigOwnerId.
    final config = await MdInsightReportImageConfigService.getConfig(
        AppConfig.sharedConfigOwnerId);
    if (mounted) setState(() => _imageConfig = config);
  }

  /// Opens the "Report Settings" editor — the two configurable images
  /// (plant-status background photo, footer brand logo) plus the current
  /// plant's Equipment Analysis ranking checklist — then persists the
  /// result per-tenant via [MdInsightReportImageConfigService].
  Future<void> _showImageConfigDialog() async {
    final plantCode = _currentPlantCode;
    final candidates = await _resolveEquipmentCandidates();
    if (!mounted) return;
    final result = await ReportImageConfigDialog.show(
      context,
      _imageConfig,
      plantCode: plantCode,
      equipmentCandidates: candidates,
      currentRanking: _equipmentRanking,
    );
    if (result == null) return;

    // Covers the whole save-then-refresh flow below, not just the dialog's
    // own upload spinner — without this the dialog closes instantly and
    // the page shows no feedback while the config POST and ranking
    // re-fetch are still in flight.
    setState(() {
      _isLoadingReport = true;
      _loadingOverlayMessage = 'Saving settings…';
    });

    final ok = await MdInsightReportImageConfigService.saveConfig(
        AppConfig.sharedConfigOwnerId, result);
    if (!mounted) return;
    if (ok) {
      setState(() => _imageConfig = result);
      // The equipment checklist may have changed — re-render the ranking
      // immediately rather than waiting for the next plant/period switch.
      // Skipped while viewing a locked historical month: that record must
      // stay frozen, not recompute against the just-edited exclusions.
      if (!_isLockedSnapshot) await _fetchMdInsightReport();
    }
    if (mounted) setState(() => _isLoadingReport = false);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
            ok ? 'Report settings updated.' : 'Failed to save report settings.')));
  }

  /// Opens the "View Logs" dialog, scoped to the currently selected plant.
  Future<void> _showLogsDialog() async {
    final plantCode = _currentPlantCode;
    await ReportLogDialog.show(context,
        plantCode: plantCode.isNotEmpty ? plantCode : null);
  }

  // ── Fetching ──────────────────────────────────────────────────────────────

  Future<void> _fetchTnbMeters() async {
    try {
      final results = await Future.wait([
        TnbMeterService.fetchMeters(),
        TnbMeterService.fetchPlants(),
      ]);
      if (!mounted) return;
      setState(() {
        _tnbMeters =
            (results[0] as List<TnbMeter>).where((m) => m.isActive).toList();
        _tnbPlants = results[1] as List<Map<String, dynamic>>;
      });
      // Open on the first registered meter, same as Max Demand Monitoring,
      // so the report's device scope matches what that page shows by default.
      if (_tnbMeters.isNotEmpty && _selectedTnbMeter == null) {
        _onTnbMeterSelected(_tnbMeters.first);
      }
    } catch (e) {
      debugPrint('MdInsightReport: error fetching TNB meters: $e');
    }
  }

  Future<void> _onTnbMeterSelected(TnbMeter meter) async {
    setState(() {
      _selectedTnbMeter = meter;
      if (meter.influxDbTag.isNotEmpty) _selectedDeviceId = meter.influxDbTag;
      // Clear any override left by a previously-viewed locked period before
      // applying this meter's own live contract capacity — otherwise a
      // stale locked value could momentarily outlive the plant switch.
      _restoreLiveSettings();
      if (meter.contractMdKw > 0) {
        _contractCapacity = meter.contractMdKw;
        _liveContractCapacity = meter.contractMdKw;
      }
      _isLoadingReport = true;
      _loadingOverlayMessage = 'Loading report…';
      _isLockedSnapshot = false;
    });
    // _fetchCurrentMaxDemand is period-independent (always "right now"), so
    // it always runs. The rest only run live if [_selectedPeriod] isn't a
    // closed month with its own locked snapshot — _fetchBillingConfig
    // chains _fetchMdInsightReport at its end (it needs the resolved
    // mdRate), so waiting on it covers the report fetch too.
    final locked = await _tryLoadLockedSnapshot();
    await Future.wait([
      if (!locked) _fetchBillingConfig(),
      if (!locked) _fetchMonthlyMaxDemand(),
      _fetchCurrentMaxDemand(),
    ]);
    if (mounted) setState(() => _isLoadingReport = false);
  }

  /// Contract capacity fallback (used until/unless the selected TNB meter
  /// has its own contractMdKw) and the overload-risk thresholds that drive
  /// the MD Status label — same source and shape as
  /// max_demand_monitoring.dart's `_loadSettings`.
  Future<void> _loadSettings() async {
    final userUid = AppStateNotifier.instance.uid ?? '';
    try {
      final response = await EnergySystemSettingsService.getSettings(userUid);
      if (!mounted) return;
      if (response['exists'] == true && response['settings'] != null) {
        final settings = response['settings'];
        if (settings['contractCapacity'] != null) {
          final cc = settings['contractCapacity'];
          setState(() {
            _contractCapacity =
                cc['contractCapacity']?.toDouble() ?? _contractCapacity;
            _liveContractCapacity = _contractCapacity;
          });
          if (cc['peakHourToU'] != null) {
            final tou = cc['peakHourToU'] as Map<String, dynamic>;
            setState(() {
              _peakStart = tou['startTime'] as String?;
              _peakEnd = tou['endTime'] as String?;
              _peakDays = tou['days'] != null
                  ? List<int>.from(tou['days'] as List)
                  : const [];
              _livePeakStart = _peakStart;
              _livePeakEnd = _peakEnd;
              _livePeakDays = _peakDays;
            });
          }
        }
        if (settings['overloadRiskLevel'] != null) {
          final r = settings['overloadRiskLevel'];
          setState(() {
            _highRiskMin = r['highRiskMin']?.toDouble() ?? 80.0;
            _mediumRiskMin = r['mediumRiskMin']?.toDouble() ?? 60.0;
            _lowRiskMin = r['lowRiskMin']?.toDouble() ?? 0.0;
            _liveHighRiskMin = _highRiskMin;
            _liveMediumRiskMin = _mediumRiskMin;
            _liveLowRiskMin = _lowRiskMin;
          });
        }
      }
    } catch (e) {
      debugPrint('MdInsightReport: error loading settings: $e');
    }
    await _fetchMdInsightReport();
  }

  /// Same Overall_monthly_energy_consumption.max_demand_kW the TNB E3 Bill
  /// Simulator and Max Demand Monitoring's "Monthly Max Demand" card read,
  /// scoped to [_selectedPeriod] so browsing a historical report month
  /// updates this card (and everything derived from it: MD Status, Estimated
  /// Surcharge, Capacity/Cost Analysis) instead of always showing the
  /// current month.
  Future<void> _fetchMonthlyMaxDemand() async {
    if (_selectedDeviceId.isEmpty) return;
    try {
      final parts = _selectedPeriod.split('-');
      final uri = Uri.parse(
              '${AppConfig.dataApiBaseSafe}/energyComparison/tnb-bill-simulator/$_selectedDeviceId')
          .replace(queryParameters: {'year': parts[0], 'month': parts[1]});
      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        setState(() {
          _monthlyMaxDemandKw =
              double.tryParse(data['max_demand_kW'].toString()) ?? 0.0;
        });
      }
    } catch (e) {
      debugPrint('MdInsightReport: error fetching monthly max demand: $e');
    }
  }

  /// Latest Overall_hourly_energy_consumption.max_demand_kW row for the
  /// selected device — the same power-load-24h endpoint Max Demand
  /// Monitoring uses, but reading the most recent single reading instead of
  /// the 24h peak, per the "Current Maximum Demand" spec.
  Future<void> _fetchCurrentMaxDemand() async {
    if (_selectedDeviceId.isEmpty) return;
    try {
      final uri = Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/power-load-24h/$_selectedDeviceId');
      final response = await http.get(uri, headers: AppConfig.headers);
      if (!mounted) return;
      if (response.statusCode != 200) return;
      final data = json.decode(response.body) as Map<String, dynamic>;
      final list = (data['data'] as List?) ?? [];
      double latest = 0.0;
      if (list.isNotEmpty) {
        final last = list.last as Map<String, dynamic>;
        latest = double.tryParse(last['max_demand_kW'].toString()) ?? 0.0;
      }
      if (latest <= 0) {
        final stats = data['statistics'] as Map<String, dynamic>?;
        latest = double.tryParse((stats?['current_max_demand_kW'] ??
                    stats?['max_demand_kW'] ??
                    0)
                .toString()) ??
            0.0;
      }
      setState(() => _currentMaxDemandKw = latest);
    } catch (e) {
      debugPrint('MdInsightReport: error fetching current max demand: $e');
    }
  }

  /// MD capacity/network rates resolved off the selected TNB meter's
  /// tariff category — same resolution order (meter category → active →
  /// electricityTariff.capacityRate fallback) as
  /// max_demand_monitoring.dart's `_fetchBillingConfig`, so the MD Surcharge
  /// figure never disagrees between the two pages.
  Future<void> _fetchBillingConfig() async {
    try {
      // Billing config is shared across every user of this client, not
      // per-login — see AppConfig.sharedConfigOwnerId.
      const userUid = AppConfig.sharedConfigOwnerId;
      final meterCategoryId = _selectedTnbMeter?.tariffCategoryId.trim() ?? '';

      // NOTE: masterBillingConfig/electricityTariff live on the ui7 data API
      // (same host master_billing_config_widget.dart saves to), not the ic7
      // CRUD API — using ic7 here silently returns empty config forever.
      // The x-client-id header is required too: the backend resolves the
      // tenant Firestore from it, so an unheadered request always reports
      // "no config found" even when one exists for the active client.
      final results = await Future.wait([
        meterCategoryId.isNotEmpty
            ? http.get(
                Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/$meterCategoryId'),
                headers: AppConfig.headers)
            : http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/active'),
                headers: AppConfig.headers),
        http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/electricityTariff'),
            headers: AppConfig.headers),
      ]);
      if (!mounted) return;
      var response = results[0];
      final tariffResponse = results[1];

      if (meterCategoryId.isNotEmpty && response.statusCode != 200) {
        response = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/masterBillingConfig/$userUid/active'),
            headers: AppConfig.headers);
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
        final rate = (config?['mdCapacityCharge'] != null
                ? double.tryParse(config!['mdCapacityCharge'].toString())
                : null) ??
            capacityRate;
        final networkRate = config?['mdNetworkCharge'] != null
            ? double.tryParse(config!['mdNetworkCharge'].toString())
            : null;
        if (rate != null || networkRate != null) {
          setState(() {
            if (rate != null) {
              _mdCapacityCharge = rate;
              _liveMdCapacityCharge = rate;
            }
            if (networkRate != null) {
              _mdNetworkCharge = networkRate;
              _liveMdNetworkCharge = networkRate;
            }
          });
        }
      }
    } catch (e) {
      debugPrint('MdInsightReport: error fetching billing config: $e');
    }
    await _fetchMdInsightReport();
  }

  /// Resolves every candidate Influx device tag that could count as
  /// "equipment" for the selected meter's plant, for MD401-404's equipment
  /// attribution.
  ///
  /// Primary source: Master Facilities records registered directly against
  /// one of the meter's bound production areas (meter.boundAreaIds —
  /// actually each area's `factory_id`, e.g. "SITE001", not the area's own
  /// `id` — translated to production-area display names via
  /// `/productionAreas`, then matched against FacilityData.productionArea,
  /// which stores the name). This picks up every device the admin
  /// registered for this plant, regardless of whether it also has a
  /// matching Equipment record — previously the resolver only walked
  /// Equipment -> Facility, so a facility with no Equipment counterpart (or
  /// a stale equipmentId/name link) silently never appeared in the
  /// contribution table even though it was clearly "in this plant" per
  /// Master Facilities.
  ///
  /// Fallback: equipment bound to the same areas (EquipmentItem
  /// .productionArea), cross-referenced to its Master Facility record by
  /// equipmentId/name/displayLabel — same match-by-equipmentId/name/
  /// displayLabel resolution max_demand_monitoring.dart's
  /// `_resolveScopedDeviceIds` uses for its Equipment MD Ranking chart.
  /// Catches facilities whose own `productionArea` field is blank/stale but
  /// whose linked Equipment record still carries the right area. Both
  /// sources feed the same tag map, so a device counted by either one shows
  /// up exactly once.
  ///
  /// Deliberately without max_demand_monitoring's fleet-wide fallback,
  /// since this report is already scoped to one plant and pulling in
  /// unrelated equipment would misattribute peak demand.
  ///
  /// This is every *candidate* — [_resolveEquipmentDeviceIds] is the one
  /// that actually gets sent to the report fetch, after subtracting
  /// whatever this plant's "Configure Images" settings dialog excluded.
  Future<List<MdEquipmentCandidate>> _resolveEquipmentCandidates() async {
    final meter = _selectedTnbMeter;
    if (meter == null || meter.boundAreaIds.isEmpty) return const [];
    try {
      final results = await Future.wait([
        FacilityService.getEquipments(),
        FacilityService.getFacilities(),
        FacilityService.getProductionAreas(),
      ]);
      final equipments = results[0] as List<EquipmentItem>;
      final facilities = results[1] as List<FacilityData>;
      final productionAreas = results[2] as List<Map<String, dynamic>>;

      final facilityByKey = <String, FacilityData>{};
      for (final f in facilities) {
        for (final key in [f.meterId.trim(), f.meterName.trim(), f.equipmentNameId.trim()]) {
          if (key.isNotEmpty) facilityByKey[key] = f;
        }
      }

      // meter.boundAreaIds actually stores each production area's
      // `factory_id` (e.g. "SITE001" — a plant/site code), NOT the
      // production area's own `id` (e.g. "ZONE001"). EquipmentItem
      // .productionArea stores the area's display `name` (e.g. "Block A
      // Production Area"). So the real chain is: boundAreaIds (factory_id)
      // -> productionAreas whose factory_id matches -> those areas' `name`
      // -> compare against equipment.productionArea. Raw ids and direct
      // id->name are also folded in as fallbacks for records that already
      // match one of those simpler forms.
      final areaNameById = <String, String>{
        for (final a in productionAreas) (a['id']?.toString() ?? ''): (a['name']?.toString() ?? ''),
      };
      final namesByFactoryId = <String, Set<String>>{};
      for (final a in productionAreas) {
        final factoryId = a['factory_id']?.toString() ?? '';
        final name = a['name']?.toString() ?? '';
        if (factoryId.isNotEmpty && name.isNotEmpty) {
          namesByFactoryId.putIfAbsent(factoryId, () => {}).add(name);
        }
      }
      final boundAreas = meter.boundAreaIds.toSet();
      final boundAreaMatchSet = <String>{
        ...boundAreas,
        for (final id in boundAreas)
          if ((areaNameById[id] ?? '').isNotEmpty) areaNameById[id]!,
        for (final id in boundAreas) ...?namesByFactoryId[id],
      };

      final candidatesByTag = <String, MdEquipmentCandidate>{};

      // Primary: Master Facilities rows registered directly for this
      // plant's production areas.
      for (final f in facilities.where((f) => boundAreaMatchSet.contains(f.productionArea))) {
        final tag = f.meterId.trim();
        if (tag.isEmpty) continue;
        final label = f.meterName.trim().isNotEmpty ? f.meterName.trim() : tag;
        candidatesByTag.putIfAbsent(tag, () => MdEquipmentCandidate(tag, label));
      }

      // Fallback: equipment bound to the same areas, resolved to its
      // Master Facility record.
      final scopedEquipments = equipments.where((e) => boundAreaMatchSet.contains(e.productionArea));
      for (final e in scopedEquipments) {
        final match = facilityByKey[e.equipmentId.trim()] ??
            facilityByKey[e.name.trim()] ??
            facilityByKey[e.displayLabel.trim()];
        final tag = match?.meterId.trim() ?? '';
        if (tag.isEmpty) continue;
        // Label by the same field the backend relabels the ranking's rows
        // with (master_facilities.meterName — mdInsightReportBuilder.js's
        // displayNameByDeviceId), not EquipmentItem.displayLabel, so a
        // candidate in this settings checklist reads with the exact same
        // name it has in the Equipment Analysis ranking table. Falls back
        // to displayLabel only when meterName is blank.
        final label = match!.meterName.trim().isNotEmpty
            ? match.meterName.trim()
            : e.displayLabel;
        candidatesByTag.putIfAbsent(tag, () => MdEquipmentCandidate(tag, label));
      }
      return candidatesByTag.values.toList();
    } catch (e) {
      debugPrint('MdInsightReport: error resolving equipment candidates: $e');
      return const [];
    }
  }

  /// Equipment device tags actually sent to the report fetch: every
  /// candidate [_resolveEquipmentCandidates] resolves for this plant, minus
  /// whatever's excluded for [_currentPlantCode] in the "Configure Images"
  /// settings dialog.
  Future<List<String>> _resolveEquipmentDeviceIds() async {
    final candidates = await _resolveEquipmentCandidates();
    final excluded =
        _imageConfig.excludedEquipmentByPlant[_currentPlantCode] ?? const [];
    if (excluded.isEmpty) return candidates.map((c) => c.tag).toList();
    final excludedSet = excluded.toSet();
    return candidates
        .map((c) => c.tag)
        .where((tag) => !excludedSet.contains(tag))
        .toList();
  }

  /// Fetches the computed MD001-404 rule lines + supporting chart/table data
  /// for the selected meter. Needs [_contractCapacity] and [_mdRate] already
  /// resolved, so this is called after `_fetchBillingConfig` (and again after
  /// `_loadSettings`, in case contract capacity arrives from there instead).
  Future<void> _fetchMdInsightReport() async {
    if (_selectedDeviceId.isEmpty || _contractCapacity <= 0) return;
    final seq = ++_reportRequestSeq;
    final equipmentIds = await _resolveEquipmentDeviceIds();
    if (!mounted || seq != _reportRequestSeq) return;
    final report = await MdInsightReportService.fetchReport(
      deviceId: _selectedDeviceId,
      cc: _contractCapacity,
      mdRate: _mdRate,
      period: _selectedPeriod,
      equipmentDeviceIds: equipmentIds,
      peakStart: _peakStart,
      peakEnd: _peakEnd,
      peakDays: _peakDays,
    );
    if (!mounted || seq != _reportRequestSeq || report == null) return;
    setState(() => _report = report);
  }

  /// Checks whether [_selectedPeriod] has a canonical locked snapshot
  /// (`source='auto'`, written by the monthly rollup at month-end) for the
  /// currently selected plant, and if so loads it in place of a live fetch
  /// — so a closed month always shows exactly what it showed when the
  /// snapshot was taken, immune to later settings changes. Returns true iff
  /// a snapshot was applied; false means the caller should fall back to the
  /// normal live fetch/recompute path (e.g. the current, still-open month,
  /// or any plant/period the rollup hasn't reached yet).
  Future<bool> _tryLoadLockedSnapshot() async {
    final plantCode = _currentPlantCode;
    if (plantCode.isEmpty) return false;

    final entry = await MdInsightReportService.fetchLockedSnapshot(
      plantCode: plantCode,
      period: _selectedPeriod,
    );
    final payload = entry?.payloadJson;
    final reportJson = (payload?['report'] as Map?)?.cast<String, dynamic>();
    final inputs = (payload?['inputs'] as Map?)?.cast<String, dynamic>();
    if (reportJson == null || inputs == null) return false;
    if (!mounted) return true;

    setState(() {
      _report = MdInsightReport.fromJson(reportJson);
      _contractCapacity =
          (inputs['contract_capacity_kw'] as num?)?.toDouble() ??
              _liveContractCapacity;
      _mdCapacityCharge =
          (inputs['md_capacity_charge'] as num?)?.toDouble() ?? 0.0;
      _mdNetworkCharge =
          (inputs['md_network_charge'] as num?)?.toDouble() ?? 0.0;
      _peakStart = inputs['peak_start']?.toString();
      _peakEnd = inputs['peak_end']?.toString();
      _peakDays = inputs['peak_days'] != null
          ? List<int>.from(inputs['peak_days'] as List)
          : const [];
      _highRiskMin =
          (inputs['high_risk_min'] as num?)?.toDouble() ?? _liveHighRiskMin;
      _mediumRiskMin = (inputs['medium_risk_min'] as num?)?.toDouble() ??
          _liveMediumRiskMin;
      _lowRiskMin =
          (inputs['low_risk_min'] as num?)?.toDouble() ?? _liveLowRiskMin;
      _monthlyMaxDemandKw =
          (inputs['monthly_max_demand_kw'] as num?)?.toDouble() ?? 0.0;
      _isLockedSnapshot = true;
    });
    return true;
  }

  /// Restores the live plant-level settings (contract capacity, tariff
  /// rate, Peak Hour ToU, risk thresholds) after leaving a locked period —
  /// see the shadow-field doc comment on [_isLockedSnapshot] for why this
  /// is needed instead of just letting the per-period fetches run.
  void _restoreLiveSettings() {
    _contractCapacity = _liveContractCapacity;
    _mdCapacityCharge = _liveMdCapacityCharge;
    _mdNetworkCharge = _liveMdNetworkCharge;
    _peakStart = _livePeakStart;
    _peakEnd = _livePeakEnd;
    _peakDays = _livePeakDays;
    _highRiskMin = _liveHighRiskMin;
    _mediumRiskMin = _liveMediumRiskMin;
    _lowRiskMin = _liveLowRiskMin;
  }

  // ── Derived values ────────────────────────────────────────────────────────

  /// Same fallback used to scope `md_insight_report_log` rows
  /// (`_logReportGeneration`, `_showLogsDialog`) and now also the
  /// per-plant Equipment Analysis exclusion list.
  String get _currentPlantCode =>
      _selectedTnbMeter?.meterCode ?? _selectedDeviceId;

  double get _currentPct => _contractCapacity > 0
      ? (_currentMaxDemandKw / _contractCapacity) * 100
      : 0.0;
  double get _monthlyPct => _contractCapacity > 0
      ? (_monthlyMaxDemandKw / _contractCapacity) * 100
      : 0.0;
  double get _excessKw =>
      (_monthlyMaxDemandKw - _contractCapacity).clamp(0, double.infinity);
  double get _mdRate => _mdCapacityCharge + _mdNetworkCharge;
  double get _totalSurcharge => _monthlyMaxDemandKw * _mdRate;

  /// Same thresholds/logic as max_demand_monitoring.dart's
  /// `_getOverloadRiskLevel`, just upper-cased to match this report's card
  /// styling (design mock shows "CRITICAL", not "Critical").
  String get _mdStatusLabel {
    final p = _monthlyPct;
    if (p >= 100) return 'CRITICAL';
    if (p >= _highRiskMin) return 'HIGH';
    if (p >= _mediumRiskMin) return 'MEDIUM';
    if (p >= _lowRiskMin) return 'LOW';
    return 'NORMAL';
  }

  Color get _mdStatusColor {
    switch (_mdStatusLabel) {
      case 'CRITICAL':
        return MdReportColors.red;
      case 'HIGH':
      case 'MEDIUM':
        return MdReportColors.orange;
      default:
        return MdReportColors.green;
    }
  }

  String _meterLabel(TnbMeter m) {
    final plantLabel =
        m.plantId.isNotEmpty ? '${_tnbPlantName(m.plantId)} — ' : '';
    return '$plantLabel${m.meterLabel.isNotEmpty ? m.meterLabel : m.meterCode}';
  }

  String _tnbPlantName(String plantId) {
    final p =
        _tnbPlants.firstWhereOrNull((p) => p['id']?.toString() == plantId);
    return p?['name']?.toString() ?? plantId;
  }

  String _fmtKw(double v) => v > 0 ? '${v.toStringAsFixed(1)} kW' : '---';

  // ── Report-driven view helpers (spec §6 date/number formatting, applied
  // client-side here to match exactly how the backend renders each rule's
  // `text`) ──────────────────────────────────────────────────────────────────

  static const _months = [
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];

  String _fmtIsoDate(String iso) {
    final parts = iso.split('-');
    if (parts.length != 3) return iso;
    final y = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 1;
    final d = int.tryParse(parts[2]) ?? 1;
    return '$d ${_months[(m - 1).clamp(0, 11)]} $y';
  }

  String _fmtThousands(num n) {
    final rounded = n.round();
    final s = rounded.abs().toString();
    final buf = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return (rounded < 0 ? '-' : '') + buf.toString();
  }

  IconData _bulletIcon(String ruleId) {
    switch (ruleId) {
      case 'MD002':
        return Icons.attach_money_rounded;
      case 'MD003':
        return Icons.schedule_rounded;
      case 'MD004':
        return Icons.groups_rounded;
      case 'MD005':
        return Icons.show_chart_rounded;
      case 'MD006':
        return Icons.format_list_bulleted_rounded;
      default:
        return Icons.warning_amber_rounded;
    }
  }

  Color _bulletColor(String ruleId) {
    switch (ruleId) {
      case 'MD002':
        return MdReportColors.green;
      case 'MD003':
        return MdReportColors.orange;
      case 'MD004':
        return MdReportColors.blue;
      case 'MD005':
        return MdReportColors.purple;
      case 'MD006':
        return MdReportColors.teal;
      default:
        return MdReportColors.red;
    }
  }

  /// The formatted number/word each rule's sentence should highlight — found
  /// by locating the exact formatted value (not by guessing from wording, so
  /// it still works if the DB-editable template text changes).
  String? _highlightMarker(MdRuleLine rule) {
    switch (rule.ruleId) {
      case 'MD001':
        final v = rule.numValue('excess_pct');
        return v != null ? '${v.toStringAsFixed(1)}%' : null;
      case 'MD002':
        final v = rule.numValue('surcharge');
        return v != null ? 'RM ${_fmtThousands(v)}' : null;
      case 'MD003':
        return rule.strValue('shift');
      case 'MD004':
        final v = rule.numValue('shift_pct');
        return v != null ? '${v.toStringAsFixed(1)}%' : null;
      case 'MD005':
        final d = rule.strValue('date');
        return d != null ? _fmtIsoDate(d) : null;
      case 'MD006':
        final v = rule.numValue('top10_pct');
        return v != null ? '${v.toStringAsFixed(1)}%' : null;
      default:
        return null;
    }
  }

  /// Executive Summary bullets built from the live MD001-006 rule lines
  /// (whichever ones aren't `insufficient_data`). MD007 (plant-status
  /// headline) is deliberately excluded — its text duplicates the separate
  /// Plant Status glass panel shown alongside these bullets.
  List<ExecutiveBullet> get _executiveBullets {
    return _report
        .section('executive_summary')
        .where((r) => r.ruleId != 'MD007' && r.text != null)
        .map((r) {
      final text = r.text!;
      final marker = _highlightMarker(r);
      final idx = marker != null ? text.indexOf(marker) : -1;
      if (idx < 0) {
        return ExecutiveBullet(
            icon: _bulletIcon(r.ruleId),
            color: _bulletColor(r.ruleId),
            prefix: text,
            highlight: '',
            suffix: '');
      }
      return ExecutiveBullet(
        icon: _bulletIcon(r.ruleId),
        color: _bulletColor(r.ruleId),
        prefix: text.substring(0, idx),
        highlight: marker!,
        suffix: text.substring(idx + marker.length),
      );
    }).toList();
  }

  String get _plantStatusMessage {
    switch (_mdStatusLabel) {
      case 'CRITICAL':
        return 'Immediate action recommended to avoid further MD charges.';
      case 'HIGH':
        return 'Demand is approaching contract capacity — monitor closely.';
      case 'MEDIUM':
        return 'Demand is trending upward within contract capacity.';
      default:
        return 'Demand is comfortably within contract capacity.';
    }
  }

  // LineAreaChart derives minX/maxX from values.length - 1 (invalid if empty)
  // and draws an isCurved line, whose spline math needs at least 2 points to
  // compute a tangent — a single-point list still throws NaN internally. Two
  // zero points keep the chart valid while looking sensibly empty.
  // LineAreaChart derives minX/maxX from values.length - 1 (invalid if empty)
  // and draws an isCurved line, whose spline math needs at least 2 points to
  // compute a tangent — a single-point list still throws NaN internally.
  // Repeating the one real value (rather than forcing zeros) keeps an early-
  // month "only one day/block logged so far" series showing its real level.
  List<double> _atLeastTwoPoints(List<double> v) {
    if (v.isEmpty) return const [0.0, 0.0];
    if (v.length == 1) return [v[0], v[0]];
    return v;
  }

  List<double> get _loadTrendValues =>
      _atLeastTwoPoints(_report.loadAnalysis?.hourlyValues ?? const []);

  List<ReportStat> get _loadAnalysisStats {
    final la = _report.loadAnalysis;
    if (la == null) {
      return const [
        ReportStat('Peak Period', '—'),
        ReportStat('Peak Load', '—'),
        ReportStat('Peak Duration', '—'),
        ReportStat('Avg. During Peak', '—'),
        ReportStat('Shift Contribution', '—'),
      ];
    }
    final s = la.stats;
    final hrs = s.peakDurationHours.floor();
    final mins = ((s.peakDurationHours - hrs) * 60).round();
    final durationLabel = hrs > 0 ? '$hrs hr ${mins}min' : '$mins min';
    final hasShift = s.dominantShiftName != null && s.dominantShiftPct != null;
    return [
      ReportStat('Peak Period', s.peakPeriod),
      ReportStat('Peak Load', '${s.peakLoadKw.toStringAsFixed(0)} kW'),
      ReportStat('Peak Duration', durationLabel),
      ReportStat(
          'Avg. During Peak', '${s.avgDuringPeakKw.toStringAsFixed(0)} kW'),
      ReportStat(
        hasShift ? '${s.dominantShiftName} Contribution' : 'Shift Contribution',
        hasShift ? '${s.dominantShiftPct!.toStringAsFixed(1)}%' : '—',
      ),
    ];
  }

  List<double> get _dailyTrendValues =>
      _atLeastTwoPoints(_report.dailySeries.map((d) => d.value).toList());

  static const _monthAbbrevs = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec'
  ];

  String get _monthAbbrev {
    if (_report.dailySeries.isEmpty) return '';
    final parts = _report.dailySeries.first.date.split('-');
    final m = parts.length >= 2 ? int.tryParse(parts[1]) : null;
    return (m != null && m >= 1 && m <= 12) ? _monthAbbrevs[m - 1] : '';
  }

  static String _periodStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}';

  /// Last 12 months (this month first) offered in the history dropdown.
  List<String> get _periodOptionValues {
    final now = DateTime.now();
    return [for (int i = 0; i < 12; i++) _periodStr(DateTime(now.year, now.month - i, 1))];
  }

  /// 'YYYY-MM' -> 'Jul 2026'.
  String _periodLabelFor(String period) {
    final parts = period.split('-');
    if (parts.length != 2) return period;
    final m = int.tryParse(parts[1]);
    final abbrev = (m != null && m >= 1 && m <= 12) ? _monthAbbrevs[m - 1] : '';
    return '$abbrev ${parts[0]}';
  }

  Future<void> _onPeriodSelected(String period) async {
    if (period == _selectedPeriod) return;
    setState(() {
      _selectedPeriod = period;
      // Clear any previous locked-period override up front — see
      // _restoreLiveSettings's doc comment — before checking whether the
      // newly selected period has its own lock.
      _restoreLiveSettings();
      _isLockedSnapshot = false;
      _isLoadingReport = true;
      _loadingOverlayMessage = 'Loading report…';
    });
    final locked = await _tryLoadLockedSnapshot();
    if (!locked) {
      await Future.wait([
        _fetchMonthlyMaxDemand(),
        _fetchMdInsightReport(),
      ]);
    }
    if (mounted) setState(() => _isLoadingReport = false);
  }

  List<ReportStat> get _trendAnalysisStats {
    final md301 = _report.rule('MD301');
    final md302 = _report.rule('MD302');
    final md303 = _report.rule('MD303');
    final md304 = _report.rule('MD304');

    final since = (md301 != null &&
            md301.status == 'ok' &&
            md301.strValue('date') != null)
        ? _fmtIsoDate(md301.strValue('date')!)
        : 'None recorded';

    var vsLastMonth = '—';
    if (md302 != null && md302.status == 'ok') {
      final pct = md302.numValue('mom_pct');
      final dir = md302.strValue('direction');
      if (pct != null && dir != null) {
        vsLastMonth = '${dir == 'up' ? '+' : '-'}${pct.toStringAsFixed(1)}%';
      }
    }

    final highestThisYear = (md303 != null &&
            md303.status == 'ok' &&
            md303.numValue('value') != null)
        ? '${md303.numValue('value')!.toStringAsFixed(0)} kW'
        : '—';

    final daysExceeded = (md304 != null &&
            md304.status == 'ok' &&
            md304.numValue('days') != null)
        ? '${md304.numValue('days')!.toStringAsFixed(0)} Days'
        : '0 Days';

    return [
      ReportStat('Above Contract Since', since),
      ReportStat('vs Last Month', vsLastMonth),
      ReportStat('Highest MD This Year', highestThisYear),
      ReportStat('Days Exceeded Contract', daysExceeded),
    ];
  }

  List<EquipmentRow> get _equipmentRanking =>
      (_report.equipmentRanking?.rows ?? const [])
          .map((r) => EquipmentRow(r.name, r.value, r.pct))
          .toList();

  double get _equipmentTotalKw => _report.equipmentRanking?.totalKw ?? 0;

  double get _equipmentTotalPct => double.parse(
      (_report.equipmentRanking?.totalPct ?? 0).toStringAsFixed(1));

  /// MD402-404's rendered sentences, reused verbatim as the Equipment
  /// Analysis panel's "Key Insights" (MD401's line is skipped here since it's
  /// already shown in the ranking table above).
  List<String> get _keyInsights => _report
      .section('equipment_analysis')
      .where((r) => r.ruleId != 'MD401' && r.text != null)
      .map((r) => r.text!)
      .toList();

  /// Falls back to today's date (still spelled per §6) while the report is
  /// still loading, rather than showing a blank header.
  String get _reportDateLabel {
    if (_report.reportDateLabel.isNotEmpty) return _report.reportDateLabel;
    final now = DateTime.now();
    return _fmtIsoDate(
        '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}');
  }

  String get _periodLabel =>
      _report.periodLabel.isNotEmpty ? _report.periodLabel : _reportDateLabel;

  String get _lastUpdatedLabel {
    final now = DateTime.now();
    final hh = now.hour.toString().padLeft(2, '0');
    final mm = now.minute.toString().padLeft(2, '0');
    return 'Last Updated: $_reportDateLabel $hh:$mm';
  }

  static const List<String> _footerNotes = [
    '1. All data shown is based on meter readings.',
    '2. MD Surcharge is estimated based on current tariff and excess demand.',
  ];
  static const String _dataSourceLabel = 'Energy Management System';
  static const String _generatedByLabel = 'SF365 BI Engine';

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final plantOptions = _tnbMeters.isNotEmpty
        ? _tnbMeters.map(_meterLabel).toList()
        : ['No plant configured'];
    final selectedPlant = _selectedTnbMeter != null
        ? _meterLabel(_selectedTnbMeter!)
        : plantOptions.first;

    final periodValues = _periodOptionValues;
    final periodLabels = periodValues.map(_periodLabelFor).toList();
    final selectedPeriodLabel = _periodLabelFor(_selectedPeriod);

    return Scaffold(
      backgroundColor: theme.primaryBackground,
      body: Stack(
        children: [
          SingleChildScrollView(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 32),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Outside the RepaintBoundary below on purpose — the plant
                // filter and Download button are on-screen controls, not
                // report content, so they shouldn't end up baked into the
                // exported PDF image.
                ReportHeader(
                  reportDateLabel: _reportDateLabel,
                  periodLabel: _periodLabel,
                  plantOptions: plantOptions,
                  selectedPlant: selectedPlant,
                  onPlantChanged: (label) {
                    final meter = _tnbMeters
                        .firstWhereOrNull((m) => _meterLabel(m) == label);
                    if (meter != null) _onTnbMeterSelected(meter);
                  },
                  periodOptions: periodLabels,
                  selectedPeriod: selectedPeriodLabel,
                  onPeriodChanged: (label) {
                    final idx = periodLabels.indexOf(label);
                    if (idx != -1) _onPeriodSelected(periodValues[idx]);
                  },
                  isPeriodLocked: _isLockedSnapshot,
                  isGenerating: _isGenerating,
                  isLoadingReport: _isLoadingReport,
                  onDownload: _downloadReport,
                  onConfigureImages: _showImageConfigDialog,
                  onViewLogs: _showLogsDialog,
                ),
                const SizedBox(height: 16),
                Stack(
                  children: [
                    RepaintBoundary(
                      key: _reportBoundaryKey,
                      child: Container(
                        color: theme.primaryBackground,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            SummaryCardsRow(cards: _summaryCards),
                            const SizedBox(height: 16),
                            ExecutiveSummarySection(
                              bullets: _executiveBullets,
                              plantStatusLabel: _mdStatusLabel,
                              plantStatusMessage: _plantStatusMessage,
                              plantStatusColor: _mdStatusColor,
                              plantImageUrl:
                                  _imageConfig.plantBackgroundImageUrl,
                            ),
                            const SizedBox(height: 16),
                            _twoColumn(
                              left: LoadAnalysisSection(
                                hourlyValues: _loadTrendValues,
                                contractCapacity: _contractCapacity,
                                stats: _loadAnalysisStats,
                                peakStart: _peakStart,
                                peakEnd: _peakEnd,
                                peakDays: _peakDays,
                                date: _report.loadAnalysis?.date,
                              ),
                              right: CapacityAnalysisSection(
                                contractCapacity: _contractCapacity,
                                monthlyMaxDemandKw: _monthlyMaxDemandKw,
                                utilizationPct: _monthlyPct,
                                exceededKw: _excessKw,
                                warningText:
                                    'Maximum Demand exceeded contract capacity by ${(_monthlyPct - 100).toStringAsFixed(1)}%.',
                              ),
                            ),
                            const SizedBox(height: 16),
                            _twoColumn(
                              left: CostAnalysisSection(
                                contractCapacity: _contractCapacity,
                                mdRate: _mdRate,
                                excessKw: _excessKw,
                                // Split of totalSurcharge that always sums back to
                                // it exactly, since Max Demand Monitoring uses one
                                // flat rate (not a separate base/excess tariff
                                // tier) — see _totalSurcharge.
                                baseCharge:
                                    (_monthlyMaxDemandKw < _contractCapacity
                                            ? _monthlyMaxDemandKw
                                            : _contractCapacity) *
                                        _mdRate,
                                excessCharge: _excessKw * _mdRate,
                                totalSurcharge: _totalSurcharge,
                                billingPeriodLabel: _periodLabel,
                              ),
                              right: TrendAnalysisSection(
                                dailyValues: _dailyTrendValues,
                                contractCapacity: _contractCapacity,
                                stats: _trendAnalysisStats,
                                monthAbbrev: _monthAbbrev,
                              ),
                            ),
                            const SizedBox(height: 16),
                            EquipmentAnalysisSection(
                              ranking: _equipmentRanking,
                              totalDemandKw: _equipmentTotalKw,
                              totalPct: _equipmentTotalPct,
                              keyInsights: _keyInsights,
                            ),
                            const SizedBox(height: 16),
                            ReportFooterBar(
                              notes: _footerNotes,
                              dataSourceLabel: _dataSourceLabel,
                              lastUpdatedLabel: _lastUpdatedLabel,
                              generatedByLabel: _generatedByLabel,
                              logoImageUrl: _imageConfig.footerLogoImageUrl,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (_isLoadingReport)
                      Positioned.fill(child: _dataLoadingOverlay(theme)),
                  ],
                ),
              ],
            ),
          ),
          if (_isGenerating) _loadingOverlay(theme),
        ],
      ),
    );
  }

  /// Lighter scrim shown over just the report content (header/plant filter
  /// stay interactive) while [_onTnbMeterSelected]/[_onPeriodSelected]
  /// re-fetch everything for a newly selected plant/period, or while
  /// [_showImageConfigDialog] saves settings and refreshes the ranking —
  /// [_loadingOverlayMessage] is set by whichever of those triggered it.
  Widget _dataLoadingOverlay(FlutterFlowTheme theme) {
    return Container(
      color: theme.primaryBackground.withOpacity(0.7),
      alignment: Alignment.center,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(strokeWidth: 3),
          const SizedBox(height: 12),
          Text(
            _loadingOverlayMessage,
            style:
                GoogleFonts.poppins(fontSize: 13, color: theme.secondaryText),
          ),
        ],
      ),
    );
  }

  /// Full-screen scrim shown while [_downloadReport] is capturing/encoding
  /// the report — that work briefly blocks the UI thread, so this at least
  /// gives clear "this is working" feedback instead of the page just going
  /// unresponsive with no explanation.
  Widget _loadingOverlay(FlutterFlowTheme theme) {
    return Positioned.fill(
      child: Container(
        color: Colors.black.withOpacity(0.55),
        alignment: Alignment.center,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 22),
          decoration: BoxDecoration(
            color: const Color(0xFF0B1B33),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withOpacity(0.12)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // A determinate bar that jumps between fixed steps rather than
              // an indeterminate spinner: this work briefly blocks the UI
              // thread on Flutter Web (no way around that here), so a
              // spinner would just stutter instead of rotating smoothly —
              // this reads as "on track" even when it only updates a few
              // times instead of animating continuously.
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  width: 180,
                  height: 6,
                  child: LinearProgressIndicator(
                    value: _generatingProgress,
                    backgroundColor: Colors.white.withOpacity(0.12),
                    valueColor: const AlwaysStoppedAnimation(Color(0xFF00D4FF)),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Text(
                _generatingStatus,
                style: GoogleFonts.poppins(
                  fontSize: 14.5,
                  fontWeight: FontWeight.w600,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'This may take a few seconds — please wait.',
                textAlign: TextAlign.center,
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  color: Colors.white60,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Fires the `md_insight_report_log` MySQL record for this generation.
  /// Called only after [_downloadReport] has already produced the PDF
  /// (spec: log the successful generation, not the button click itself), and
  /// deliberately not awaited by the caller — a logging failure shouldn't
  /// stop the user from getting their already-generated PDF.
  Future<void> _logReportGeneration() async {
    final plantCode = _currentPlantCode;
    if (plantCode.isEmpty) return;
    await MdInsightReportService.logReportGeneration(
      plantCode: plantCode,
      period: _selectedPeriod,
      generatedBy: currentUserEmail.isNotEmpty ? currentUserEmail : currentUserUid,
      reportState: _report.reportState,
      payload: {
        'plant_label': _selectedTnbMeter != null ? _meterLabel(_selectedTnbMeter!) : null,
        'report_date_label': _reportDateLabel,
        'period_label': _periodLabel,
        'current_max_demand_kw': _currentMaxDemandKw,
        'monthly_max_demand_kw': _monthlyMaxDemandKw,
        'contract_capacity_kw': _contractCapacity,
        'md_status': _mdStatusLabel,
        'total_surcharge': _totalSurcharge,
      },
    );
  }

  List<SummaryCardData> get _summaryCards => [
        SummaryCardData(
          icon: Icons.show_chart,
          iconColor: MdReportColors.blue,
          title: 'Current Maximum Demand',
          value: _fmtKw(_currentMaxDemandKw),
          valueColor: MdReportColors.red,
          subtitle: _currentMaxDemandKw > 0
              ? '${_currentPct.toStringAsFixed(1)}% of Contract Capacity'
              : '---',
          subtitleColor: MdReportColors.red,
        ),
        SummaryCardData(
          icon: Icons.bar_chart_rounded,
          iconColor: MdReportColors.blue,
          title: 'Monthly Maximum Demand',
          value: _fmtKw(_monthlyMaxDemandKw),
          valueColor: MdReportColors.red,
          subtitle: _monthlyMaxDemandKw > 0
              ? '${_monthlyPct.toStringAsFixed(1)}% of Contract Capacity'
              : '---',
          subtitleColor: MdReportColors.red,
        ),
        SummaryCardData(
          icon: Icons.speed_rounded,
          iconColor: const Color(0xFF94A3B8),
          title: 'Contract Capacity',
          value: _fmtKw(_contractCapacity),
          subtitle: '',
        ),
        SummaryCardData(
          icon: Icons.warning_amber_rounded,
          iconColor: MdReportColors.orange,
          title: 'MD Status',
          value: _mdStatusLabel,
          valueColor: _mdStatusColor,
          subtitle: _monthlyMaxDemandKw > _contractCapacity
              ? 'Exceeded by ${_excessKw.toStringAsFixed(1)} kW'
              : (_monthlyMaxDemandKw > 0
                  ? '${_monthlyPct.toStringAsFixed(1)}% of Contract Capacity'
                  : '---'),
        ),
        SummaryCardData(
          icon: Icons.attach_money_rounded,
          iconColor: MdReportColors.green,
          title: 'Estimated MD Surcharge',
          value: _monthlyMaxDemandKw > 0
              ? 'RM ${_totalSurcharge.toStringAsFixed(2)}'
              : '---',
          subtitle: 'This Billing Month',
          subtitleColor: MdReportColors.green,
        ),
      ];

  Widget _twoColumn({required Widget left, required Widget right}) {
    return LayoutBuilder(builder: (context, constraints) {
      final isWide = constraints.maxWidth > 900;
      if (!isWide) {
        return Column(children: [
          SizedBox(height: 420, child: left),
          const SizedBox(height: 16),
          SizedBox(height: 420, child: right)
        ]);
      }
      return SizedBox(
        height: 430,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: left),
            const SizedBox(width: 16),
            Expanded(child: right)
          ],
        ),
      );
    });
  }

  /// Captures the on-screen report (the full [RepaintBoundary]-wrapped
  /// content, not just the visible scroll viewport) as a high-res PNG and
  /// hands it to [MdInsightReportPdfExporter] so the downloaded PDF is a
  /// pixel-faithful copy of the design mock, whatever data is currently
  /// showing.
  Future<void> _downloadReport() async {
    if (_isLoadingReport) {
      // The selected period's data is still being fetched — bail out rather
      // than screenshotting whatever the previous period left on screen.
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Still loading this period\'s report — please wait.')));
      return;
    }
    setState(() {
      _isGenerating = true;
      _generatingStatus = 'Capturing report…';
      _generatingProgress = 0.1;
    });
    // The setState above dirties the download button's spinner, which lives
    // inside the same RepaintBoundary we're about to capture — toImage()
    // asserts ('!debugNeedsPaint' is not true) if called before that pending
    // paint has actually happened, so wait for the frame to complete first.
    // endOfFrame (rather than Future.delayed) is used at each checkpoint
    // below too, since it's the reliable way to guarantee a frame — and so
    // the updated status text — actually painted before the next blocking
    // chunk of work starts.
    await WidgetsBinding.instance.endOfFrame;
    try {
      final boundary = _reportBoundaryKey.currentContext!.findRenderObject()
          as RenderRepaintBoundary;
      // pixelRatio 1.0 (screen resolution, no upscaling) keeps the
      // encode/embed work — which briefly blocks the UI thread with no way
      // to run it off-thread on Flutter Web — as short as possible while
      // still being sharp enough to read on a printed page.
      final image = await boundary.toImage(pixelRatio: 1.0);

      setState(() {
        _generatingStatus = 'Encoding image…';
        _generatingProgress = 0.4;
      });
      await WidgetsBinding.instance.endOfFrame;

      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      final pngBytes = byteData!.buffer.asUint8List();
      debugPrint(
          'MdInsightReport: captured ${image.width}x${image.height}px, ${pngBytes.lengthInBytes} bytes');

      setState(() {
        _generatingStatus = 'Building PDF…';
        _generatingProgress = 0.7;
      });
      await WidgetsBinding.instance.endOfFrame;

      await MdInsightReportPdfExporter.exportImage(
        reportDateLabel: _reportDateLabel,
        periodLabel: _periodLabel,
        pngBytes: pngBytes,
        pixelWidth: image.width,
        pixelHeight: image.height,
      );
      if (mounted) setState(() => _generatingProgress = 1.0);
      unawaited(_logReportGeneration());
    } catch (e) {
      debugPrint('MdInsightReport: error generating PDF: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Failed to generate report.')));
      }
    } finally {
      if (mounted) {
        setState(() {
          _isGenerating = false;
          _generatingProgress = 0.0;
        });
      }
    }
  }
}
