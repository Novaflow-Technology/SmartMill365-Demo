import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/session_storage.dart';
import '/flutter_flow/user_presence.dart';
import 'package:expandable/expandable.dart';
import 'home_page_dialog.dart';
import '/web_app_template/pom_command_center/pom_config.dart';

/// Mobile-only slide-in navigation drawer.
/// Matches the WareTrack-style dark drawer shown in the design reference.
class MobileNavDrawer extends StatefulWidget {
  const MobileNavDrawer({super.key});

  @override
  State<MobileNavDrawer> createState() => _MobileNavDrawerState();
}

class _MobileNavDrawerState extends State<MobileNavDrawer> {
  // ── Palette ────────────────────────────────────────────────────────────────
  // Accent stays consistent (purple, like the WareTrack logo) across themes.
  static const _accent     = Color(0xFF6C63FF);
  static const _accentLight= Color(0xFF8B83FF);

  bool get _isLight => Theme.of(context).brightness == Brightness.light;
  FlutterFlowTheme get _ffTheme => FlutterFlowTheme.of(context);

  Color get _bgColor => _isLight ? _ffTheme.secondaryBackground : const Color(0xFF0D1117);
  Color get _cardColor => _isLight ? _ffTheme.primaryBackground : const Color(0xFF161B22);
  Color get _divider => _isLight ? _ffTheme.cardStroke : const Color(0xFF21262D);
  Color get _textPrimary => _isLight ? _ffTheme.txtPrimary : Colors.white;
  Color get _textSecondary => _isLight ? _ffTheme.txtTertiary : const Color(0xFF8B949E);

  static const _kFadeExtra = <String, dynamic>{
    kTransitionInfoKey: TransitionInfo(
      hasTransition: true,
      transitionType: PageTransitionType.fade,
      duration: Duration(milliseconds: 0),
    ),
  };

  // Expandable controllers — same statics used in desktop nav
  final _ctrl1   = ExpandableController(); // Equipment Monitoring
  final _ctrl2   = ExpandableController(); // Energy Monitoring
  final _ctrl3   = ExpandableController(); // Work Order
  final _ctrl4   = ExpandableController(); // Settings
  final _ctrl5   = ExpandableController(); // Equipment Data
  final _ctrl6   = ExpandableController(); // Energy Data
  final _ctrl7   = ExpandableController(); // Production Task
  final _ctrlKwh = ExpandableController(); // kWh / Tonne
  final _ctrlTnbBilling = ExpandableController(); // TNB Billing Engine Simulator
  final _ctrlReports = ExpandableController(); // Reports section

  @override
  void dispose() {
    _ctrl1.dispose();
    _ctrl2.dispose();
    _ctrl3.dispose();
    _ctrl4.dispose();
    _ctrl5.dispose();
    _ctrl6.dispose();
    _ctrl7.dispose();
    _ctrlKwh.dispose();
    super.dispose();
  }

  Future<void> _logout() async {
    final uid = AppStateNotifier.instance.uid;
    AppRoles.clearDynamicModules();
    SessionStorage.clearSession();
    if (uid != null) {
      try {
        await UserPresence.goOffline(uid).timeout(const Duration(seconds: 3));
      } catch (_) {}
    }
    await FirebaseAuth.instance.signOut();
    if (mounted) {
      Navigator.of(context).pop(); // close drawer first
      context.goNamed('loginPage');
    }
  }

  bool _canAccess(String module) {
    final roles = AppStateNotifier.instance.userRole ?? '';
    return AppRoles.canAccess(roles, module);
  }

