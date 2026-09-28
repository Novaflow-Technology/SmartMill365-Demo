import 'dart:async';
import 'package:smartmachine365/utils/leak_probe.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:google_fonts/google_fonts.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:http/http.dart' as http;
import 'mqtt_platform_client_stub.dart'
    if (dart.library.html) 'mqtt_platform_client_web.dart' as mqtt_platform;

import 'powerconsumptionenergydetails_widget.dart';
import 'powerrankingcard_widget.dart';
import 'powerusagecard_widget.dart';
import 'powerdiagram_widget.dart';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'package:flutter/material.dart';
import 'package:smartmachine365/services/app_config.dart';

import 'energy_overview_model.dart';
export 'energy_overview_model.dart';

import '../../flutter_flow/nav/router_tracker.dart';

class EnergyOverviewWidget extends StatefulWidget {
  const EnergyOverviewWidget({super.key});

  @override
  State<EnergyOverviewWidget> createState() => _EnergyOverviewWidgetState();
}

class _EnergyOverviewWidgetState extends State<EnergyOverviewWidget> {
  late EnergyOverviewModel _model;

  Timer? _timer;
  Timer? _updateTimeTimer;
  double dailyUsage = 0.0;
  double prevEdel = 0.0;

  String selectedPeriod = "daily";
  String selectedOrder = "desc";

  bool isFirstLoad = true;

  final List<String> excludedDeviceIds = [
    'TD10_65_Screw',
    'TD10_75_Screw',
    'TD7_120_Screw',
    'TD7_65_Screw',
    'TD8_120_Screw',
    'TD8_65_Screw',
    'TD9_65_Screw',
    'TD9_120_Screw',
    'TD9_75_Screw',
  ];

  final String brokerUrl = 'wss://hub.novaplus.my:9001/ws';
  final String clientId = 'Web-customerid';
  final String username = 'nova';
  final String password = 'Nov@flow6889';
  final String subscribeTopic = 'data/SSMYP_MMPM_250018/DPM/#';

  MqttClient? client;
  List<dynamic> apiDevices = [];
  List<dynamic> rankingDevices = [];
  List<dynamic> chartDevices = [];
  List<dynamic> topics = [];
  List<dynamic> usageDevices = [];
  Map<String, Map<String, dynamic>> sensorDataByDevice = {};
  Map<String, double> powerDataByDevice = {};
  String lastUpdateTime = '';

  final scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    LeakProbe.register('EnergyOverview.State');
    _model = createModel(context, () => EnergyOverviewModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
    _initialDataFetch();
    setupMqtt();
    Future.delayed(const Duration(seconds: 20), () {
      if (apiDevices.isEmpty ||
          rankingDevices.isEmpty ||
          chartDevices.isEmpty) {
        fetchTopics();
      }
    });
    routeTracker.addListener(_onRouteChanged);
  }

