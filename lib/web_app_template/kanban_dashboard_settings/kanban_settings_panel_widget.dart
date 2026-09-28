import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/components/card_widget/card_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_dropdown_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_form_field_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/kanban_text_field_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/ecc_interface_preview_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/monitor_preview_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/radio_option_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/row_counter_widget.dart';
import 'package:smartmachine365/web_app_template/kanban_dashboard_settings/widget_config_dialog.dart';
import '../../services/app_config.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';

const _kCardBg = Color.fromRGBO(0, 4, 51, 1);
const _kBorderRadius = 16.0;

BoxDecoration kanbanCardDecoration(BuildContext context) {
  final isLight = Theme.of(context).brightness == Brightness.light;
  final primary = FlutterFlowTheme.of(context).primary;
  return BoxDecoration(
    borderRadius: BorderRadius.circular(_kBorderRadius),
    color: isLight ? FlutterFlowTheme.of(context).secondaryBackground : _kCardBg,
    border: Border.all(color: primary.withOpacity(0.4), width: 1),
    boxShadow: [
      BoxShadow(
        color: primary.withOpacity(0.08),
        blurRadius: 16,
        spreadRadius: 1,
      ),
    ],
  );
}

class KanbanSettingsPanelWidget extends StatefulWidget {
  final String previewTitle;
  final String previewRemark;
  final Map<String, dynamic>? templateData;
  final String? selectedTemplateId;
  final ValueChanged<String> onTitleChanged;
  final ValueChanged<String> onRemarkChanged;
  final VoidCallback? onTemplateApplied;
  final VoidCallback? onTemplateSaved;

  // ── Currently-active template info (from GET /:uid/active) ──────────────
  /// The templateId that was last successfully applied to the dashboard.
  final String? activeTemplateId;

  /// Human-readable name/desc of the active template, shown in the status bar.
  final String? activeTemplateName;

  /// ISO timestamp of the last apply action.
  final String? lastAppliedAt;

  // ── Cell grid ────────────────────────────────────────────────────────────
  final List<KanbanCellConfig?> cells;
  final void Function(int cellIndex)? onCellTap;
  final void Function(int cellIndex)? onCellDelete;
  final void Function(int fromIndex, int toIndex)? onCellDrop;
  final Widget Function(KanbanCellConfig cell)? widgetBuilder;

  /// uid of the user that originally created the currently-selected template.
  /// When non-empty, update / apply calls are routed to this uid instead of
  /// the current logged-in user, so non-superadmin roles can edit shared
  /// dashboards published by an admin.
  final String? templateOwnerUid;

  const KanbanSettingsPanelWidget({
    Key? key,
    required this.previewTitle,
    required this.previewRemark,
    this.templateData,
    this.selectedTemplateId,
    required this.onTitleChanged,
    required this.onRemarkChanged,
    this.onTemplateApplied,
    this.onTemplateSaved,
    // active template status
    this.activeTemplateId,
    this.activeTemplateName,
    this.lastAppliedAt,
    // cells
    this.cells = const [],
    this.onCellTap,
    this.onCellDelete,
    this.onCellDrop,
    this.widgetBuilder,
    this.templateOwnerUid,
  }) : super(key: key);

  @override
  State<KanbanSettingsPanelWidget> createState() => _KanbanSettingsPanelState();
}

class _KanbanSettingsPanelState extends State<KanbanSettingsPanelWidget> {
  final _descController = TextEditingController();
  final _titleController = TextEditingController();
  final _remarkController = TextEditingController();
  final _intervalController = TextEditingController();

  // ── Interface type selector ──────────────────────────────────────────────
  /// 'KANBAN_GRID' or 'ECC'
  String _selectedInterfaceType = '';

  // ── PECC config (fetched from Plant Energy Command Center) ───────────────
  Map<String, dynamic>? _peccConfig;
  bool _isLoadingPecc = false;

  // ── Data Config Setting (ECC only) ──────────────────────────────────
  static const _allDataConfigs = [
    'Energy cost',
    'Energy consumption',
    'Max demand',
    'PF',
    'MD charges',
    'Carbon emission',
  ];
  String? _dataConfigSetting;
  final List<String> _recentDataConfigs = [];

