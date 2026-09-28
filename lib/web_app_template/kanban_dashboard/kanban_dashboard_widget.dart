import 'dart:async';
import 'package:smartmachine365/utils/leak_probe.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/web_app_template/kanban_dashboard/kanban_panel_builder_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/kanban_panel_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/cell_state_model.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/response.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/models/pecc_live_data.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/services/kanban_cell_services.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard/services/pecc_data_service.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/ecc_interface_preview_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/plant_energy_command_center/hero_card_settings_dialog.dart';
import 'package:smartmachine365/flutter_flow/rbac.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/lot_command_center_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/lot48_command_center_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/factory_overview_command_center_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_grid_preview.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/services/scope_resolver.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/session_storage.dart';

class KanbanDashboardWidget extends StatefulWidget {
  /// When set (e.g. "Lot 237"), this view is scoped to that factory's command
  /// center (loads its per-factory config). Empty/null → the group view.
  final String? initialPlantName;
  const KanbanDashboardWidget({super.key, this.initialPlantName});

  @override
  State<KanbanDashboardWidget> createState() => _KanbanDashboardWidgetState();
}

class _KanbanDashboardWidgetState extends State<KanbanDashboardWidget> {
  final scaffoldKey = GlobalKey<ScaffoldState>();

  // ── Grid constants ────────────────────────────────────────────────
  static const int _crossAxisCount = 4;
  static const int _rowCount = 3;
  static const double _gap = 2.0;

  // cellIndex → live state / metadata
  final Map<int, CellStateModel> _cellStates = {};
  final Map<int, String> _cellTypes = {};
  final Map<int, String> _cellNames = {};
  final Map<int, Map<String, dynamic>> _cellConfigs = {};
  final Map<int, String> _cellSizes = {};

  bool _isLoadingSettings = true;
  String? _settingsError;
  String _dashboardTitle = '';

  // ── Interface type ────────────────────────────────────────────────────────
  /// 'ECC' → render Energy Command Center header; anything else → classic header.
  String _interfaceType = 'KANBAN_GRID';
  Map<String, dynamic>? _ecConfig;

  /// Whose PECC settings document [_ecConfig] was read from — the centre
  /// card's own settings dialog writes back to this same document, group or
  /// per-factory, rather than guessing at a uid of its own.
  String? _peccConfigUid;
  PeccLiveData _peccLiveData = PeccLiveData.empty;
  int _peccLoadVersion = 0;
  int _peccDataTick = 0;
  Timer? _peccRefreshTimer;
  Timer? _peccProgressDebounce;
  String? _peccRefreshUid;
  bool _peccResolveInFlight = false;
  bool _peccInitialLoadDone = false;

  /// Master Facilities display names keyed by meterId.
  /// Loaded once per PECC load; used to override saved widget labels.
  final Map<String, String> _facilityDisplayNames = {};

  static const String _settingsUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

  // ── Helpers ───────────────────────────────────────────────────────
  String? _safeString(dynamic v) {
    if (v is String) return v.isEmpty ? null : v;
    return null;
  }

