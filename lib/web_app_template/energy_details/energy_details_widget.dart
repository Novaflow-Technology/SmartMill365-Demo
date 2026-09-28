//WEB
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:smartmachine365/flutter_flow/nav/nav.dart';
import 'package:smartmachine365/services/scope_resolver.dart';
import 'package:smartmachine365/services/filter_memory.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/flutter_flow/flutter_flow_drop_down.dart';
import 'package:smartmachine365/web_app_template/energy_details/Powerconsumptionhourlyenergydetailscard_widget.dart';
import 'package:smartmachine365/web_app_template/energy_details/equipmentcard_widget.dart';

import 'influxdb_service.dart';
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/services/facility_service.dart';
import 'package:smartmachine365/web_app_template/master_facility_setting/models/facility_data.dart';

import 'energydetailscurrentcard_widget.dart';
import 'energydetailsenergycard_widget.dart';
import 'energydetailspowercard_widget.dart';
import 'energydetailsvoltagecard_widget.dart';
import 'powerconsumptionenergydetailscard_widget.dart';
import 'powerusagecardenergydetails_widget.dart';
import 'realtimepowercard_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/flutter_flow/form_field_controller.dart';
import 'energy_details_model.dart';
export 'energy_details_model.dart';

import '../../flutter_flow/nav/router_tracker.dart';
import 'package:smartmachine365/utils/leak_probe.dart';
import 'package:smartmachine365/utils/memory_guard.dart';

/// Hoisted out of build(): this page rebuilds every couple of seconds (live
/// polling + the equipment card's 2s ticker), and constructing the provider
/// inline allocated a fresh AssetImage on every one of those frames.
const AssetImage _kBackgroundImage =
    AssetImage('assets/images/backgroundanimated.gif');

class EnergyDetailsWidget extends StatefulWidget {
  const EnergyDetailsWidget({super.key});

  @override
  State<EnergyDetailsWidget> createState() => _EnergyDetailsWidgetState();
}

class _EnergyDetailsWidgetState extends State<EnergyDetailsWidget> {
  late EnergyDetailsModel _model;

  String selectedPeriod = "daily";
  List<Map<String, dynamic>> chartData = [];
  String lastPeriod = '';
  bool isLoading = false;
  bool isLoading1 = false;
  bool isLoading2 = false;
  bool _noDataAvailable = false;
  Timer? _timer;
  double dailyUsage = 0.0;
  double monthlyUsage = 0.0;
  double yearlyUsage = 0.0;
  double dailyEmission = -1.0; // -1 = use card's estimate (Danapac/Demo)
  double peakUsage = 0.0;
  double averageUsage = 0.0;
  double prevEdel = 0.0;
  double usage = 0.0;

  double maxDemandKW = 0.0;
  double dailyConsumption = 0.0;

  bool isLoadingHourly = true;
  List<Map<String, dynamic>> chartDataHourly = [];
  List<Map<String, dynamic>> chartDataHourlyPrevious = [];
  // Malaysia time (UTC+8, no DST) so "today" matches MYT regardless of the
  // viewer's device timezone.
  DateTime selectedDate = DateTime.now().toUtc().add(const Duration(hours: 8));

  late InfluxDBService _influxService;

  /// One client for the page. http.get() creates and tears down a client per
  /// call; a single one is closed in dispose(), which aborts anything still in
  /// flight rather than letting it land on a dead State.
  final http.Client _client = http.Client();

  /// Bumped on every 5s poll. Only the widgets that show live sensor values
  /// listen to it, so a poll no longer rebuilds the whole page — the hourly bar
  /// chart, the filter bar and the rest are untouched. Rebuilding everything is
  /// what made CPU spike to 60% every five seconds and then fall back to idle.
  final ValueNotifier<int> _sensorTick = ValueNotifier<int>(0);

  Map<String, dynamic> currentData = {};
  Map<String, dynamic> voltageData = {};
  Map<String, dynamic> powerData = {};
  Map<String, dynamic> energyData = {};

  List<String> topics = [];
  // meterId -> meterName, sourced from Master Facility Setting so renaming a
  // device there is reflected in this dropdown without any backend change.
  Map<String, String> deviceDisplayNames = {};
  String? selectedTopic;
  String lastUpdateTime = '';

  bool isCardHovered = false;
  bool isCardPressed = false;
  bool isEquipmentCardHovered = false;
  bool isEquipmentCardPressed = false;

  String selectedDuration = "1h";

  List<FacilityData> _allFacilities = [];
  List<String> _allTopics = [];
  String selectedPlant = 'All';
  String selectedSite = 'All';
  String selectedProductionArea = 'All';
  String selectedEquipment = 'All';

