import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:url_launcher/link.dart';
import 'package:smartmachine365/flutter_flow/nav/main_layout_cubit.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/user_presence.dart';
import '/flutter_flow/nav/nav.dart';
import '/flutter_flow/session_storage.dart';
import 'package:flutter/material.dart';
import 'home_page_dialog.dart';
import 'side_nav_model.dart';
import '/web_app_template/pom_command_center/pom_config.dart';
export 'side_nav_model.dart';
import 'package:expandable/expandable.dart';
import 'package:smartmachine365/web_app_template/notifications/notification_bell_widget.dart';

class SideNavWidget extends StatefulWidget {
  const SideNavWidget({
    super.key,
    this.selectedNav = 1,
    required this.name,
    required this.email,
    required this.roles,
  });

  final int selectedNav;
  final String name;
  final String email;
  final String roles;

  @override
  State<SideNavWidget> createState() => _SideNavWidgetState();
}

class _SideNavWidgetState extends State<SideNavWidget> {
  late SideNavModel _model;
  late String roles;
  late String name;
  late String email;

  String? _hoveredItem;
  static final Map<String, String> _resolvedPathsCache = {};

  static const _kFadeExtra = <String, dynamic>{
    kTransitionInfoKey: TransitionInfo(
      hasTransition: true,
      transitionType: PageTransitionType.fade,
      duration: Duration(milliseconds: 0),
    ),
  };

  // ── Cyberpunk palette ─────────────────────────────────────────────────────
  static const _cyan = Color(0xFF00D4FF);
  static const _blue = Color(0xFF2563EB);
  static const _darkBg = Color(0xFF020B2D);
  static const _darkBorder = Color(0xFF1A2550);

