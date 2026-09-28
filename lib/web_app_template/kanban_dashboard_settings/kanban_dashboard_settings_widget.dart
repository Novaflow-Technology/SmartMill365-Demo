import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/energy_comparison/powerconsumptionenergydetailscard_widget.dart';
import 'package:smartmachine365/web_app_template/energy_comparison/Powerconsumptionhourlyenergydetailscard_widget.dart';
import 'package:smartmachine365/web_app_template/energy_details/Powerconsumptionhourlyenergydetailscard_widget.dart' as energy_details;
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/available_panel_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/frequent_use_templates_panel_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_settings_panel_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/select_dialog_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/widget_config_dialog.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/daily_max_demand_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/equipment_load_correlation_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/equipment_md_ranking_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/power_load_distribution_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/power_load_trend_chart_widget.dart';
import 'package:smartmachine365/web_app_template/max_demand_monitoring/yearonyear_analaysis_chart_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';

class KanbanDashboardSettingsWidget extends StatefulWidget {
  const KanbanDashboardSettingsWidget({super.key});

  @override
  State<KanbanDashboardSettingsWidget> createState() => _KanbanDashboardSettingsWidgetState();
}

class _KanbanDashboardSettingsWidgetState extends State<KanbanDashboardSettingsWidget> {
  final scaffoldKey = GlobalKey<ScaffoldState>();
  final _templatePanelKey = GlobalKey<FrequentUseTemplatesWidgetPanelState>();

  String _selectedTemplate = 'blank';
  String _previewTitle = '';
  String _previewRemark = '';
  Map<String, dynamic>? _selectedTemplateData;
  // uid of the user who originally created the currently-selected template.
  // Templates are stored under their creator's uid, so any edit / cell-save /
  // apply call MUST be addressed to that uid — not the current logged-in user
  // (who may be a non-superadmin viewing a shared dashboard).
  String _selectedTemplateOwnerUid = '';

  // 12 cells (4x3 grid). Null = empty slot.
  final List<KanbanCellConfig?> _cells = List.filled(12, null, growable: false);

  // Active template state (from GET /:uid/active)
  String? _activeTemplateId;
  String? _activeTemplateName;
  String? _lastAppliedAt;