  bool displayDefaultTitle = true;
  bool showGrid = true;
  bool showChartValue = false;

  String layout = 'Above 100 in. Vertical Screen Kanban (4x3 ...)';
  String leftOption = 'Picture / L...';
  String rightOption = 'Time';
  String displayMode = 'Scroll Up/...';
  int interval = 20;

  int headerRows = 0;
  int headerMax = 2;
  int footerRows = 0;
  int footerMax = 1;

  String previewTitle = '';
  String previewDesc = '';
  String previewRemark = '';

  bool _isSaving = false;
  bool _isApplying = false;
  bool _isUpdating = false;

  // ── Derived helpers ──────────────────────────────────────────────────────

  /// True when the user has picked a real existing template (not blank).
  bool get _isExistingTemplate => widget.selectedTemplateId != null && widget.selectedTemplateId!.isNotEmpty && widget.selectedTemplateId != 'blank';

  /// True when the selected template is the one currently applied to the
  /// dashboard — used to decorate the Apply button.
  bool get _isCurrentlyActive => _isExistingTemplate && widget.activeTemplateId != null && widget.selectedTemplateId == widget.activeTemplateId;

  // ── Lifecycle ─────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    _titleController.addListener(() => setState(() => previewTitle = _titleController.text));
    _descController.addListener(() => setState(() => previewDesc = _descController.text));
    _remarkController.addListener(() => setState(() => previewRemark = _remarkController.text));
    _intervalController.addListener(() {
      final parsed = int.tryParse(_intervalController.text);
      if (parsed != null) {
        setState(() => interval = parsed);
      }
    });

    _titleController.text = widget.previewTitle;
    _remarkController.text = widget.previewRemark;
    _intervalController.text = interval.toString();

    if (widget.templateData != null) {
      _loadTemplateData(widget.templateData!);
    }