  Future<void> _initialDataFetch() async {
    await fetchOverviewData();
    if (!mounted) return;
    await fetchPowerData();
    if (mounted) {
      setState(() => isFirstLoad = false);
      _timer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (mounted) {
          await fetchOverviewData();
          if (!mounted) return;
          await fetchPowerData();
          if (!mounted) return;
        }
      });
    }
  }

  void _onRouteChanged() {
    if (routeTracker.currentRoute != '/energyComparison') {
      client?.disconnect();
      _timer?.cancel();
      _updateTimeTimer?.cancel();
      routeTracker.removeListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    LeakProbe.unregister('EnergyOverview.State');
    routeTracker.removeListener(_onRouteChanged);
    _timer?.cancel();
    _updateTimeTimer?.cancel();
    client?.disconnect();
    _model.maybeDispose();
    super.dispose();
  }

  Future<void> setupMqtt() async {
    if (!kIsWeb) return;
    final mqttClient =
        mqtt_platform.createMqttClient("wss://hub.novaplus.my:9001", clientId);
    client = mqttClient;
    mqttClient.port = 9001;
    mqttClient.logging(on: false);
    mqttClient.onConnected = onConnected;
    mqttClient.onSubscribed = onSubscribed;
    mqttClient.onDisconnected = onDisconnected;

    final connMess = MqttConnectMessage()
        .withClientIdentifier(clientId)
        .authenticateAs(username, password)
        .startClean();
    mqttClient.connectionMessage = connMess;

    try {
      await mqttClient.connect();
      if (!mounted) return;
    } catch (e) {
      mqttClient.disconnect();
      return;
    }

    mqttClient.updates!
        .listen((List<MqttReceivedMessage<MqttMessage>> messages) {
      final recMess = messages.first.payload as MqttPublishMessage;
      final message =
          MqttPublishPayload.bytesToStringAsString(recMess.payload.message);
      try {
        final processedMsg = message.replaceAllMapped(
          RegExp(r'(:\s*)NaN(\s*[,}])'),
          (match) => '${match.group(1)}"NaN"${match.group(2)}',
        );
        var data = json.decode(processedMsg);
        String deviceCode = 'unknown';
        if (data['id'] is String) deviceCode = data['id'];
        if (excludedDeviceIds.contains(deviceCode)) return;
        if (mounted) setState(() => sensorDataByDevice[deviceCode] = data);
      } catch (e) {
        print('MQTT: Error processing message: $e');
      }
    });
    mqttClient.subscribe(subscribeTopic, MqttQos.atMostOnce);
  }

  void onConnected() => print('MQTT: Connected');
  void onSubscribed(String topic) => print('MQTT: Subscribed to $topic');
  void onDisconnected() => print('MQTT: Disconnected');

  Future<void> fetchOverviewData() async {
    if (!mounted) return;
    try {
      print(
          'fetchOverviewData: clientId=${AppConfig.clientId}, headers=${AppConfig.headers}');
      final res = await http.get(
          Uri.parse(
              'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyOverview/data/$selectedPeriod'),
          headers: AppConfig.headers);
      if (res.statusCode == 200) {
        final data = json.decode(res.body);
        final filtered = data
            .where((i) => !excludedDeviceIds.contains(i['device']?.toString()))
            .map((i) => Map<String, dynamic>.from(i))
            .toList();
        // Keep showing the previously loaded devices if this fetch came back
        // empty (e.g. no data yet for the selected period) instead of wiping
        // the screen blank.
        if (mounted)
          setState(() {
            lastUpdateTime =
                DateTime.now().toLocal().toString().substring(0, 19);
            if (filtered.isNotEmpty) apiDevices = filtered;
          });
      }
    } catch (e) {
      print('Exception fetching API data: $e');
    }
    await fetchChart();
    if (!mounted) return;
  }

  List<String> getDefaultDeviceIds() => [
        'MSB',
        'CM1',
        'CM2',
        'TD10',
        'MOTAN',
        'C10',
        'CA',
        'C4',
        'L9',
        'C7',
        'C8',
        'C9',
        'TD9_SUB',
        'TD9',
        'TD9 SUB',
        'TDB',
        'TD7',
        'TD8',
        'C2',
        'T17'
      ];

  Future<void> fetchPowerData() async {
    if (!mounted) return;
    try {
      List<String> deviceIds = apiDevices
          .map((d) => d['device']?.toString())
          .where((id) => id != null && !excludedDeviceIds.contains(id))
          .cast<String>()
          .toList();
      if (deviceIds.isEmpty) deviceIds = getDefaultDeviceIds();

      print(              
          'fetchPowerData: clientId=${AppConfig.clientId}, headers=${AppConfig.headers}');
      final res = await http.get(
          Uri.parse(
              'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/timeseries/$selectedPeriod'
              '?machine_ids=${deviceIds.join(',')}&fields=PeakDemand'),
          headers: AppConfig.headers);

      if (res.statusCode == 200) {
        final powerData = json.decode(res.body);
        final Map<String, double> newPower = {};
        for (var item in powerData) {
          if (item['machine_id'] != null &&
              item['data'] != null &&
              item['data']['power_kw'] != null) {
            newPower[item['machine_id'].toString()] =
                (item['data']['power_kw'] as num).toDouble();
          }
        }
        // Keep showing previously loaded power values if this fetch came
        // back empty, instead of clearing the diagram.
        if (mounted)
          setState(() {
            lastUpdateTime =
                DateTime.now().toLocal().toString().substring(0, 19);
            if (newPower.isNotEmpty) powerDataByDevice = newPower;
          });
      }
    } catch (e) {
      print('Exception fetching power data: $e');
    }
  }

  Future<void> fetchChart() async {
    if (!mounted) return;
    try {
      setState(() => chartDevices = apiDevices);
    } catch (e) {
      print("Error in fetch chart: $e");
    }
    await fetchRanking();
    if (!mounted) return;
  }

  Future<void> fetchRanking() async {
    if (!mounted) return;
    try {
      final sorted = List.from(apiDevices)
        ..sort((a, b) {
          final aE = _getValidEnergyValue(a['total_energy']);
          final bE = _getValidEnergyValue(b['total_energy']);
          return selectedOrder.toLowerCase() == "asc"
              ? aE.compareTo(bE)
              : bE.compareTo(aE);
        });
      if (mounted) setState(() => rankingDevices = sorted);
    } catch (e) {
      print("Error in fetch ranking: $e");
    }
  }

  double _getValidEnergyValue(dynamic value) {
    if (value == null) return 0.0;
    if (value is num) return value < 0 ? 0.0 : value.toDouble();
    if (value is String) {
      final p = double.tryParse(value) ?? 0.0;
      return p < 0 ? 0.0 : p;
    }
    return 0.0;
  }

  Future<void> fetchTopics() async {
    try {
      print(
          'fetchTopics: clientId=${AppConfig.clientId}, headers=${AppConfig.headers}');
      final res = await http.get(
          Uri.parse(
              'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energyDetailsInfluxDb/devices'),
          headers: AppConfig.headers);
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final filtered = data
            .where(
                (d) => !excludedDeviceIds.contains(d['device_id']?.toString()))
            .toList();
        final fetchedTopics = filtered
            .map((d) => {'device': d['device_id'], 'total_energy': 0.0})
            .toList();
        if (fetchedTopics.isNotEmpty && mounted) {
          setState(() => topics = fetchedTopics);
        }
      }
    } catch (e) {
      print('Exception fetching devices: $e');
    }
  }

  Widget _buildCyberpunkDropdown({
    required BuildContext context,
    required String? value,
    required List<String> options,
    required String hint,
    required double width,
    required void Function(String?) onChanged,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    const cyan = Color(0xFF00D4FF);
    final safeValue = (value != null && options.contains(value)) ? value : null;
    return Container(
      width: width,
      height: 42,
      decoration: BoxDecoration(
        color: isLight
            ? theme.secondaryBackground
            : const Color(0xFF071A2E).withOpacity(0.95),
        border: Border.all(
            color: isLight ? theme.alternate : cyan.withOpacity(0.5),
            width: 1.2),
        boxShadow: isLight
            ? null
            : [BoxShadow(color: cyan.withOpacity(0.08), blurRadius: 8)],
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: isLight ? theme.primary : cyan,
              boxShadow: isLight
                  ? null
                  : [
                      BoxShadow(
                          color: cyan.withOpacity(0.85),
                          blurRadius: 8,
                          spreadRadius: 0)
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
                  focusColor: Colors.transparent,
                  hint: Text(hint,
                      style: GoogleFonts.poppins(
                          color: isLight
                              ? theme.secondaryText
                              : cyan.withOpacity(0.82),
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  style: GoogleFonts.poppins(
                      color: isLight ? theme.primaryText : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  icon: Icon(Icons.keyboard_arrow_down_rounded,
                      color: isLight ? theme.primary : cyan, size: 20),
                  items: options
                      .map((opt) => DropdownMenuItem<String>(
                            value: opt,
                            child: Text(opt,
                                style: GoogleFonts.poppins(
                                    color: isLight
                                        ? theme.primaryText
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

  void onOrderChanged(String newOrder) {
    setState(() => selectedOrder = newOrder);
    fetchRanking();
  }


  @override
  Widget build(BuildContext context) {
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
          child: LayoutBuilder(
            builder: (context, constraints) {
              final isMobile = constraints.maxWidth < kBreakpointLarge;
              return Container(
                width: double.infinity,
                height: double.infinity,
                decoration: BoxDecoration(
                  color: FlutterFlowTheme.of(context).primaryBackground,
                  image: DecorationImage(
                    fit: BoxFit.cover,
                    image: Image.asset('assets/images/backgroundanimated\\.gif')
                        .image,
                  ),
                ),
                child: isMobile
                    // ── Mobile: vertical scrollable layout ─────────────────
                    ? SingleChildScrollView(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Dashboard/EnergyOverview',
                              style: FlutterFlowTheme.of(context)
                                  .titleLarge
                                  .override(
                                    fontFamily: 'Poppins',
                                    color: FlutterFlowTheme.of(context)
                                        .txtSecondary,
                                    fontSize: 12,
                                    letterSpacing: 0.0,
                                    font: GoogleFonts.poppins(),
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Energy Overview',
                              style: FlutterFlowTheme.of(context)
                                  .headlineMedium
                                  .override(
                                    fontFamily: 'Poppins',
                                    letterSpacing: 0.0,
                                    fontWeight: FontWeight.normal,
                                    font: GoogleFonts.poppins(
                                        fontWeight: FontWeight.normal),
                                  ),
                            ),
                            const SizedBox(height: 4),
                            Builder(builder: (context) {
                              final isLight = Theme.of(context).brightness ==
                                  Brightness.light;
                              final txtColor = isLight
                                  ? FlutterFlowTheme.of(context).txtSecondary
                                  : Colors.white;
                              return RichText(
                                text: TextSpan(children: [
                                  TextSpan(
                                    text: 'Last Update: ',
                                    style: TextStyle(
                                        color: txtColor,
                                        fontWeight: FontWeight.bold,
                                        fontSize: 12),
                                  ),
                                  TextSpan(
                                      text: lastUpdateTime,
                                      style: TextStyle(
                                          color: txtColor, fontSize: 12)),
                                ]),
                              );
                            }),
                            const SizedBox(height: 8),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _buildCyberpunkDropdown(
                                  context: context,
                                  value: selectedPeriod == 'daily'
                                      ? 'Daily'
                                      : selectedPeriod == 'monthly'
                                          ? 'Monthly'
                                          : 'Yearly',
                                  options: const ['Daily', 'Monthly', 'Yearly'],
                                  hint: 'Daily',
                                  width: 130,
                                  onChanged: (newVal) async {
                                    if (newVal != null) {
                                      setState(() {
                                        _model.dropDownValue =
                                            newVal.toLowerCase();
                                        selectedPeriod = newVal.toLowerCase();
                                        isFirstLoad = true;
                                      });
                                      await fetchOverviewData();
                                      await fetchPowerData();
                                      setState(() => isFirstLoad = false);
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            // Power diagram (fixed height on mobile)
                            SizedBox(
                              height: 420,
                              child: wrapWithModel(
                                model: _model.powerdiagramModel,
                                child: PowerdiagramWidget(
                                  apiDevices:
                                      apiDevices.isEmpty ? topics : apiDevices,
                                  mqttDevices: sensorDataByDevice,
                                  powerData: powerDataByDevice,
                                  isLoading: isFirstLoad,
                                ),
                                updateCallback: () => setState(() {}),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 300,
                              child: wrapWithModel(
                                model:
                                    _model.powerconsumptionenergydetailsModel,
                                updateCallback: () => safeSetState(() {}),
                                child: PowerconsumptionenergydetailsWidget(
                                  isLoading: isFirstLoad,
                                  devices: chartDevices.isEmpty
                                      ? topics
                                      : chartDevices,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 180,
                              child: wrapWithModel(
                                model: _model.powerusagecardModel,
                                updateCallback: () => safeSetState(() {}),
                                child: PowerusagecardWidget(
                                  isLoading: isFirstLoad,
                                  devices: chartDevices,
                                  period: selectedPeriod,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            SizedBox(
                              height: 320,
                              child: wrapWithModel(
                                model: _model.powerrankingcardModel,
                                updateCallback: () => safeSetState(() {}),
                                child: PowerrankingcardWidget(
                                  title: 'Energy Ranking',
                                  onOrderChanged: onOrderChanged,
                                  order: selectedOrder,
                                  isLoading: isFirstLoad,
                                  rankingDevices: rankingDevices.isEmpty
                                      ? topics
                                      : rankingDevices,
                                ),
                              ),
                            ),
                            const SizedBox(height: 16),
                          ],
                        ),
                      )
                    // ── Desktop: original fixed-height flex layout ──────────
                    : Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          mainAxisSize: MainAxisSize.max,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            // ── Breadcrumb ──
                            Text(
                              'Dashboard/EnergyOverview',
                              style: FlutterFlowTheme.of(context)
                                  .titleLarge
                                  .override(
                                    fontFamily: 'Poppins',
                                    color: FlutterFlowTheme.of(context)
                                        .txtSecondary,
                                    fontSize: 12,
                                    letterSpacing: 0.0,
                                    font: GoogleFonts.poppins(),
                                  ),
                            ),
                            const SizedBox(height: 4),

                            // ── Title + Last Update ──
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text(
                                  'Energy Overview',
                                  style: FlutterFlowTheme.of(context)
                                      .headlineMedium
                                      .override(
                                        fontFamily: 'Poppins',
                                        letterSpacing: 0.0,
                                        fontWeight: FontWeight.normal,
                                        font: GoogleFonts.poppins(
                                          fontWeight: FontWeight.normal,
                                        ),
                                      ),
                                ),
                                Padding(
                                  padding: const EdgeInsets.only(right: 10),
                                  child: Builder(builder: (context) {
                                    final isLight =
                                        Theme.of(context).brightness ==
                                            Brightness.light;
                                    final txtColor = isLight
                                        ? FlutterFlowTheme.of(context)
                                            .txtSecondary
                                        : Colors.white;
                                    return RichText(
                                      text: TextSpan(children: [
                                        TextSpan(
                                          text: 'Last Update: ',
                                          style: TextStyle(
                                              color: txtColor,
                                              fontWeight: FontWeight.bold),
                                        ),
                                        TextSpan(
                                          text: lastUpdateTime,
                                          style: TextStyle(color: txtColor),
                                        ),
                                      ]),
                                    );
                                  }),
                                ),
                              ],
                            ),
                            const SizedBox(height: 1),

                            // ── Dropdown ──
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                _buildCyberpunkDropdown(
                                  context: context,
                                  value: selectedPeriod == 'daily'
                                      ? 'Daily'
                                      : selectedPeriod == 'monthly'
                                          ? 'Monthly'
                                          : 'Yearly',
                                  options: const ['Daily', 'Monthly', 'Yearly'],
                                  hint: 'Daily',
                                  width: 130,
                                  onChanged: (newVal) async {
                                    if (newVal != null) {
                                      setState(() {
                                        _model.dropDownValue =
                                            newVal.toLowerCase();
                                        selectedPeriod = newVal.toLowerCase();
                                        isFirstLoad = true;
                                      });
                                      await fetchOverviewData();
                                      if (!mounted) return;
                                      await fetchPowerData();
                                      if (!mounted) return;
                                      setState(() => isFirstLoad = false);
                                    }
                                  },
                                ),
                              ],
                            ),
                            const SizedBox(height: 5),

                            // ── Main content — Expanded supaya isi baki height ──
                            Expanded(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  // ── Left: diagram ──
                                  Expanded(
                                    flex: 5,
                                    child: wrapWithModel(
                                      model: _model.powerdiagramModel,
                                      child: PowerdiagramWidget(
                                        apiDevices: apiDevices.isEmpty
                                            ? topics
                                            : apiDevices,
                                        mqttDevices: sensorDataByDevice,
                                        powerData: powerDataByDevice,
                                        isLoading: isFirstLoad,
                                      ),
                                      updateCallback: () => setState(() {}),
                                    ),
                                  ),
                                  const SizedBox(width: 10),

                                  // ── Right: 3 cards — Expanded + flex proporsional ──
                                  Expanded(
                                    flex: 2,
                                    child: Column(
                                      mainAxisSize: MainAxisSize.max,
                                      children: [
                                        // Energy Distribution — 38%
                                        Expanded(
                                          flex: 38,
                                          child: wrapWithModel(
                                            model: _model
                                                .powerconsumptionenergydetailsModel,
                                            updateCallback: () =>
                                                safeSetState(() {}),
                                            child:
                                                PowerconsumptionenergydetailsWidget(
                                              isLoading: isFirstLoad,
                                              devices: chartDevices.isEmpty
                                                  ? topics
                                                  : chartDevices,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),

                                        // Energy Usage — 22%
                                        Expanded(
                                          flex: 22,
                                          child: wrapWithModel(
                                            model: _model.powerusagecardModel,
                                            updateCallback: () =>
                                                safeSetState(() {}),
                                            child: PowerusagecardWidget(
                                              isLoading: isFirstLoad,
                                              devices: chartDevices,
                                              period: selectedPeriod,
                                            ),
                                          ),
                                        ),
                                        const SizedBox(height: 10),

                                        // Energy Ranking — 40%
                                        Expanded(
                                          flex: 40,
                                          child: wrapWithModel(
                                            model: _model.powerrankingcardModel,
                                            updateCallback: () =>
                                                safeSetState(() {}),
                                            child: PowerrankingcardWidget(
                                              title: 'Energy  Ranking',
                                              onOrderChanged: onOrderChanged,
                                              order: selectedOrder,
                                              isLoading: isFirstLoad,
                                              rankingDevices:
                                                  rankingDevices.isEmpty
                                                      ? topics
                                                      : rankingDevices,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
              );
            },
          ),
        ),
      ),
    );
  }
}