  // ── Nav item ───────────────────────────────────────────────────────────────
  Widget _item(String label, String routeName, IconData icon, {String? module}) {
    if (module != null && !_canAccess(module)) return const SizedBox.shrink();

    return InkWell(
      onTap: () {
        Navigator.of(context).pop(); // close drawer
        context.goNamed(routeName, extra: _kFadeExtra);
      },
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _accentLight, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: _textPrimary,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: _textSecondary, size: 16),
          ],
        ),
      ),
    );
  }

  // ── Action item (icon row triggering a callback, no chevron) ──────────────
  Widget _actionItem(String label, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _accentLight, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w500,
                  color: _textPrimary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Section (expandable) ───────────────────────────────────────────────────
  Widget _section({
    required String label,
    required IconData icon,
    required ExpandableController controller,
    required List<Widget> children,
    List<String>? modules,
  }) {
    if (modules != null && !modules.any(_canAccess)) return const SizedBox.shrink();

    return ExpandableNotifier(
      controller: controller,
      child: ExpandablePanel(
        header: Container(
          margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: _accent.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: _accentLight, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  style: GoogleFonts.poppins(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w500,
                    color: _textPrimary,
                  ),
                ),
              ),
            ],
          ),
        ),
        collapsed: const SizedBox.shrink(),
        expanded: Padding(
          padding: const EdgeInsets.only(left: 16, bottom: 4),
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
          expandIcon: Icons.keyboard_arrow_down_rounded,
          collapseIcon: Icons.keyboard_arrow_up_rounded,
          iconSize: 20,
          iconColor: _textSecondary,
        ),
      ),
    );
  }

  // ── Sub-item (inside a section) ─────────────────────────────────────────
  Widget _subItem(String label, String routeName, {String? module, Map<String, String>? queryParameters}) {
    if (module != null && !_canAccess(module)) return const SizedBox.shrink();

    return InkWell(
      onTap: () {
        Navigator.of(context).pop();
        context.goNamed(routeName, queryParameters: queryParameters ?? {}, extra: _kFadeExtra);
      },
      borderRadius: BorderRadius.circular(8),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8)),
        child: Row(
          children: [
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(right: 10),
              decoration: BoxDecoration(
                color: _accent.withOpacity(0.6),
                shape: BoxShape.circle,
              ),
            ),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.poppins(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  color: _textSecondary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Divider ────────────────────────────────────────────────────────────────
  Widget _dividerLine() => Container(
        height: 1,
        margin: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
        color: _divider,
      );

  @override
  Widget build(BuildContext context) {
    final appState = AppStateNotifier.instance;
    final name  = appState.userName  ?? appState.userEmail ?? 'User';
    final email = appState.userEmail ?? '';
    final roles = appState.userRole  ?? '';
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final isSuperAdmin = AppRoles.normalizeRole(roles) == AppRoles.superAdmin;

    return Drawer(
      backgroundColor: _bgColor,
      width: 280,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topRight:    Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // ── Logo header ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _accent,
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withOpacity(0.4),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.precision_manufacturing_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'SMARTFACTORY',
                          style: GoogleFonts.poppins(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: _textPrimary,
                            letterSpacing: 1.2,
                          ),
                        ),
                        Text(
                          '365',
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: _accentLight,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    icon: Icon(Icons.close_rounded, color: _textSecondary, size: 20),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // ── User profile card ─────────────────────────────────────────
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _cardColor,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: _divider, width: 1),
              ),
              child: Row(
                children: [
                  // Avatar
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [_accent, _accent.withOpacity(0.6)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        initial,
                        style: GoogleFonts.poppins(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name,
                          style: GoogleFonts.poppins(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: _textPrimary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          roles.isNotEmpty ? roles : email,
                          style: GoogleFonts.poppins(
                            fontSize: 11,
                            color: _textSecondary,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 8),

            // ── "Menu" label ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 4),
              child: Row(
                children: [
                  Text(
                    'Menu',
                    style: GoogleFonts.poppins(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _textSecondary,
                      letterSpacing: 1.0,
                    ),
                  ),
                ],
              ),
            ),

            // ── Scrollable nav list ────────────────────────────────────────
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.only(bottom: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Kanban Dashboard: SmartMill's Group POM Command Center.
                    _section(
                      label: 'Kanban Dashboard',
                      icon: Icons.view_kanban,
                      controller: _ctrlKwh, // reuse a spare controller
                      modules: [AppRoles.kModuleKanbanDashboard, AppRoles.kModuleKanbanDashboardSettings],
                      children: [
                        _subItem('Group POM Command Center', 'PomGroupCommandCenter'),
                        for (final m in PomCalc(PomConfigStore.live).activeMills())
                          _subItem('${PomCalc.short((m['name'] ?? '').toString())} Command Center', 'MillCommandCenter',
                              queryParameters: {'mill': m['id'].toString()}),
                      ],
                    ),

                    _dividerLine(),

                    // Equipment Monitoring
                    _section(
                      label: 'Equipment Monitoring',
                      icon: Icons.precision_manufacturing_rounded,
                      controller: _ctrl1,
                      modules: [
                        AppRoles.kModuleEquipmentOverview,
                        AppRoles.kModuleEquipmentDetails,
                        AppRoles.kModuleProductionLineKpi,
                        AppRoles.kModuleMachineKpi,
                      ],
                      children: [
                        _subItem('Equipment Overview',    'EquipmentOverview',   module: AppRoles.kModuleEquipmentOverview),
                        _subItem('Equipment Details',     'EquipmentDetails',    module: AppRoles.kModuleEquipmentDetails),
                        _subItem('Production Line KPI',   'ProductionLineKPI',   module: AppRoles.kModuleProductionLineKpi),
                        _subItem('Machine KPI',           'MachineKPI',          module: AppRoles.kModuleMachineKpi),
                        _subItem('Sterilizer',            'SterilizerStation',   module: AppRoles.kModuleEquipmentOverview),
                        _subItem('Digester',              'DigesterStation',     module: AppRoles.kModuleEquipmentOverview),
                      ],
                    ),

                    // Energy Monitoring
                    _section(
                      label: 'Energy Monitoring',
                      icon: Icons.energy_savings_leaf_rounded,
                      controller: _ctrl2,
                      modules: [
                        AppRoles.kModuleEnergyOverview,
                        AppRoles.kModuleEnergyComparison,
                        AppRoles.kModuleEnergyDetails,
                        AppRoles.kModuleCarbonEmission,
                        AppRoles.kModulePfMonitoring,
                      ],
                      children: [
                        _subItem('Energy Overview',          'EnergyOverview',       module: AppRoles.kModuleEnergyOverview),
                        _subItem('Device Energy Comparison', 'DeviceEnergyComparison', module: AppRoles.kModuleDeviceEnergyComparison),
                        _subItem('Energy Historical Data',   'EnergyComparison',     module: AppRoles.kModuleEnergyComparison),
                        _subItem('Energy Details',           'EnergyDetails',        module: AppRoles.kModuleEnergyDetails),
                        _subItem('Carbon Emission',          'CarbonEmission',       module: AppRoles.kModuleCarbonEmission),
                        _subItem('PF Monitoring',            'PowerFactorMonitoring',module: AppRoles.kModulePfMonitoring),
                      ],
                    ),

                    _dividerLine(),

                    _item('Max Demand', 'MaxDemandMonitoring', Icons.bolt, module: AppRoles.kModuleMaxDemand),
                    _item('MD Prediction', 'MdPrediction', Icons.trending_up, module: AppRoles.kModuleMdPrediction),
                    _item('Sankey Energy Flow', 'SankeyEnergyFlow', Icons.power, module: AppRoles.kSankeyEnergyFlow),

                    // kWh / Tonne
                    _section(
                      label: 'kWh / Tonne',
                      icon: Icons.electric_meter,
                      controller: _ctrlKwh,
                      modules: [
                        AppRoles.kModuleKwhTone,
                        AppRoles.kModuleSecComparison,
                        AppRoles.kModuleProductionOutputLog,
                      ],
                      children: [
                        _subItem('kWh per Tonne',             'kwhTone',              module: AppRoles.kModuleKwhTone),
                        _subItem('SEC Comparison Insight',    'SecComparisonInsight', module: AppRoles.kModuleSecComparison),
                        _subItem('Production Output Log',     'ProductionOutputLog',  module: AppRoles.kModuleProductionOutputLog),
                      ],
                    ),

                    _section(
                      label: 'TNB Billing Engine Simulator',
                      icon: Icons.receipt_long,
                      controller: _ctrlTnbBilling,
                      modules: [AppRoles.kModuleTnbBilling],
                      children: [
                        _subItem('Bill Simulator', 'TnbE3BillSimulator', module: AppRoles.kModuleTnbBilling),
                        _subItem('Bill Simulator Data Logger', 'TnbBillDataLogger', module: AppRoles.kModuleTnbBilling),
                      ],
                    ),

                    _dividerLine(),

                    // Work Order
                    _section(
                      label: 'Work Order Mgmt',
                      icon: Icons.manage_search,
                      controller: _ctrl3,
                      modules: [
                        AppRoles.kModuleWorkOrderOverview,
                        AppRoles.kModuleWorkOrderReport,
                        AppRoles.kModuleProductionCalendar,
                      ],
                      children: [
                        _subItem('Work Order Overview',  'WorkOrderOverview',   module: AppRoles.kModuleWorkOrderOverview),
                        _subItem('Work Order Report',    'WorkOrderReport',     module: AppRoles.kModuleWorkOrderReport),
                        _subItem('Production Calendar',  'ProductionCalendar',  module: AppRoles.kModuleProductionCalendar),
                      ],
                    ),

                    // Production Task
                    _section(
                      label: 'Production Task',
                      icon: Icons.factory,
                      controller: _ctrl7,
                      modules: [AppRoles.kModuleProductionTask],
                      children: [
                        _subItem('Work Station', 'ProductionTaskWorkStation', module: AppRoles.kModuleProductionTask),
                      ],
                    ),

                    // Equipment Data
                    _section(
                      label: 'Equipment Data',
                      icon: Icons.bar_chart,
                      controller: _ctrl5,
                      modules: [
                        AppRoles.kModuleEquipStatusData,
                        AppRoles.kModuleEquipDataLogger,
                        AppRoles.kModuleEquipAlarmData,
                        AppRoles.kModuleOeeData,
                      ],
                      children: [
                        _subItem('Equipment Status Data',   'EquipmentStatusData', module: AppRoles.kModuleEquipStatusData),
                        _subItem('Equipment Data Logger',   'EquipmentDataLogger', module: AppRoles.kModuleEquipDataLogger),
                        _subItem('Equipment Alarm Data',    'EquipmentAlarmData',  module: AppRoles.kModuleEquipAlarmData),
                        _subItem('OEE Data',                'OEEData',             module: AppRoles.kModuleOeeData),
                      ],
                    ),

                    // Energy Data
                    _section(
                      label: 'Energy Data',
                      icon: Icons.equalizer,
                      controller: _ctrl6,
                      modules: [
                        AppRoles.kModuleEnergyDataLogger1,
                        AppRoles.kModuleEnergyDataLogger2,
                        AppRoles.kModuleEnergyVsWorkOrder,
                        AppRoles.kModuleEquipEnergyData,
                      ],
                      children: [
                        _subItem('Energy Data Logger',    'EnergyDataLogger',    module: AppRoles.kModuleEnergyDataLogger1),
                        _subItem('Solar Generation Data', 'EnergyDataLogger2',   module: AppRoles.kModuleEnergyDataLogger2),
                        _subItem('Energy vs Work Order',  'EnergyVsWorkOrder',   module: AppRoles.kModuleEnergyVsWorkOrder),
                        _subItem('Equipment Energy Data', 'EquipmentEnergyData', module: AppRoles.kModuleEquipEnergyData),
                      ],
                    ),

                    _dividerLine(),

                    _section(
                      label: 'Reports',
                      icon: Icons.text_snippet,
                      controller: _ctrlReports,
                      modules: const [AppRoles.kModuleReports],
                      children: [
                        _subItem('MD Insight Report', 'MdInsightReport', module: AppRoles.kModuleReports),
                      ],
                    ),
                    _item('Device Settings','DeviceSettings', Icons.developer_board,   module: AppRoles.kModuleDeviceSetup),

                    // Settings
                    _section(
                      label: 'Settings',
                      icon: Icons.settings_input_component_rounded,
                      controller: _ctrl4,
                      modules: const [
                        AppRoles.kModuleGfsPlant,
                        AppRoles.kModuleGfsEquipment,
                        AppRoles.kModuleUserMgmt,
                        AppRoles.kModuleMasterFacilitySetting,
                        AppRoles.kModuleKanbanDashboardSettings,
                        AppRoles.kModuleEnergySystemSettings,
                      ],
                      children: [
                        _subItem('Master Facility',       'MasterFacilitySetting',  module: AppRoles.kModuleMasterFacilitySetting),
                        _subItem('Kanban Dashboard Setting','KanbanDashboardSettings',module: AppRoles.kModuleKanbanDashboardSettings),
                        _subItem('Station Page Setting','StationPageSetting',module: AppRoles.kModuleKanbanDashboardSettings),
                        _subItem('Group POM Command Center', 'PomGroupCommandCenterSetting'),
                        _subItem('Plant',                 'GfsPlant',               module: AppRoles.kModuleGfsPlant),
                        _subItem('Production Block',      'GfsProductionArea',      module: AppRoles.kModuleGfsProductionArea),
                        _subItem('Equipment',             'GfsEquipment',           module: AppRoles.kModuleGfsEquipment),
                        _subItem('Product',               'GfsProduct',             module: AppRoles.kModuleGfsProduct),
                        _subItem('Alarm',                 'GfsAlarm',               module: AppRoles.kModuleGfsAlarm),
                        _subItem('TNB Meter',             'GfsTnbMeter',            module: AppRoles.kModuleGfsTnbMeter),
                        _subItem('Shift',                 'GfsShift',               module: AppRoles.kModuleGfsShift),
                        _subItem('Manage Users & Groups', 'ManageUserGroups',       module: AppRoles.kModuleUserMgmt),
                        _subItem('Energy System Settings','EnergySystemSettings',   module: AppRoles.kModuleEnergySystemSettings),
                        _subItem('Master Billing Config', 'MasterBillingConfig',    module: AppRoles.kModuleMasterBillingConfig),
                        _subItem('Tariff Setup',          'TariffCategorySetup',    module: AppRoles.kModuleTariffConfig),
                        _subItem('Emission Factor',       'EmissionFactorManagement',module: AppRoles.kModuleEmissionFactorMgmt),
                        _subItem('Carbon Dashboard Config','CarbonDashboardConfigSetting',module: AppRoles.kModuleCarbonDashboardConfig),
                        _subItem('Device Discovery',      'DeviceDiscovery',        module: AppRoles.kModuleDeviceDiscovery),
                        _subItem('Device Live Insight',   'DeviceLiveInsight',      module: AppRoles.kModuleDeviceLiveInsight),
                      ],
                    ),

                    // Super Admin: Integration Config
                    if (isSuperAdmin) ...[
                      _dividerLine(),
                      _item('Integration Config', 'IntegrationConfig', Icons.cable_rounded),
                    ],
                  ],
                ),
              ),
            ),

            // ── Account actions ─────────────────────────────────────────────
            _dividerLine(),
            _actionItem('Profile Settings', Icons.manage_accounts_outlined, () {
              Navigator.of(context).pop();
              context.goNamed('ProfileSettings', extra: _kFadeExtra);
            }),
            _actionItem('Set Home Page', Icons.home_outlined, () {
              showHomePageDialog(context, roles);
            }),
            _actionItem(
              _isLight ? 'Dark Mode' : 'Light Mode',
              _isLight ? Icons.dark_mode_outlined : Icons.light_mode_outlined,
              () => setDarkModeSetting(context, _isLight ? ThemeMode.dark : ThemeMode.light),
            ),

            // ── Logout button at bottom ───────────────────────────────────
            _dividerLine(),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: InkWell(
                onTap: _logout,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                  decoration: BoxDecoration(
                    color: Colors.redAccent.withOpacity(0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.redAccent.withOpacity(0.2), width: 1),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: Colors.redAccent.withOpacity(0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(Icons.logout_rounded, color: Colors.redAccent, size: 18),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Logout',
                        style: GoogleFonts.poppins(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