  /// The equipment this user is allowed to see.
  ///
  /// Every filter on this screen reads from here rather than from the raw
  /// list, so the user's data scope is applied once instead of in each
  /// dropdown. Filtering at the source also means the queries built from a
  /// selection cannot reach past the scope, which four separately filtered
  /// dropdowns could not promise.
  ///
  /// Note the naming trap this has to live with: on an equipment row `zone`
  /// holds the Production Area and `productionArea` holds the Line. The scope
  /// is about areas, so `zone` is what it compares.
  List<FacilityData> get _scopedFacilities {
    final scope = AppStateNotifier.instance.dataScope;
    if (scope.isUnrestricted) return _allFacilities;
    return _allFacilities
        .where((f) => ScopeResolver.allowsFacilityNames(
              scope,
              plantName: f.plant,
              areaName: f.zone,
            ))
        .toList();
  }

  List<String> get _plantOptions {
    final plants = _scopedFacilities.map((f) => f.plant).where((p) => p.isNotEmpty && p != '-').toSet().toList()..sort();
    return ['All', ...plants];
  }

  List<String> get _siteOptions {
    var facilities = _scopedFacilities.toList();
    if (selectedPlant != 'All') {
      facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    }
    final sites = facilities.map((f) => f.zone).where((z) => z.isNotEmpty && z != '-').toSet().toList()..sort();
    return ['All', ...sites];
  }

  List<String> get _productionAreaOptions {
    var facilities = _scopedFacilities.toList();
    if (selectedPlant != 'All') facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All') facilities = facilities.where((f) => f.zone == selectedSite).toList();
    final areas = facilities.map((f) => f.productionArea).where((a) => a.isNotEmpty && a != '-').toSet().toList()..sort();
    return ['All', ...areas];
  }

  List<String> get _equipmentOptions {
    var facilities = _scopedFacilities.toList();
    if (selectedPlant != 'All') facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All') facilities = facilities.where((f) => f.zone == selectedSite).toList();
    if (selectedProductionArea != 'All') facilities = facilities.where((f) => f.productionArea == selectedProductionArea).toList();
    final equipments = facilities.map((f) => f.equipmentNameId).where((e) => e.isNotEmpty && e != '-').toSet().toList()..sort();
    return ['All', ...equipments];
  }

  List<String> get _filteredTopics {
    if (selectedPlant == 'All' && selectedSite == 'All' && selectedProductionArea == 'All' && selectedEquipment == 'All') {
      return _allTopics;
    }
    var facilities = _scopedFacilities.toList();
    if (selectedPlant != 'All') facilities = facilities.where((f) => f.plant == selectedPlant).toList();
    if (selectedSite != 'All') facilities = facilities.where((f) => f.zone == selectedSite).toList();
    if (selectedProductionArea != 'All') facilities = facilities.where((f) => f.productionArea == selectedProductionArea).toList();
    if (selectedEquipment != 'All') facilities = facilities.where((f) => f.equipmentNameId == selectedEquipment).toList();
    final facilityMeterIds = facilities.map((f) => f.meterId).toSet();
    return _allTopics.where((t) => facilityMeterIds.contains(t)).toList();
  }

  static const String _filterScreen = 'energy_details';

  /// Keeps the current selection for the next visit. Fire-and-forget — nothing
  /// on screen waits for it.
  void _rememberFilters() {
    FilterMemory.save(_filterScreen, {
      'plant': selectedPlant,
      'site': selectedSite,
      'productionArea': selectedProductionArea,
      'equipment': selectedEquipment,
      'topic': selectedTopic,
    });
  }

  /// Puts back what was selected last time, skipping anything no longer
  /// offered. A meter can be renamed, retired, or moved outside this user's
  /// access between visits, so a remembered value never wins over what the
  /// dropdown actually holds.
  Future<void> _restoreFilters() async {
    final saved = await FilterMemory.load(_filterScreen);
    if (saved.isEmpty || !mounted) return;
    String pick(String key, List<String> options, String current) {
      final v = saved[key];
      return (v != null && options.contains(v)) ? v : current;
    }
    final wantTopic = saved['topic'];
    setState(() {
      selectedPlant = pick('plant', _plantOptions, selectedPlant);
      selectedSite = pick('site', _siteOptions, selectedSite);
      selectedProductionArea =
          pick('productionArea', _productionAreaOptions, selectedProductionArea);
      selectedEquipment =
          pick('equipment', _equipmentOptions, selectedEquipment);
      topics = _filteredTopics;
      if (wantTopic != null && topics.contains(wantTopic)) {
        selectedTopic = wantTopic;
        _model.dropDownValueController?.value = wantTopic;
      } else if (topics.isNotEmpty && !topics.contains(selectedTopic)) {
        selectedTopic = topics.first;
        _model.dropDownValueController?.value = selectedTopic;
      }
    });
    final t = selectedTopic;
    if (t == null) return;
    _influxService.switchDevice(t);
    await fetchAggregateData();
    if (!mounted) return;
    await fetchDataHourly();
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
        if (!_productionAreaOptions.contains(selectedProductionArea)) selectedProductionArea = 'All';
        if (!_equipmentOptions.contains(selectedEquipment)) selectedEquipment = 'All';
      }
      if (site != null) {
        selectedSite = site;
        if (!_productionAreaOptions.contains(selectedProductionArea)) selectedProductionArea = 'All';
        if (!_equipmentOptions.contains(selectedEquipment)) selectedEquipment = 'All';
      }
      if (productionArea != null) {
        selectedProductionArea = productionArea;
        if (!_equipmentOptions.contains(selectedEquipment)) selectedEquipment = 'All';
      }
      if (equipment != null) {
        selectedEquipment = equipment;
      }