  static const String _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      safeSetState(() {});
      _fetchActiveTemplate();
    });
  }

  // ---------------------------------------------------------------------------
  // API helpers
  // ---------------------------------------------------------------------------

  Future<void> _fetchActiveTemplate() async {
    final uid = AppStateNotifier.instance.uid ?? '';
    if (uid.isEmpty) return;

    try {
      final res = await http.get(
        Uri.parse('$_baseUrl/$uid/active'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 15));

      if (!mounted || res.statusCode != 200) return;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final settings = body['appliedSettings'] as Map<String, dynamic>?;

      setState(() {
        _activeTemplateId = body['activeTemplate'] as String?;
        _activeTemplateName = (settings?['kanbanDesc'] as String?) ?? (settings?['title'] as String?);
        _lastAppliedAt = settings?['appliedAt'] as String?;
      });
    } catch (e) {
      debugPrint('Error fetching active template: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Cell loading
  // ---------------------------------------------------------------------------

  void _loadCellsFromTemplate(Map<String, dynamic>? data) {
    for (int i = 0; i < _cells.length; i++) {
      _cells[i] = null;
    }

    final rawCells = data?['cells'] as List?;
    if (rawCells != null) {
      for (final raw in rawCells) {
        final rawMap = raw as Map<String, dynamic>? ?? {};
        final idx = (rawMap['cellIndex'] as num?)?.toInt() ?? -1;
        if (idx < 0 || idx >= _cells.length) continue;

        _cells[idx] = KanbanCellConfig(
          cellIndex: idx,
          widgetType: (rawMap['widgetType'] as String?) ?? '',
          widgetName: (rawMap['widgetName'] as String?) ?? '',
          size: (rawMap['size'] as String?) ?? '1x1',
          config: Map<String, dynamic>.from(rawMap['config'] ?? {}),
        );
      }
    }

    setState(() {});
  }

  /// Returns the uid that owns the currently-selected template (the user
  /// that created it). Falls back to the current logged-in user when no
  /// template is selected, so brand-new templates are saved under the
  /// current user's own document.
  String _ownerUid() {
    if (_selectedTemplateOwnerUid.isNotEmpty) return _selectedTemplateOwnerUid;
    return AppStateNotifier.instance.uid ?? '';
  }

  Future<void> _fetchAndLoadTemplate(String templateId) async {
    final uid = _ownerUid();
    if (uid.isEmpty || templateId == 'blank') return;

    try {
      final res = await http
          .get(
            Uri.parse('$_baseUrl/$uid'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 15));

      if (!mounted || res.statusCode != 200) return;

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      final templates = (body['data']?['templates'] as List?) ?? [];
      final fresh = templates.cast<Map<String, dynamic>>().firstWhere((t) => t['id'] == templateId, orElse: () => {});

      if (fresh.isEmpty) return;

      // If the stored template is missing interfaceType/ecConfig (saved before
      // those fields existed), carry them over from the currently-selected data
      // so the dropdown does not reset to the default.
      final merged = Map<String, dynamic>.from(fresh);
      if ((merged['interfaceType'] == null || (merged['interfaceType'] as String?)!.isEmpty) && _selectedTemplateData != null) {
        merged['interfaceType'] = _selectedTemplateData!['interfaceType'];
      }
      if (merged['ecConfig'] == null && _selectedTemplateData != null) {
        merged['ecConfig'] = _selectedTemplateData!['ecConfig'];
      }

      setState(() => _selectedTemplateData = merged);

      if (fresh['cells'] is List) {
        _loadCellsFromTemplate(fresh);
      }
    } catch (e) {
      debugPrint('Error fetching fresh template: $e');
    }
  }

  // ---------------------------------------------------------------------------
  // Cell interactions
  // ---------------------------------------------------------------------------

  void _onCellSaved(KanbanCellConfig saved) {
    setState(() => _cells[saved.cellIndex] = saved);
    _saveCellToApi(saved);
  }

  Future<void> _saveCellToApi(KanbanCellConfig cell) async {
    if (_selectedTemplate == 'blank') return;
    final uid = _ownerUid();
    if (uid.isEmpty) return;
    try {
      await http
          .put(
            Uri.parse('$_baseUrl/$uid/template/$_selectedTemplate/cell'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(cell.toJson()),
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Error saving cell to API: $e');
    }
  }

  Future<void> _openWidgetSelector(int cellIndex) async {
    if (_selectedTemplate == 'blank') {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Please select or save a template first'),
        backgroundColor: Colors.orange,
        duration: Duration(seconds: 2),
      ));
      return;
    }

    final uid = _ownerUid();
    if (uid.isEmpty) return;

    final existing = _cells[cellIndex];

    if (existing != null) {
      final meta = getWidgetMeta(existing.widgetType);
      if (meta == null) return;

      await showDialog<bool>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (_) => WidgetConfigDialog(
          cellIndex: cellIndex,
          widgetMeta: meta,
          uid: uid,
          templateId: _selectedTemplate,
          existingConfig: existing,
          onSaved: _onCellSaved,
        ),
      );
    } else {
      await showDialog<void>(
        context: context,
        useRootNavigator: true,
        barrierDismissible: false,
        builder: (_) => SelectDialogWidget(
          cellIndex: cellIndex,
          uid: uid,
          templateId: _selectedTemplate,
          onSaved: _onCellSaved,
        ),
      );
    }
  }

  void _onCellDrop(int fromIndex, int toIndex) {
    if (fromIndex == toIndex) return;
    final fromCell = _cells[fromIndex];
    final toCell = _cells[toIndex];

    // Swap locally
    setState(() {
      _cells[toIndex] = fromCell != null
          ? KanbanCellConfig(
              cellIndex: toIndex,
              widgetType: fromCell.widgetType,
              widgetName: fromCell.widgetName,
              size: fromCell.size,
              config: Map<String, dynamic>.from(fromCell.config),
            )
          : null;
      _cells[fromIndex] = toCell != null
          ? KanbanCellConfig(
              cellIndex: fromIndex,
              widgetType: toCell.widgetType,
              widgetName: toCell.widgetName,
              size: toCell.size,
              config: Map<String, dynamic>.from(toCell.config),
            )
          : null;
    });

    _persistCellSwap(fromIndex, toIndex, fromCell, toCell);
  }

  Future<void> _persistCellSwap(
    int fromIndex,
    int toIndex,
    KanbanCellConfig? originalFrom,
    KanbanCellConfig? originalTo,
  ) async {
    if (_selectedTemplate == 'blank') return;
    final uid = _ownerUid();
    if (uid.isEmpty) return;

    final futures = <Future>[];
    final cellUrl = '$_baseUrl/$uid/template/$_selectedTemplate/cell';

    // PUT fromCell at new toIndex position
    if (originalFrom != null) {
      final moved = KanbanCellConfig(
        cellIndex: toIndex,
        widgetType: originalFrom.widgetType,
        widgetName: originalFrom.widgetName,
        size: originalFrom.size,
        config: Map<String, dynamic>.from(originalFrom.config),
      );
      futures.add(
        http
            .put(
              Uri.parse(cellUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(moved.toJson()),
            )
            .timeout(const Duration(seconds: 10)),
      );
    }

    // PUT toCell at fromIndex (swap), or DELETE fromIndex if toCell was empty
    if (originalTo != null) {
      final swapped = KanbanCellConfig(
        cellIndex: fromIndex,
        widgetType: originalTo.widgetType,
        widgetName: originalTo.widgetName,
        size: originalTo.size,
        config: Map<String, dynamic>.from(originalTo.config),
      );
      futures.add(
        http
            .put(
              Uri.parse(cellUrl),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode(swapped.toJson()),
            )
            .timeout(const Duration(seconds: 10)),
      );
    } else {
      // fromCell moved to toIndex, so fromIndex slot is now empty
      futures.add(
        http.delete(
          Uri.parse('$_baseUrl/$uid/template/$_selectedTemplate/cell/$fromIndex'),
          headers: {'Content-Type': 'application/json'},
        ).timeout(const Duration(seconds: 10)),
      );
    }

    try {
      await Future.wait(futures);
    } catch (e) {
      debugPrint('Error persisting cell swap: $e');
    }
  }

  Future<void> _deleteCell(int cellIndex) async {
    if (_selectedTemplate == 'blank') return;
    final uid = _ownerUid();
    if (uid.isEmpty) return;

    setState(() => _cells[cellIndex] = null);

    try {
      await http.delete(
        Uri.parse('$_baseUrl/$uid/template/$_selectedTemplate/cell/$cellIndex'),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));
    } catch (e) {
      debugPrint('Error deleting cell: $e');
    }
  }

  Widget _buildCellPreview(KanbanCellConfig cell) => _CellPreviewWrapper(cell: cell);

  void _onTemplateApplied() {
    _templatePanelKey.currentState?.refresh();
    _fetchAndLoadTemplate(_selectedTemplate);
    _fetchActiveTemplate();
  }

  void _onTemplateSaved() => _templatePanelKey.currentState?.refresh();

  // ---------------------------------------------------------------------------
  // Page header
  // ---------------------------------------------------------------------------

  Widget _buildPageHeader(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final primary = theme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 24),
      padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLight
              ? [theme.primaryBackground, primary.withOpacity(0.06), theme.primaryBackground]
              : [const Color(0xFF020B2D), primary.withOpacity(0.06), const Color(0xFF020B2D)],
        ),
        border: Border(
          bottom: BorderSide(color: primary.withOpacity(0.3), width: 1),
        ),
      ),
      child: Stack(
        alignment: Alignment.center,
        children: [
          // ── Gradient accent lines ──
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [Colors.transparent, primary],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 24),
              const SizedBox(width: 24),
              Expanded(
                child: Container(
                  height: 1,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [primary, Colors.transparent],
                    ),
                  ),
                ),
              ),
            ],
          ),
          // ── Title ──
          Column(
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '[ ',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w300,
                      color: primary.withOpacity(0.5),
                    ),
                  ),
                  Text(
                    'KANBAN DASHBOARD SETTINGS',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: isLight ? theme.primaryText : Colors.white,
                      letterSpacing: 3.0,
                      shadows: [
                        Shadow(color: primary.withOpacity(0.8), blurRadius: 12),
                        Shadow(color: primary.withOpacity(0.4), blurRadius: 24),
                      ],
                    ),
                  ),
                  Text(
                    ' ]',
                    style: GoogleFonts.poppins(
                      fontSize: 18,
                      fontWeight: FontWeight.w300,
                      color: primary.withOpacity(0.5),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                'Dashboard  /  Kanban Dashboard Settings',
                style: GoogleFonts.poppins(
                  fontSize: 11,
                  fontWeight: FontWeight.w400,
                  color: primary,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          // ── Active template status ──
          Positioned(
            right: 0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'ACTIVE TEMPLATE',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w500,
                    color: theme.secondaryText,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0xFF10B981),
                    boxShadow: [
                      BoxShadow(
                        color: const Color(0xFF10B981).withOpacity(0.7),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  _activeTemplateName ?? 'None',
                  style: GoogleFonts.poppins(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isLight ? theme.primaryText : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  // ── Shared sidebar widgets ──
  Widget _buildSidebar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        FrequentUseTemplatesWidgetPanel(
          key: _templatePanelKey,
          selectedTemplateId: _selectedTemplate,
          onTemplateSelected: (id, title, remark, fullData) {
            final previousId = _selectedTemplate;
            setState(() {
              _selectedTemplate = id;
              _previewTitle = title;
              _previewRemark = remark;
              _selectedTemplateData = fullData;
              _selectedTemplateOwnerUid = (fullData['userId'] as String?) ?? '';
              // Clear cells whenever we switch to a different template.
              // Cells for the new template are then loaded from the server
              // by _fetchAndLoadTemplate. Re-selecting the same template
              // keeps local cells intact (preserving unsaved edits).
              if (id != previousId) {
                for (int i = 0; i < _cells.length; i++) {
                  _cells[i] = null;
                }
              }
            });
            _fetchAndLoadTemplate(id);
          },
        ),
        const SizedBox(height: 16),
        const AvailablePanelWidget(),
      ],
    );
  }

  Widget _buildSettingsPanel() {
    return KanbanSettingsPanelWidget(
      previewTitle: _previewTitle,
      previewRemark: _previewRemark,
      templateData: _selectedTemplateData,
      selectedTemplateId: _selectedTemplate,
      onTitleChanged: (v) => setState(() => _previewTitle = v),
      onRemarkChanged: (v) => setState(() => _previewRemark = v),
      onTemplateApplied: _onTemplateApplied,
      onTemplateSaved: _onTemplateSaved,
      activeTemplateId: _activeTemplateId,
      activeTemplateName: _activeTemplateName,
      lastAppliedAt: _lastAppliedAt,
      cells: List.unmodifiable(_cells),
      onCellTap: _openWidgetSelector,
      onCellDelete: _deleteCell,
      onCellDrop: _onCellDrop,
      widgetBuilder: _buildCellPreview,
      templateOwnerUid: _selectedTemplateOwnerUid,
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: LayoutBuilder(
          builder: (context, constraints) {
            final isWide = constraints.maxWidth >= 900;

            return SingleChildScrollView(
              padding: EdgeInsets.symmetric(
                horizontal: isWide ? 16 : 12,
                vertical: isWide ? 24 : 16,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildPageHeader(context),
                  if (isWide)
                    // ── Desktop: side-by-side ──
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _buildSidebar(),
                        const SizedBox(width: 16),
                        Expanded(child: _buildSettingsPanel()),
                      ],
                    )
                  else
                    // ── Mobile/Tablet: stacked ──
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildSidebar(),
                        const SizedBox(height: 16),
                        _buildSettingsPanel(),
                      ],
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

// =============================================================================
// _CellPreviewWrapper  — FIX: uses FittedBox to scale-down chart widgets
//                         so they never overflow their cell boundaries.
// =============================================================================

class _CellPreviewWrapper extends StatelessWidget {
  final KanbanCellConfig cell;
  const _CellPreviewWrapper({required this.cell});

  /// Safe config accessor — always returns a non-null String.
  String _str(String key) => (cell.config[key] as String?) ?? '';

  DateTime? _parseDate(String value) {
    if (value.isEmpty) return null;
    try {
      return DateTime.parse(value);
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      // Guard against zero-size constraints (e.g. during first layout pass).
      final w = constraints.maxWidth.isFinite && constraints.maxWidth > 0 ? constraints.maxWidth : 200.0;
      final h = constraints.maxHeight.isFinite && constraints.maxHeight > 0 ? constraints.maxHeight : 150.0;

      return ClipRect(
        child: SizedBox(
          width: w,
          height: h,
          // ── KEY FIX ────────────────────────────────────────────────────
          // Chart widgets have their own intrinsic sizes (often 300–400 px
          // tall).  Wrapping them in a FittedBox with BoxFit.contain makes
          // them scale down proportionally so they always fit the cell.
          //
          // IgnorePointer prevents the scaled chart from intercepting taps
          // that belong to the cell overlay (delete button, tap-to-edit).
          // ──────────────────────────────────────────────────────────────
          child: IgnorePointer(
            child: FittedBox(
              fit: BoxFit.contain,
              alignment: Alignment.topCenter,
              child: SizedBox(
                // Give the child a fixed reference size that matches a
                // "normal" single cell.  FittedBox will then scale the
                // whole subtree so it fits inside the actual cell.
                width: w,
                height: h,
                child: _buildContent(),
              ),
            ),
          ),
        ),
      );
    });
  }

  Widget _buildContent() {
    switch (cell.widgetType) {
      // -----------------------------------------------------------------------
      case 'EQUIPMENT_MD_RANKING':
        return EquipmentMdRankingChart(
          title: cell.widgetName,
          selectedEventDate: _str('eventDate'),
          selectedEventStart: _str('eventStart'),
          selectedEventEnd: _str('eventEnd'),
          rankingData: const [],
          isLoading: false,
          onRefresh: () {},
          onDateChanged: (_, __, ___) {},
        );

      // -----------------------------------------------------------------------
      case 'DAILY_CHART':
        return PowerconsumptionenergydetailscardWidget(
          title: cell.widgetName,
          chartData: const [],
          isLoading: false,
          period: _str('period'),
        );

      // -----------------------------------------------------------------------
      case 'HOURLY_CHART':
        return PowerconsumptionhourlyenergydetailscardWidget(
          title: cell.widgetName,
          selectedDate: _parseDate(_str('selectedDate')) ?? DateTime.now(),
          chartData: const [],
          isLoading: false,
          onDateChanged: (_) {},
          chartDataPrevious: const [],
        );

      // -----------------------------------------------------------------------
      case 'MONTHLY_CHART':
        return PowerconsumptionenergydetailscardWidget(
          title: cell.widgetName,
          chartData: const [],
          isLoading: false,
          period: _str('period'),
        );

      // -----------------------------------------------------------------------
      case 'YEAR_OVER_YEAR_CHART':
        return PowerconsumptionhourlyenergydetailscardWidget(
          title: cell.widgetName,
          selectedDate: _parseDate(_str('selectedDate')) ?? DateTime.now(),
          chartData: const [],
          isLoading: false,
          onDateChanged: (_) {},
          chartDataPrevious: const [],
        );

      case 'LAST24H_CHART':
        return energy_details.PowerconsumptionhourlyenergydetailscardWidget(
          title: cell.widgetName,
          selectedDate: _parseDate(_str('selectedDate')) ?? DateTime.now(),
          chartData: const [],
          isLoading: false,
          onDateChanged: (_) {},
          chartDataPrevious: const [],
        );

      // -----------------------------------------------------------------------
      case '24H_POWER_LOAD_TREND':
        return PowerLoadTrendChart(
          title: cell.widgetName,
          powerLoadData: const [],
          isLoading: false,
          contractCapacity: 0,
          lastUpdated: null,
        );

      // -----------------------------------------------------------------------
      case 'DAILY_MAX_DEMAND_THIS_MONTH':
        return DailyMaxDemandChart(
          title: cell.widgetName,
          chartData: const [],
          isLoading: false,
          onRefresh: () {},
          contractCapacity: 0,
        );

      // -----------------------------------------------------------------------
      case 'POWER_LOAD_DISTRIBUTION_TODAY':
        return PowerLoadDistributionChart(
          title: cell.widgetName,
          distributionData: const [],
          isLoading: false,
          onRefresh: () {},
        );

      // -----------------------------------------------------------------------
      case 'YEAR_ON_YEAR_ANALYSIS':
        return YearOnYearAnalysisChart(
          title: cell.widgetName,
          chartData: const [],
          comparisonYearData: const [],
          isLoading: false,
          onRefresh: () {},
          contractCapacity: 0,
        );

      // -----------------------------------------------------------------------
      case 'EQUIPMENT_LOAD_CORRELATION':
        return EquipmentLoadCorrelationChart(
          title: cell.widgetName,
          isLoading: false,
          onRefresh: () {},
          selectedEventDate: _str('eventDate'),
          selectedEventStart: _str('eventStart'),
          selectedEventEnd: _str('eventEnd'),
          seriesData: const {},
          deviceIds: const [],
          systemPeak: 0,
          errorMessage: '',
          selectedInterval: _str('interval'),
          onIntervalChanged: (_) {},
          onDateChanged: (_, __, ___) {},
        );

      // -----------------------------------------------------------------------
      default:
        return _PreviewPlaceholder(cell: cell);
    }
  }
}

// =============================================================================
// _PreviewPlaceholder
// =============================================================================

class _PreviewPlaceholder extends StatelessWidget {
  final KanbanCellConfig cell;
  const _PreviewPlaceholder({required this.cell});

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    return Container(
      color: Colors.transparent,
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cell.widgetName,
            style: TextStyle(
              color: theme.primary,
              fontSize: 13,
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            cell.widgetType,
            style: TextStyle(
              color: theme.primary.withOpacity(0.5),
              fontSize: 10,
              fontFamily: 'Poppins',
            ),
          ),
          const Spacer(),
          Center(
            child: Icon(
              Icons.bar_chart_outlined,
              color: theme.primary.withOpacity(0.2),
              size: 40,
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }
}