    _fetchPeccConfig();
  }

  @override
  void didUpdateWidget(covariant KanbanSettingsPanelWidget old) {
    super.didUpdateWidget(old);
    if (old.previewTitle != widget.previewTitle) _titleController.text = widget.previewTitle;
    if (old.previewRemark != widget.previewRemark) _remarkController.text = widget.previewRemark;
    if (old.templateData != widget.templateData && widget.templateData != null) {
      // Only fully reload when a DIFFERENT template is selected.
      // If the same template ID comes in (async refresh from _fetchAndLoadTemplate),
      // skip the reload so user's manual dropdown/field changes are preserved.
      final oldId = old.templateData?['id'] as String?;
      final newId = widget.templateData!['id'] as String?;
      if (oldId != newId) {
        _loadTemplateData(widget.templateData!);
      }
    }
  }

  @override
  void dispose() {
    _descController.dispose();
    _titleController.dispose();
    _remarkController.dispose();
    _intervalController.dispose();
    super.dispose();
  }

  // ── Data helpers ──────────────────────────────────────────────────────────
  void _loadTemplateData(Map<String, dynamic> data) {
    setState(() {
      _descController.text = data['kanbanDesc'] ?? '';
      _titleController.text = data['title'] ?? '';
      _remarkController.text = data['remark'] ?? '';
      _intervalController.text = (data['interval'] ?? 20).toString();
      interval = data['interval'] ?? 20;
      layout = _layoutEnumToString(data['layout'] ?? 'VERTICAL_4X3');
      leftOption = _leftEnumToString(data['left'] ?? 'PICTURE');
      rightOption = _rightEnumToString(data['right'] ?? 'TIME');
      displayMode = _displayEnumToString(data['display'] ?? 'SCROLL_UP');
      displayDefaultTitle = data['displayDefaultTitle'] ?? true;
      showGrid = data['showGrid'] ?? true;
      showChartValue = data['chartValue'] ?? false;
      headerRows = data['headerRows'] ?? 0;
      footerRows = data['footerRows'] ?? 0;
      _selectedInterfaceType = data['interfaceType'] ?? 'KANBAN_GRID';
      if (data['ecConfig'] is Map<String, dynamic>) {
        _peccConfig = data['ecConfig'] as Map<String, dynamic>;
      } else {
        _peccConfig = null;
      }
    });
    // After setState: sync PECC config state to the resolved interface type.
    // Always re-fetch the live PECC config for ECC templates — the template's
    // own ecConfig is a snapshot taken when it was last saved/applied, so it
    // goes stale the moment branding (e.g. the factory photo) is updated on
    // the separate Plant Energy Command Center settings page.
    if (_selectedInterfaceType == 'ECC') {
      _fetchPeccConfig();
    }
  }

  // ── PECC config fetch ─────────────────────────────────────────────────────

  Future<void> _fetchPeccConfig() async {
    final uid = AppStateNotifier.instance.uid ?? '';
    if (uid.isEmpty) return;
    setState(() => _isLoadingPecc = true);
    try {
      final res = await http
          .get(
            Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/plant-energy-command-center/$uid'),
            headers: AppConfig.headers,
          )
          .timeout(const Duration(seconds: 10));
      if (!mounted) return;
      if (res.statusCode == 200) {
        final body = jsonDecode(res.body) as Map<String, dynamic>;
        if (body['exists'] == true && body['settings'] != null) {
          setState(() => _peccConfig = body['settings'] as Map<String, dynamic>);
        }
      }
    } catch (e) {
      debugPrint('[PECC fetch] error: $e');
    }
    if (mounted) setState(() => _isLoadingPecc = false);
  }

  // ── ECC mapping helpers ───────────────────────────────────────────────────

  String get _eccOrgName => ((_peccConfig?['branding'] as Map<String, dynamic>?)?['topBarBranding'] ?? '').toString();

  String get _eccLocationBadge => ((_peccConfig?['branding'] as Map<String, dynamic>?)?['buildingLabel'] ?? '').toString();

  String get _eccDashTitle {
    final label = _eccLocationBadge;
    return label.isEmpty ? 'ENERGY COMMAND CENTER' : '$label ENERGY COMMAND CENTER';
  }

  String get _eccBgImageUrl => ((_peccConfig?['branding'] as Map<String, dynamic>?)?['photoUrl'] ?? '').toString();

  List<String> get _eccCostDriverLabels {
    for (final sec in (_peccConfig?['sections'] as List<dynamic>? ?? [])) {
      final s = sec as Map<String, dynamic>;
      if ((s['title']?.toString() ?? '').contains('Cost Drivers')) {
        return (s['widgets'] as List<dynamic>? ?? []).map((w) => (w as Map<String, dynamic>)['label']?.toString() ?? '').toList();
      }
    }
    return [];
  }

  // ── Enum converters ───────────────────────────────────────────────────────
  String _layoutEnumToString(String v) {
    switch (v.toUpperCase()) {
      case 'STANDARD_3X2':
        return 'Standard Kanban (3x2)';
      case 'WIDE_5X3':
        return 'Wide Kanban (5x3)';
      default:
        return 'Above 100 in. Vertical Screen Kanban (4x3 ...)';
    }
  }

  String _leftEnumToString(String v) {
    switch (v.toUpperCase()) {
      case 'LOGO':
        return 'Logo';
      case 'NONE':
        return 'None';
      default:
        return 'Picture / L...';
    }
  }

  String _rightEnumToString(String v) {
    switch (v.toUpperCase()) {
      case 'DATE':
        return 'Date';
      case 'NONE':
        return 'None';
      default:
        return 'Time';
    }
  }

  String _displayEnumToString(String v) {
    switch (v.toUpperCase()) {
      case 'FADE':
        return 'Fade';
      case 'SLIDE':
        return 'Slide';
      default:
        return 'Scroll Up/...';
    }
  }

  String get leftOptionEnum => leftOption == 'Logo'
      ? 'LOGO'
      : leftOption == 'None'
          ? 'NONE'
          : 'PICTURE';
  String get rightOptionEnum => rightOption == 'Date'
      ? 'DATE'
      : rightOption == 'None'
          ? 'NONE'
          : 'TIME';
  String get displayModeEnum => displayMode == 'Fade'
      ? 'FADE'
      : displayMode == 'Slide'
          ? 'SLIDE'
          : 'SCROLL_UP';
  String get layoutEnum => layout == 'Standard Kanban (3x2)'
      ? 'STANDARD_3X2'
      : layout == 'Wide Kanban (5x3)'
          ? 'WIDE_5X3'
          : 'VERTICAL_4X3';

  Map<String, dynamic> get _bodyPayload => {
        "kanbanDesc": _descController.text,
        "layout": layoutEnum,
        "remark": _remarkController.text,
        "title": _titleController.text,
        "left": leftOptionEnum,
        "right": rightOptionEnum,
        "display": displayModeEnum,
        "interval": interval,
        "chartValue": showChartValue,
        "footer": footerRows > 0,
        "headerRows": headerRows,
        "footerRows": footerRows,
        "displayDefaultTitle": displayDefaultTitle,
        "showGrid": showGrid,
        // Include current cell layout so the server doesn't clear them on update.
        "cells": widget.cells.where((c) => c != null).map((c) => c!.toJson()).toList(),
        "interfaceType": _selectedInterfaceType,
        if (_peccConfig != null) "ecConfig": _peccConfig!,
      };

  // ── API calls ─────────────────────────────────────────────────────────────
  static const _base = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings';

  Future<void> _saveTemplate() async {
    final uid = AppStateNotifier.instance.uid ?? '';
    if (uid.isEmpty) return _showError('User ID is missing');

    setState(() => _isSaving = true);
    try {
      final res =
          await http.post(Uri.parse('$_base/$uid'), headers: AppConfig.headers, body: jsonEncode(_bodyPayload)).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        _showSuccess('Kanban template saved successfully');
        widget.onTemplateSaved?.call();
      } else {
        _showError(_parseError(res.body, 'Failed to save'));
      }
    } on TimeoutException {
      _showError('Request timed out');
    } on SocketException catch (e) {
      _showError('Network error: ${e.message}');
    } catch (e) {
      _showError('Error: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _updateTemplate() async {
    // Existing templates live under their original creator's uid — route the
    // update there so non-superadmin roles can edit shared dashboards.
    final ownerUid = widget.templateOwnerUid ?? '';
    final uid = ownerUid.isNotEmpty ? ownerUid : (AppStateNotifier.instance.uid ?? '');
    final tid = widget.selectedTemplateId ?? '';
    if (uid.isEmpty) return _showError('User ID is missing');
    if (!_isExistingTemplate) return _showError('Please select a valid template to update');

    setState(() => _isUpdating = true);
    try {
      final res = await http
          .put(Uri.parse('$_base/$uid/template/$tid'), headers: AppConfig.headers, body: jsonEncode(_bodyPayload))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        _showSuccess('Kanban template updated successfully');
        widget.onTemplateSaved?.call();
      } else {
        _showError(_parseError(res.body, 'Failed to update'));
      }
    } on TimeoutException {
      _showError('Request timed out');
    } on SocketException catch (e) {
      _showError('Network error: ${e.message}');
    } catch (e) {
      _showError('Error: $e');
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  Future<void> _applyTemplate() async {
    final ownerUid = widget.templateOwnerUid ?? '';
    final uid = ownerUid.isNotEmpty ? ownerUid : (AppStateNotifier.instance.uid ?? '');
    final tid = widget.selectedTemplateId ?? '';
    if (uid.isEmpty) return _showError('User ID is missing');
    if (!_isExistingTemplate) return _showError('Please select a valid template to apply');

    setState(() => _isApplying = true);
    try {
      final res = await http
          .post(Uri.parse('$_base/$uid/apply/$tid'), headers: {'Content-Type': 'application/json'}, body: jsonEncode({}))
          .timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final result = jsonDecode(res.body) as Map<String, dynamic>;
        if (!mounted) return;
        final applied = result['appliedSettings'];
        if (applied is Map<String, dynamic>) {
          // The apply response wraps template fields under 'settings'.
          final settings = applied['settings'];
          _loadTemplateData(
            settings is Map<String, dynamic> ? settings : applied,
          );
        }
        _showSuccess(result['message'] ?? 'Template applied successfully');
        widget.onTemplateApplied?.call();
      } else {
        _showError(_parseError(res.body, 'Failed to apply template'));
      }
    } on TimeoutException {
      _showError('Request timed out');
    } on SocketException catch (e) {
      _showError('Network error: ${e.message}');
    } catch (e) {
      _showError('Error: $e');
    } finally {
      if (mounted) setState(() => _isApplying = false);
    }
  }

  // ── Feedback helpers ──────────────────────────────────────────────────────
  String _parseError(String body, String fallback) {
    try {
      return jsonDecode(body)['error'] ?? fallback;
    } catch (_) {
      return fallback;
    }
  }

  void _showError(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.red,
      duration: const Duration(seconds: 3),
    ));
  }

  void _showSuccess(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
      content: Text(msg),
      backgroundColor: Colors.green,
      duration: const Duration(seconds: 3),
    ));
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);

    return CardWidget(
      glowColor: theme.primary,
      blurSigma: 2,
      topPadMultiplier: 0.8,
      bottomPadMultiplier: 0.8,
      armLenMultiplier: 0.4,
      builder: (context, sizing) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.activeTemplateId != null) const SizedBox(height: 12),

          // ── Form fields ──────────────────────────────────────────────────
          KanbanFormFieldWidget(
            label: 'Kanban Desc.:',
            required: true,
            child: KanbanTextFieldWidget(controller: _descController),
          ),
          const SizedBox(height: 10),
          Row(children: [
            Expanded(
              child: KanbanFormFieldWidget(
                label: 'Layout:',
                required: true,
                child: KanbanDropdownWidget(
                  value: layout,
                  items: [
                    'Above 100 in. Vertical Screen Kanban (4x3 ...)',
                    'Standard Kanban (3x2)',
                    'Wide Kanban (5x3)',
                  ],
                  onChanged: (v) => setState(() => layout = v!),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Row(children: [
              Checkbox(
                value: displayDefaultTitle,
                onChanged: (v) => setState(() => displayDefaultTitle = v!),
                activeColor: theme.primary,
                side: BorderSide(color: theme.primary),
              ),
              Text('Display Default Title', style: TextStyle(color: theme.primaryText, fontSize: 12, fontFamily: 'Poppins')),
              const SizedBox(width: 16),
              Checkbox(
                value: showGrid,
                onChanged: (v) => setState(() => showGrid = v!),
                activeColor: theme.primary,
                side: BorderSide(color: theme.primary),
              ),
              Text('Show grid or not', style: TextStyle(color: theme.primaryText, fontSize: 12, fontFamily: 'Poppins')),
            ]),
          ]),
          const SizedBox(height: 10),
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: KanbanFormFieldWidget(
                label: 'Remark:',
                child: SizedBox(
                  height: 70,
                  child: TextField(
                    controller: _remarkController,
                    maxLines: 3,
                    style: TextStyle(color: theme.primaryText, fontSize: 13, fontFamily: 'Poppins'),
                    decoration: InputDecoration(
                      filled: true,
                      fillColor: theme.primary.withOpacity(0.04),
                      contentPadding: const EdgeInsets.all(8),
                      border:
                          OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: theme.primary.withOpacity(0.5))),
                      enabledBorder:
                          OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: theme.primary.withOpacity(0.5))),
                      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(6), borderSide: BorderSide(color: theme.primary)),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(children: [
                KanbanFormFieldWidget(label: 'Title:', labelWidth: 60, child: KanbanTextFieldWidget(controller: _titleController)),
                const SizedBox(height: 8),
                KanbanFormFieldWidget(
                  label: 'Left:',
                  labelWidth: 60,
                  child: Row(children: [
                    Expanded(
                        child: KanbanDropdownWidget(
                            value: leftOption, items: ['Picture / L...', 'Logo', 'None'], onChanged: (v) => setState(() => leftOption = v!))),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed: () {},
                      child: Text('Upload Image', style: TextStyle(color: theme.primary, fontSize: 12, fontFamily: 'Poppins')),
                    ),
                  ]),
                ),
                const SizedBox(height: 8),
                KanbanFormFieldWidget(
                    label: 'Right:',
                    labelWidth: 60,
                    child: KanbanDropdownWidget(
                        value: rightOption, items: ['Time', 'Date', 'None'], onChanged: (v) => setState(() => rightOption = v!))),
                const SizedBox(height: 8),
                KanbanFormFieldWidget(
                  label: 'Display:',
                  labelWidth: 60,
                  child: Row(children: [
                    Expanded(
                        child: KanbanDropdownWidget(
                            value: displayMode, items: ['Scroll Up/...', 'Fade', 'Slide'], onChanged: (v) => setState(() => displayMode = v!))),
                    const SizedBox(width: 8),
                    Text('Interval:', style: TextStyle(color: theme.primaryText, fontSize: 12, fontFamily: 'Poppins')),
                    const SizedBox(width: 4),
                    SizedBox(width: 50, child: KanbanTextFieldWidget(controller: _intervalController, hint: '20')),
                    const SizedBox(width: 4),
                    Text('Second', style: TextStyle(color: theme.primaryText, fontSize: 12, fontFamily: 'Poppins')),
                  ]),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  const SizedBox(width: 68),
                  Text('Chart Value:', style: TextStyle(color: theme.primaryText, fontSize: 12, fontFamily: 'Poppins')),
                  const SizedBox(width: 8),
                  RadioOptionWidget(
                      label: 'Do not show', value: false, groupValue: showChartValue, onChanged: (v) => setState(() => showChartValue = v!)),
                  const SizedBox(width: 12),
                  RadioOptionWidget(label: 'Show', value: true, groupValue: showChartValue, onChanged: (v) => setState(() => showChartValue = v!)),
                ]),
              ]),
            ),
          ]),

          const SizedBox(height: 16),
          Divider(color: FlutterFlowTheme.of(context).alternate),
          const SizedBox(height: 20),

          // ── Interface Display (Kanban Grid / Energy Command Center) ──────────
          _buildInterfaceDisplaySection(context),
        ],
      ),
    );
  }

  // ── Interface Display Section ─────────────────────────────────────────────

  Widget _buildInterfaceDisplaySection(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final primary = theme.primary;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: primary.withOpacity(0.3)),
        color: isLight ? theme.secondaryBackground : const Color(0xFF00041E),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header ──────────────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: primary.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.desktop_mac_outlined, color: primary, size: 18),
                ),
                const SizedBox(width: 12),
                Text(
                  'Interface Display',
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isLight ? theme.primaryText : Colors.white,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // ── Dropdown selector ────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: KanbanFormFieldWidget(
              label: 'Display Type:',
              labelWidth: 96,
              child: KanbanDropdownWidget(
                value: _selectedInterfaceType == 'ECC' ? 'Energy Command Center' : 'Kanban Grid',
                items: const ['Kanban Grid', 'Energy Command Center'],
                onChanged: (v) {
                  final next = v == 'Energy Command Center' ? 'ECC' : 'KANBAN_GRID';
                  setState(() => _selectedInterfaceType = next);
                  if (next == 'ECC') _fetchPeccConfig();
                },
              ),
            ),
          ),
          const SizedBox(height: 12),

          Divider(height: 1, color: primary.withOpacity(0.2)),

          // ── Preview content ──────────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: _selectedInterfaceType == 'ECC' ? _buildEccPreview(context) : _buildKanbanGridPreview(context),
          ),

          Divider(height: 1, color: primary.withOpacity(0.2)),

          // ── Action buttons (per-interface) ───────────────────────────────────
          Padding(
            padding: const EdgeInsets.all(16),
            child: _ActionButtons(
              isExistingTemplate: _isExistingTemplate,
              isCurrentlyActive: _isCurrentlyActive,
              isSaving: _isSaving,
              isUpdating: _isUpdating,
              isApplying: _isApplying,
              onCancel: () => Navigator.of(context).maybePop(),
              onSave: _saveTemplate,
              onUpdate: _updateTemplate,
              onApply: _applyTemplate,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEccPreview(BuildContext context) {
    if (_isLoadingPecc) {
      return const SizedBox(
        height: 80,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_peccConfig == null)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'No Plant Energy Command Center config found. Configure it first in Plant Energy Command Center settings.',
              style: GoogleFonts.poppins(fontSize: 11, color: Colors.orange.shade300),
            ),
          ),
        // ── Data Config Setting field ──────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              SizedBox(
                width: 140,
                child: Text(
                  'Data Config Setting',
                  style: GoogleFonts.poppins(fontSize: 12, fontWeight: FontWeight.w500),
                ),
              ),
              Expanded(
                child: _DataConfigDropdown(
                  value: _dataConfigSetting,
                  allItems: _allDataConfigs,
                  recentItems: _recentDataConfigs,
                  onChanged: (v) {
                    setState(() {
                      _dataConfigSetting = v;
                      if (v != null) {
                        _recentDataConfigs.remove(v);
                        _recentDataConfigs.insert(0, v);
                        if (_recentDataConfigs.length > 3) _recentDataConfigs.removeLast();
                      }
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        EccInterfacePreviewWidget(
          orgName: _eccOrgName,
          orgSubLabel: '',
          dashTitle: _eccDashTitle,
          dashSubtitle: '',
          locationBadge: _eccLocationBadge,
          costDriverLabels: _eccCostDriverLabels,
          bgImageUrl: _eccBgImageUrl,
        ),
      ],
    );
  }

  Widget _buildKanbanGridPreview(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (!_isExistingTemplate)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Text(
                    'Save a template first, then tap a cell to add a widget',
                    style: TextStyle(color: Colors.orange.shade300, fontSize: 11, fontFamily: 'Poppins'),
                  ),
                ),
              MonitorPreviewWidget(
                headerRows: headerRows,
                footerRows: footerRows,
                dateLabel: previewTitle,
                cells: widget.cells,
                onCellTap: widget.onCellTap,
                onCellDelete: widget.onCellDelete,
                onCellDrop: widget.onCellDrop,
                widgetBuilder: widget.widgetBuilder,
              ),
            ],
          ),
        ),
        const SizedBox(width: 16),
        Column(children: [
          RowCounterWidget(
            label: 'Header',
            current: headerRows,
            max: headerMax,
            onAdd: () {
              if (headerRows < headerMax) setState(() => headerRows++);
            },
            onRemove: () {
              if (headerRows > 0) setState(() => headerRows--);
            },
          ),
          const SizedBox(height: 24),
          RowCounterWidget(
            label: 'Footer',
            current: footerRows,
            max: footerMax,
            onAdd: () {
              if (footerRows < footerMax) setState(() => footerRows++);
            },
            onRemove: () {
              if (footerRows > 0) setState(() => footerRows--);
            },
          ),
        ]),
      ],
    );
  }
}