  @override
  void setState(VoidCallback callback) {
    super.setState(callback);
    _model.onUpdate();
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => SideNavModel());
    AppStateNotifier.instance.addListener(_onAppStateChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => safeSetState(() {}));
    // The per-mill Command Center entries come from the published POM config.
    PomConfigStore.ensureLoaded().then((_) => safeSetState(() {}));
  }

  void _onAppStateChanged() {
    if (mounted) safeSetState(() {});
  }

  @override
  void dispose() {
    AppStateNotifier.instance.removeListener(_onAppStateChanged);
    _model.maybeDispose();
    super.dispose();
  }

  Future<void> _logout(BuildContext context) async {
    final uid = AppStateNotifier.instance.uid;
    AppRoles.clearDynamicModules();
    SessionStorage.clearSession();
    if (uid != null) {
      try {
        await UserPresence.goOffline(uid).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await FirebaseAuth.instance.signOut();
    if (context.mounted) context.goNamed('loginPage');
  }

  bool _canAccess(String module) => AppRoles.canAccess(roles, module);

  // ── Nav item ───────────────────────────────────────────────────────────────
  Widget _navItem(
    BuildContext context,
    String label,
    String routeName, {
    String? module,
    bool indent = true,
    IconData? icon,
    Map<String, String>? queryParameters,
  }) {
    if (module != null && !AppRoles.canAccess(roles, module)) {
      return const SizedBox.shrink();
    }
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    // Unique per-entry key so two items sharing a route (e.g. the group vs a
    // per-factory command center, both PlantEnergyCommandCenterSetting) don't
    // highlight together on hover.
    final qp = queryParameters ?? const <String, String>{};
    final itemKey = qp.isEmpty
        ? routeName
        : '$routeName?${qp.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final isHovered = _hoveredItem == itemKey;
    final accent = isLight ? _blue : _cyan;

    String? routePath = _resolvedPathsCache[itemKey];
    if (routePath == null) {
      try {
        routePath = GoRouter.of(context).namedLocation(routeName, queryParameters: qp);
        _resolvedPathsCache[itemKey] = routePath;
      } catch (_) {
        routePath = '/';
      }
    }

    return Link(
      uri: Uri.parse(routePath),
      target: LinkTarget.self,
      builder: (context, followLink) => MouseRegion(
        onEnter: (_) => safeSetState(() => _hoveredItem = itemKey),
        onExit: (_) => safeSetState(() {
          if (_hoveredItem == itemKey) _hoveredItem = null;
        }),
        child: Padding(
          padding: EdgeInsetsDirectional.fromSTEB(indent ? 8 : 8, 0, 8, 0),
          child: InkWell(
            splashColor: Colors.transparent,
            focusColor: Colors.transparent,
            hoverColor: Colors.transparent,
            highlightColor: Colors.transparent,
            onTap: () => context.goNamed(routeName, queryParameters: qp, extra: _kFadeExtra),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              width: double.infinity,
              height: 38,
              decoration: BoxDecoration(
                color: isHovered ? (isLight ? accent.withOpacity(0.08) : _cyan.withOpacity(0.07)) : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: Border(
                  left: BorderSide(
                    color: isHovered ? accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
              child: Padding(
                padding: EdgeInsetsDirectional.fromSTEB(indent ? 46 : 12, 0, 8, 0),
                child: Row(
                  children: [
                    if (icon != null) ...[
                      Icon(
                        icon,
                        color: isHovered ? accent : (isLight ? theme.txtSecondary : Colors.white54),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                    ],
                    Expanded(
                      child: Text(
                        label,
                        softWrap: true,
                        overflow: TextOverflow.visible,
                        style: GoogleFonts.poppins(
                          fontSize: 13,
                          fontWeight: icon != null ? FontWeight.w600 : FontWeight.w400,
                          color: isHovered ? accent : (isLight ? theme.txtSecondary : Colors.white70),
                          letterSpacing: 0.2,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Section ────────────────────────────────────────────────────────────────
  Widget _section(
    BuildContext context, {
    required String label,
    required IconData icon,
    required ExpandableController controller,
    required List<Widget> children,
    List<String>? modules,
  }) {
    if (modules != null && modules.isNotEmpty) {
      if (!modules.any((m) => _canAccess(m))) return const SizedBox.shrink();
    }
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final accent = isLight ? _blue : _cyan;

    return ExpandableNotifier(
      controller: controller,
      child: ExpandablePanel(
        header: Padding(
          padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 6, 6),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: accent,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              Icon(icon, color: isLight ? theme.txtPrimary : Colors.white70, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isLight ? theme.txtPrimary : Colors.white,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
        ),
        collapsed: const SizedBox(height: 2),
        expanded: Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
        theme: ExpandableThemeData(
          tapHeaderToExpand: true,
          tapBodyToExpand: false,
          tapBodyToCollapse: false,
          headerAlignment: ExpandablePanelHeaderAlignment.center,
          hasIcon: true,
          expandIcon: Icons.chevron_right_rounded,
          collapseIcon: Icons.keyboard_arrow_down_rounded,
          iconSize: 20,
          iconColor: isLight ? theme.txtTertiary : Colors.white38,
        ),
      ),
    );
  }

  // ── Sub-section (nested expandable inside a section) ─────────────────────
  Widget _subSection(
    BuildContext context, {
    required String label,
    required ExpandableController controller,
    required List<Widget> children,
    List<String>? modules,
  }) {
    if (modules != null && modules.isNotEmpty) {
      if (!modules.any((m) => _canAccess(m))) return const SizedBox.shrink();
    }
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final accent = isLight ? _blue : _cyan;

    return Padding(
      padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 0, 0),
      child: ExpandableNotifier(
        controller: controller,
        child: ExpandablePanel(
          header: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(8, 4, 6, 4),
            child: Row(
              children: [
                Container(
                  width: 2,
                  height: 14,
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.6),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    label,
                    style: GoogleFonts.poppins(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: isLight ? theme.txtSecondary : Colors.white60,
                      letterSpacing: 0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          collapsed: const SizedBox(height: 2),
          expanded: Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: children,
            ),
          ),
          theme: ExpandableThemeData(
            tapHeaderToExpand: true,
            tapBodyToExpand: false,
            tapBodyToCollapse: false,
            headerAlignment: ExpandablePanelHeaderAlignment.center,
            hasIcon: true,
            expandIcon: Icons.chevron_right_rounded,
            collapseIcon: Icons.keyboard_arrow_down_rounded,
            iconSize: 16,
            iconColor: isLight ? theme.txtTertiary : Colors.white38,
          ),
        ),
      ),
    );
  }

  // ── System section (Super Admin only) ─────────────────────────────────────
  Widget _systemSection(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final accent = theme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Container(
                  width: 3,
                  height: 14,
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'SYSTEM',
                  style: GoogleFonts.poppins(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: accent,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: accent.withOpacity(0.12),
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: accent.withOpacity(0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock_outline_rounded, size: 9, color: accent),
                      const SizedBox(width: 3),
                      Text(
                        'SA ONLY',
                        style: GoogleFonts.poppins(
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          color: accent,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Link(
            uri: Uri.parse(_resolvedPathsCache['IntegrationConfig'] ??= () {
              try {
                return GoRouter.of(context).namedLocation('IntegrationConfig');
              } catch (_) {
                return '/';
              }
            }()),
            target: LinkTarget.self,
            builder: (context, followLink) => MouseRegion(
            onEnter: (_) => safeSetState(() => _hoveredItem = 'IntegrationConfig'),
            onExit: (_) => safeSetState(() {
              if (_hoveredItem == 'IntegrationConfig') _hoveredItem = null;
            }),
            child: InkWell(
              splashColor: Colors.transparent,
              focusColor: Colors.transparent,
              hoverColor: Colors.transparent,
              highlightColor: Colors.transparent,
              onTap: () => context.goNamed('IntegrationConfig', extra: _kFadeExtra),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeInOut,
                width: double.infinity,
                height: 38,
                decoration: BoxDecoration(
                  color: _hoveredItem == 'IntegrationConfig'
                      ? accent.withOpacity(0.10)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                  border: Border(
                    left: BorderSide(
                      color: _hoveredItem == 'IntegrationConfig' ? accent : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                ),
                child: Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 0, 8, 0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.cable_rounded,
                        color: _hoveredItem == 'IntegrationConfig'
                            ? accent
                            : (isLight ? theme.txtSecondary : Colors.white54),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          'Integration Config',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: _hoveredItem == 'IntegrationConfig'
                                ? accent
                                : (isLight ? theme.txtSecondary : Colors.white70),
                            letterSpacing: 0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          ),  // Link builder
        ],
      ),
    );
  }

  // ── Neon divider ───────────────────────────────────────────────────────────
  Widget _neonDivider(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isLight
              ? [Colors.transparent, _blue.withOpacity(0.3), Colors.transparent]
              : [Colors.transparent, _cyan.withOpacity(0.5), Colors.transparent],
        ),
      ),
    );
  }

  // ── Build ──────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final appState = AppStateNotifier.instance;
    roles = appState.userRole ?? widget.roles;
    name = appState.userName ?? widget.name;
    email = appState.userEmail ?? widget.email;

    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);

    return NotificationToastListener(
      child: BlocBuilder<MainLayoutCubit, MainLayoutState>(
      builder: (context, state) {
        return Visibility(
          visible: responsiveVisibility(
            context: context,
            phone: false,
            tablet: false,
          ),
          child: SafeArea(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeIn,
              width: state.showSideNav ? 270.0 : 0,
              height: double.infinity,
              decoration: BoxDecoration(
                color: isLight ? theme.secondaryBackground : _darkBg,
                boxShadow: [
                  BoxShadow(color: Colors.black.withOpacity(0.12), blurRadius: 6, offset: const Offset(2, 0)),
                ],
                border: Border(
                  right: BorderSide(
                    color: isLight ? theme.cardStroke : _darkBorder,
                    width: 1,
                  ),
                ),
              ),
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // ── Top bar: collapse + title ──────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(12, 8, 8, 0),
                      child: Row(
                        children: [
                          Container(
                            width: 7,
                            height: 7,
                            decoration: BoxDecoration(
                              color: isLight ? theme.primary.withOpacity(0.7) : _cyan,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Text(
                              'SMARTFACTORY365',
                              style: GoogleFonts.poppins(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: isLight ? theme.txtPrimary : Colors.white,
                                letterSpacing: 1.8,
                              ),
                            ),
                          ),
                          IconButton(
                            iconSize: 20,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                            color: isLight ? theme.txtTertiary : Colors.white38,
                            onPressed: () {
                              context.read<MainLayoutCubit>().showSideNav(false);
                              context.read<MainLayoutCubit>().showButton(false);
                            },
                            icon: const Tooltip(
                              message: 'Hide side bar',
                              child: Icon(Icons.chevron_left_rounded),
                            ),
                          ),
                        ],
                      ),
                    ),

                    _neonDivider(context),

                    // ── Nav list ───────────────────────────────────────────
                    Expanded(
                      child: SingleChildScrollView(
                        controller: SideNavModel.navScrollController,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Kanban Dashboard: SmartMill's Group POM Command
                            // Center. Gated on either permission so it still
                            // shows for a settings-only account.
                            _section(
                              context,
                              label: 'Kanban Dashboard',
                              icon: Icons.view_kanban,
                              controller: SideNavModel.expandableControllerKanbanView,
                              modules: const [
                                AppRoles.kModuleKanbanDashboard,
                                AppRoles.kModuleKanbanDashboardSettings,
                              ],
                              children: [
                                _navItem(context, 'Group POM Command Center', 'PomGroupCommandCenter'),
                                // One entry per mill in the Group setting — add
                                // a mill there and its Command Center appears
                                // here, with nothing to wire up per mill.
                                for (final m in PomCalc(PomConfigStore.live).activeMills())
                                  _navItem(context, '${PomCalc.short((m['name'] ?? '').toString())} Command Center', 'MillCommandCenter',
                                      queryParameters: {'mill': m['id'].toString()}),
                              ],
                            ),

                            _neonDivider(context),

                            // 1. Equipment Monitoring
                            _section(
                              context,
                              label: 'Equipment Monitoring',
                              icon: Icons.precision_manufacturing_rounded,
                              controller: SideNavModel.expandableController1,
                              modules: [
                                AppRoles.kModuleEquipmentOverview,
                                AppRoles.kModuleEquipmentDetails,
                                AppRoles.kModuleProductionLineKpi,
                                AppRoles.kModuleMachineKpi
                              ],
                              children: [
                                _navItem(context, 'Equipment Overview', 'EquipmentOverview', module: AppRoles.kModuleEquipmentOverview),
                                _navItem(context, 'Equipment Details', 'EquipmentDetails', module: AppRoles.kModuleEquipmentDetails),
                                _navItem(context, 'Production Line KPI', 'ProductionLineKPI', module: AppRoles.kModuleProductionLineKpi),
                                _navItem(context, 'Machine KPI', 'MachineKPI', module: AppRoles.kModuleMachineKpi),
                              ],
                            ),

                            // 2. Energy Monitoring
                            _section(
                              context,
                              label: 'Energy Monitoring',
                              icon: Icons.energy_savings_leaf_rounded,
                              controller: SideNavModel.expandableController2,
                              modules: [
                                AppRoles.kModuleEnergyOverview,
                                AppRoles.kModuleEnergyComparison,
                                AppRoles.kModuleEnergyDetails,
                                AppRoles.kModuleCarbonEmission,
                                AppRoles.kModulePfMonitoring
                              ],
                              children: [
                                _navItem(context, 'Energy Overview', 'EnergyOverview', module: AppRoles.kModuleEnergyOverview),
                                _navItem(context, 'Device Energy Comparison', 'DeviceEnergyComparison', module: AppRoles.kModuleDeviceEnergyComparison),
                                _navItem(context, 'Energy Historical Data', 'EnergyComparison', module: AppRoles.kModuleEnergyComparison),
                                _navItem(context, 'Energy Details', 'EnergyDetails', module: AppRoles.kModuleEnergyDetails),
                                _navItem(context, 'Carbon Emission', 'CarbonEmission', module: AppRoles.kModuleCarbonEmission),
                                _navItem(context, 'PF Monitoring', 'PowerFactorMonitoring', module: AppRoles.kModulePfMonitoring),
                              ],
                            ),

                            _neonDivider(context),

                            // Utility Monitoring
                            _section(
                              context,
                              label: 'Utility Monitoring',
                              icon: Icons.air_rounded,
                              controller: SideNavModel.expandableControllerUtility,
                              modules: const [AppRoles.kModuleAirCompressorMonitoring],
                              children: [
                                _navItem(context, 'Air Compressor Monitoring', 'AirCompressorMonitoring',
                                    module: AppRoles.kModuleAirCompressorMonitoring),
                              ],
                            ),

                            _neonDivider(context),

                            // Standalone items
                            _navItem(context, 'Max Demand Monitoring', 'MaxDemandMonitoring',
                                indent: false, icon: Icons.bolt, module: AppRoles.kModuleMaxDemand),
                            _navItem(context, 'MD Prediction', 'MdPrediction',
                                indent: false, icon: Icons.trending_up, module: AppRoles.kModuleMdPrediction),
                            _navItem(context, 'Sankey Energy Flow', 'SankeyEnergyFlow',
                                indent: false, icon: Icons.power, module: AppRoles.kSankeyEnergyFlow),
                            _section(
                              context,
                              label: 'kWh / Tonne',
                              icon: Icons.electric_meter,
                              controller: SideNavModel.expandableControllerKwh,
                              modules: [
                                AppRoles.kModuleKwhTone,
                                AppRoles.kModuleSecComparison,
                                AppRoles.kModuleProductionOutputLog,
                              ],
                              children: [
                                _navItem(context, 'kWh per Tonne', 'kwhTone', module: AppRoles.kModuleKwhTone),
                                _navItem(context, 'SEC Comparison Insight', 'SecComparisonInsight', module: AppRoles.kModuleSecComparison),
                                _navItem(context, 'Production Output Data Log', 'ProductionOutputLog', module: AppRoles.kModuleProductionOutputLog),
                              ],
                            ),
                            _section(
                              context,
                              label: 'TNB Billing Engine Simulator',
                              icon: Icons.receipt_long,
                              controller: SideNavModel.expandableControllerTnbBilling,
                              modules: const [AppRoles.kModuleTnbBilling, AppRoles.kModuleSolarSettlement],
                              children: [
                                _navItem(context, 'Bill Simulator', 'TnbE3BillSimulator', module: AppRoles.kModuleTnbBilling),
                                _navItem(context, 'Bill Simulator Data Logger', 'TnbBillDataLogger', module: AppRoles.kModuleTnbBilling),
                                _navItem(context, 'Solar Settlement', 'SolarSettlement', module: AppRoles.kModuleSolarSettlement),
                              ],
                            ),

                            _neonDivider(context),

                            // 3. Work Order Mgmt
                            _section(
                              context,
                              label: 'Work Order Mgmt',
                              icon: Icons.manage_search,
                              controller: SideNavModel.expandableController3,
                              modules: [AppRoles.kModuleWorkOrderOverview, AppRoles.kModuleWorkOrderReport, AppRoles.kModuleProductionCalendar],
                              children: [
                                _navItem(context, 'Work Order Overview', 'WorkOrderOverview', module: AppRoles.kModuleWorkOrderOverview),
                                _navItem(context, 'Work Order Report', 'WorkOrderReport', module: AppRoles.kModuleWorkOrderReport),
                                _navItem(context, 'Production Calendar', 'ProductionCalendar', module: AppRoles.kModuleProductionCalendar),
                              ],
                            ),

                            // 4. Production Task Overview
                            _section(
                              context,
                              label: 'Production Task Overview',
                              icon: Icons.factory,
                              controller: SideNavModel.expandableController8,
                              modules: [AppRoles.kModuleProductionTask],
                              children: [
                                _navItem(context, 'Production Task Work Station', 'ProductionTaskWorkStation',
                                    module: AppRoles.kModuleProductionTask),
                              ],
                            ),

                            // 5. Equipment Data
                            _section(
                              context,
                              label: 'Equipment Data',
                              icon: Icons.bar_chart,
                              controller: SideNavModel.expandableController5,
                              modules: [
                                AppRoles.kModuleEquipStatusData,
                                AppRoles.kModuleEquipDataLogger,
                                AppRoles.kModuleEquipAlarmData,
                                AppRoles.kModuleOeeData
                              ],
                              children: [
                                _navItem(context, 'Equipment Status Data', 'EquipmentStatusData', module: AppRoles.kModuleEquipStatusData),
                                _navItem(context, 'Equipment Data Logger', 'EquipmentDataLogger', module: AppRoles.kModuleEquipDataLogger),
                                _navItem(context, 'Equipment Alarm Data', 'EquipmentAlarmData', module: AppRoles.kModuleEquipAlarmData),
                                _navItem(context, 'OEE Data', 'OEEData', module: AppRoles.kModuleOeeData),
                              ],
                            ),

                            // 6. Energy Data
                            _section(
                              context,
                              label: 'Energy Data',
                              icon: Icons.equalizer,
                              controller: SideNavModel.expandableController6,
                              modules: [
                                AppRoles.kModuleEnergyDataLogger1,
                                AppRoles.kModuleEnergyDataLogger2,
                                AppRoles.kModuleEnergyVsWorkOrder,
                                AppRoles.kModuleEquipEnergyData
                              ],
                              children: [
                                _navItem(context, 'Energy Data Logger', 'EnergyDataLogger', module: AppRoles.kModuleEnergyDataLogger1),
                                _navItem(context, 'Solar Generation Data', 'EnergyDataLogger2', module: AppRoles.kModuleEnergyDataLogger2),
                                _navItem(context, 'Energy vs Work Order', 'EnergyVsWorkOrder', module: AppRoles.kModuleEnergyVsWorkOrder),
                                _navItem(context, 'Equipment Energy Data', 'EquipmentEnergyData', module: AppRoles.kModuleEquipEnergyData),
                              ],
                            ),

                            _neonDivider(context),

                            _section(
                              context,
                              label: 'Reports',
                              icon: Icons.text_snippet,
                              controller: SideNavModel.expandableControllerReports,
                              modules: const [AppRoles.kModuleReports],
                              children: [
                                _navItem(context, 'MD Insight Report', 'MdInsightReport', module: AppRoles.kModuleReports),
                              ],
                            ),
                            _navItem(context, 'Device Settings', 'DeviceSettings',
                                indent: false, icon: Icons.developer_board, module: AppRoles.kModuleDeviceSetup),
                            // 7. Settings
                            _section(
                              context,
                              label: 'Settings',
                              icon: Icons.settings_input_component_rounded,
                              controller: SideNavModel.expandableController4,
                              modules: const [
                                AppRoles.kModuleGfsPlant,
                                AppRoles.kModuleGfsProductionArea,
                                AppRoles.kModuleGfsEquipment,
                                AppRoles.kModuleGfsProduct,
                                AppRoles.kModuleGfsAlarm,
                                AppRoles.kModuleMasterFacilitySetting,
                                AppRoles.kModuleUserMgmt,
                                AppRoles.kModuleKanbanDashboardSettings,
                                AppRoles.kModuleEnergySystemSettings,
                                AppRoles.kModuleMasterBillingConfig,
                                AppRoles.kModuleTariffConfig,
                                AppRoles.kModuleDeviceSetup,
                                AppRoles.kModuleEmissionFactorMgmt,
                              ],
                              children: [
                                _navItem(context, 'Master Facility Setting', 'MasterFacilitySetting', module: AppRoles.kModuleMasterFacilitySetting),
                                // Kanban Dashboard settings grouped together —
                                // holds the general kanban setting, the group
                                // command center, and each factory's own
                                // command center (Lot 237, etc.).
                                _subSection(
                                  context,
                                  label: 'Kanban Dashboard',
                                  controller: SideNavModel.expandableControllerKanban,
                                  modules: const [AppRoles.kModuleKanbanDashboardSettings],
                                  children: [
                                    _navItem(context, 'Kanban Dashboard Setting', 'KanbanDashboardSettings',
                                        module: AppRoles.kModuleKanbanDashboardSettings),
                                    _navItem(context, 'Group POM Command Center', 'PomGroupCommandCenterSetting'),
                                  ],
                                ),
                                _subSection(
                                  context,
                                  label: 'Utility Monitoring',
                                  controller: SideNavModel.expandableControllerUtilitySettings,
                                  modules: const [AppRoles.kModuleAirCompressorDashboardConfig],
                                  children: [
                                    _navItem(context, 'Air Compressor Dashboard Setting', 'AirCompressorDashboardConfigSetting',
                                        module: AppRoles.kModuleAirCompressorDashboardConfig),
                                  ],
                                ),
                                _subSection(
                                  context,
                                  label: 'General Factory Setting',
                                  controller: SideNavModel.expandableController9,
                                  modules: const [
                                    AppRoles.kModuleGfsPlant,
                                    AppRoles.kModuleGfsProductionArea,
                                    AppRoles.kModuleGfsProductionLine,
                                    AppRoles.kModuleGfsEquipment,
                                    AppRoles.kModuleGfsProcess,
                                    AppRoles.kModuleGfsProduct,
                                    AppRoles.kModuleGfsProductProcessRouting,
                                    AppRoles.kModuleGfsInstrumentDevices,
                                    AppRoles.kModuleGfsParameterSetting,
                                    AppRoles.kModuleGfsAlarm,
                                    AppRoles.kModuleGfsShift,
                                    AppRoles.kModuleGfsShiftCalendar,
                                    AppRoles.kModuleGfsDowntimeCalendar,
                                    AppRoles.kModuleGfsAbnormalReason,
                                    AppRoles.kModuleGfsDeviceType,
                                    AppRoles.kModuleGfsTnbMeter,
                                  ],
                                  children: [
                                    _navItem(context, 'Plant', 'GfsPlant', module: AppRoles.kModuleGfsPlant),
                                    _navItem(context, 'Production Block', 'GfsProductionArea', module: AppRoles.kModuleGfsProductionArea),
                                    _navItem(context, 'Production Line', 'GfsProductionLine', module: AppRoles.kModuleGfsProductionLine),
                                    _navItem(context, 'Process Setting', 'GfsProcess', module: AppRoles.kModuleGfsProcess),
                                    _navItem(context, 'Equipment Category', 'GfsEquipmentCategory', module: AppRoles.kModuleGfsEquipmentCategory),
                                    _navItem(context, 'Equipment', 'GfsEquipment', module: AppRoles.kModuleGfsEquipment),
                                    _navItem(context, 'Device Type Setting', 'GfsDeviceType', module: AppRoles.kModuleGfsDeviceType),
                                    _navItem(context, 'Product', 'GfsProduct', module: AppRoles.kModuleGfsProduct),
                                    _navItem(context, 'Abnormal Reason Setting', 'GfsAbnormalReason', module: AppRoles.kModuleGfsAbnormalReason),
                                    // _navItem(context, 'Product Process Routing', 'GfsProductProcessRouting', module: AppRoles.kModuleGfsProductProcessRouting),
                                    // _navItem(context, 'Instrument Devices', 'GfsInstrumentDevices', module: AppRoles.kModuleGfsInstrumentDevices),
                                    // _navItem(context, 'Parameter Setting', 'GfsParameterSetting', module: AppRoles.kModuleGfsParameterSetting),
                                    _navItem(context, 'Alarm', 'GfsAlarm', module: AppRoles.kModuleGfsAlarm),
                                    _navItem(context, 'TNB Meter', 'GfsTnbMeter', module: AppRoles.kModuleGfsTnbMeter),
                                    _navItem(context, 'Shift', 'GfsShift', module: AppRoles.kModuleGfsShift),
                                    // _navItem(context, 'Shift Calendar', 'GfsShiftCalendar', module: AppRoles.kModuleGfsShiftCalendar),
                                    // _navItem(context, 'Downtime Calendar', 'GfsDowntimeCalendar', module: AppRoles.kModuleGfsDowntimeCalendar),
                                  ],
                                ),
                                _subSection(
                                  context,
                                  label: 'User & Access',
                                  controller: SideNavModel.expandableControllerS1,
                                  modules: const [AppRoles.kModuleUserMgmt],
                                  children: [
                                    _navItem(context, 'Manage Users & Groups', 'ManageUserGroups', module: AppRoles.kModuleUserMgmt),
                                    _navItem(context, 'Password Management', 'PasswordManagement', module: AppRoles.kModuleUserMgmt),
                                  ],
                                ),
                                _subSection(
                                  context,
                                  label: 'Energy & Billing',
                                  controller: SideNavModel.expandableControllerS2,
                                  modules: const [
                                    AppRoles.kModuleEnergySystemSettings,
                                    AppRoles.kModuleMasterBillingConfig,
                                    AppRoles.kModuleTariffConfig,
                                    AppRoles.kModuleEnergySankeyFlowSetting,
                                    AppRoles.kModuleEmissionFactorMgmt,
                                    AppRoles.kModuleCarbonDashboardConfig,
                                  ],
                                  children: [
                                    _navItem(context, 'Energy System Settings', 'EnergySystemSettings', module: AppRoles.kModuleEnergySystemSettings),
                                    _navItem(context, 'Master Billing Config', 'MasterBillingConfig', module: AppRoles.kModuleMasterBillingConfig),
                                    _navItem(context, 'Tariff Category Setup', 'TariffCategorySetup', module: AppRoles.kModuleTariffConfig),
                                    _navItem(context, 'Energy Sankey Flow Setting', 'EnergySankeyFlowSetting',
                                        module: AppRoles.kModuleEnergySankeyFlowSetting),
                                    _navItem(context, 'Emission Factor Management', 'EmissionFactorManagement', module: AppRoles.kModuleEmissionFactorMgmt),
                                    _navItem(context, 'Carbon Dashboard Config', 'CarbonDashboardConfigSetting',
                                        module: AppRoles.kModuleCarbonDashboardConfig),
                                  ],
                                ),
                                _subSection(
                                  context,
                                  label: 'Data',
                                  controller: SideNavModel.expandableControllerS3,
                                  modules: const [AppRoles.kModuleDeviceDiscovery, AppRoles.kModuleDeviceLiveInsight],
                                  children: [
                                    _navItem(context, 'Device Discovery', 'DeviceDiscovery', module: AppRoles.kModuleDeviceDiscovery),
                                    _navItem(context, 'Device Live Data Insight', 'DeviceLiveInsight', module: AppRoles.kModuleDeviceLiveInsight),
                                  ],
                                ),
                              ],
                            ),
                          ].divide(const SizedBox(height: 2)),
                        ),
                      ),
                    ),

                    // 8. System — Super Admin only
                    if (AppRoles.normalizeRole(roles) == AppRoles.superAdmin) ...[
                      _neonDivider(context),
                      _systemSection(context),
                    ],

                    _neonDivider(context),

                    // ── User footer ────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: isLight ? theme.cardStroke : const Color(0xFF1A2550),
                          ),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Row 1: Avatar + name/email + notification bell
                          Row(
                            children: [
                              Container(
                                width: 36,
                                height: 36,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: isLight ? theme.primaryBackground : const Color(0xFF0D1B4B),
                                  border: Border.all(
                                    color: isLight ? theme.cardStroke : const Color(0xFF1A2550),
                                  ),
                                ),
                                child: Center(
                                  child: Text(
                                    name.isNotEmpty ? name[0].toUpperCase() : '?',
                                    style: GoogleFonts.poppins(
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                      color: isLight ? _blue : _cyan,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Text(
                                      name,
                                      style: GoogleFonts.poppins(
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600,
                                        color: isLight ? theme.txtPrimary : Colors.white,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    Text(
                                      email,
                                      style: GoogleFonts.poppins(
                                        fontSize: 10,
                                        color: isLight ? theme.txtTertiary : Colors.white38,
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              // Notification bell — right-aligned in user row
                              NotificationBellWidget(
                                iconColor: isLight ? _blue : _cyan,
                              ),
                            ],
                          ),
                          const SizedBox(height: 10),
                          // Row 2: Action icons — evenly spaced
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              _iconBtn(
                                context,
                                key: '__profile__',
                                icon: Icons.manage_accounts_outlined,
                                tooltip: 'Profile Settings',
                                onTap: () => context.goNamed('ProfileSettings', extra: _kFadeExtra),
                              ),
                              _iconBtn(
                                context,
                                key: '__homepage__',
                                icon: Icons.home_outlined,
                                tooltip: 'Set Home Page',
                                onTap: () => showHomePageDialog(context, roles),
                              ),
                              _iconBtn(
                                context,
                                key: '__theme__',
                                icon: Theme.of(context).brightness == Brightness.dark
                                    ? Icons.light_mode_outlined
                                    : Icons.dark_mode_outlined,
                                tooltip: Theme.of(context).brightness == Brightness.dark
                                    ? 'Light Mode'
                                    : 'Dark Mode',
                                onTap: () {
                                  final isDark = Theme.of(context).brightness == Brightness.dark;
                                  setDarkModeSetting(context, isDark ? ThemeMode.light : ThemeMode.dark);
                                },
                              ),
                              _iconBtn(
                                context,
                                key: '__logout__',
                                icon: Icons.logout_rounded,
                                tooltip: 'Logout',
                                onTap: () => _logout(context),
                                isDestructive: true,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
    );
  }

  Widget _iconBtn(
    BuildContext context, {
    required String key,
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool isDestructive = false,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final isHovered = _hoveredItem == key;
    final accent = isLight ? _blue : _cyan;
    final hoverColor = isDestructive ? Colors.redAccent : accent;

    return MouseRegion(
      onEnter: (_) => safeSetState(() => _hoveredItem = key),
      onExit: (_) => safeSetState(() {
        if (_hoveredItem == key) _hoveredItem = null;
      }),
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          splashColor: Colors.transparent,
          focusColor: Colors.transparent,
          hoverColor: Colors.transparent,
          highlightColor: Colors.transparent,
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isHovered ? hoverColor.withOpacity(0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: isHovered ? hoverColor.withOpacity(0.5) : Colors.transparent,
                width: 1,
              ),
            ),
            child: Icon(
              icon,
              size: 18,
              color: isHovered ? hoverColor : (isLight ? theme.txtTertiary : Colors.white38),
            ),
          ),
        ),
      ),
    );
  }
}
