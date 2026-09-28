import 'dart:async';
import 'dart:convert';

import 'package:google_fonts/google_fonts.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/form_field_controller.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/models/facility_data.dart';

import 'powerconsumptionenergydetailscard_widget.dart';
import 'energy_comparison_model.dart';
export 'energy_comparison_model.dart';

import '../../flutter_flow/nav/router_tracker.dart';
import 'package:smartmachine365/services/filter_memory.dart';

class EnergyComparisonWidget extends StatefulWidget {
  final String pageTitle;
  final String breadcrumbTitle;
  final bool deviceComparisonMode;
  final String? initialDeviceId;

  const EnergyComparisonWidget({
    super.key,
    this.pageTitle = 'Energy Flow',
    this.breadcrumbTitle = 'Dashboard/Energy Flow',
    this.deviceComparisonMode = false,
    this.initialDeviceId,
  });

  @override
  State<EnergyComparisonWidget> createState() => _EnergyComparisonWidgetState();
}

class _EnergyComparisonWidgetState extends State<EnergyComparisonWidget> {
  late EnergyComparisonModel _model;

  // Loading states for individual cards
  bool isLoading1 = true;
  bool isLoading2 = true;
  bool isLoading3 = true;
  bool isLoading4 = true;
  bool isLoadingA = true;
  bool isLoadingB = true;

  // Data for individual cards
  List<Map<String, dynamic>> chartData1 = [];
  List<Map<String, dynamic>> chartData2 = [];
  List<Map<String, dynamic>> chartData3 = [];
  List<Map<String, dynamic>> chartData4 = [];
  List<Map<String, dynamic>> chartDataA = [];
  List<Map<String, dynamic>> chartDataB = [];

  Timer? _timer;
  List<String> topics = [];
  String? selectedTopic;
  String? selectedDeviceA;
  String? selectedDeviceB;
  String lastUpdateTime = '';

  // Chart date filters. Null = live default view (Hourly: rolling last 24h,
  // Daily: backend's default window); set = pinned to that calendar day/month.
  DateTime? hourlyFilterDate;
  DateTime? dailyFilterMonth;

  static const List<String> _monthNames = [
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
    'Dec',
  ];