      topics = _filteredTopics;
      _rememberFilters();

      if (topics.isNotEmpty && (selectedTopic == null || !topics.contains(selectedTopic))) {
        selectedTopic = topics.first;
        _model.dropDownValueController?.value = selectedTopic;
      } else if (topics.isEmpty) {
        selectedTopic = null;
      }
    });

    if (selectedTopic != previousTopic && selectedTopic != null) {
      // The previous device's chart data and decoded bitmaps are dead the
      // moment the selection changes — let them go instead of waiting for
      // pressure to build.
      releaseCachedMemory();
      _influxService.switchDevice(selectedTopic!);
      fetchAggregateData();
      fetchDataHourly();
    }
  }

  static const List<String> durationOptions = ['5s', '1m', '5m', '15m', '30m', '1h', '4h', '12h', '24h'];

  String _convertDurationToMinutes(String duration) {
    final value = int.tryParse(duration.replaceAll(RegExp(r'[a-zA-Z]'), '')) ?? 1;
    final unit = duration.replaceAll(RegExp(r'[0-9]'), '');

    switch (unit) {
      case 's':
        return "${value}s";
      case 'm':
        return "${value}m";
      case 'h':
        return "${value}h";
      default:
        return value.toString();
    }
  }

  @override
  void initState() {
    super.initState();
    LeakProbe.register('EnergyDetails.State');
    _model = createModel(context, () => EnergyDetailsModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);

    _influxService = InfluxDBService(
      pollingInterval: const Duration(seconds: 5),
      onDataReceived: _onInfluxDataReceived,
      onError: (error) => print('InfluxDB Error: $error'),
    );

    _timer = Timer.periodic(const Duration(minutes: 5), (_) {
      fetchAggregateData();
      fetchDataHourly();
    });

    Future.delayed(const Duration(seconds: 1), () {
      if (selectedTopic == null || topics.isEmpty) {
        fetchTopics();
      }
    });

    routeTracker.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    if (routeTracker.currentRoute != '/energyDetails') {
      _timer?.cancel();
      _influxService.dispose();
      routeTracker.removeListener(_onRouteChanged);
    }
  }

  void _onInfluxDataReceived(SensorData data) {
    if (!mounted) return;
    currentData = data.current;
    voltageData = data.voltage;
    powerData = data.power;
    energyData = data.energy;
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
    prevEdel = _extractEdelValue(energyData);
    // No setState: only the live-value widgets rebuild.
    _sensorTick.value++;
  }

  /// Rebuilds [child] whenever a poll lands, and nothing else on the page.
  Widget _onSensorTick(Widget Function() build) => ValueListenableBuilder<int>(
        valueListenable: _sensorTick,
        builder: (_, __, ___) => build(),
      );

  double _extractEdelValue(Map<String, dynamic> data) {
    if (data.containsKey('Edel')) {
      final val = data['Edel'];
      return val is num ? val.toDouble() : 0.0;
    }
    return 0.0;
  }

  void _setNoData() {
    if (!mounted) return;
    setState(() {
      _noDataAvailable = true;
      isLoading = false;
      isLoading1 = false;
      isLoading2 = false;
      isLoadingHourly = false;
    });
  }

  Future<void> _loadDeviceDisplayNames() async {
    try {
      final facilities = await FacilityService.getFacilities();
      if (!mounted) return;
      setState(() {
        deviceDisplayNames = {
          for (final f in facilities)
            if (f.meterId.isNotEmpty && f.meterName.isNotEmpty) f.meterId: f.meterName,
        };
      });
    } catch (_) {
      // Names are a display-only nicety — keep showing raw device IDs on failure.
    }
  }

  Future<void> fetchTopics() async {
    if (!mounted) return;
    _loadDeviceDisplayNames();
    try {
      final results = await Future.wait([
        http
            .get(
              Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/devices'),
              headers: AppConfig.headers,
            )
            .timeout(const Duration(seconds: 25)),
        FacilityService.getFacilities().catchError((_) => <FacilityData>[]),
      ]);

      if (!mounted) return;

      final response = results[0] as http.Response;
      final facilities = results[1] as List<FacilityData>;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final List<String> fetchedTopics = List<String>.from(
          data.map((d) => d['device_id']),
        );

        if (fetchedTopics.isEmpty) {
          _setNoData();
          return;
        }

        if (!mounted) return;
        setState(() {
          _noDataAvailable = false;
          _allTopics = fetchedTopics;
          _allFacilities = facilities;
          topics = _filteredTopics;
          bool hasMSB = topics.contains("MSB");
          selectedTopic = hasMSB ? "MSB" : (topics.isNotEmpty ? topics.first : null);
          _model.dropDownValueController ??= FormFieldController<String>(selectedTopic);
          // The options exist now, so a remembered selection can be checked
          // against them and put back.
          WidgetsBinding.instance
              .addPostFrameCallback((_) => _restoreFilters());
          if (selectedTopic != null) {
            _influxService.startPolling(selectedTopic!);
            fetchAggregateData();
            fetchDataHourly();
          }
        });
      } else {
        print('Error fetching devices: ${response.statusCode}');
        _setNoData();
      }
    } catch (e) {
      print('Exception fetching devices: $e');
      if (mounted) _setNoData();
    }
  }

  bool _hourlyInFlight = false;

  Future<void> fetchDataHourly() async {
    // The 5-minute timer, the device dropdown, the date picker and the duration
    // picker all call this. Without a guard a slow response let several runs
    // overlap, each holding its own buffers — and every request had no timeout,
    // so a hung one was retained for the life of the page.
    if (selectedTopic == null || !mounted || _hourlyInFlight) return;
    _hourlyInFlight = true;

    setState(() => isLoadingHourly = true);

    try {
      final dateString = DateFormat('yyyy-MM-dd').format(selectedDate);
      final durationParam = selectedDuration;

      final url = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/data/$selectedTopic/hourly'
          '?date=$dateString&duration=$durationParam';

      print('Fetching hourly data with duration: $selectedDuration');
      print('URL: $url');

      final response = await _client
          .get(Uri.parse(url), headers: AppConfig.headers)
          .timeout(const Duration(seconds: 20));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);

        List<dynamic> currentList = [];
        List<dynamic> previousList = [];

        if (jsonData is Map && jsonData.containsKey('data')) {
          var dataObj = jsonData['data'];
          if (dataObj is Map) {
            currentList = dataObj['current'] ?? [];
            previousList = dataObj['previous'] ?? [];
          }
        }

        final currentData = currentList
            .map<Map<String, dynamic>>((item) => {
                  'label': item['label']?.toString() ?? '',
                  'value': item['value'] is num ? item['value'].toDouble() : 0.0,
                  'time': item['time']?.toString() ?? item['label']?.toString() ?? '',
                })
            .toList();

        final previousData = previousList
            .map<Map<String, dynamic>>((item) => {
                  'label': item['label']?.toString() ?? '',
                  'value': item['value'] is num ? item['value'].toDouble() : 0.0,
                  'time': item['time']?.toString() ?? item['label']?.toString() ?? '',
                })
            .toList();

        setState(() {
          chartDataHourly = currentData;
          chartDataHourlyPrevious = previousData;
        });

        print('âœ… Fetched hourly data - Current: ${currentData.length} points, Previous: ${previousData.length} points');
      } else {
        print('âŒ Error fetching hourly data: ${response.statusCode}');
        print('Response: ${response.body}');
        if (!mounted) return;
        setState(() {
          chartDataHourly = [];
          chartDataHourlyPrevious = [];
        });
      }
    } catch (e) {
      print("âŒ Exception fetching hourly data: $e");
      if (!mounted) return;
      setState(() {
        chartDataHourly = [];
        chartDataHourlyPrevious = [];
      });
    } finally {
      _hourlyInFlight = false;
      if (mounted) setState(() => isLoadingHourly = false);
    }
  }

  Future<void> fetchCurrentDayData() async {
    if (selectedTopic == null || !mounted) return;

    try {
      final response = await _client.get(
        Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/current/$selectedTopic',
        ),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          maxDemandKW = (data['max_demand_kW'] ?? 0).toDouble();
          dailyConsumption = (data['energy_consumption_kWh'] ?? 0).toDouble();
        });
        print('Fetched current day data - Max Demand: $maxDemandKW kW, Daily Consumption: $dailyConsumption kWh');
      } else {
        print('Error fetching current day data: ${response.statusCode}');
        setState(() {
          maxDemandKW = 0.0;
          dailyConsumption = 0.0;
        });
      }
    } catch (e) {
      print('Exception fetching current day data: $e');
      if (!mounted) return;
      setState(() {
        maxDemandKW = 0.0;
        dailyConsumption = 0.0;
      });
    }
  }

  Future<void> fetchChartData() async {
    if (selectedTopic == null || !mounted) return;
    setState(() => isLoading = true);

    try {
      final chartResponse = await _client.get(
        Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/data/$selectedTopic/$selectedPeriod',
        ),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 20));
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
        setState(() => chartData = processedData);
      } else {
        setState(() => chartData = []);
      }

      final lastPeriodResponse = await _client.get(
        Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/vs/$selectedTopic/$selectedPeriod',
        ),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (lastPeriodResponse.statusCode == 200) {
        final lastPeriodData = jsonDecode(lastPeriodResponse.body);
        setState(() {
          lastPeriod = lastPeriodData[0]['percentage_changed'].toString();
        });
      } else {
        setState(() => lastPeriod = '');
      }
    } catch (e) {
      print('Exception fetching chart data: $e');
      if (!mounted) return;
      setState(() {
        chartData = [];
        lastPeriod = '';
      });
    }

    if (mounted) setState(() => isLoading = false);
  }

  Future<void> fetchPowerUsage() async {
    if (selectedTopic == null || !mounted) return;
    setState(() => isLoading1 = true);

    try {
      final response = await _client.get(
        Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetails/total/$selectedTopic',
        ),
        headers: AppConfig.headers,
      ).timeout(const Duration(seconds: 20));
      if (!mounted) return;
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        double daily = 0.0, monthly = 0.0, yearly = 0.0, emission = 0.0;

        for (var entry in data) {
          final period = entry['period'];
          final totalEnergy = (entry['total_energy'] ?? 0).toDouble();
          if (period == 'daily') {
            daily = totalEnergy.isFinite ? totalEnergy : 0.0;
            // Real carbon emission from MySQL Overall_daily (clients); -1 marks
            // "not provided" so the card keeps its estimate for Danapac/Demo.
            emission = (entry['daily_emission'] ?? -1).toDouble();
          } else if (period == 'monthly') {
            monthly = totalEnergy.isFinite ? totalEnergy : 0.0;
          } else if (period == 'yearly') {
            yearly = totalEnergy.isFinite ? totalEnergy : 0.0;
          }
        }

        setState(() {
          dailyUsage = daily;
          monthlyUsage = monthly;
          yearlyUsage = yearly;
          dailyEmission = emission;

          if (selectedPeriod.toLowerCase() == 'daily') {
            usage = dailyUsage;
          } else if (selectedPeriod.toLowerCase() == 'monthly') {
            usage = monthlyUsage;
          } else if (selectedPeriod.toLowerCase() == 'yearly') {
            usage = yearlyUsage;
          } else {
            usage = 0.0;
          }
        });
      } else {
        setState(() {
          dailyUsage = 0.0;
          monthlyUsage = 0.0;
          yearlyUsage = 0.0;
          usage = 0.0;
        });
      }
    } catch (e) {
      print('Exception fetching power usage: $e');
      if (!mounted) return;
      setState(() {
        dailyUsage = 0.0;
        monthlyUsage = 0.0;
        yearlyUsage = 0.0;
        usage = 0.0;
      });
    }

    if (mounted) setState(() => isLoading1 = false);
  }

  bool _aggregateInFlight = false;

  /// Driven by the same 5-minute timer as fetchDataHourly, plus every device
  /// and filter change, so it needs the same guard. The body has several early
  /// returns, hence the wrapper - the flag must reset on every path.
  Future<void> fetchAggregateData() async {
    if (selectedTopic == null || !mounted || _aggregateInFlight) return;
    _aggregateInFlight = true;
    try {
      await _fetchAggregateDataInner();
    } finally {
      _aggregateInFlight = false;
    }
  }

  Future<void> _fetchAggregateDataInner() async {
    if (selectedTopic == null || !mounted) return;

    setState(() {
      isLoading2 = true;
      isLoading = true;
      isLoading1 = true;
    });

    try {
      final stats = await _influxService.queryEnergyStats(selectedTopic!);
      if (!mounted) return;
      setState(() {
        peakUsage = stats['peak'] ?? 0.0;
        averageUsage = stats['average'] ?? 0.0;
      });
      print("Fetched peak/average from InfluxDB");
    } catch (e) {
      // A request aborted by dispose() is not a failed reading. Zeroing the
      // figures on the way out — or on a request the next page already
      // replaced — showed the operator 0 kW for data that was fine.
      if (!mounted) return;
      print('Error fetching energy stats from InfluxDB: $e');
      if (mounted) {
        setState(() {
          peakUsage = 0.0;
          averageUsage = 0.0;
        });
      }
    }

    await fetchCurrentDayData();
    if (!mounted) return;

    setState(() => isLoading2 = false);

    await fetchPowerUsage();
    if (!mounted) return;
    await fetchChartData();
    if (!mounted) return;
  }

  void onPeriodChanged(String newPeriod) {
    setState(() => selectedPeriod = newPeriod);

    if (selectedPeriod.toLowerCase() == 'daily') {
      usage = dailyUsage;
    } else if (selectedPeriod.toLowerCase() == 'monthly') {
      usage = monthlyUsage;
    } else if (selectedPeriod.toLowerCase() == 'yearly') {
      usage = yearlyUsage;
    } else {
      usage = 0.0;
    }

    fetchChartData();
  }

  @override
  void dispose() {
    LeakProbe.unregister('EnergyDetails.State');
    _sensorTick.dispose();
    _client.close();
    routeTracker.removeListener(_onRouteChanged);
    _influxService.dispose();
    _model.dispose();
    _timer?.cancel();
    // Chart arrays can hold a few thousand points each. Drop them and the
    // decoded bitmaps now rather than leaving them for the collector to find.
    chartData = const [];
    chartDataHourly = const [];
    chartDataHourlyPrevious = const [];
    releaseCachedMemory();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_noDataAvailable) {
      return Scaffold(
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: _buildNoDataBanner(),
      );
    }
    if (selectedTopic == null || selectedTopic!.isEmpty) {
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
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SafeArea(
          child: Row(
            children: [
              Expanded(
                child: Align(
                  alignment: const AlignmentDirectional(0, -1),
                  child: Container(
                    width: double.infinity,
                    constraints: const BoxConstraints.expand(),
                    decoration: BoxDecoration(
                      color: FlutterFlowTheme.of(context).primaryBackground,
                      image: const DecorationImage(
                        fit: BoxFit.cover,
                        image: _kBackgroundImage,
                      ),
                    ),
                    padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 24),
                    child: SingleChildScrollView(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Padding(
                            padding: const EdgeInsetsDirectional.only(bottom: 0),
                            child: Text(
                              'Dashboard/EnergyDetails',
                              style: FlutterFlowTheme.of(context).titleLarge.override(
                                    fontFamily: 'Poppins',
                                    color: FlutterFlowTheme.of(context).txtSecondary,
                                    fontSize: 12,
                                    letterSpacing: 0.0,
                                    font: GoogleFonts.poppins(),
                                  ),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsetsDirectional.only(bottom: 16),
                            child: Text(
                              'Energy Details',
                              style: FlutterFlowTheme.of(context).headlineMedium.override(
                                    fontFamily: 'Poppins',
                                    letterSpacing: 0.0,
                                    font: GoogleFonts.poppins(),
                                  ),
                            ),
                          ),
                          _buildTopBar(),
                          if (_noDataAvailable)
                            _buildNoDataBanner()
                          else ...[
                            _buildMainCards(),
                            const SizedBox(height: 10),
                            _buildSensorCards(),
                            const SizedBox(height: 16),
                            _buildHourlyChartCard(),
                            const SizedBox(height: 10),
                            _buildEquipmentCard(),
                          ],
                        ],
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

  Widget _buildTopBar() {
    const cCyan = Color(0xFF00E5FF);
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    final accentColor = isLight ? theme.primary : cCyan;

    // Scaled proportionally for desktop, but floored so text/icons stay
    // legible instead of shrinking to a couple of pixels on a phone-width
    // screen.
    final sw = MediaQuery.of(context).size.width;
    final fsMeta = (sw * 0.0064).clamp(11.0, 13.0);
    final iconSz = (sw * 0.0110).clamp(18.0, 22.0);
    final pad = (sw * 0.010).clamp(8.0, 20.0);
    final radius = (sw * 0.005).clamp(6.0, 10.0);
    final borderW = (sw * 0.0008).clamp(1.0, 1.6);

    // Below the tablet breakpoint, a fixed 170-180px dropdown wraps onto its
    // own row with wasted space beside it — lay filters out as a tidy
    // 2-column grid instead. contentWidth accounts for the page's 16px
    // horizontal padding on each side.
    final double contentWidth = sw - 32;
    final bool narrowFilters = sw < kBreakpointMedium;
    double dw(double desktopWidth) {
      if (!narrowFilters) return desktopWidth;
      final twoUp = (contentWidth - 10) / 2;
      return twoUp < 140 ? contentWidth : twoUp;
    }

    return Padding(
      padding: const EdgeInsetsDirectional.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 10,
            runSpacing: 8,
            children: [
              _buildCyberpunkDropdown(
                context: context,
                value: selectedPlant == 'All' ? null : selectedPlant,
                options: _plantOptions.where((o) => o != 'All').toList(),
                hint: 'Plant',
                width: dw(170),
                onChanged: (val) => _onFilterChanged(plant: val ?? 'All'),
              ),
              _buildCyberpunkDropdown(
                context: context,
                value: selectedSite == 'All' ? null : selectedSite,
                options: _siteOptions.where((o) => o != 'All').toList(),
                hint: 'Zone / Production Area',
                width: dw(170),
                onChanged: (val) => _onFilterChanged(site: val ?? 'All'),
              ),
              _buildCyberpunkDropdown(
                context: context,
                value: selectedProductionArea == 'All' ? null : selectedProductionArea,
                options: _productionAreaOptions.where((o) => o != 'All').toList(),
                hint: 'Production Line',
                width: dw(180),
                onChanged: (val) => _onFilterChanged(productionArea: val ?? 'All'),
              ),
              _buildCyberpunkDropdown(
                context: context,
                value: selectedEquipment == 'All' ? null : selectedEquipment,
                options: _equipmentOptions.where((o) => o != 'All').toList(),
                hint: 'Equipment',
                width: dw(180),
                onChanged: (val) => _onFilterChanged(equipment: val ?? 'All'),
              ),
              _buildCyberpunkDropdown(
                context: context,
                value: selectedTopic,
                options: topics,
                hint: 'Devices',
                width: dw(180),
                labelBuilder: (id) => deviceDisplayNames[id] ?? id,
                onChanged: (val) async {
                  if (val != null && val != selectedTopic) {
                    setState(() {
                      selectedTopic = val;
                      _model.dropDownValueController?.value = val;
                    });
                    _rememberFilters();
                    _influxService.switchDevice(val);
                    await fetchAggregateData();
                    if (!mounted) return;
                    await fetchDataHourly();
                    if (!mounted) return;
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              if (_allFacilities.isNotEmpty &&
                  (selectedPlant != 'All' || selectedSite != 'All' || selectedProductionArea != 'All' || selectedEquipment != 'All'))
                GestureDetector(
                  onTap: () {
                    final previousTopic = selectedTopic;
                    setState(() {
                      selectedPlant = 'All';
                      selectedSite = 'All';
                      selectedProductionArea = 'All';
                      selectedEquipment = 'All';
                      topics = _filteredTopics;
                      FilterMemory.clear(_filterScreen);
                      if (topics.isNotEmpty && (selectedTopic == null || !topics.contains(selectedTopic))) {
                        selectedTopic = topics.first;
                        _model.dropDownValueController?.value = selectedTopic;
                      }
                    });
                    if (selectedTopic != previousTopic && selectedTopic != null) {
                      _influxService.switchDevice(selectedTopic!);
                      fetchAggregateData();
                      fetchDataHourly();
                    }
                  },
                  child: Container(
                    height: 32,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.redAccent.withOpacity(0.5)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.filter_alt_off_rounded, color: Colors.redAccent, size: 15),
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
                  Container(
                    width: 8,
                    height: 8,
                    margin: const EdgeInsets.only(right: 6),
                    decoration: BoxDecoration(
                      color: _influxService.isConnected ? Colors.green : Colors.red,
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: (_influxService.isConnected ? Colors.green : Colors.red).withOpacity(0.5),
                          blurRadius: 4,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                  ),
                  Text(
                    _influxService.isConnected ? 'Live' : 'Disconnected',
                    style: TextStyle(
                      color: _influxService.isConnected ? Colors.green : Colors.red,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(width: 12),
                  GestureDetector(
                    onTap: () async {
                      setState(() {
                        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
                      });
                      fetchAggregateData();
                      fetchDataHourly();
                      fetchPowerUsage();
                    },
                    child: Container(
                      padding: EdgeInsets.all(pad * 0.28),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.08),
                        borderRadius: BorderRadius.circular(radius * 0.4),
                        border: Border.all(
                          color: accentColor.withOpacity(0.35),
                          width: borderW,
                        ),
                      ),
                      child: Icon(
                        Icons.refresh_rounded,
                        color: accentColor.withOpacity(0.80),
                        size: iconSz,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (lastUpdateTime.isNotEmpty &&
                      responsiveVisibility(context: context, phone: false))
                    Text(
                      'UPDATED $lastUpdateTime',
                      style: GoogleFonts.poppins(
                        color: accentColor.withOpacity(0.65),
                        fontSize: fsMeta,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNoDataBanner() {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.symmetric(vertical: 40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.cloud_off_rounded, size: 56, color: Colors.white24),
          const SizedBox(height: 16),
          Text(
            'No energy data available',
            style: GoogleFonts.poppins(fontSize: 18, color: Colors.white54, fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Text(
            'InfluxDB is not configured or no devices found.',
            style: GoogleFonts.poppins(fontSize: 13, color: Colors.white38),
          ),
          const SizedBox(height: 20),
          TextButton.icon(
            onPressed: () {
              setState(() => _noDataAvailable = false);
              fetchTopics();
            },
            icon: const Icon(Icons.refresh_rounded, color: Colors.cyanAccent),
            label: Text('Retry', style: GoogleFonts.poppins(color: Colors.cyanAccent)),
          ),
        ],
      ),
    );
  }

  Widget _buildMainCards() {
    final edelValue = _extractEdelValue(energyData);

    return LayoutBuilder(
      builder: (context, constraints) {
        const double spacing = 16.0;
        // Below this, a 4-column grid can't fit even the 260px minimum card
        // width without the doubled-width chart card overflowing the screen —
        // stack everything full-width instead of shrinking it into place.
        final bool isStacked = constraints.maxWidth < kBreakpointMedium;

        Widget card1 = wrapWithModel(
          model: _model.realtimepowercardModel,
          updateCallback: () => setState(() {}),
          child: RealtimepowercardWidget(
            peak_energy: maxDemandKW.clamp(0.0, 800.0),
            average_energy: dailyConsumption.clamp(0.0, 800.0),
            power: powerData,
            prevEdel: edelValue,
            isLoading: isLoading2,
          ),
        );

        Widget card2 = wrapWithModel(
          model: _model.powerusagecardenergydetailsModel,
          updateCallback: () => setState(() {}),
          child: PowerusagecardenergydetailsWidget(
            dailyUsage: dailyUsage,
            monthlyUsage: monthlyUsage,
            yearlyUsage: yearlyUsage,
            dailyEmission: dailyEmission,
            isLoading: isLoading1,
          ),
        );

        Widget card3 = SizedBox(
          height: 380,
          child: wrapWithModel(
            model: _model.powerconsumptionenergydetailscardModel,
            updateCallback: () => setState(() {}),
            child: InkWell(
              onTap: () {},
              onHover: (h) => setState(() => isCardHovered = h),
              onHighlightChanged: (p) => setState(() => isCardPressed = p),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isCardPressed
                      ? Colors.blue[100]?.withOpacity(0.3)
                      : isCardHovered
                          ? const Color.fromARGB(255, 18, 211, 236).withOpacity(0.3)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isCardHovered ? 0.3 : 0.1),
                      blurRadius: isCardHovered ? 12 : 6,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: PowerconsumptionenergydetailscardWidget(
                  period: selectedPeriod,
                  chartData: chartData,
                  totalEnergy: usage,
                  lastPeriod: lastPeriod,
                  onPeriodChanged: onPeriodChanged,
                  isLoading: isLoading,
                ),
              ),
            ),
          ),
        );

        if (isStacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              card1,
              const SizedBox(height: spacing),
              card2,
              const SizedBox(height: spacing),
              card3,
            ],
          );
        }

        const int crossAxisCount = 4;
        final double totalSpacing = spacing * (crossAxisCount - 1);
        final double optimalWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;
        final double cardWidth = optimalWidth < 260 ? 260 : optimalWidth;

        return SizedBox(
          width: double.infinity,
          child: Wrap(
            spacing: spacing,
            runSpacing: spacing,
            alignment: WrapAlignment.start,
            runAlignment: WrapAlignment.start,
            children: [
              SizedBox(width: cardWidth, child: card1),
              SizedBox(width: cardWidth, child: card2),
              SizedBox(width: (cardWidth * 2) + spacing, child: card3),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSensorCards() {
    return LayoutBuilder(
      builder: (context, constraints) {
        double spacing = 16.0;
        int crossAxisCount = 4;

        double totalSpacing = spacing * (crossAxisCount - 1);
        double optimalWidth = (constraints.maxWidth - totalSpacing) / crossAxisCount;

        double cardWidth = optimalWidth < 260 ? 260 : optimalWidth;

        return SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: cardWidth,
                  child: wrapWithModel(
                    model: _model.energydetailscurrentcardModel,
                    updateCallback: () => setState(() {}),
                    child: RepaintBoundary(child: _onSensorTick(() => EnergydetailscurrentcardWidget(currentData: currentData))),
                  ),
                ),
                SizedBox(width: spacing),
                SizedBox(
                  width: cardWidth,
                  child: wrapWithModel(
                    model: _model.energydetailsvoltagecardModel,
                    updateCallback: () => setState(() {}),
                    child: RepaintBoundary(child: _onSensorTick(() => EnergydetailsvoltagecardWidget(voltageData: voltageData))),
                  ),
                ),
                SizedBox(width: spacing),
                SizedBox(
                  width: cardWidth,
                  child: wrapWithModel(
                    model: _model.energydetailspowercardModel,
                    updateCallback: () => setState(() {}),
                    child: RepaintBoundary(child: _onSensorTick(() => EnergydetailspowercardWidget(powerData: powerData))),
                  ),
                ),
                SizedBox(width: spacing),
                SizedBox(
                  width: cardWidth,
                  child: wrapWithModel(
                    model: _model.energydetailsenergycardModel,
                    updateCallback: () => setState(() {}),
                    child: RepaintBoundary(child: _onSensorTick(() => EnergydetailsenergycardWidget(energyData: energyData))),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildHourlyChartCard() {
    return PowerconsumptionhourlyenergydetailscardWidget(
      chartData: chartDataHourly,
      chartDataPrevious: chartDataHourlyPrevious,
      isLoading: isLoadingHourly,
      title: 'Last 24 hours Power Load (kW)',
      selectedDate: selectedDate,
      selectedDuration: selectedDuration,
      durationOptions: durationOptions,
      onDateChanged: (newDate) {
        setState(() {
          selectedDate = newDate;
          isLoadingHourly = true;
        });
        print('“… Date changed to: ${DateFormat('yyyy-MM-dd').format(newDate)}');
        fetchDataHourly();
      },
      onDurationChanged: (newDuration) {
        setState(() {
          selectedDuration = newDuration;
          isLoadingHourly = true;
        });
        print('🔄 Duration changed to: $newDuration');
        fetchDataHourly();
      },
    );
  }

  Widget _buildEquipmentCard() {
    return Row(
      children: [
        Expanded(
          child: wrapWithModel(
            model: _model.equipmentCardModel,
            updateCallback: () => setState(() {}),
            child: InkWell(
              onTap: () => print('Equipment card tapped'),
              onHover: (h) => Future.microtask(() {
                if (mounted) setState(() => isEquipmentCardHovered = h);
              }),
              onHighlightChanged: (p) => Future.microtask(() {
                if (mounted) setState(() => isEquipmentCardPressed = p);
              }),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isEquipmentCardPressed
                      ? Colors.blue[100]?.withOpacity(0.3)
                      : isEquipmentCardHovered
                          ? const Color.fromARGB(255, 18, 211, 236).withOpacity(0.3)
                          : Colors.transparent,
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(isEquipmentCardHovered ? 0.3 : 0.1),
                      blurRadius: isEquipmentCardHovered ? 12 : 6,
                      offset: Offset(0, isEquipmentCardHovered ? 6 : 3),
                    ),
                  ],
                ),
                child: RepaintBoundary(
                  child: _onSensorTick(() => EquipmentCardWidget(
                        currentData: currentData,
                        voltageData: voltageData,
                        powerData: powerData,
                      )),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