class _ActionButtons extends StatelessWidget {
  final bool isExistingTemplate;
  final bool isCurrentlyActive;
  final bool isSaving;
  final bool isUpdating;
  final bool isApplying;
  final VoidCallback onCancel;
  final VoidCallback onSave;
  final VoidCallback onUpdate;
  final VoidCallback onApply;

  const _ActionButtons({
    required this.isExistingTemplate,
    required this.isCurrentlyActive,
    required this.isSaving,
    required this.isUpdating,
    required this.isApplying,
    required this.onCancel,
    required this.onSave,
    required this.onUpdate,
    required this.onApply,
  });

  static Widget _spinner() =>
      const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, valueColor: AlwaysStoppedAnimation(Colors.white)));

  @override
  Widget build(BuildContext context) {
    final theme = FlutterFlowTheme.of(context);

    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        // ── Cancel ──────────────────────────────────────────────────────────
        OutlinedButton(
          onPressed: onCancel,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.primaryText,
            side: BorderSide(color: theme.primary.withOpacity(0.5)),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          ),
          child: const Text('Cancel', style: TextStyle(fontFamily: 'Poppins', fontSize: 13)),
        ),

        // ── Existing template actions ────────────────────────────────────────
        if (isExistingTemplate) ...[
          const SizedBox(width: 12),

          // Apply Template
          Tooltip(
            message: isCurrentlyActive ? 'This template is currently live on the dashboard' : 'Push this template to the live dashboard',
            child: ElevatedButton.icon(
              onPressed: isApplying ? null : onApply,
              icon: isApplying
                  ? _spinner()
                  : Icon(
                      isCurrentlyActive ? Icons.check_circle : Icons.play_arrow_rounded,
                      size: 16,
                    ),
              label: Text(
                isCurrentlyActive ? 'Applied' : 'Apply Template',
                style: const TextStyle(fontFamily: 'Poppins', fontSize: 13),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: isCurrentlyActive
                    ? const Color(0xFF00897B) // teal-green when live
                    : Colors.orange.shade700,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),

          const SizedBox(width: 12),

          // Update Template
          ElevatedButton.icon(
            onPressed: isUpdating ? null : onUpdate,
            icon: isUpdating ? _spinner() : const Icon(Icons.save_outlined, size: 16),
            label: const Text('Update Template', style: TextStyle(fontFamily: 'Poppins', fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],

        // ── New (blank) template action ──────────────────────────────────────
        if (!isExistingTemplate) ...[
          const SizedBox(width: 12),
          ElevatedButton.icon(
            onPressed: isSaving ? null : onSave,
            icon: isSaving ? _spinner() : const Icon(Icons.add_circle_outline, size: 16),
            label: const Text('Save Template', style: TextStyle(fontFamily: 'Poppins', fontSize: 13)),
            style: ElevatedButton.styleFrom(
              backgroundColor: theme.primary,
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
            ),
          ),
        ],
      ],
    );
  }
}

// ── Data Config Setting Dropdown ─────────────────────────────────────────────
class _DataConfigDropdown extends StatefulWidget {
  final String? value;
  final List<String> allItems;
  final List<String> recentItems;
  final ValueChanged<String?> onChanged;

  const _DataConfigDropdown({
    required this.value,
    required this.allItems,
    required this.recentItems,
    required this.onChanged,
  });

  @override
  State<_DataConfigDropdown> createState() => _DataConfigDropdownState();
}

class _DataConfigDropdownState extends State<_DataConfigDropdown> {
  final _layerLink = LayerLink();
  OverlayEntry? _overlay;
  bool _open = false;

  void _toggle() => _open ? _close() : _show();

  void _close() {
    _overlay?.remove();
    _overlay = null;
    setState(() => _open = false);
  }

  void _show() {
    final renderBox = context.findRenderObject() as RenderBox;
    final size = renderBox.size;

    // Build items: recent first (with divider), then remaining
    final recent = widget.recentItems;
    final rest = widget.allItems.where((e) => !recent.contains(e)).toList();

    _overlay = OverlayEntry(
      builder: (_) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        onTap: _close,
        child: Stack(children: [
          CompositedTransformFollower(
            link: _layerLink,
            showWhenUnlinked: false,
            offset: Offset(0, size.height + 4),
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              color: const Color(0xFF1A2133),
              child: SizedBox(
                width: size.width,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (recent.isNotEmpty) ...[
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                        child: Text('Recent', style: GoogleFonts.poppins(fontSize: 10, color: Colors.white38)),
                      ),
                      for (final item in recent)
                        _dropdownItem(item, isRecent: true),
                      const Divider(height: 1, color: Colors.white12),
                    ],
                    for (final item in rest) _dropdownItem(item),
                  ],
                ),
              ),
            ),
          ),
        ]),
      ),
    );
    Overlay.of(context).insert(_overlay!);
    setState(() => _open = true);
  }

  Widget _dropdownItem(String item, {bool isRecent = false}) {
    final selected = widget.value == item;
    return InkWell(
      onTap: () {
        _close();
        widget.onChanged(item);
      },
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        color: selected ? const Color(0xFF1E88E5).withOpacity(0.15) : Colors.transparent,
        child: Row(children: [
          if (isRecent) const Icon(Icons.history, size: 14, color: Colors.white38),
          if (isRecent) const SizedBox(width: 6),
          Expanded(child: Text(item, style: GoogleFonts.poppins(fontSize: 12, color: Colors.white))),
          if (selected) const Icon(Icons.check, size: 14, color: Color(0xFF1E88E5)),
        ]),
      ),
    );
  }

  @override
  void dispose() {
    _close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CompositedTransformTarget(
      link: _layerLink,
      child: GestureDetector(
        onTap: _toggle,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: _open ? const Color(0xFF1E88E5) : Colors.white24),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Expanded(
              child: Text(
                widget.value ?? 'Select data config...',
                style: GoogleFonts.poppins(fontSize: 12, color: widget.value != null ? Colors.white : Colors.white38),
              ),
            ),
            Icon(_open ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 18, color: Colors.white54),
          ]),
        ),
      ),
    );
  }
}