  String _ymd(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  String _ym(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}';

  // Card interaction states
  bool isCardHovered1 = false;
  bool isCardPressed1 = false;
  bool isCardHovered2 = false;
  bool isCardPressed2 = false;
  bool isCardHovered3 = false;
  bool isCardPressed3 = false;
  bool isCardHovered4 = false;
  bool isCardPressed4 = false;
  bool isCardHoveredA = false;
  bool isCardPressedA = false;
  bool isCardHoveredB = false;
  bool isCardPressedB = false;

  final scaffoldKey = GlobalKey<ScaffoldState>();

  List<FacilityData> _allFacilities = [];
  static const String _filterScreen = 'energy_comparison';
  bool _filtersRestored = false;

  void _rememberFilters() => FilterMemory.save(_filterScreen, {
        'plant': selectedPlant,
        'site': selectedSite,
        'productionArea': selectedProductionArea,
        'equipment': selectedEquipment,
        'deviceA': selectedDeviceA,
        'deviceB': selectedDeviceB,
      });

  /// Restores once, as soon as the dropdowns have something to match against.
  /// Anything no longer offered is ignored, so a retired meter cannot pin the
  /// screen to a device that is not there.
  void _restoreFiltersOnce(List<String> devices) {
    if (_filtersRestored || devices.isEmpty) return;
    _filtersRestored = true;
    FilterMemory.load(_filterScreen).then((saved) {
      if (saved.isEmpty || !mounted) return;
      setState(() {
        if (_plantOptions.contains(saved['plant'])) selectedPlant = saved['plant']!;
        if (_siteOptions.contains(saved['site'])) selectedSite = saved['site']!;
        if (_productionAreaOptions.contains(saved['productionArea'])) {
          selectedProductionArea = saved['productionArea']!;
        }
        if (_equipmentOptions.contains(saved['equipment'])) {
          selectedEquipment = saved['equipment']!;
        }
        if (devices.contains(saved['deviceA'])) selectedDeviceA = saved['deviceA'];
        if (devices.contains(saved['deviceB'])) selectedDeviceB = saved['deviceB'];
      });
    });
  }

  String selectedPlant = 'All';
  String selectedSite = 'All';
  String selectedProductionArea = 'All';
  String selectedEquipment = 'All';

  List<String> get _plantOptions {
    final plants = _allFacilities
        .map((f) => f.plant)
        .where((p) => p.isNotEmpty && p != '-')
        .toSet()
        .toList()
      ..sort();
    return ['All', ...plants];
  }

  List<String> get _siteOptions {
    var facilities = _allFacilities.toList();
    if (selectedPlant != 'All')
      facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    final sites = facilities
        .map((f) => f.zone)
        .where((z) => z.isNotEmpty && z != '-')
        .toSet()
        .toList()
      ..sort();
    return ['All', ...sites];
  }

  List<String> get _productionAreaOptions {
    var facilities = _allFacilities.toList();
    if (selectedPlant != 'All')
      facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All')
      facilities = facilities.where((f) => f.zone == selectedSite).toList();
    final areas = facilities
        .map((f) => f.productionArea)
        .where((a) => a.isNotEmpty && a != '-')
        .toSet()
        .toList()
      ..sort();
    return ['All', ...areas];
  }

  List<String> get _equipmentOptions {
    var facilities = _allFacilities.toList();
    if (selectedPlant != 'All')
      facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All')
      facilities = facilities.where((f) => f.zone == selectedSite).toList();
    if (selectedProductionArea != 'All')
      facilities = facilities
          .where((f) => f.productionArea == selectedProductionArea)
          .toList();
    final equipments = facilities
        .map((f) => f.equipmentNameId)
        .where((e) => e.isNotEmpty && e != '-')
        .toSet()
        .toList()
      ..sort();
    return ['All', ...equipments];
  }

  String _deviceDisplayName(String meterId) {
    for (final f in _allFacilities) {
      if (f.meterId.trim() == meterId) {
        final name = f.meterName.trim();
        if (name.isNotEmpty && name != meterId) return '$name ($meterId)';
        return name.isNotEmpty ? name : meterId;
      }
    }
    return meterId;
  }

  List<String> get _filteredTopics {
    var facilities = _allFacilities.where((f) {
      final status = f.status.trim().toLowerCase();
      if (status.isNotEmpty && status != 'active') return false;
      final id = f.meterId.trim();
      return id.isNotEmpty && id != '-';
    }).toList();
    if (selectedPlant != 'All')
      facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All')
      facilities = facilities.where((f) => f.zone == selectedSite).toList();
    if (selectedProductionArea != 'All')
      facilities = facilities
          .where((f) => f.productionArea == selectedProductionArea)
          .toList();
    if (selectedEquipment != 'All')
      facilities = facilities
          .where((f) => f.equipmentNameId == selectedEquipment)
          .toList();
    final ids = facilities.map((f) => f.meterId.trim()).toSet().toList()
      ..sort();
    return ids;
  }

  void _onFilterChanged({
    String? plant,
    String? site,
    String? productionArea,
    String? equipment,
  }) {
    final previousTopic = selectedTopic;

    setState(() {
      if (plant != null) {
        selectedPlant = plant;
        if (!_siteOptions.contains(selectedSite)) selectedSite = 'All';
        if (!_productionAreaOptions.contains(selectedProductionArea))
          selectedProductionArea = 'All';
        if (!_equipmentOptions.contains(selectedEquipment))
          selectedEquipment = 'All';
      }
      if (site != null) {
        selectedSite = site;
        if (!_productionAreaOptions.contains(selectedProductionArea))
          selectedProductionArea = 'All';
        if (!_equipmentOptions.contains(selectedEquipment))
          selectedEquipment = 'All';
      }
      if (productionArea != null) {
        selectedProductionArea = productionArea;
        if (!_equipmentOptions.contains(selectedEquipment))
          selectedEquipment = 'All';
      }
      if (equipment != null) {
        selectedEquipment = equipment;
      }

      topics = _filteredTopics;

      if (widget.deviceComparisonMode) {
        if (topics.isEmpty) {
          selectedDeviceA = null;
          selectedDeviceB = null;
        } else {
          if (selectedDeviceA == null || !topics.contains(selectedDeviceA)) {
            selectedDeviceA = topics.first;
          }
          if (selectedDeviceB == null ||
              !topics.contains(selectedDeviceB) ||
              selectedDeviceB == selectedDeviceA) {
            selectedDeviceB = topics.firstWhere(
              (id) => id != selectedDeviceA,
              orElse: () => selectedDeviceA!,
            );
          }
        }
      } else {
        if (topics.isNotEmpty &&
            (selectedTopic == null || !topics.contains(selectedTopic))) {
          selectedTopic = topics.first;
          _model.dropDownValueController?.value = selectedTopic;
        } else if (topics.isEmpty) {
          selectedTopic = null;
        }
      }
    });

    if (widget.deviceComparisonMode) {
      final selectedDevice = selectedDeviceA;
      if (selectedDevice != null) {
        setState(() {
          isLoadingA = true;
          isLoadingB = true;
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        });
        fetchComparisonData();
      }
    } else if (selectedTopic != previousTopic && selectedTopic != null) {
      setState(() {
        isLoading1 = true;
        isLoading2 = true;
        isLoading3 = true;
        isLoading4 = true;
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
      fetchDataHourly();
    }
    _rememberFilters();
  }

  void _clearAllFilters() {
    final previousTopic = selectedTopic;
    setState(() {
      selectedPlant = 'All';
      selectedSite = 'All';
      selectedProductionArea = 'All';
      selectedEquipment = 'All';
      topics = _filteredTopics;
      if (widget.deviceComparisonMode) {
        if (topics.isEmpty) {
          selectedDeviceA = null;
          selectedDeviceB = null;
        } else {
          selectedDeviceA = topics.first;
          selectedDeviceB = topics.length > 1
              ? topics.firstWhere((id) => id != selectedDeviceA,
                  orElse: () => selectedDeviceA!)
              : selectedDeviceA;
        }
      } else {
        if (topics.isNotEmpty &&
            (selectedTopic == null || !topics.contains(selectedTopic))) {
          selectedTopic = topics.first;
          _model.dropDownValueController?.value = selectedTopic;
        }
      }
    });
    if (widget.deviceComparisonMode) {
      setState(() {
        isLoadingA = true;
        isLoadingB = true;
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
      fetchComparisonData();
    } else if (selectedTopic != previousTopic && selectedTopic != null) {
      setState(() {
        isLoading1 = true;
        isLoading2 = true;
        isLoading3 = true;
        isLoading4 = true;
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
      fetchDataHourly();
    }
  }

  bool get _hasActiveFilters =>
      _allFacilities.isNotEmpty &&
      (selectedPlant != 'All' ||
          selectedSite != 'All' ||
          selectedProductionArea != 'All' ||
          selectedEquipment != 'All');

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
        border: Border.all(
            color: isLight ? theme.alternate : cyan.withOpacity(0.5),
            width: 1.2),
        borderRadius: BorderRadius.circular(6),
        boxShadow: [BoxShadow(color: cyan.withOpacity(0.08), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: isLight ? theme.primary : cyan,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(6), bottomLeft: Radius.circular(6)),
              boxShadow: [
                BoxShadow(
                    color: (isLight ? theme.primary : cyan).withOpacity(0.8),
                    blurRadius: 6)
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: safeValue,
                  isExpanded: true,
                  dropdownColor: isLight
                      ? theme.secondaryBackground
                      : const Color(0xFF071A2E),
                  menuMaxHeight: 300,
                  hint: Text(hint,
                      style: GoogleFonts.poppins(
                          color: isLight
                              ? theme.secondaryText
                              : cyan.withOpacity(0.8),
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  style: GoogleFonts.poppins(
                      color: isLight ? theme.txtPrimary : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  icon: Icon(Icons.keyboard_arrow_down_rounded,
                      color: isLight ? theme.primary : cyan, size: 22),
                  items: options
                      .map((opt) => DropdownMenuItem<String>(
                            value: opt,
                            child: Text(labelBuilder?.call(opt) ?? opt,
                                style: GoogleFonts.poppins(
                                    color: isLight
                                        ? theme.txtPrimary
                                        : Colors.white,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
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

  // ── Hourly / Daily chart date filters ────────────────────────────────────

  Future<void> _pickHourlyDate() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: hourlyFilterDate ?? now,
      firstDate: DateTime(2023, 1, 1),
      lastDate: now,
      helpText: 'Select date for Hourly Chart',
    );
    if (picked == null) return;
    setState(() {
      // Picking today = the live view; treat it as clearing the filter so the
      // chart keeps its rolling-24h behaviour (which includes the current hour).
      final isToday = picked.year == now.year &&
          picked.month == now.month &&
          picked.day == now.day;
      hourlyFilterDate = isToday ? null : picked;
      isLoading1 = true;
    });
    fetchDataHourly(chain: false);
  }

  void _clearHourlyDate() {
    if (hourlyFilterDate == null) return;
    setState(() {
      hourlyFilterDate = null;
      isLoading1 = true;
    });
    fetchDataHourly(chain: false);
  }

  Future<void> _pickDailyMonth() async {
    final now = DateTime.now();
    int year = (dailyFilterMonth ?? now).year;
    final picked = await showDialog<DateTime>(
      context: context,
      builder: (dialogContext) {
        final isLight = Theme.of(dialogContext).brightness == Brightness.light;
        final theme = FlutterFlowTheme.of(dialogContext);
        const cyan = Color(0xFF00D4FF);
        final accent = isLight ? theme.primary : cyan;
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor:
                isLight ? theme.secondaryBackground : const Color(0xFF071A2E),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: accent.withOpacity(0.5)),
            ),
            title: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: Icon(Icons.chevron_left, color: accent),
                  onPressed: () => setDialogState(() => year--),
                ),
                Text(
                  '$year',
                  style: GoogleFonts.poppins(
                    color: isLight ? theme.txtPrimary : Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.chevron_right,
                      color:
                          year < now.year ? accent : accent.withOpacity(0.25)),
                  onPressed: year < now.year
                      ? () => setDialogState(() => year++)
                      : null,
                ),
              ],
            ),
            content: SizedBox(
              width: 300,
              child: GridView.count(
                crossAxisCount: 3,
                shrinkWrap: true,
                mainAxisSpacing: 8,
                crossAxisSpacing: 8,
                childAspectRatio: 2.2,
                children: List.generate(12, (i) {
                  final month = i + 1;
                  final isFuture = year == now.year && month > now.month;
                  final isSelected = dailyFilterMonth != null &&
                      dailyFilterMonth!.year == year &&
                      dailyFilterMonth!.month == month;
                  return OutlinedButton(
                    onPressed: isFuture
                        ? null
                        : () => Navigator.of(dialogContext)
                            .pop(DateTime(year, month)),
                    style: OutlinedButton.styleFrom(
                      backgroundColor: isSelected
                          ? accent.withOpacity(0.2)
                          : Colors.transparent,
                      side: BorderSide(
                          color: isSelected
                              ? accent
                              : accent.withOpacity(isFuture ? 0.1 : 0.4)),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6)),
                      padding: EdgeInsets.zero,
                    ),
                    child: Text(
                      _monthNames[i],
                      style: GoogleFonts.poppins(
                        color: isFuture
                            ? (isLight ? theme.secondaryText : Colors.white38)
                            : (isLight ? theme.txtPrimary : Colors.white),
                        fontSize: 13,
                        fontWeight:
                            isSelected ? FontWeight.w700 : FontWeight.w500,
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),
        );
      },
    );
    if (picked == null) return;
    setState(() {
      dailyFilterMonth = picked;
      isLoading2 = true;
    });
    fetchDataDaily(chain: false);
  }

  void _clearDailyMonth() {
    if (dailyFilterMonth == null) return;
    setState(() {
      dailyFilterMonth = null;
      isLoading2 = true;
    });
    fetchDataDaily(chain: false);
  }

  /// Compact filter chip shown at a chart card's top-right: calendar icon +
  /// current selection, with an inline clear (×) when a filter is active.
  Widget _buildChartFilterChip({
    required String label,
    required bool active,
    required VoidCallback onTap,
    required VoidCallback onClear,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    const cyan = Color(0xFF00D4FF);
    final accent = isLight ? theme.primary : cyan;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? accent.withOpacity(0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
              color: accent.withOpacity(active ? 0.7 : 0.4), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.calendar_month_rounded, size: 14, color: accent),
            const SizedBox(width: 6),
            Text(
              label,
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: active
                    ? accent
                    : (isLight ? theme.secondaryText : Colors.white70),
                fontWeight: FontWeight.w600,
              ),
            ),
            if (active) ...[
              const SizedBox(width: 6),
              InkWell(
                onTap: onClear,
                child: Icon(Icons.close_rounded, size: 14, color: accent),
              ),
            ],
          ],
        ),
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => EnergyComparisonModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);

    fetchTopics();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      fetchDataDaily();
      setState(() {
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
    });
    routeTracker.addListener(_onRouteChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => safeSetState(() {}));
  }

  void _onRouteChanged() {
    final route = routeTracker.currentRoute.toLowerCase();
    if (route == '/energycomparison' || route == '/deviceenergycomparison') {
      fetchTopics();
      _timer ??= Timer.periodic(const Duration(minutes: 5), (_) {
        fetchDataDaily();
        if (mounted) {
          setState(() {
            lastUpdateTime =
                DateTime.now().toLocal().toString().substring(0, 19);
          });
        }
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    routeTracker.removeListener(_onRouteChanged);
    _model.dispose();
    _timer?.cancel();
    super.dispose();
  }

  Future<void> fetchTopics() async {
    try {
      final facilities = await FacilityService.getFacilities();
      if (!mounted) return;
      final previousTopic = selectedTopic;
      setState(() {
        _allFacilities = facilities;
        topics = _filteredTopics;
        if (topics.isEmpty) {
          selectedTopic = null;
          selectedDeviceA = null;
          selectedDeviceB = null;
          return;
        }

        if (widget.deviceComparisonMode) {
          if (selectedDeviceA == null || !topics.contains(selectedDeviceA)) {
            selectedDeviceA = topics.first;
          }
          if (selectedDeviceB == null ||
              !topics.contains(selectedDeviceB) ||
              selectedDeviceB == selectedDeviceA) {
            selectedDeviceB = topics.firstWhere(
              (id) => id != selectedDeviceA,
              orElse: () => selectedDeviceA!,
            );
          }
        } else {
          final initId = widget.initialDeviceId ?? '';
          if (initId.isNotEmpty) {
            final targetNorm = initId.trim().toLowerCase();
            FacilityData? matched;
            for (final f in facilities) {
              if (f.meterId.trim().toLowerCase() == targetNorm ||
                  f.meterName.trim().toLowerCase() == targetNorm ||
                  f.equipmentNameId.trim().toLowerCase() == targetNorm ||
                  f.machineName.trim().toLowerCase() == targetNorm) {
                matched = f;
                break;
              }
            }
            if (matched != null && topics.contains(matched.meterId.trim())) {
              selectedTopic = matched.meterId.trim();
            } else if (topics.contains(initId)) {
              selectedTopic = initId;
            } else if (previousTopic != null && topics.contains(previousTopic)) {
              selectedTopic = previousTopic;
            } else {
              final hasMSB = topics.contains('MSB');
              selectedTopic = hasMSB ? 'MSB' : topics.first;
            }
          } else if (previousTopic != null && topics.contains(previousTopic)) {
            selectedTopic = previousTopic;
          } else {
            final hasMSB = topics.contains('MSB');
            selectedTopic = hasMSB ? 'MSB' : topics.first;
          }
          _model.dropDownValueController ??=
              FormFieldController<String>(selectedTopic);
          _model.dropDownValueController?.value = selectedTopic;
        }
      });
      if (widget.deviceComparisonMode) {
        fetchComparisonData();
      } else if (selectedTopic != null && selectedTopic != previousTopic) {
        fetchDataHourly();
      }
    } catch (e) {
      print('Exception fetching facilities: $e');
    }
  }

  Future<List<Map<String, dynamic>>> _fetchHourlyComparisonSeries(
      String deviceId) async {
    final base =
        'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$deviceId/hourly';
    final url = hourlyFilterDate != null
        ? '$base?date=${_ymd(hourlyFilterDate!)}'
        : '$base?window=rolling24h';
    final chartResponse =
        await http.get(Uri.parse(url), headers: AppConfig.headers);
    if (!mounted) return [];
    if (chartResponse.statusCode != 200) return [];
    final jsonData = jsonDecode(chartResponse.body);
    List<dynamic> dataList;
    if (jsonData is List) {
      dataList = jsonData;
    } else if (jsonData is Map && jsonData.containsKey('data')) {
      dataList = jsonData['data'];
    } else {
      dataList = [];
    }
    return dataList.map<Map<String, dynamic>>((item) {
      return {
        'label': item['label'].toString(),
        'value': item['value'] is num ? item['value'] : 0,
      };
    }).toList();
  }

  Future<void> fetchComparisonData() async {
    if (selectedDeviceA == null && selectedDeviceB == null) return;
    setState(() {
      isLoadingA = true;
      isLoadingB = true;
      lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
    });

    try {
      final futureA = selectedDeviceA == null
          ? Future.value(<Map<String, dynamic>>[])
          : _fetchHourlyComparisonSeries(selectedDeviceA!);
      final futureB = selectedDeviceB == null
          ? Future.value(<Map<String, dynamic>>[])
          : _fetchHourlyComparisonSeries(selectedDeviceB!);
      final results = await Future.wait([futureA, futureB]);
      if (!mounted) return;
      setState(() {
        chartDataA = results[0];
        chartDataB = results[1];
      });
    } catch (e) {
      print('ERROR: Failed to fetch comparison data, error: $e');
    } finally {
      if (mounted) {
        setState(() {
          isLoadingA = false;
          isLoadingB = false;
        });
      }
    }
  }

  double _sumDataValues(List<Map<String, dynamic>> chartData) {
    return chartData.fold<double>(0, (sum, point) {
      final value = point['value'];
      return sum + ((value is num) ? value.toDouble() : 0.0);
    });
  }

  String _deviceName(String? meterId) {
    if (meterId == null || meterId.isEmpty) return 'None';
    return _deviceDisplayName(meterId);
  }

  Future<void> fetchDataHourly({bool chain = true}) async {
    if (selectedTopic == null) return;

    try {
      // Default: rolling last 24 hours ending at the current hour — Malaysia
      // time (UTC+8, no DST), regardless of the viewer's device timezone. The
      // backend computes the window itself from NOW(); window=rolling24h
      // opts into that instead of the default "hours 0..now of today" shape
      // (kept for other callers that compare specific calendar days).
      // When the user picks a date in the card's filter, request that
      // calendar day's 0..23 breakdown instead via ?date=.
      final base =
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/hourly';
      final url = hourlyFilterDate != null
          ? '$base?date=${_ymd(hourlyFilterDate!)}'
          : '$base?window=rolling24h';
      final chartResponse =
          await http.get(Uri.parse(url), headers: AppConfig.headers);
      if (!mounted) return;

      if (chartResponse.statusCode == 200) {
        final jsonData = jsonDecode(chartResponse.body);
        List<dynamic> dataList;
        if (jsonData is List) {
          dataList = jsonData;
        } else if (jsonData is Map && jsonData.containsKey('data')) {
          dataList = jsonData['data'];
        } else {
          dataList = [];
        }
        final processedData = dataList.map<Map<String, dynamic>>((item) {
          return {
            'label': item['label'].toString(),
            'value': item['value'] is num ? item['value'] : 0,
          };
        }).toList();

        setState(() => chartData1 = processedData);
        print('Successfully fetched hourly data for topic: $url');
      } else {
        setState(() => chartData1 = []);
      }
    } catch (e) {
      print("ERROR: Failed to fetch hourly data, error: $e");
    } finally {
      setState(() => isLoading1 = false);
      if (chain) fetchDataDaily();
    }
  }

  Future<void> fetchDataDaily({bool chain = true}) async {
    if (selectedTopic == null) return;

    try {
      // ?month=YYYY-MM pins the chart to that calendar month's per-day
      // breakdown (the card's month filter); omitted = backend default window.
      final base =
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/daily';
      final url = dailyFilterMonth != null
          ? '$base?month=${_ym(dailyFilterMonth!)}'
          : base;
      final chartResponse =
          await http.get(Uri.parse(url), headers: AppConfig.headers);
      if (!mounted) return;
      if (chartResponse.statusCode == 200) {
        final jsonData = jsonDecode(chartResponse.body);
        List<dynamic> dataList;
        if (jsonData is List) {
          dataList = jsonData;
        } else if (jsonData is Map && jsonData.containsKey('data')) {
          dataList = jsonData['data'];
        } else {
          dataList = [];
        }

        final processedData = dataList.map<Map<String, dynamic>>((item) {
          return {
            'label': item['label'].toString(),
            'value': item['value'] is num ? item['value'] : 0,
          };
        }).toList();

        setState(() => chartData2 = processedData);
        print('Successfully fetched daily data for topic: $url');
      } else {
        setState(() => chartData2 = []);
      }
    } catch (e) {
      print("ERROR: Failed to fetch daily data, error: $e");
    } finally {
      setState(() => isLoading2 = false);
      if (chain) fetchDataMonthly();
    }
  }

  Future<void> fetchDataMonthly() async {
    if (selectedTopic == null) return;

    try {
      final chartResponse = await http.get(
          Uri.parse(
              'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/monthly'),
          headers: AppConfig.headers);
      if (!mounted) return;
      if (chartResponse.statusCode == 200) {
        final jsonData = jsonDecode(chartResponse.body);
        List<dynamic> dataList;
        if (jsonData is List) {
          dataList = jsonData;
        } else if (jsonData is Map && jsonData.containsKey('data')) {
          dataList = jsonData['data'];
        } else {
          dataList = [];
        }

        final processedData = dataList.map<Map<String, dynamic>>((item) {
          return {
            'label': item['label'].toString(),
            'value': item['value'] is num ? item['value'] : 0,
          };
        }).toList();

        setState(() => chartData3 = processedData);
        print(
            'Successfully fetched monthly data for topic: https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/monthly');
      } else {
        setState(() => chartData3 = []);
      }
    } catch (e) {
      print("ERROR: Failed to fetch monthly data, error: $e");
    } finally {
      setState(() => isLoading3 = false);
      fetchDataYearly();
    }
  }

  Future<void> fetchDataYearly() async {
    if (selectedTopic == null) return;

    try {
      final chartResponse = await http.get(
          Uri.parse(
              'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/yearly'),
          headers: AppConfig.headers);
      if (!mounted) return;
      if (chartResponse.statusCode == 200) {
        final jsonData = jsonDecode(chartResponse.body);
        List<dynamic> dataList;
        if (jsonData is List) {
          dataList = jsonData;
        } else if (jsonData is Map && jsonData.containsKey('data')) {
          dataList = jsonData['data'];
        } else {
          dataList = [];
        }
        final processedData = dataList.map<Map<String, dynamic>>((item) {
          return {
            'label': item['label'].toString(),
            'value': item['value'] is num ? item['value'] : 0,
          };
        }).toList();

        setState(() => chartData4 = processedData);
        print(
            'Successfully fetched yearly data for topic: https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/yearly');
      } else {
        setState(() => chartData4 = []);
      }
    } catch (e) {
      print("ERROR: Failed to fetch yearly data, error: $e");
    } finally {
      setState(() => isLoading4 = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.deviceComparisonMode
        ? selectedDeviceA == null && selectedDeviceB == null
        : selectedTopic == null || selectedTopic!.isEmpty) {
      return Scaffold(
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    return GestureDetector(
      onTap: () {
        FocusScope.of(context).unfocus();
        FocusManager.instance.primaryFocus?.unfocus();
      },
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SafeArea(
          top: true,
          child: Row(
            mainAxisSize: MainAxisSize.max,
            children: [
              Expanded(
                child: Align(
                  alignment: const AlignmentDirectional(0, -1),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(
                      minHeight: double.infinity,
                      maxWidth: double.infinity,
                      maxHeight: double.infinity,
                    ),
                    decoration: BoxDecoration(
                      color: FlutterFlowTheme.of(context).primaryBackground,
                      image: DecorationImage(
                        fit: BoxFit.cover,
                        image:
                            Image.asset('assets/images/backgroundanimated.gif')
                                .image,
                      ),
                    ),
                    child: Padding(
                      padding:
                          const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 24),
                      child: SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // Header section - always visible
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                  0, 0, 0, 4),
                              child: Text(
                                widget.breadcrumbTitle,
                                style: FlutterFlowTheme.of(context)
                                    .titleLarge
                                    .override(
                                      fontFamily: 'Poppins',
                                      color: FlutterFlowTheme.of(context)
                                          .primaryText,
                                      fontSize: 12,
                                      letterSpacing: 0.0,
                                      font: GoogleFonts.poppins(),
                                    ),
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsetsDirectional.fromSTEB(
                                  0, 0, 0, 4),
                              child: Text(
                                widget.pageTitle,
                                style: FlutterFlowTheme.of(context)
                                    .headlineMedium
                                    .override(
                                      fontFamily: 'Poppins',
                                      letterSpacing: 0.0,
                                      font: GoogleFonts.poppins(),
                                    ),
                              ),
                            ),
                            Padding(
                              padding:
                                  const EdgeInsetsDirectional.only(bottom: 10),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 8,
                                    children: [
                                      _buildCyberpunkDropdown(
                                        context: context,
                                        value: selectedPlant == 'All'
                                            ? null
                                            : selectedPlant,
                                        options: _plantOptions
                                            .where((o) => o != 'All')
                                            .toList(),
                                        hint: 'Plant',
                                        width: 170,
                                        onChanged: (val) => _onFilterChanged(
                                            plant: val ?? 'All'),
                                      ),
                                      _buildCyberpunkDropdown(
                                        context: context,
                                        value: selectedSite == 'All'
                                            ? null
                                            : selectedSite,
                                        options: _siteOptions
                                            .where((o) => o != 'All')
                                            .toList(),
                                        hint: 'Zone / Production Area',
                                        width: 170,
                                        onChanged: (val) => _onFilterChanged(
                                            site: val ?? 'All'),
                                      ),
                                      _buildCyberpunkDropdown(
                                        context: context,
                                        value: selectedProductionArea == 'All'
                                            ? null
                                            : selectedProductionArea,
                                        options: _productionAreaOptions
                                            .where((o) => o != 'All')
                                            .toList(),
                                        hint: 'Production Line',
                                        width: 180,
                                        onChanged: (val) => _onFilterChanged(
                                            productionArea: val ?? 'All'),
                                      ),
                                      _buildCyberpunkDropdown(
                                        context: context,
                                        value: selectedEquipment == 'All'
                                            ? null
                                            : selectedEquipment,
                                        options: _equipmentOptions
                                            .where((o) => o != 'All')
                                            .toList(),
                                        hint: 'Equipment',
                                        width: 180,
                                        onChanged: (val) => _onFilterChanged(
                                            equipment: val ?? 'All'),
                                      ),
                                      if (widget.deviceComparisonMode) ...[
                                        _buildCyberpunkDropdown(
                                          context: context,
                                          value: selectedDeviceA,
                                          options: (() {
                                            _restoreFiltersOnce(topics);
                                            return topics;
                                          })(),
                                          hint: 'Device A',
                                          width: 180,
                                          labelBuilder: _deviceDisplayName,
                                          onChanged: (val) {
                                            if (val != null &&
                                                val != selectedDeviceA) {
                                              setState(() {
                                                selectedDeviceA = val;
                                                isLoadingA = true;
                                                isLoadingB = true;
                                                lastUpdateTime = DateTime.now()
                                                    .toLocal()
                                                    .toString()
                                                    .substring(0, 19);
                                              });
                                              _rememberFilters();
                                              fetchComparisonData();
                                            }
                                          },
                                        ),
                                        _buildCyberpunkDropdown(
                                          context: context,
                                          value: selectedDeviceB,
                                          options: topics,
                                          hint: 'Device B',
                                          width: 180,
                                          labelBuilder: _deviceDisplayName,
                                          onChanged: (val) {
                                            if (val != null &&
                                                val != selectedDeviceB) {
                                              setState(() {
                                                selectedDeviceB = val;
                                                isLoadingA = true;
                                                isLoadingB = true;
                                                lastUpdateTime = DateTime.now()
                                                    .toLocal()
                                                    .toString()
                                                    .substring(0, 19);
                                              });
                                              _rememberFilters();
                                              fetchComparisonData();
                                            }
                                          },
                                        ),
                                      ] else
                                        _buildCyberpunkDropdown(
                                          context: context,
                                          value: selectedTopic,
                                          options: topics,
                                          hint: 'Meter / Device',
                                          width: 180,
                                          labelBuilder: _deviceDisplayName,
                                          onChanged: (val) {
                                            if (val != null &&
                                                val != selectedTopic) {
                                              setState(() {
                                                selectedTopic = val;
                                                _model.dropDownValueController
                                                    ?.value = val;
                                                isLoading1 = true;
                                                isLoading2 = true;
                                                isLoading3 = true;
                                                isLoading4 = true;
                                                lastUpdateTime = DateTime.now()
                                                    .toLocal()
                                                    .toString()
                                                    .substring(0, 19);
                                              });
                                              fetchDataHourly();
                                            }
                                          },
                                        ),
                                    ],
                                  ),
                                  const SizedBox(height: 10),
                                  if (widget.deviceComparisonMode)
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Expanded(
                                              child: _buildCard(
                                                chartData: chartDataA,
                                                isLoading: isLoadingA,
                                                period: 'Hourly',
                                                title: _deviceName(
                                                    selectedDeviceA),
                                                isHovered: isCardHoveredA,
                                                isPressed: isCardPressedA,
                                                onHover: (hovering) =>
                                                    Future.microtask(() {
                                                  if (mounted)
                                                    setState(() =>
                                                        isCardHoveredA =
                                                            hovering);
                                                }),
                                                onPressed: (pressed) =>
                                                    Future.microtask(() {
                                                  if (mounted)
                                                    setState(() =>
                                                        isCardPressedA =
                                                            pressed);
                                                }),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: _buildCard(
                                                chartData: chartDataB,
                                                isLoading: isLoadingB,
                                                period: 'Hourly',
                                                title: _deviceName(
                                                    selectedDeviceB),
                                                isHovered: isCardHoveredB,
                                                isPressed: isCardPressedB,
                                                onHover: (hovering) =>
                                                    Future.microtask(() {
                                                  if (mounted)
                                                    setState(() =>
                                                        isCardHoveredB =
                                                            hovering);
                                                }),
                                                onPressed: (pressed) =>
                                                    Future.microtask(() {
                                                  if (mounted)
                                                    setState(() =>
                                                        isCardPressedB =
                                                            pressed);
                                                }),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 12),
                                        Row(
                                          children: [
                                            Expanded(
                                              child:
                                                  _buildComparisonSummaryCard(
                                                context: context,
                                                title: 'Device A',
                                                deviceName: _deviceName(
                                                    selectedDeviceA),
                                                value:
                                                    _sumDataValues(chartDataA),
                                                isLoading: isLoadingA,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child:
                                                  _buildComparisonSummaryCard(
                                                context: context,
                                                title: 'Device B',
                                                deviceName: _deviceName(
                                                    selectedDeviceB),
                                                value:
                                                    _sumDataValues(chartDataB),
                                                isLoading: isLoadingB,
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child:
                                                  _buildComparisonSummaryCard(
                                                context: context,
                                                title: 'Delta',
                                                deviceName: '',
                                                value: _sumDataValues(
                                                        chartDataA) -
                                                    _sumDataValues(chartDataB),
                                                isLoading: false,
                                                isDelta: true,
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 16),
                                      ],
                                    )
                                  else
                                    _buildCard(
                                      chartData: chartData1,
                                      isLoading: isLoading1,
                                      period: 'Hourly',
                                      title: 'Hourly Chart',
                                      isHovered: isCardHovered1,
                                      isPressed: isCardPressed1,
                                      onHover: (hovering) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardHovered1 = hovering);
                                      }),
                                      onPressed: (pressed) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardPressed1 = pressed);
                                      }),
                                      headerAction: _buildChartFilterChip(
                                        label: hourlyFilterDate != null
                                            ? '${hourlyFilterDate!.day.toString().padLeft(2, '0')} ${_monthNames[hourlyFilterDate!.month - 1]} ${hourlyFilterDate!.year}'
                                            : 'Last 24 Hrs',
                                        active: hourlyFilterDate != null,
                                        onTap: _pickHourlyDate,
                                        onClear: _clearHourlyDate,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            if (!widget.deviceComparisonMode) ...[
                              const SizedBox(height: 16),

                              // Daily Chart
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCard(
                                      chartData: chartData2,
                                      isLoading: isLoading2,
                                      period: 'Daily',
                                      title: 'Daily Chart',
                                      isHovered: isCardHovered2,
                                      isPressed: isCardPressed2,
                                      onHover: (hovering) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardHovered2 = hovering);
                                      }),
                                      onPressed: (pressed) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardPressed2 = pressed);
                                      }),
                                      headerAction: _buildChartFilterChip(
                                        label: dailyFilterMonth != null
                                            ? '${_monthNames[dailyFilterMonth!.month - 1]} ${dailyFilterMonth!.year}'
                                            : 'Latest',
                                        active: dailyFilterMonth != null,
                                        onTap: _pickDailyMonth,
                                        onClear: _clearDailyMonth,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Monthly and Yearly Charts
                              Row(
                                children: [
                                  Expanded(
                                    child: _buildCard(
                                      chartData: chartData3,
                                      isLoading: isLoading3,
                                      period: 'Monthly',
                                      title: 'Monthly Chart',
                                      isHovered: isCardHovered3,
                                      isPressed: isCardPressed3,
                                      onHover: (hovering) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardHovered3 = hovering);
                                      }),
                                      onPressed: (pressed) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardPressed3 = pressed);
                                      }),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: _buildCard(
                                      chartData: chartData4,
                                      isLoading: isLoading4,
                                      period: 'Yearly',
                                      title: 'Year-Over-Year Chart',
                                      isHovered: isCardHovered4,
                                      isPressed: isCardPressed4,
                                      onHover: (hovering) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardHovered4 = hovering);
                                      }),
                                      onPressed: (pressed) =>
                                          Future.microtask(() {
                                        if (mounted)
                                          setState(
                                              () => isCardPressed4 = pressed);
                                      }),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 16),
                            ],
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                if (_hasActiveFilters)
                                  GestureDetector(
                                    onTap: _clearAllFilters,
                                    child: Container(
                                      height: 32,
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 14),
                                      alignment: Alignment.center,
                                      decoration: BoxDecoration(
                                        color:
                                            Colors.redAccent.withOpacity(0.12),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                            color: Colors.redAccent
                                                .withOpacity(0.5)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.filter_alt_off_rounded,
                                              color: Colors.redAccent,
                                              size: 15),
                                          const SizedBox(width: 6),
                                          Text(
                                            'Clear Filters',
                                            style: GoogleFonts.poppins(
                                              color: Colors.redAccent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  )
                                else
                                  const SizedBox.shrink(),
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Builder(builder: (context) {
                                      final isLight =
                                          Theme.of(context).brightness ==
                                              Brightness.light;
                                      final txtColor = isLight
                                          ? FlutterFlowTheme.of(context)
                                              .primaryText
                                          : Colors.white;
                                      return RichText(
                                        text: TextSpan(
                                          children: [
                                            TextSpan(
                                              text: 'Last Update: ',
                                              style: TextStyle(
                                                color: txtColor,
                                                fontWeight: FontWeight.bold,
                                              ),
                                            ),
                                            TextSpan(
                                              text: lastUpdateTime,
                                              style: TextStyle(color: txtColor),
                                            ),
                                          ],
                                        ),
                                      );
                                    }),
                                    const SizedBox(width: 8),
                                    Builder(builder: (context) {
                                      final isLight =
                                          Theme.of(context).brightness ==
                                              Brightness.light;
                                      final iconColor = isLight
                                          ? FlutterFlowTheme.of(context)
                                              .primaryText
                                          : Colors.white;
                                      return TextButton.icon(
                                        onPressed: () {
                                          setState(() {
                                            isLoading1 = true;
                                            isLoading2 = true;
                                            isLoading3 = true;
                                            isLoading4 = true;
                                            isLoadingA = true;
                                            isLoadingB = true;
                                            lastUpdateTime = DateTime.now()
                                                .toLocal()
                                                .toString()
                                                .substring(0, 19);
                                          });
                                          if (widget.deviceComparisonMode) {
                                            fetchComparisonData();
                                          } else {
                                            fetchDataHourly();
                                          }
                                        },
                                        icon: Icon(Icons.refresh,
                                            size: 16, color: iconColor),
                                        label: Text('Refresh',
                                            style: TextStyle(color: iconColor)),
                                        style: TextButton.styleFrom(
                                          padding: const EdgeInsets.symmetric(
                                              vertical: 5),
                                          backgroundColor: Colors.transparent,
                                        ),
                                      );
                                    }),
                                  ],
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildComparisonSummaryCard({
    required BuildContext context,
    required String title,
    required String deviceName,
    required double value,
    required bool isLoading,
    bool isDelta = false,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final accent = isDelta ? Colors.orangeAccent : theme.primary;
    final cardColor = isDelta
        ? Colors.orangeAccent.withOpacity(0.08)
        : (isLight ? Colors.white : const Color(0xFF0F202F));
    final valueLabel = '${value.toStringAsFixed(2)} kWh';

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withOpacity(0.18)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: GoogleFonts.poppins(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            deviceName.isNotEmpty ? deviceName : 'No device selected',
            style: GoogleFonts.poppins(
              fontSize: 11,
              color: isLight ? theme.secondaryText : Colors.white70,
            ),
          ),
          const SizedBox(height: 10),
          if (isLoading)
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          else
            Text(
              valueLabel,
              style: GoogleFonts.poppins(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: theme.primaryText,
              ),
            ),
          if (isDelta) ...[
            const SizedBox(height: 6),
            Text(
              'Difference between devices',
              style: GoogleFonts.poppins(
                fontSize: 11,
                color: isLight ? theme.secondaryText : Colors.white70,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildCard({
    required List<Map<String, dynamic>> chartData,
    required bool isLoading,
    required String period,
    required String title,
    required bool isHovered,
    required bool isPressed,
    required Function(bool) onHover,
    required Function(bool) onPressed,
    Widget? headerAction,
  }) {
    return wrapWithModel(
      model: _model.powerconsumptionenergydetailscardModel,
      updateCallback: () => setState(() {}),
      child: InkWell(
        onTap: () {},
        onHover: onHover,
        onHighlightChanged: onPressed,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            color: isPressed
                ? Colors.blue[100]?.withOpacity(0.3)
                : isHovered
                    ? const Color.fromARGB(255, 18, 211, 236).withOpacity(0.3)
                    : Colors.transparent,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(isHovered ? 0.3 : 0.1),
                blurRadius: isHovered ? 12 : 6,
                offset: Offset(0, isHovered ? 6 : 3),
              ),
            ],
          ),
          child: PowerconsumptionenergydetailscardWidget(
            chartData: chartData,
            isLoading: isLoading,
            period: period,
            title: title,
            headerAction: headerAction,
          ),
        ),
      ),
    );
  }
}