  ({int cols, int rows}) _parseSize(String size) {
    final parts = size.split('x');
    if (parts.length != 2) return (cols: 1, rows: 1);
    return (
      cols: int.tryParse(parts[0].trim()) ?? 1,
      rows: int.tryParse(parts[1].trim()) ?? 1,
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Fetch active settings
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _fetchActiveSettings(String uid) async {
    // Try the current user's own settings first; if none exist (404 / null
    // settings / empty uid), fall back to the most recently published
    // dashboard from any admin/superadmin so every assigned role can view
    // what an admin has already configured.
    if (uid.trim().isNotEmpty) {
      final ok = await _tryFetchActiveFor(uid);
      if (ok) return;
    }

    final fallbackUid = await _findFallbackAdminUid();
    if (fallbackUid != null) {
      final ok = await _tryFetchActiveFor(fallbackUid);
      if (ok) return;
    }

    if (!mounted) return;
    setState(() {
      _settingsError = 'No dashboard has been configured yet';
      _isLoadingSettings = false;
    });
  }

  /// Returns true when settings were successfully loaded for [uid].
  Future<bool> _tryFetchActiveFor(String uid) async {
    try {
      final res = await http.get(
        Uri.parse('$_settingsUrl/$uid/active'),
        // Shared headers, so this read revalidates like every other config
        // read rather than being served from the browser's own copy.
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 15));
      if (!mounted) return false;

      if (res.statusCode != 200) return false;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['success'] != true) return false;

      final appliedSettings = body['appliedSettings'] as Map<String, dynamic>?;
      final settings = appliedSettings?['settings'] as Map<String, dynamic>?;
      final cells = appliedSettings?['cells'] as List<dynamic>? ?? [];
      // No active template applied for this uid → let caller try fallback.
      if (settings == null && cells.isEmpty) return false;

      final resolvedType = _safeString(settings?['interfaceType']) ?? 'KANBAN_GRID';
      final resolvedConfig = settings?['ecConfig'] is Map<String, dynamic> ? settings!['ecConfig'] as Map<String, dynamic> : null;

      // A per-factory view (e.g. Lot 237) must never inherit the group's
      // active-template config (its photo/branding) — it loads only that
      // factory's own config below.
      final isPlantView = widget.initialPlantName?.trim().isNotEmpty ?? false;
      setState(() {
        _dashboardTitle = _safeString(settings?['title']) ?? _safeString(body['activeTemplate']) ?? '';
        _interfaceType = resolvedType;
        _ecConfig = isPlantView ? null : resolvedConfig;
        _isLoadingSettings = false;
        _settingsError = null;
      });
      _applySettingsToPanels(cells);

      // Always refresh ECC branding from the live PECC config — the applied
      // template's stored ecConfig is a snapshot taken at apply time, so it
      // goes stale the moment branding (e.g. the factory photo) is updated
      // afterwards on the Plant Energy Command Center settings page. For a
      // per-factory view, always load that factory's own config regardless of
      // the group's template type.
      if (resolvedType == 'ECC' || isPlantView) {
        await _loadPlantPecc(uid);
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Fetches live PECC branding when the applied template is ECC but stored
  /// ecConfig is absent (e.g. template saved before ecConfig was persisted).
  /// Loads a per-factory (Lot) command center config. Tries the current user's
  /// own config first; if that factory isn't configured under this uid, falls
  /// back to the admin who published dashboards — so any viewer (incl.
  /// non-admins) sees what an admin set up, same as the group view.
  Future<void> _loadPlantPecc(String uid) async {
    final loadVersion = ++_peccLoadVersion;
    _peccInitialLoadDone = false;
    // Keep showing the last live snapshot while refreshing (stale-while-revalidate).
    await AppConfig.init();
    // Load Master Facility display names in parallel with the PECC config.
    unawaited(_loadFacilityNames());
    final ok = await _fetchPeccConfig(uid, loadVersion: loadVersion);
    if (ok) return;
    final adminUid = await _findFallbackAdminUid();
    if (adminUid != null && adminUid != uid) {
      await _fetchPeccConfig(adminUid, loadVersion: loadVersion);
    }
  }

  /// Fetches Master Facilities display names and stores them in [_facilityDisplayNames].
  /// These override the labels saved in settings so that renames in Master Facilities
  /// are immediately reflected on all lot kanban cards without re-saving settings.
  /// Null until checked. True when this dashboard shows a plant outside the
  /// signed-in user's scope.
  bool _outOfScope = false;

  /// The Kanban dashboard resolves its meters from the command centre's saved
  /// meter groups, not from the facility master, so the filtering that covers
  /// every other module does not reach it. Without this check a user granted
  /// one block could open any lot's command centre by its route and read the
  /// whole site.
  Future<void> _checkScope() async {
    final scope = AppStateNotifier.instance.dataScope;
    if (scope.isUnrestricted) return;
    final plant = widget.initialPlantName?.trim() ?? '';
    bool blocked;
    if (plant.isEmpty) {
      // The group view rolls every lot together, which is precisely what a
      // restricted account is not entitled to see.
      blocked = true;
    } else {
      try {
        await ScopeResolver.load();
        final id = ScopeResolver.plantIdByName(plant);
        // An unknown plant name cannot be checked, so it is refused rather
        // than waved through.
        blocked = id.isEmpty || !scope.allowsPlant(id);
        if (!blocked && scope.areaIds.isNotEmpty) {
          // Someone restricted to a block still has to hold the whole site as
          // a plant, because the meters record their plant as the site rather
          // than the block. That must not become a way into the site-wide
          // command centre, which shows the other blocks too. With areas
          // granted, only the plants owning one of them open.
          blocked = !scope.areaIds
              .any((a) => ScopeResolver.parentPlantOf(a) == id);
        }
      } catch (_) {
        blocked = true;
      }
    }
    if (mounted && blocked != _outOfScope) setState(() => _outOfScope = blocked);
  }

  Widget _noAccess() {
    final names = ScopeResolver.namesFor(AppStateNotifier.instance.dataScope);
    final allowed = [...names.plants, ...names.areas].join(', ');
    return Container(
      color: const Color(0xFF050D1A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Icon(Icons.lock_outline, size: 52, color: Color(0xFF2C4A6E)),
        const SizedBox(height: 16),
        Text('Not available for your account',
            style: GoogleFonts.poppins(
                color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        SizedBox(
          width: responsiveDialogWidth(context, 420),
          child: Text(
            allowed.isEmpty
                ? 'This dashboard covers plants outside the access assigned to you.'
                : 'This dashboard covers plants outside your access. You are assigned: $allowed.',
            textAlign: TextAlign.center,
            style: GoogleFonts.poppins(
                color: const Color(0xFF5B7FA6), fontSize: 12.5, height: 1.5),
          ),
        ),
      ]),
    );
  }

  Future<void> _loadFacilityNames() async {
    await _checkScope();
    try {
      final facilities = await FacilityService.getFacilities();
      final names = <String, String>{};
      for (final f in facilities) {
        final id = f.meterId.trim();
        final name = f.meterName.trim();
        if (id.isNotEmpty && name.isNotEmpty && name != '-') {
          names[id] = name;
        }
      }
      if (mounted && names.isNotEmpty) {
        setState(() => _facilityDisplayNames.addAll(names));
      }
    } catch (_) {}
  }

  Future<bool> _fetchPeccConfig(String uid, {required int loadVersion}) async {
    if (uid.isEmpty) return false;
    try {
      const peccBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center';
      // Scope to this factory's config when the view is a per-factory command
      // center (e.g. "Lot 237"); empty → the group config.
      final plant = widget.initialPlantName?.trim() ?? '';
      final qp = plant.isNotEmpty ? '?plantId=${Uri.encodeQueryComponent(plant)}' : '';
      // Must send x-client-id (AppConfig.headers) so the backend reads the
      // SAME per-client Firestore the setting saved to — otherwise it reads
      // the default DB and the factory's config/photo isn't found.
      final res = await http.get(Uri.parse('$peccBase/$uid$qp'), headers: AppConfig.headers).timeout(const Duration(seconds: 10));
      if (!mounted || res.statusCode != 200) return false;
      if (loadVersion != _peccLoadVersion) return false;
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      if (body['exists'] == true && body['settings'] is Map<String, dynamic>) {
        final settings = body['settings'] as Map<String, dynamic>;
        setState(() {
          _ecConfig = settings;
          // Remembered so the centre card's own settings dialog saves back
          // to the exact document it was read from, group or per-factory.
          _peccConfigUid = uid;
        });
        await _loadPeccLiveData(uid, ecConfig: settings, loadVersion: loadVersion);
        _startPeccAutoRefresh(uid);
        return true;
      } else if (plant.isNotEmpty) {
        // Factory has no saved config under this uid — return false so caller checks adminUid for this factory's config
        setState(() => _ecConfig = null);
        return false;
      }
      return false;
    } catch (e) {
      debugPrint('[Dashboard PECC] fetch error: $e');
      return false;
    }
  }

  bool _peccKpisChanged(PeccLiveData a, PeccLiveData b) =>
      a.pfPlantTotalKwh != b.pfPlantTotalKwh ||
      a.pfPlantGridKwh != b.pfPlantGridKwh ||
      a.pfPlantSolarKwh != b.pfPlantSolarKwh ||
      a.heroGridImportToday != b.heroGridImportToday ||
      a.heroSolarToday != b.heroSolarToday ||
      a.heroTotalEnergyToday != b.heroTotalEnergyToday;

  /// Resolves saved PECC mappings → live kWh + RM for group or per-factory view.
  Future<void> _loadPeccLiveData(
    String uid, {
    Map<String, dynamic>? ecConfig,
    required int loadVersion,
    bool includeCharts = true,
  }) async {
    if (_peccResolveInFlight) return;
    final raw = ecConfig ?? _ecConfig;
    if (raw == null || uid.isEmpty) return;
    _peccResolveInFlight = true;
    final config = Map<String, dynamic>.from(raw);
    final plant = widget.initialPlantName?.trim() ?? '';
    if ((config['plantId']?.toString() ?? '').isEmpty && plant.isNotEmpty) {
      config['plantId'] = plant;
    }
    try {
      final data = await PeccDataService.resolve(
        ecConfig: config,
        userId: uid,
        includeCharts: includeCharts,
        onProgress: includeCharts
            ? (partial) {
                if (!mounted || loadVersion != _peccLoadVersion) return;
                _peccProgressDebounce?.cancel();
                _peccProgressDebounce = Timer(const Duration(milliseconds: 400), () {
                  if (!mounted || loadVersion != _peccLoadVersion) return;
                  setState(() => _peccLiveData = _peccLiveData.mergeWith(partial));
                });
              }
            : null,
      ).timeout(
        Duration(seconds: includeCharts ? 75 : 20),
        onTimeout: () => _peccLiveData,
      );
      if (!mounted || loadVersion != _peccLoadVersion) return;
      _peccProgressDebounce?.cancel();
      final merged = _peccLiveData.mergeWith(data);
      final kpiChanged = _peccKpisChanged(_peccLiveData, merged);
      if (!includeCharts && !kpiChanged) return;
      setState(() {
        _peccLiveData = merged;
        if (includeCharts || kpiChanged) _peccDataTick++;
        _peccInitialLoadDone = true;
      });
    } catch (e) {
      debugPrint('[Dashboard PECC] live data error: $e');
    } finally {
      _peccResolveInFlight = false;
    }
  }

  void _startPeccAutoRefresh(String uid) {
    _peccRefreshUid = uid;
    _peccRefreshTimer?.cancel();
    _peccRefreshTimer = Timer.periodic(const Duration(seconds: 90), (_) {
      if (!mounted || _ecConfig == null || _peccResolveInFlight) return;
      final route = ModalRoute.of(context);
      if (route != null && !route.isCurrent) {
        return;
      }
      final refreshUid = _peccRefreshUid ?? uid;
      _loadPeccLiveData(
        refreshUid,
        loadVersion: _peccLoadVersion,
        includeCharts: false,
      );
    });
  }

  @override
  void dispose() {
    LeakProbe.unregister('KanbanDashboard.State');
    _peccRefreshTimer?.cancel();
    _peccProgressDebounce?.cancel();
    super.dispose();
  }

  /// Scans /list for any user that has published kanban templates and
  /// returns the most recently used userId. This lets non-admin roles
  /// inherit the dashboard configured by an admin/superadmin.
  Future<String?> _findFallbackAdminUid() async {
    try {
      final res = await http.get(
        Uri.parse('$_settingsUrl/list'),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 15));
      if (res.statusCode != 200) return null;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final data = body['data'] as List<dynamic>? ?? [];
      if (data.isEmpty) return null;

      // /list is already sorted by createdAt desc; pick the first userId.
      for (final raw in data) {
        final t = raw as Map<String, dynamic>;
        final ownerUid = _safeString(t['userId']);
        if (ownerUid != null) return ownerUid;
      }
      return null;
    } catch (_) {
      return null;
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Apply cells → seed states → trigger fetches
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _applySettingsToPanels(List<dynamic> cells) {
    setState(() {
      _cellStates.clear();
      _cellTypes.clear();
      _cellNames.clear();
      _cellConfigs.clear();
      _cellSizes.clear();

      for (final raw in cells) {
        final cell = raw as Map<String, dynamic>;
        final cellIndex = (cell['cellIndex'] as num?)?.toInt() ?? -1;
        final widgetType = _safeString(cell['widgetType']) ?? '';
        final widgetName = _safeString(cell['widgetName']) ?? '';
        final config = Map<String, dynamic>.from(cell['config'] as Map? ?? {});
        final size = _safeString(cell['size']) ?? '1x1';

        if (cellIndex < 0 || cellIndex >= _crossAxisCount * _rowCount) continue;

        _cellTypes[cellIndex] = widgetType;
        _cellNames[cellIndex] = widgetName;
        _cellConfigs[cellIndex] = config;
        _cellSizes[cellIndex] = size;
        // ✅ Use LoadingResult instead of the old flat isLoading: true
        _cellStates[cellIndex] = const CellStateModel(result: LoadingResponse());

        _loadCellData(cellIndex, widgetType, config);
      }
    });
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Fetch + update state for one cell
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _loadCellData(
    int cellIndex,
    String widgetType,
    Map<String, dynamic> config,
  ) async {
    setState(() => _cellStates[cellIndex] = const CellStateModel(result: LoadingResponse()));

    try {
      final result = await KanbanCellServices.fetch(widgetType, config);
      if (!mounted) return;
      // ✅ result is already a KanbanCellResult subtype — pass it directly
      setState(() => _cellStates[cellIndex] = CellStateModel(result: result));
    } catch (e) {
      if (!mounted) return;
      setState(() => _cellStates[cellIndex] = CellStateModel(result: ErrorResponse(e.toString())));
    }
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Build the child widget for one cell
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _panelWidget(
    int cellIndex,
    String widgetType,
    String widgetName,
    Map<String, dynamic> config,
  ) {
    return KanbanPanelBuilderWidget.build(
      cellIndex: cellIndex,
      widgetType: widgetType,
      widgetName: widgetName,
      config: config,
      state: _cellStates[cellIndex] ?? const CellStateModel(),
      onRefresh: () => _loadCellData(cellIndex, widgetType, config),
      // ✅ Route date changes by widgetType — hourly uses ISO date,
      //    MD ranking uses event date/start/end
      onDateChanged: (date, start, end) {
        final updated = Map<String, dynamic>.from(config);

        if (widgetType == 'HOURLY_CHART') {
          final parsed = DateTime.tryParse(date);
          if (parsed != null) updated['selectedDate'] = parsed;
        } else {
          updated['eventDate'] = date;
          updated['eventStart'] = start;
          updated['eventEnd'] = end;
        }

        _cellConfigs[cellIndex] = updated;
        _loadCellData(cellIndex, widgetType, updated);
      },
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Build the spanned grid using Stack + Positioned
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildSpannedGrid(BoxConstraints constraints) {
    final double totalW = constraints.maxWidth;
    final double totalH = constraints.maxHeight;

    final double cellW = (totalW - (_crossAxisCount - 1) * _gap) / _crossAxisCount;
    final double cellH = (totalH - (_rowCount - 1) * _gap) / _rowCount;

    final Set<int> coveredIndices = {};

    for (final entry in _cellTypes.entries) {
      final cellIndex = entry.key;
      final sizeStr = _cellSizes[cellIndex] ?? '1x1';
      final span = _parseSize(sizeStr);

      final int col = cellIndex % _crossAxisCount;
      final int row = cellIndex ~/ _crossAxisCount;
      final int colSpan = span.cols.clamp(1, _crossAxisCount - col);
      final int rowSpan = span.rows.clamp(1, _rowCount - row);

      for (int r = row; r < row + rowSpan; r++) {
        for (int c = col; c < col + colSpan; c++) {
          coveredIndices.add(r * _crossAxisCount + c);
        }
      }
    }

    final List<Widget> positioned = [];

    // ── Step 2: Render background empty cells ──
    for (int i = 0; i < _crossAxisCount * _rowCount; i++) {
      if (coveredIndices.contains(i)) continue;

      final int col = i % _crossAxisCount;
      final int row = i ~/ _crossAxisCount;
      final double x = col * (cellW + _gap);
      final double y = row * (cellH + _gap);

      positioned.add(
        Positioned(
          left: x,
          top: y,
          width: cellW,
          height: cellH,
          child: KanbanPanelWidget(child: null, onAdd: () {}),
        ),
      );
    }

    // ── Step 3: Render configured/spanning cells on top ──
    for (final entry in _cellTypes.entries) {
      final cellIndex = entry.key;
      final widgetType = entry.value;
      final widgetName = _cellNames[cellIndex] ?? '';
      final config = _cellConfigs[cellIndex] ?? {};
      final sizeStr = _cellSizes[cellIndex] ?? '1x1';

      final int col = cellIndex % _crossAxisCount;
      final int row = cellIndex ~/ _crossAxisCount;
      final span = _parseSize(sizeStr);
      final int colSpan = span.cols.clamp(1, _crossAxisCount - col);
      final int rowSpan = span.rows.clamp(1, _rowCount - row);

      final double x = col * (cellW + _gap);
      final double y = row * (cellH + _gap);
      final double w = colSpan * cellW + (colSpan - 1) * _gap;
      final double h = rowSpan * cellH + (rowSpan - 1) * _gap;

      positioned.add(
        Positioned(
          left: x,
          top: y,
          width: w,
          height: h,
          child: KanbanPanelWidget(
            child: _panelWidget(cellIndex, widgetType, widgetName, config),
            onAdd: () {},
          ),
        ),
      );
    }

    return Stack(children: positioned);
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Lifecycle
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  void initState() {
    super.initState();
    LeakProbe.register('KanbanDashboard.State');
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      safeSetState(() {});
      await AppConfig.init();
      final stateUid = AppStateNotifier.instance.uid;
      final uid = (stateUid != null && stateUid.isNotEmpty) ? stateUid : (SessionStorage.getActiveUid() ?? '');
      // A per-factory view (e.g. Lot 237) renders its own fixed CEO layout and
      // loads ONLY that factory's PECC config directly — it must not depend on
      // the group's active kanban template (which could resolve to a fallback
      // admin uid where this factory's config doesn't live).
      if (widget.initialPlantName?.trim().isNotEmpty ?? false) {
        setState(() => _isLoadingSettings = false);
        await _loadPlantPecc(uid);
      } else {
        await _fetchActiveSettings(uid);
      }
    });
  }

  @override
  void didUpdateWidget(covariant KanbanDashboardWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldPlant = oldWidget.initialPlantName?.trim() ?? '';
    final newPlant = widget.initialPlantName?.trim() ?? '';
    if (oldPlant == newPlant) return;

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      setState(() {
        _isLoadingSettings = true;
        _settingsError = null;
        _ecConfig = null;
        _peccLiveData = PeccLiveData.empty;
      });
      await AppConfig.init();
      final stateUid = AppStateNotifier.instance.uid;
      final uid = (stateUid != null && stateUid.isNotEmpty) ? stateUid : (SessionStorage.getActiveUid() ?? '');
      if (newPlant.isNotEmpty) {
        setState(() => _isLoadingSettings = false);
        await _loadPlantPecc(uid);
      } else {
        await _fetchActiveSettings(uid);
      }
    });
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  // Build
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: Theme.of(context).brightness == Brightness.light ? FlutterFlowTheme.of(context).primaryBackground : const Color(0xFF020B2D),
        // Covers the group view as well as the per-lot one: the all-plants
        // roll-up is exactly what a restricted account must not see.
        body: _outOfScope
            ? _noAccess()
            : _isLoadingSettings
            ? Center(
                child: CircularProgressIndicator(
                    color: Theme.of(context).brightness == Brightness.light ? FlutterFlowTheme.of(context).primary.withOpacity(0.4) : Colors.white38))
            : (widget.initialPlantName?.trim().isNotEmpty ?? false)
                ? _buildLotDashboard()
                : _interfaceType == 'ECC'
                ? _buildEccDashboard()
                : Column(
                    children: [
                      // ── Header ────────────────────────────────────────────
                      SizedBox(
                        width: double.infinity,
                        height: KanbanGridPreview.titleBarHeight,
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            Image.asset('assets/images/header_dashboard.png', fit: BoxFit.fill),
                            Center(
                              child: Text(
                                _dashboardTitle,
                                style: GoogleFonts.poppins(
                                  color: Theme.of(context).brightness == Brightness.light ? FlutterFlowTheme.of(context).txtPrimary : Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      // ── Grid ──────────────────────────────────────────────
                      Expanded(
                        child: _settingsError != null
                            ? Center(
                                child: Text(
                                  _settingsError!,
                                  style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                                  textAlign: TextAlign.center,
                                ),
                              )
                            : Padding(
                                padding: const EdgeInsets.all(_gap),
                                child: LayoutBuilder(
                                  builder: (context, constraints) => _buildSpannedGrid(constraints),
                                ),
                              ),
                      ),
                    ],
                  ),
      ),
    );
  }

  // ── Per-factory (Lot) CEO dashboard ───────────────────────────────────────

  /// Whether this lot has a command centre configured at all.
  ///
  /// A lot nobody has set up used to render the full dashboard furniture with
  /// a dash in every figure, which reads as broken rather than as unconfigured.
  bool get _lotHasNoConfig {
    final cfg = _ecConfig;
    if (cfg == null) return true;
    // Deliberately only "nothing was ever created" — not "nothing is mapped
    // yet". A lot whose sections exist but whose devices are still blank is
    // half-configured, and its own dashboard is the right place to see that.
    // Lot 48 is exactly that case, and hiding it would be a regression.
    final sections = cfg['sections'] as List<dynamic>? ?? const [];
    final groups = cfg['groups'] as List<dynamic>? ?? const [];
    return sections.isEmpty && groups.isEmpty;
  }

  /// Shown in place of a dashboard for a lot that has not been set up.
  Widget _lotNotConfigured(String plant) {
    return Container(
      color: const Color(0xFF050D1A),
      alignment: Alignment.center,
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.dashboard_customize_outlined,
              size: 54, color: Color(0xFF2C4A6E)),
          const SizedBox(height: 18),
          Text(
            plant.isEmpty ? 'Command center' : plant,
            style: GoogleFonts.poppins(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 8),
          Text(
            'Not set up yet',
            style: GoogleFonts.poppins(
                color: const Color(0xFF7FA8D4),
                fontSize: 13,
                fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 10),
          SizedBox(
            width: responsiveDialogWidth(context, 420),
            child: Text(
              'No meters have been mapped for this lot. Open its Energy '
              'Command Center settings, create a Meter Group and assign it to '
              'the panels, and this dashboard fills in.',
              textAlign: TextAlign.center,
              style: GoogleFonts.poppins(
                  color: const Color(0xFF5B7FA6), fontSize: 12, height: 1.5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLotDashboard() {
    final branding = _ecConfig?['branding'] as Map<String, dynamic>? ?? {};
    final orgName = branding['topBarBranding']?.toString() ?? '';
    // Same two settings the group view uses, so a lot dashboard is named from
    // the settings page rather than inheriting whatever the building label
    // happened to be. Blank falls back to the previous behaviour.
    final configuredSubLabel =
        branding['topBarSubLabel']?.toString().trim() ?? '';
    final orgSubLabel = configuredSubLabel.isNotEmpty
        ? configuredSubLabel
        : (branding['buildingLabel']?.toString() ?? '');
    final photoUrl = branding['photoUrl']?.toString() ?? '';
    final lotLogoUrl = branding['logoUrl']?.toString() ?? '';
    final widgetLabels = <String, String>{};
    // Flow-diagram card positions — 'flow.blockA' etc. — keyed the same as
    // the live widget's anchor maps (prefix stripped), so a saved xPct/yPct
    // moves that card; unset keys keep their built-in spot.
    final widgetPositions = <String, (double, double)>{};
    final sections = _ecConfig?['sections'];
    if (sections is List) {
      for (final sec in sections) {
        if (sec is! Map) continue;
        final widgets = sec['widgets'];
        if (widgets is! List) continue;
        for (final w in widgets) {
          if (w is! Map) continue;
          final key = w['key']?.toString() ?? '';
          final label = w['label']?.toString() ?? '';
          final device = w['selectedDevice']?.toString().trim() ?? '';
          if (key.isEmpty) continue;
          // Prefer Master Facilities display name over saved setting label.
          // This means renaming a meter in Master Facilities immediately
          // reflects on all lot kanban cards without re-saving settings.
          final facilityName = device.isNotEmpty ? _facilityDisplayNames[device] : null;
          final effectiveLabel = (facilityName != null && facilityName.isNotEmpty)
              ? facilityName
              : (label.isNotEmpty ? label : null);
          if (effectiveLabel != null) widgetLabels[key] = effectiveLabel;
          if (key.startsWith('flow.')) {
            final x = double.tryParse(w['xPct']?.toString() ?? '');
            final y = double.tryParse(w['yPct']?.toString() ?? '');
            if (x != null && y != null) {
              widgetPositions[key.substring('flow.'.length)] =
                  ((x / 100).clamp(0.0, 1.0), (y / 100).clamp(0.0, 1.0));
            }
          }
        }
      }
    }
    final plant = widget.initialPlantName!.trim();
    final plantLower = plant.toLowerCase();
    // Nothing mapped: say so, rather than drawing a dashboard of dashes.
    // Waits for the load to finish so a slow fetch does not flash this.
    // Refused before anything is drawn, so no figure from another lot reaches
    // the screen even briefly.
    if (_outOfScope) return _noAccess();
    if (!_isLoadingSettings && _lotHasNoConfig) {
      return _lotNotConfigured(plant);
    }
    // Each centre keeps its own viewer. Routing every plant to the Factory
    // Overview widget made Lot 237 and Lot 48 render Block B's layout against
    // their own config, whose widget keys differ — so both showed "No devices
    // resolved" instead of their mappings.
    if (plantLower == 'lot 48') {
      return Lot48CommandCenterWidget(
        lotName: plant,
        orgName: orgName,
        orgSubLabel: orgSubLabel,
        logoUrl: lotLogoUrl,
        bgImageUrl: photoUrl,
        liveData: _peccLiveData,
        widgetLabels: widgetLabels,
        widgetPositions: widgetPositions,
        dataTick: _peccDataTick,
      );
    }
    // Every Lot 237 block gets this viewer, not Block B alone. The layout was
    // written for Block B but nothing in it is specific to Block B: the machine
    // rows, meter groups and labels all come from configuration, which is saved
    // per plant. Lot 237 and Lot 48 stay on their own viewers — their widget
    // keys differ, and routing them here made both render empty.
    final isLot237Block = const [
      'lot 237 block a', 'lot237blocka', 'block a',
      'lot 237 block b', 'lot237blockb', 'block b',
      'lot 237 block c', 'lot237blockc', 'block c',
    ].contains(plantLower);
    if (isLot237Block) {
      return FactoryOverviewCommandCenterWidget(
        lotName: plant,
        orgName: orgName,
        orgSubLabel: orgSubLabel,
        bgImageUrl: photoUrl,
        liveData: _peccLiveData,
        widgetLabels: widgetLabels,
        ecConfig: _ecConfig,
        dataTick: _peccDataTick,
        onConfigChanged: () {
          final uid = AppStateNotifier.instance.uid ?? '';
          if (uid.isNotEmpty) _loadPlantPecc(uid);
        },
      );
    }
    return LotCommandCenterWidget(
      lotName: plant,
      orgName: orgName,
      orgSubLabel: orgSubLabel,
      logoUrl: lotLogoUrl,
      bgImageUrl: photoUrl,
      liveData: _peccLiveData,
      widgetLabels: widgetLabels,
      widgetPositions: widgetPositions,
      dataTick: _peccDataTick,
      cardStyles: CardStyleSet.fromJson(branding['cardStyles'] as Map<String, dynamic>?),
      canEditCards: _canEditCards,
      onSaveCardStyle: _saveCardStyle,
    );
  }

  // ── ECC full-page dashboard ───────────────────────────────────────────────

  Widget _buildEccDashboard() {
    final branding = _ecConfig?['branding'] as Map<String, dynamic>? ?? {};
    final orgName = branding['topBarBranding']?.toString() ?? '';
    // Both of these were literals here, so naming a site meant a code change
    // and a release. Settings can now supply them; blank keeps what the
    // dashboard has always shown.
    final configuredSubLabel =
        branding['topBarSubLabel']?.toString().trim() ?? '';
    final orgSubLabel = configuredSubLabel.isNotEmpty
        ? configuredSubLabel
        : 'ENERGY COST MANAGEMENT CENTER';
    final buildingLabel = branding['buildingLabel']?.toString() ?? '';
    final configuredTitle = branding['dashTitle']?.toString().trim() ?? '';
    // Per-factory view → "<LOT> ENERGY COMMAND CENTER"; group → default.
    final plant = widget.initialPlantName?.trim() ?? '';
    final dashTitle = configuredTitle.isNotEmpty
        ? configuredTitle
        : (plant.isNotEmpty
            ? '$plant Energy Command Center'.toUpperCase()
            : (buildingLabel.isEmpty
                ? 'ENERGY COMMAND CENTER'
                : buildingLabel));
    final locationBadge = plant.isNotEmpty ? plant : buildingLabel;
    final photoUrl = branding['photoUrl']?.toString() ?? '';
    final logoUrl = branding['logoUrl']?.toString() ?? '';
    // Centre card position from settings, as percentages. Both are needed —
    // one alone is not a place — and blank keeps the built-in position.
    final heroX = double.tryParse(branding['heroXPct']?.toString() ?? '');
    final heroY = double.tryParse(branding['heroYPct']?.toString() ?? '');
    final (double, double)? heroPosition = heroX == null || heroY == null
        ? null
        : ((heroX / 100).clamp(0.0, 1.0), (heroY / 100).clamp(0.0, 1.0));
    // Unconfigured (both figures unset) draws the card exactly as it always
    // has — the group's total cost and total energy, nothing else.
    final heroCardConfig = HeroCardConfig.fromJson(branding['heroCard'] as Map<String, dynamic>?);

    final sections = _ecConfig?['sections'] as List<dynamic>? ?? [];
    final cdLabels = sections
        .cast<Map<String, dynamic>>()
        .where((s) => (s['title'] as String? ?? '').toLowerCase().contains('cost driver'))
        .expand<String>(
            (s) => ((s['widgets'] as List<dynamic>?) ?? []).cast<Map<String, dynamic>>().map((item) => (item['label'] as String? ?? '').trim()))
        .where((l) => l.isNotEmpty)
        .take(4)
        .toList();

    final pinsList = _ecConfig?['pins'] as List<dynamic>? ?? [];
    final pinLabels = <String>[];
    // Every pin the configuration defines, in the same order the map draws
    // them. This used to walk a fixed [0,1,2,4,5,6], so a pin added in
    // settings reached the map with no name — a numbered card and a blank
    // title where the site should be.
    final pinIndices = <int>[];
    for (final p in pinsList) {
      if (p is! Map) continue;
      final k = p['key']?.toString() ?? '';
      final m = RegExp(r'^(?:pin|cost_drivers)\[(\d+)\]$').firstMatch(k);
      if (m != null) pinIndices.add(int.parse(m.group(1)!));
    }
    pinIndices.sort();
    final orderedPins =
        pinIndices.isEmpty ? const [0, 1, 2, 4, 5, 6] : pinIndices;

    for (final i in orderedPins) {
      final pinMap = pinsList.firstWhere(
        (p) => p is Map && (p['key'] == 'pin[$i]' || p['key'] == 'cost_drivers[$i]'),
        orElse: () => null,
      );
      final dName = (pinMap is Map ? pinMap['displayName']?.toString() : null)?.trim() ?? '';
      // Ignore stale Cost Driver 4 label that may be saved under a wrong key
      final isStale = dName.toLowerCase().contains('cost driver 4') || dName.toLowerCase().contains('237c');
      if (dName.isNotEmpty && !isStale) {
        pinLabels.add(dName);
      } else {
        final secMatch = pinLabels.length < cdLabels.length ? cdLabels[pinLabels.length] : '';
        pinLabels.add(secMatch);
      }
    }

    return EccInterfacePreviewWidget(
      dashboardMode: true,
      orgName: orgName,
      orgSubLabel: orgSubLabel,
      dashTitle: dashTitle,
      dashSubtitle: _dashboardTitle,
      locationBadge: locationBadge,
      costDriverLabels: pinLabels,
      bgImageUrl: photoUrl,
      logoUrl: logoUrl,
      liveData: _peccLiveData,
      heroPosition: heroPosition,
      heroConfig: heroCardConfig.isCustom ? heroCardConfig : null,
      // The centre card only exists on the group map, and only a Super
      // Admin may reprice/relabel what it totals — the same authority the
      // rates it can be built from (Solar Settlement, TNB billing) already
      // require. Null leaves the card exactly as unclickable as any other
      // figure on the dashboard.
      onHeroTap: plant.isEmpty && _canEditHeroCard
          ? () => _openHeroCardDialog(heroCardConfig, orderedPins, pinLabels)
          : null,
      // Only the group view drills into a factory; inside a factory view the
      // pins aren't re-clickable. Tapping a pin opens that factory's command
      // center (same viewer, ?plant=<lot>).
      onLotTap: plant.isNotEmpty
          ? null
          : (lotLabel) => context.pushNamed(
                'KanbanDashboard',
                queryParameters: {'plant': lotLabel.replaceAll('LOT ', 'Lot ')},
              ),
      cardStyles: CardStyleSet.fromJson(branding['cardStyles'] as Map<String, dynamic>?),
      canEditCards: _canEditCards,
      onSaveCardStyle: _saveCardStyle,
    );
  }

  /// Only a Super Admin may reprice or relabel the centre card — the figures
  /// it can be built from (Solar Settlement's rates, TNB billing) are already
  /// gated the same way, and the card decides what a viewer reads as the
  /// group's own total.
  bool get _canEditHeroCard =>
      AppRoles.normalizeRole(AppStateNotifier.instance.userRole ?? '') ==
      AppRoles.superAdmin;

  Future<void> _openHeroCardDialog(
    HeroCardConfig current,
    List<int> pinIndices,
    List<String> pinLabels,
  ) async {
    final uid = _peccConfigUid;
    if (uid == null) return;
    final lots = [
      for (var i = 0; i < pinIndices.length; i++)
        HeroLotOption(
          pinIndex: pinIndices[i],
          label: i < pinLabels.length && pinLabels[i].trim().isNotEmpty
              ? pinLabels[i].trim()
              : 'Cost Driver ${pinIndices[i] + 1}',
        ),
    ];
    final result =
        await HeroCardSettingsDialog.show(context, initial: current, lots: lots);
    if (result == null || !mounted) return;
    final ok = await _savePeccBranding(
        uid, (branding) => {...branding, 'heroCard': result.toJson()});
    if (!ok && mounted) _showSaveError('the centre card');
  }

  /// Only a Super Admin sees any card on these dashboards as editable — one
  /// gate, shared by the group map's centre card and every per-card style
  /// added since, rather than each asking its own question about who may.
  bool get _canEditCards => _canEditHeroCard;

  /// Opens the small font-size/colour dialog for one card and saves the
  /// result — the same entry point whichever dashboard or card asks for it.
  Future<bool> _saveCardStyle(String key, CardTextStyle style) async {
    final uid = _peccConfigUid;
    if (uid == null) return false;
    final ok = await _savePeccBranding(uid, (branding) {
      final styles = Map<String, dynamic>.from(branding['cardStyles'] as Map? ?? {});
      styles[key] = style.toJson();
      return {...branding, 'cardStyles': styles};
    });
    if (!ok && mounted) _showSaveError('the card style');
    return ok;
  }

  /// Writes [mutate]'s change to `branding` back into the exact PECC document
  /// [_ecConfig] was read from — group or per-factory, whichever is on
  /// screen. Every other field goes back unchanged: the API replaces
  /// `branding` (and `sections`/`pins`/`cards`/`groups`) wholesale rather than
  /// merging inside them, so sending anything less than the full document
  /// would silently erase whatever [mutate] did not itself just edit.
  Future<bool> _savePeccBranding(
    String uid,
    Map<String, dynamic> Function(Map<String, dynamic> branding) mutate,
  ) async {
    final current = _ecConfig;
    if (current == null) return false;
    final payload = Map<String, dynamic>.from(current);
    final branding = Map<String, dynamic>.from(payload['branding'] as Map? ?? {});
    payload['branding'] = mutate(branding);
    if (payload['sections'] is! List) payload['sections'] = <dynamic>[];
    try {
      const peccBase = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center';
      final res = await http
          .post(
            Uri.parse('$peccBase/$uid'),
            headers: AppConfig.headers,
            body: jsonEncode(payload),
          )
          .timeout(const Duration(seconds: 15));
      if (!mounted) return false;
      if (res.statusCode == 200) {
        setState(() => _ecConfig = payload);
        return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  void _showSaveError(String what) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Could not save $what. Nothing was changed.')),
    );
  }
}
