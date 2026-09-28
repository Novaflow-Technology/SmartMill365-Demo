import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/web_app_template/equipment_details/Equipmentcard_widget.dart';
import 'package:smartmachine365/web_app_template/equipment_details/downtimeanalysiscard_widget.dart';
import 'package:smartmachine365/web_app_template/equipment_details/equipmentdowntimecard_widget.dart';
import 'package:smartmachine365/web_app_template/equipment_details/productioncard_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'dart:async';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';

import 'alarmlistcardproduction_widget.dart';
import 'equipmentcardmaindetails_widget.dart';
import 'runtimeoeecard_widget.dart';
import 'stationkpicard_widget.dart';
import 'workordercard_widget.dart';
import 'equipment_details_model.dart';
export 'equipment_details_model.dart';

import '../../flutter_flow/nav/router_tracker.dart';
import 'package:smartmachine365/flutter_flow/helper/parse_double_value.dart';

// Configuration class for API URLs
class ApiConfig {
  static const String baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static const String dataUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static String get productionAreas => '$baseUrl/productionAreas';
  static String equipment(String productionAreaId) =>
      '$baseUrl/productionAreas/equipment/$productionAreaId';
  static String alarm(String productionAreaName) =>
      '$dataUrl/equipmentDetails/alarm/$productionAreaName';
  static String dailyStatus(String productionAreaName) =>
      '$dataUrl/equipmentDetails/daily-status/$productionAreaName';
  static String workOrder(String workOrderId) =>
      '$baseUrl/workOrders/$workOrderId';
  static String product(String productId) =>
      '$baseUrl/workOrders/product/$productId';
  static String get equipmentStatus => '$dataUrl/equipmentStatus/status';
  static String get overallDailyMachineBatch =>
      '$dataUrl/equipmentDetails/overall-daily-machine-oee/latest/batch';
  static String machineStatus24h(String productionArea, String equipmentId) =>
      '$dataUrl/equipmentDetails/utilization/machine-status-24h/$productionArea/$equipmentId';
  static String machineEfficiency(String productionArea, String equipmentId) =>
      '$dataUrl/equipmentDetails/overall-daily-machine-efficiency/$productionArea/$equipmentId';
  static String machineEfficiencyByDate(String productionArea, String equipmentId, String period) =>
      '$dataUrl/equipmentDetails/overall-machine-efficiency/$productionArea/$equipmentId/$period';
  static String downtimeStatusDuration(String machineId, String workOrderId) =>
      '$dataUrl/equipmentDetails/alarms/status-duration/$machineId/$workOrderId';
  static String plannedWOInput(String machineId, String workOrderId) =>
      '$dataUrl/equipmentDetails/planned-wo-input/$machineId/$workOrderId';
  static String overallWOPerformance(String machineId, String workOrderId) =>
      '$dataUrl/equipmentDetails/overall-wo-performance/$machineId/$workOrderId';
  static String machinePlannedInput(String machineId, String period) =>
      '$dataUrl/equipmentDetails/machine-planned-input/$machineId/$period';
}

class EquipmentDetailsWidget extends StatefulWidget {
  final String selectedEquipmentId;
  final String productionAreaName;
  final bool? isWorkOrderDetails;

  const EquipmentDetailsWidget(
      {super.key,
      required this.selectedEquipmentId,
      required this.productionAreaName,
      this.isWorkOrderDetails});

  @override
  _EquipmentDetailsWidgetState createState() => _EquipmentDetailsWidgetState();
}

class _EquipmentDetailsWidgetState extends State<EquipmentDetailsWidget> {
  late EquipmentDetailsModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  bool isLoading = true;
  bool isLoading1 = true;
  bool isLoading2 = true;
  bool isLoading3 = true;
  bool isLoading4 = true;
  bool isLoadingStatus = true;

  late Timer _timer;
  late Timer _timer1;
  late Timer _statusTimer;
  List<Map<String, String>> productionAreaList = [];
  Map<String, Map<String, dynamic>> equipmentList = {};
  List<Map<String, dynamic>> equipmentFromFirestore = [];
  String? selectedEquipmentId;
  String? selectedProductionAreaId = '';
  String? selectedProductionAreaName = '';
  Map<String, dynamic>? selectedEquipmentDetails;
  List<dynamic> alarmData = [];
  String lastUpdateTime = '';

  // Status-related variables
  Map<String, dynamic> equipmentStatusData = {};
  bool apiError = false;
  String apiErrorMessage = '';

  int running = 0;
  int idle = 0;
  int alarm = 0;
  int stopped = 0;

  int progress = 0;
  int quantity = 0;
  String unit = '';
  String selectedWorkID = '';
  String productId = '';
  String productName = '';
  String date = '';
  String combinedEquipmentNames = '';
  int status = 5;
  bool show = true;
  String prodAreaName = "";
  String selectEquipId = "";

  // OEE Data related
  Map<String, dynamic> oeeData = {};
  bool isLoadingOEE = true;
  double availability = 0.0;
  double performance = 0.0;
  double quality = 0.0;
  double oee = 0.0;

  // Utilization data
  List<Map<String, dynamic>> utilizationData = [];
  bool isLoadingUtilization = true;

  int actualIdleMinutes = 0;
  int actualRunningMinutes = 0;
  int actualAlarmMinutes = 0;
  int actualStoppedMinutes = 0;

// DAILY efficiency data (from fetchMachineEfficiency)
  List<Map<String, dynamic>> dailyMachineEfficiencyData = [];
  bool isLoadingDailyEfficiency = true;
  int dailyActualProduction = 0;
  int dailyPlannedProduction = 0;

// PERIOD efficiency data (from fetchMachineEfficiencyByDate)
  List<Map<String, dynamic>> periodMachineEfficiencyData = [];
  bool isLoadingPeriodEfficiency = true;
  int periodActualProduction = 0;
  int periodPlannedProduction = 0;
  String currentEfficiencyPeriod = 'daily';
  bool isLoadingEfficiencyPeriodChange = false;

  List<String> downtimeCategories = [];
  List<double> downtimeTimeValues = [];
  List<double> downtimeAccumulatedValues = [];
  int totalDowntime = 0;
  double downtimeMaxY = 1200;
  bool isLoadingDowntime = true;

  String plannedStartTime = '';
  String checkInTime = '';
  String targetCompletionTime = '';
  String estimatedCompletionTime = '';
  int remainingHour = 0;
  double remainingHours = 0.0;
  double estimatedDelay = 0.0;
  bool isLateStart = false;
  bool isOverdue = false;

  List<Map<String, dynamic>> machineStatusData = [];
  bool isLoadingMachineStatus = true;
  String? processID;
  String? processIDWoP;
  String? equipProcessID;
  String? workOrderID;
  String jobOrderID = '';

  Map<String, Map<String, dynamic>> equipmentFullProcessData = {};
  int jobOrderGrossQuantity = 0;
  int jobOrderExpectedQuantity = 0;
  String runStatus = 'N/A';
  Map<String, Map<String, dynamic>> equipmentPerformanceData = {};

  String woPlannedCycleTime = '';
  String woActualCycleTime = '';
  bool isLoadingCycleTime = false;

  final GlobalKey _equipmentCardKey = GlobalKey();
  double _equipmentCardHeight = 0.0;
  bool _heightMeasurementScheduled = false;

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => EquipmentDetailsModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);

    prodAreaName = widget.productionAreaName;
    selectEquipId = widget.selectedEquipmentId;

    _timer = Timer.periodic(const Duration(minutes: 2), (timer) {
      if (mounted) fetchAlarm();
    });
    _timer1 = Timer.periodic(const Duration(minutes: 1), (timer) {
      // if (mounted) fetchRunTimeStatus();
    });
    _statusTimer = Timer.periodic(const Duration(seconds: 5), (timer) {
      if (mounted && selectedEquipmentDetails != null) {
        fetchEquipmentStatus();
      }
    });

    routeTracker.addListener(_onRouteChanged);

    fetchProductionAreas();
    fetchMachineStatus24h();
  }

  void _onRouteChanged() {
    if (routeTracker.currentRoute != '/equipmentDetails') {
      _timer.cancel();
      _timer1.cancel();
      _statusTimer.cancel();
      routeTracker.removeListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    routeTracker.removeListener(_onRouteChanged);
    _model.dispose();
    _timer.cancel();
    _timer1.cancel();
    _statusTimer.cancel();
    super.dispose();
  }

  Future<void> fetchProductionAreas() async {
    if (!mounted) return;

    setState(() => isLoading = true);
    try {
      print('Fetching production areas from: ${ApiConfig.productionAreas}');
      final response = await http.get(Uri.parse(ApiConfig.productionAreas));

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        if (data == null) {
          throw Exception('API returned null data');
        }

        List<Map<String, String>> areas = [];

        if (data is List) {
          for (var item in data) {
            if (item != null && item is Map<String, dynamic>) {
              final id = item['id']?.toString();
              final name = item['name']?.toString();

              if (id != null &&
                  name != null &&
                  id.isNotEmpty &&
                  name.isNotEmpty) {
                areas.add({
                  'id': id,
                  'name': name,
                });
              }
            }
          }
        } else {
          throw Exception(
              'API returned unexpected format: expected List, got ${data.runtimeType}');
        }

        // Equipment uses 'P1'/'P2' as productionArea — remap Intech-P1/P2 to match
        for (int i = 0; i < areas.length; i++) {
          if (areas[i]['id'] == 'Intech-P1') areas[i] = {'id': 'P1', 'name': areas[i]['name']!};
          if (areas[i]['id'] == 'Intech-P2') areas[i] = {'id': 'P2', 'name': areas[i]['name']!};
        }
        if (!areas.any((a) => a['id'] == 'P1')) {
          areas.insert(0, {'id': 'P1', 'name': 'Plant 1'});
        }

        if (!mounted) return;

        setState(() {
          productionAreaList = areas;

          if (prodAreaName.isNotEmpty && selectEquipId.isNotEmpty) {
            // Find the selected production area more safely
            Map<String, String>? selectedProductionArea;
            try {
              selectedProductionArea = productionAreaList
                  .firstWhere((area) => area['id'] == prodAreaName);
            } catch (e) {
              print('Production area with id $prodAreaName not found');
              selectedProductionArea = null;
            }

            if (selectedProductionArea != null) {
              selectedProductionAreaName = selectedProductionArea['name'];
              selectedProductionAreaId = prodAreaName;
              _model.dropDownValueController?.value =
                  selectedProductionAreaName;
            } else if (productionAreaList.isNotEmpty) {
              selectedProductionAreaId = productionAreaList[0]['id'];
              selectedProductionAreaName = productionAreaList[0]['name'];
              _model.dropDownValueController?.value =
                  selectedProductionAreaName;
            }
          } else if (productionAreaList.isNotEmpty) {
            // Default to 'P1' area where equipment data lives
            final p1 = productionAreaList.firstWhere(
              (a) => a['id'] == 'P1',
              orElse: () => productionAreaList[0],
            );
            selectedProductionAreaId = p1['id'];
            selectedProductionAreaName = p1['name'];
            _model.dropDownValueController?.value = selectedProductionAreaName;
          }
        });

        print(
            "Successfully fetched production areas: ${productionAreaList.length}");
        print(
            "Selected production area: $selectedProductionAreaName (ID: $selectedProductionAreaId)");

        if (selectedProductionAreaId?.isNotEmpty == true) {
          await fetchEquipmentFromFirestore();
          // await fetchRunTimeStatus();
        }
      } else {
        throw Exception(
            'Failed to load production areas (status ${response.statusCode}): ${response.body}');
      }
    } catch (e, stackTrace) {
      print('Error fetching production areas from API: $e');
      print('Stack trace: $stackTrace');

      if (mounted) {
        setState(() {
          productionAreaList = [
            {'id': 'p1', 'name': 'Plant 1'},
            {'id': 'p2', 'name': 'Plant 2'}
          ];

          selectedProductionAreaId = 'p2';
          selectedProductionAreaName = 'Plant 2';
          _model.dropDownValueController?.value = 'Plant 2';

          equipmentFromFirestore = [];
          selectedEquipmentId = null;
          selectEquipId = "PE120";
          selectedEquipmentDetails = null;
          equipmentStatusData = {};

          isLoading1 = true;
          isLoading2 = true;
          isLoading3 = true;
          isLoading4 = true;
          isLoadingStatus = true;
        });

        await fetchEquipmentFromFirestore();
        // await fetchRunTimeStatus();
      }
    } finally {
      if (mounted) {
        setState(() => isLoading = false);
      }
    }
  }

  Future<void> fetchEquipmentFromFirestore() async {
    if (!mounted) return;

    if (selectedProductionAreaId == null || selectedProductionAreaId!.isEmpty) {
      print('No production area selected, skipping equipment fetch');
      if (mounted) {
        setState(() {
          equipmentFromFirestore = [];
          selectedEquipmentId = null;
          selectedEquipmentDetails = null;
          selectedWorkID = 'N/A';
          _model.equipmentDropDownValueController?.value = null;
          isLoading1 = false;
          isLoading3 = false;
          isLoading4 = false;
          isLoadingStatus = false;
        });
      }
      return;
    }

    setState(() => isLoading1 = true);
    try {
      final querySnapshot = await FirebaseFirestore.instance
          .collection('equipments')
          .where('productionArea', isEqualTo: selectedProductionAreaId)
          .get();

      final currentUserId = AppStateNotifier.instance.uid ?? '';

      final equipments = await Future.wait(querySnapshot.docs.map((doc) async {
        final data = doc.data();
        // Handle work_id as either String or List
        String workId;
        final rawWorkId = data['work_id'];
        if (rawWorkId is String) {
          workId = rawWorkId;
        } else if (rawWorkId is List) {
          workId = rawWorkId.isNotEmpty
              ? rawWorkId[0].toString()
              : 'Unknown Work ID';
        } else {
          workId = 'Unknown Work ID';
        }

        // Resolve image: prefer user-specific, fall back to shared default
        String imageUrl = data['imageUrl'] as String? ?? '';
        if (currentUserId.isNotEmpty) {
          final userImageDoc = await FirebaseFirestore.instance
              .collection('equipments')
              .doc(doc.id)
              .collection('userImages')
              .doc(currentUserId)
              .get();
          if (userImageDoc.exists) {
            imageUrl = userImageDoc.data()?['imageUrl'] as String? ?? imageUrl;
          }
        }

        return {
          'id': doc.id,
          'equipment_id': data['equipment_id'] as String? ?? '',
          'name': data['name'] as String? ?? 'Unknown Equipment',
          'productionArea': data['productionArea'] as String? ?? '',
          'work_id': workId,
          'PIC': data['PIC'] as String? ?? '',
          'factory_id': data['factory_id'] as String? ?? '',
          'modelType': data['modelType'] as String? ?? '',
          'product': data['product'] as String? ?? '',
          'purchaseDate': data['purchaseDate'] as Timestamp? ?? Timestamp.now(),
          'serialNo': data['serialNo'] as String? ?? '',
          'warrantyDate': data['warrantyDate'] as Timestamp? ?? Timestamp.now(),
          'work_order_id':
              (data['work_id'] is List && (data['work_id'] as List).isNotEmpty)
                  ? (data['work_id'] as List).first.toString()
                  : '',
          'imageUrl': imageUrl,
        };
      }));

      if (!mounted) return;

      setState(() {
        equipmentFromFirestore = equipments;
      });

      print(
          "Successfully fetched ${equipments.length} equipments for production area: $selectedProductionAreaId");
      if (equipments.isNotEmpty) {
        print(
            "Available equipment names: ${equipments.map((e) => e['name']).toList()}");
        print("Looking for equipment: '$selectEquipId'");
      }

      // Enhanced equipment selection logic
      if (equipments.isNotEmpty) {
        Map<String, dynamic>? selectedEquipment;

        // Try to find the specified equipment first
        if (selectEquipId.isNotEmpty) {
          try {
            selectedEquipment = equipments.firstWhere(
              (equipment) {
                final equipmentName =
                    equipment['name']?.toString()?.trim() ?? '';
                final targetName = selectEquipId.toString().trim();
                print("Comparing: '$equipmentName' with '$targetName'");
                return equipmentName == targetName;
              },
            );
            print("Found matching equipment: ${selectedEquipment?['name']}");
          } catch (e) {
            print(
                'Equipment "$selectEquipId" not found in available equipments');
            print(
                'Available options: ${equipments.map((e) => '"${e['name']}"').join(', ')}');
            // Fall back to first equipment if specified equipment not found
            selectedEquipment = equipments.first;
          }
        } else {
          // Always default to first equipment if no specific equipment requested
          selectedEquipment = equipments.first;
        }

        // Set the selected equipment
        if (selectedEquipment != null) {
          final equipmentId = selectedEquipment['id'] as String?;
          final equipmentName = selectedEquipment['name'] as String?;
          final workId = selectedEquipment['work_id'] as String? ?? 'N/A';

          setState(() {
            selectedEquipmentId = equipmentId;
            selectedEquipmentDetails = selectedEquipment;
            selectedWorkID = workId;

            // Update dropdown controller safely
            if (_model.equipmentDropDownValueController != null) {
              _model.equipmentDropDownValueController!.value = equipmentName;
            }

            // Clear previous status data
            equipmentStatusData = {};

            // Reset loading states
            isLoadingStatus = true;
            isLoading3 = true;
            isLoading4 = true;
          });

          print("Selected equipment: $equipmentName (ID: $equipmentId)");
          print("Work ID: $selectedWorkID");

          await fetchEquipmentProcessIds();
          await fetchMachinePerformance();
          await fetchWOCycleTimes();

          // Fetch all related data for the selected equipment
          try {
            await Future.wait([
              fetchEquipmentList(),
              fetchEquipmentStatus(),
              fetchAlarm(),
              fetchEquipmentOEE(),
              fetchMachineStatus24h(),
              fetchMachineEfficiency(),
              fetchMachineEfficiencyByDate(),
              fetchDowntimeData(),
              fetchWOCycleTimes()
            ]);

            // Fetch work progress if we have a valid work ID
            if (selectedWorkID != 'N/A' &&
                selectedWorkID != 'Unknown Work ID') {
              await fetchWorkProgress();
            } else {
              if (mounted) {
                setState(() {
                  progress = 0;
                  quantity = 0;
                  unit = '';
                  show = false;
                  isLoading3 = false;
                });
              }
            }
          } catch (e) {
            print('Error fetching related data: $e');
            if (mounted) {
              setState(() {
                isLoading3 = false;
                isLoading4 = false;
                isLoadingStatus = false;
              });
            }
          }
        }
      } else {
        // Handle empty equipment list
        setState(() {
          selectedEquipmentId = null;
          selectedEquipmentDetails = null;
          selectedWorkID = 'N/A';
          if (_model.equipmentDropDownValueController != null) {
            _model.equipmentDropDownValueController!.value = null;
          }
          progress = 0;
          quantity = 0;
          unit = '';
          equipmentStatusData = {};
          alarmData = [];
          isLoading3 = false;
          isLoading4 = false;
          isLoadingStatus = false;
        });
      }
    } catch (e) {
      print('Error fetching equipments from Firestore: $e');
      if (mounted) {
        setState(() {
          equipmentFromFirestore = [];
          selectedEquipmentId = null;
          selectedEquipmentDetails = null;
          selectedWorkID = 'N/A';
          if (_model.equipmentDropDownValueController != null) {
            _model.equipmentDropDownValueController!.value = null;
          }
          progress = 0;
          quantity = 0;
          unit = '';
          equipmentStatusData = {};
          alarmData = [];
          isLoading3 = false;
          isLoading4 = false;
          isLoadingStatus = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => isLoading1 = false);
      }
    }
  }

  Future<void> fetchEquipmentStatus() async {
    if (selectedEquipmentDetails == null) {
      print('No equipment selected, skipping status fetch');
      setState(() => isLoadingStatus = false);
      return;
    }

    setState(() => isLoadingStatus = true);
    try {
      final requestBody = [
        {
          'equipmentId': selectedEquipmentDetails!['equipment_id'] ??
              selectedEquipmentDetails!['name'],
          'productionArea': selectedEquipmentDetails!['productionArea'],
        }
      ];

      print('Sending POST request to: ${ApiConfig.equipmentStatus}');
      print('Request body: ${jsonEncode(requestBody)}');

      final response = await http
          .post(
            Uri.parse(ApiConfig.equipmentStatus),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      print('Status response: ${response.statusCode}');
      print('Status response body: ${response.body}');

      if (response.statusCode == 200) {
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        final List<dynamic> data = jsonDecode(response.body);

        setState(() {
          apiError = false;
          apiErrorMessage = '';

          if (data.isNotEmpty) {
            final statusData = data[0];
            equipmentStatusData = {
              'machine_status':
                  statusData['machine_status'] ?? {'m_status': -1},
              'total_good_quantity': statusData['total_good_quantity'] ?? 0,
              'total_gross_quantity': statusData['total_gross_quantity'] ?? 0,
              'job_order_id': statusData['job_order_id'],
              'work_id': statusData['job_order_id'] ??
                  selectedEquipmentDetails!['work_id'],
              'oee': statusData['oee'],
              'alarm': statusData['alarm'] ?? {},
              'unit': selectedEquipmentDetails!['unit'] ?? 'units',
              'process': selectedEquipmentDetails!['process'] ?? '1',
            };

            // Join status data with selected equipment details
            selectedEquipmentDetails = {
              ...selectedEquipmentDetails!,
              'status': equipmentStatusData,
              'equipment_status': getEquipmentStatusString(equipmentStatusData),
            };
          }
        });
        print('Successfully fetched equipment status');
      } else {
        print('Failed to fetch equipment status: ${response.statusCode}');
        setState(() {
          apiError = true;
          apiErrorMessage =
              'Failed to fetch equipment status (Error ${response.statusCode})';
          equipmentStatusData = {
            'machine_status': {'m_status': -1},
            'total_good_quantity': 0,
            'total_gross_quantity': 0,
            'job_order_id': null,
            'work_id': selectedEquipmentDetails!['work_id'],
            'oee': null,
            'alarm': {},
            'unit': selectedEquipmentDetails!['unit'] ?? 'units',
            'process': selectedEquipmentDetails!['process'] ?? '1',
          };

          // Join error status with selected equipment details
          selectedEquipmentDetails = {
            ...selectedEquipmentDetails!,
            'status': equipmentStatusData,
            'equipment_status': 'Unknown',
          };
        });
      }
    } catch (e) {
      print('Error fetching equipment status: $e');
      setState(() {
        apiError = true;
        apiErrorMessage = 'Error fetching equipment status: $e';
        equipmentStatusData = {
          'machine_status': {'m_status': -1},
          'total_good_quantity': 0,
          'total_gross_quantity': 0,
          'job_order_id': null,
          'work_id': selectedEquipmentDetails!['work_id'],
          'oee': null,
          'alarm': {},
          'unit': selectedEquipmentDetails!['unit'] ?? 'units',
          'process': selectedEquipmentDetails!['process'] ?? '1',
        };

        // Join error status with selected equipment details
        selectedEquipmentDetails = {
          ...selectedEquipmentDetails!,
          'status': equipmentStatusData,
          'equipment_status': 'Unknown',
        };
      });
    } finally {
      setState(() => isLoadingStatus = false);
    }
  }

  String getEquipmentStatusString(Map<String, dynamic> statusData) {
    final rawStatus = statusData['machine_status']?['m_status'];
    final statusCode = int.tryParse(rawStatus.toString()) ?? -1;

    switch (statusCode) {
      case 1:
        return 'Running';
      case 0:
        return 'Idle';
      case 2:
        return 'Stopped';
      case 3:
        return 'Stopped';
      default:
        return 'Unknown';
    }
  }

  Future<void> fetchAlarm() async {
    if (selectedEquipmentDetails == null ||
        selectedEquipmentDetails!['name'] == null) {
      print('No equipment selected, skipping alarm fetch');
      setState(() {
        alarmData = [];
        isLoading4 = false;
      });
      return;
    }

    setState(() => isLoading4 = true);
    try {
      final response = await http.get(Uri.parse(ApiConfig.alarm(
          selectedEquipmentDetails!['name'].toString().trim())));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          alarmData = data ?? [];
        });
        print("Successfully fetched alarm data: ${alarmData.length} items");
      } else {
        throw Exception('Failed to load alarm (status ${response.statusCode})');
      }
    } catch (e) {
      print('Error fetching alarm from API: $e');
      setState(() {
        alarmData = [];
      });
    } finally {
      setState(() => isLoading4 = false);
    }
  }

  Future<void> fetchEquipmentList() async {
    if (selectedProductionAreaId == null ||
        selectedProductionAreaId!.isEmpty ||
        prodAreaName.isNotEmpty) {
      print('No production area ID, skipping equipment list fetch');
      return;
    }

    try {
      final uri = Uri.parse(ApiConfig.equipment(selectedProductionAreaId!));
      final response = await http.get(uri);

      if (response.statusCode != 200) {
        throw Exception('Failed to load equipment: ${response.statusCode}');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final Map<String, Map<String, dynamic>> grouped = {};

      for (final item in data) {
        final rawName = (item['name'] as String?)?.trim() ?? '';
        if (rawName.isEmpty) continue;
        final prefix =
            rawName.contains('_') ? rawName.split('_').first : rawName;
        final equipmentId =
            (item['equipment_id'] as String?)?.trim() ?? rawName;

        grouped.putIfAbsent(prefix, () => {});
        grouped[prefix]![equipmentId] = {
          'id': equipmentId,
          'name': rawName,
          'work_id': item['work_id'] ?? 'Unknown Work ID',
          'productionArea': item['productionArea'],
        };
      }

      setState(() {
        equipmentList = grouped;
      });
      print(
          "Successfully fetched equipment list: ${grouped.keys.length} groups");
      getCombinedWorkOrder(equipmentList);
    } catch (e) {
      print('API error fetching equipment: $e');
    }
  }

  Future<void> getCombinedWorkOrder(Map<String, dynamic> equipmentList) async {
    setState(() {
      isLoading3 = true;
    });
    final String prefix = selectedProductionAreaName ?? '';
    final Map<String, dynamic> eqItems =
        (equipmentList[prefix] as Map<String, dynamic>?) ?? {};
    final List<String> childNames = eqItems.values
        .map((childDetails) => childDetails['name'] as String)
        .toList();
    final String namesJoined = childNames.join(', ');
    final workOrders = eqItems.values.expand((childDetails) {
      final dynamic rawWorkId = childDetails['work_id'];
      if (rawWorkId is List) {
        return rawWorkId.cast<String>();
      } else if (rawWorkId is String) {
        return [rawWorkId];
      }
      return <String>[];
    }).toSet();
    if (workOrders.isNotEmpty) {
      setState(() {
        selectedWorkID = workOrders.first;
        combinedEquipmentNames = namesJoined;
      });
      fetchWorkProgress();
    } else {
      setState(() {
        selectedWorkID = 'Work ID Required';
        quantity = 0;
        progress = 0;
        unit = '';
        show = false;
        isLoading3 = false;
      });
    }
  }

  Future<void> fetchWorkProgress() async {
    // Use workOrderID if available, otherwise fall back to selectedWorkID
    final workOrder = workOrderID ?? selectedWorkID;

    if (workOrder == 'Unset Work ID' ||
        workOrder == 'N/A' ||
        workOrder.isEmpty) {
      print('No valid work order selected');
      setState(() {
        progress = 0;
        quantity = 0;
        unit = '';
        show = false;
        _resetTimelineData();
        isLoading3 = false;
      });
      return;
    }

    setState(() => isLoading3 = true);

    try {
      // Get machine ID from selected equipment
      final machineId = selectedEquipmentDetails?['name'].toString().trim() ??
          selectedEquipmentDetails?['equipment_id'] ??
          selectedEquipmentId ??
          '';

      if (machineId.isEmpty) {
        throw Exception('No valid machine ID available');
      }

      print('ðŸ” Fetching work progress data:');
      print('   Machine ID: $machineId');
      print('   Work Order ID: $workOrder');

      // Fetch all required data concurrently
      final futures = await Future.wait([
        http.get(Uri.parse(ApiConfig.workOrder(workOrder))),
        http.get(Uri.parse(ApiConfig.plannedWOInput(machineId, workOrder))),
        http.get(
            Uri.parse(ApiConfig.overallWOPerformance(machineId, workOrder))),
      ]);

      final workOrderResponse = futures[0];
      final plannedWOResponse = futures[1];
      final performanceResponse = futures[2];

      int tempProgress = jobOrderGrossQuantity;
      int tempQuantity = quantity;
      String tempUnit = unit;
      String tempProductId = productId;
      String tempDate = date;
      int tempStatus = status;

      // Process original work order data
      if (workOrderResponse.statusCode == 200) {
        final data = jsonDecode(workOrderResponse.body);
        final workOrderData = data is List ? data[0] : data;

        tempStatus = workOrderData['status'] ?? 5;
        tempUnit = workOrderData['unit'] ?? '';
        tempProductId = workOrderData['product'] ?? '';
        tempDate = workOrderData['planEndDate']?.toString() ?? '';

        // Only use work order data if we don't have better data yet
        if (tempQuantity == 0) {
          tempQuantity = workOrderData['quantity'] ?? 0;
        }
        if (tempProgress == 0) {
          tempProgress = workOrderData['progress'] ?? 0;
        }

        print('ðŸ“¦ Work Order data:');
        print('   Initial Quantity: $tempQuantity');
        print('   Initial Progress: $tempProgress');
      }

      // Process performance data - HIGHEST PRIORITY for progress
      if (performanceResponse.statusCode == 200) {
        final performanceData = jsonDecode(performanceResponse.body);

        if (performanceData != null &&
            performanceData is Map<String, dynamic>) {
          final woThroughput =
              (performanceData['WO_Throughput'] as num?)?.toInt() ?? 0;

          // CRITICAL: Performance API has the most accurate progress
          if (woThroughput > 0) {
            tempProgress = woThroughput;
            print('✅ Updated progress from performance API: $tempProgress');
          }

          checkInTime = performanceData['CheckIn_Timestamp']?.toString() ?? '';
          print('✅ Check-in Time: $checkInTime');
        }
      } else if (performanceResponse.statusCode == 404) {
        print(
            '⚠ï¸ No performance data found for machine: $machineId, workOrder: $workOrder');
        checkInTime = '';
      }

      // Process planned WO input data
      if (plannedWOResponse.statusCode == 200) {
        final plannedData = jsonDecode(plannedWOResponse.body);

        plannedStartTime =
            plannedData['Planned_Production_Start_Date']?.toString() ?? '';
        targetCompletionTime =
            plannedData['Planned_Production_Completion_Date']?.toString() ?? '';
        // estimatedCompletionTime = plannedData['Estimated_Completion']?.toString() ?? '';
        remainingHours =
            (plannedData['Remaining_Hours'] as num?)?.toDouble() ?? 0.0;

        // Use planned quantity only if we still don't have quantity
        if (tempQuantity == 0) {
          tempQuantity =
              (plannedData['Planned_Quantity'] as num?)?.toInt() ?? 0;
        }

        print('✅ Successfully fetched planned WO data:');
        print('   Planned Start: $plannedStartTime');
        print('   Target Completion: $targetCompletionTime');
        print('   Remaining Hours: $remainingHours');
      } else if (plannedWOResponse.statusCode == 404) {
        print(
            '⚠ï¸ No planned WO data found for machine: $machineId, workOrder: $workOrder');
        _setDefaultPlannedData();
      }

      // NOW update state with all the collected values at once
      setState(() {
        progress = tempProgress;
        quantity = tempQuantity;
        unit = tempUnit;
        productId = tempProductId;
        date = tempDate;
        status = tempStatus;
        show = true;
      });

      print("✅ Final values after fetchWorkProgress:");
      print("   Progress: $progress");
      print("   Quantity: $quantity");
      print("   Unit: $unit");

      // Fetch additional data
      fetchProduct();
      fetchMachineStatus24h();
      fetchEstimatedCompletionTime();
    } catch (e) {
      print('âŒ Error fetching work progress from API: $e');
      setState(() {
        progress = 0;
        quantity = 0;
        unit = '';
        show = false;
        _resetTimelineData();
      });
    } finally {
      setState(() => isLoading3 = false);
    }
  }

  Future<void> fetchEstimatedCompletionTime() async {
    if (selectedEquipmentDetails == null || selectedProductionAreaId == null) {
      print('Missing required parameters for estimated completion time');
      return;
    }

    try {
      final String productionArea =
          selectedProductionAreaId?.toString().trim() ?? '';
      final String equipmentId =
          selectedEquipmentDetails!['equipment_id']?.toString().trim() ?? '';

      if (equipmentId.isEmpty || productionArea.isEmpty) {
        throw Exception('Missing required parameters');
      }

      final String apiUrl =
          '${ApiConfig.dataUrl}/equipmentDetails/pwo-estimated-time/$productionArea/$equipmentId';

      print('ðŸ” Fetching estimated completion time:');
      print('   URL: $apiUrl');

      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);

        if (data.isNotEmpty && data[0]['Estimated_Completion'] != null) {
          setState(() {
            estimatedCompletionTime =
                data[0]['Estimated_Completion']?.toString() ?? '';
            remainingHour = data[0]['Remaining_Production_Time'] ?? 0;
          });

          print(
              '✅ Estimated completion time fetched: $estimatedCompletionTime');
        } else {
          print('⚠ï¸ No estimated completion time in response');
        }
      } else if (response.statusCode == 404) {
        print('ℹï¸ No estimated completion time found');
        setState(() {
          estimatedCompletionTime = '';
          remainingHour = 0;
        });
      } else {
        throw Exception(
            'Failed to fetch estimated completion time: ${response.statusCode}');
      }
    } catch (e) {
      print('âŒ Error fetching estimated completion time: $e');
      setState(() {
        estimatedCompletionTime = '';
      });
    }
  }

// Helper method to set default planned data when API returns 404
  void _setDefaultPlannedData() {
    // Use existing date as fallback or current time
    final now = DateTime.now();
    final fallbackStart =
        now.subtract(Duration(hours: 2)); // Assume started 2 hours ago
    final fallbackEnd =
        now.add(Duration(hours: 6)); // Assume 8 hours total duration

    setState(() {
      plannedStartTime = fallbackStart.toIso8601String();
      targetCompletionTime =
          date.isNotEmpty ? date : fallbackEnd.toIso8601String();
      estimatedCompletionTime = '';
      remainingHours = 0.0;
    });
  }

// Reset timeline data to defaults
  void _resetTimelineData() {
    plannedStartTime = '';
    checkInTime = '';
    targetCompletionTime = '';
    estimatedCompletionTime = '';
    remainingHours = 0.0;
    estimatedDelay = 0.0;
    isLateStart = false;
    isOverdue = false;
  }

  Future<void> fetchProduct() async {
    if (productId.isEmpty) {
      setState(() {
        productName = '';
        isLoading3 = false;
      });
      return;
    }
    try {
      final response = await http.get(Uri.parse(ApiConfig.product(productId)));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        setState(() {
          productName = data['name'] ?? '';
        });
        print("Successfully fetched product: $productName");
      } else {
        throw Exception(
            'Failed to load product (status ${response.statusCode})');
      }
    } catch (e) {
      print('Error fetching product from API: $e');
      setState(() {
        productName = '';
      });
    } finally {
      setState(() {
        isLoading3 = false;
      });
    }
  }

  // Future<void> fetchRunTimeStatus() async {
  //   if (selectedProductionAreaName == null || selectedProductionAreaName!.isEmpty) {
  //     print('No production area name, skipping runtime status fetch');
  //     setState(() {
  //       running = 0;
  //       idle = 0;
  //       alarm = 0;
  //       stopped = 0;
  //       isLoading2 = false;
  //     });
  //     return;
  //   }

  //   setState(() => isLoading2 = true);
  //   try {
  //     final response = await http.get(Uri.parse(ApiConfig.dailyStatus(selectedProductionAreaName!)));

  //     if (response.statusCode == 200) {
  //       final data = jsonDecode(response.body);
  //       final runTimeStatus = data is List ? data[0] : data;

  //       setState(() {
  //         running = runTimeStatus['running'] ?? 0;
  //         idle = runTimeStatus['idle'] ?? 0;
  //         alarm = runTimeStatus['alarm'] ?? 0;
  //         stopped = runTimeStatus['stopped'] ?? 0;
  //       });
  //       print("Successfully fetched runtime status: running=$running, idle=$idle, alarm=$alarm, stopped=$stopped");
  //     } else {
  //       throw Exception('Failed to load runtime status (status ${response.statusCode})');
  //     }
  //   } catch (e) {
  //     print('Error fetching runtime status from API: $e');
  //     setState(() {
  //       running = 0;
  //       idle = 0;
  //       alarm = 0;
  //       stopped = 0;
  //     });
  //   } finally {
  //     setState(() => isLoading2 = false);
  //   }
  // }

  Future<Map<String, Map<String, dynamic>>> fetchBatchOEEData(
      List<String> machineIds) async {
    if (machineIds.isEmpty) {
      print('No machine IDs provided for batch OEE fetch');
      return {};
    }

    try {
      print('Fetching OEE data for ${machineIds.length} machines in batch');

      final response = await http
          .post(
            Uri.parse(ApiConfig.overallDailyMachineBatch),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'machineIds': machineIds}),
          )
          .timeout(const Duration(seconds: 30));

      print('Batch OEE API response status: ${response.statusCode}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> dataMap = jsonDecode(response.body);
        final Map<String, Map<String, dynamic>> result = {};

        for (var machineId in machineIds) {
          if (dataMap.containsKey(machineId)) {
            final data = dataMap[machineId];
            result[machineId] = {
              'Overall_Machine_OEE': ParseDoubleValue.parseDoubleValue(
                      data['Overall_Machine_OEE']) /
                  100.0,
              'Machine_Quality':
                  ParseDoubleValue.parseDoubleValue(data['Machine_Quality']) /
                      100.0,
              'Machine_Availability': ParseDoubleValue.parseDoubleValue(
                      data['Machine_Availability']) /
                  100.0,
              'Machine_Efficiency': ParseDoubleValue.parseDoubleValue(
                      data['Machine_Efficiency']) /
                  100.0,
            };

            // Clamp all values
            result[machineId]!.forEach((key, value) {
              if (value is double) {
                result[machineId]![key] = value.clamp(0.0, 1.0);
              }
            });

            print(
                'Fetched OEE for $machineId: ${(result[machineId]!['Overall_Machine_OEE']! * 100).toStringAsFixed(1)}%');
          } else {
            // No data found for this machine
            print('No OEE data found for $machineId');
            result[machineId] = {
              'Overall_Machine_OEE': 0.0,
              'Machine_Quality': 0.0,
              'Machine_Availability': 0.0,
              'Machine_Efficiency': 0.0,
            };
          }
        }

        print('Successfully fetched batch OEE for ${result.length} machines');
        return result;
      } else {
        print('Failed to fetch batch OEE: ${response.statusCode}');
        return {};
      }
    } catch (e) {
      print('Error in fetchBatchOEEData: $e');
      return {};
    }
  }

// Helper method to update current equipment OEE from batch data
  void updateOEEFromBatch(Map<String, Map<String, dynamic>> batchData) {
    if (selectedEquipmentDetails == null) return;

    final equipmentId = selectedEquipmentDetails!['name'].toString().trim() ??
        selectedEquipmentDetails!['equipment_id'];

    if (equipmentId != null && batchData.containsKey(equipmentId)) {
      final data = batchData[equipmentId]!;
      setState(() {
        availability = data['Machine_Availability'] ?? 0.0;
        performance = data['Machine_Efficiency'] ?? 0.0;
        quality = data['Machine_Quality'] ?? 0.0;
        oee = data['Overall_Machine_OEE'] ?? 0.0;
        oeeData = data;
        isLoadingOEE = false;
      });

      print('Updated OEE from batch data for $equipmentId');
    }
  }

  Future<void> fetchEquipmentOEE() async {
    if (equipmentFromFirestore.isEmpty) {
      print('No equipment to fetch OEE data for');
      setState(() => isLoadingOEE = false); // ADD THIS
      return;
    }

    // Get all equipment IDs/names, ensure they're strings, and trim whitespace
    final machineIds = equipmentFromFirestore
        .map((equip) => (equip['name']?.toString() ?? '').trim())
        .where((name) => name.isNotEmpty)
        .toList();

    if (machineIds.isEmpty) {
      print('No valid machine IDs for OEE fetch');
      setState(() => isLoadingOEE = false); // ADD THIS
      return;
    }

    print('Fetching OEE for machines: $machineIds');

    try {
      // Fetch batch OEE data
      final batchOEEData = await fetchBatchOEEData(machineIds);

      print('Batch OEE data received: $batchOEEData'); // DEBUG

      updateOEEFromBatch(batchOEEData);

      setState(() => isLoadingOEE = false); // ADD THIS
    } catch (e) {
      print('Error fetching OEE data: $e'); // ADD ERROR HANDLING
      setState(() => isLoadingOEE = false); // ADD THIS
    }
  }

  Future fetchMachineStatus24h() async {
    if (!_areParametersValidForMachineStatus()) {
      print('âŒ Skipping API call - Required parameters are incomplete');
      setState(() {
        machineStatusData = [];
        isLoadingMachineStatus = false;
        _setDefaultMachineStatusValues();
      });
      return;
    }

    setState(() => isLoadingMachineStatus = true);

    try {
      final String equipmentId =
          selectedEquipmentDetails!['equipment_id']?.toString().trim() ?? '';
      final String productionArea =
          selectedProductionAreaId?.toString().trim() ?? '';

      final String apiUrl =
          ApiConfig.machineStatus24h(productionArea, equipmentId);

      print('ðŸ” Fetching 24h machine status:');
      print('   URL: $apiUrl');
      print('   Production Area: $productionArea');
      print('   Equipment ID: $equipmentId');

      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      print('ðŸ“¡ Machine Status API Response:');
      print('   Status Code: ${response.statusCode}');

      if (response.statusCode == 200) {
        final Map responseData = jsonDecode(response.body);
        final List dataList = responseData['data'] ?? [];
        final Map? summary = responseData['summary'];

        print('✅ Successfully parsed machine status response:');
        print('   Data Count: ${dataList.length}');

        if (summary != null) {
          print('   Summary: ${summary}');

          setState(() {
            // Update machine status data from the response
            machineStatusData = dataList.cast<Map<String, dynamic>>();

            // Convert summary data from double to int (if required)
            actualRunningMinutes = (summary['runningMinutes'] ?? 0.0).toInt();
            actualIdleMinutes = (summary['idleMinutes'] ?? 0.0).toInt();
            actualStoppedMinutes = (summary['stoppedMinutes'] ?? 0.0).toInt();

            // Get ProcessID from data (if available)
            if (dataList.isNotEmpty) {
              processID = dataList[0]['processID']?.toString();
            }

            // Set loading status to false once data is fetched
            isLoadingMachineStatus = false;
          });

          print('ðŸ“Š Machine status summary:');
          print(
              '   ðŸŸ¢ Running: $actualRunningMinutes minutes (${summary['runningPercentage']}%)');
          print(
              '   ðŸŸ¡ Idle: $actualIdleMinutes minutes (${summary['idlePercentage']}%)');
          print(
              '   ⚫ Stopped: $actualStoppedMinutes minutes (${summary['stoppedPercentage']}%)');
          print('   ðŸ”§ Process ID: $processID');
        }
      } else if (response.statusCode == 400) {
        final errorData = jsonDecode(response.body);
        final errorMessage = errorData['error'] ?? 'Bad request';
        print('âŒ API Error 400: $errorMessage');
        setState(() {
          machineStatusData = [];
          isLoadingMachineStatus = false;
          _setDefaultMachineStatusValues();
        });
      } else if (response.statusCode == 404) {
        print(
            'iï¸ No machine status data found for: $productionArea / $equipmentId');
        setState(() {
          machineStatusData = [];
          isLoadingMachineStatus = false;
          _setDefaultMachineStatusValues();
        });
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e, stackTrace) {
      print('âŒ Error fetching machine status: $e');
      print('ðŸ“‹ Stack trace: $stackTrace');
      setState(() {
        machineStatusData = [];
        isLoadingMachineStatus = false;
        _setDefaultMachineStatusValues();
      });
    }
  }

  bool _areParametersValidForMachineStatus() {
    if (selectedEquipmentDetails == null) {
      print('âŒ Missing equipment details for machine status fetch');
      return false;
    }

    final String equipmentId =
        selectedEquipmentDetails!['equipment_id']?.toString().trim() ?? '';
    if (equipmentId.isEmpty) {
      print('âŒ Equipment ID is empty or null');
      return false;
    }

    if (selectedProductionAreaId == null || selectedProductionAreaId!.isEmpty) {
      print('âŒ Production Area ID is empty or null');
      return false;
    }

    print('✅ All required parameters are valid for machine status');
    print('   Production Area: $selectedProductionAreaId');
    print('   Equipment ID: $equipmentId');

    return true;
  }

  void _setDefaultMachineStatusValues() {
    actualRunningMinutes = 0;
    actualIdleMinutes = 0;
    actualStoppedMinutes = 0;
    processID = null;

    print('ðŸ“Š Set default machine status values (all zeros)');
  }

  Future<void> fetchMachineEfficiency() async {
    if (selectedEquipmentDetails == null) {
      print('No equipment selected, skipping daily efficiency fetch');
      setState(() {
        isLoadingDailyEfficiency = false;
        dailyMachineEfficiencyData = [];
        dailyActualProduction = 0;
        dailyPlannedProduction = 0;
      });
      return;
    }

    setState(() => isLoadingDailyEfficiency = true);

    try {
      final String productionArea =
          selectedProductionAreaId?.toString().trim() ?? '';
      final String equipmentId =
          selectedEquipmentDetails!['equipment_id']?.toString().trim() ?? '';

      if (equipmentId.isEmpty || productionArea.isEmpty) {
        throw Exception('Missing required parameters');
      }

      final String apiUrl =
          ApiConfig.machineEfficiency(productionArea, equipmentId);

      print('ðŸ” Fetching DAILY machine efficiency:');
      print('   URL: $apiUrl');

      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {'Content-Type': 'application/json'},
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        List<Map<String, dynamic>> dataList = [];

        if (responseData is List) {
          dataList = responseData.cast<Map<String, dynamic>>();
        } else if (responseData is Map<String, dynamic>) {
          dataList = [responseData];
        }

        if (dataList.isNotEmpty) {
          // Process and integrate the response data
          processIDWoP = dataList[0]['ProcessID']?.toString();
          workOrderID = dataList[0]['WorkOrderID']?.toString();
        }

        setState(() {
          dailyMachineEfficiencyData = dataList;
          dailyActualProduction = 0;
          dailyPlannedProduction = 0;

          for (var record in dailyMachineEfficiencyData) {
            dailyActualProduction +=
                (record['ActualProductionQuantity'] as num?)?.toInt() ?? 0;
            dailyPlannedProduction +=
                (record['PlannedProductionQuantity'] as num?)?.toInt() ?? 0;
          }
        });

        print('✅ DAILY efficiency fetched:');
        print('   Actual: $dailyActualProduction');
        print('   Planned: $dailyPlannedProduction');
      } else {
        setState(() {
          dailyMachineEfficiencyData = [];
          dailyActualProduction = 0;
          dailyPlannedProduction = 0;
        });
      }
    } catch (e) {
      print('âŒ Error fetching daily efficiency: $e');
      setState(() {
        dailyMachineEfficiencyData = [];
        dailyActualProduction = 0;
        dailyPlannedProduction = 0;
      });
    } finally {
      setState(() => isLoadingDailyEfficiency = false);
    }
  }

  List<Map<String, dynamic>> periodPlannedInputData = [];
  bool isLoadingPlannedInput = true;
  int periodTotalPlannedQty = 0;

// Update the fetchMachineEfficiencyByDate method (around line 950)
  Future<void> fetchMachineEfficiencyByDate({String? period}) async {
    if (selectedEquipmentDetails == null) {
      print('No equipment selected, skipping period efficiency fetch');
      setState(() {
        isLoadingPeriodEfficiency = false;
        periodMachineEfficiencyData = [];
        periodActualProduction = 0;
        periodPlannedProduction = 0;

        // Reset planned input data
        isLoadingPlannedInput = false;
        periodPlannedInputData = [];
        periodTotalPlannedQty = 0;
      });
      return;
    }

    final String effectivePeriod = period ?? currentEfficiencyPeriod;

    setState(() {
      if (period != null) {
        isLoadingEfficiencyPeriodChange = true;
      } else {
        isLoadingPeriodEfficiency = true;
        isLoadingPlannedInput = true; // Add this
      }
    });

    try {
      final String productionArea =
          selectedProductionAreaId?.toString().trim() ?? '';
      final String equipmentId =
          selectedEquipmentDetails!['equipment_id']?.toString().trim() ?? '';

      if (equipmentId.isEmpty || productionArea.isEmpty) {
        throw Exception('Missing required parameters');
      }

      // Map period values to backend accepted values
      final periodMap = {'30days': 'daily', 'daily': 'daily', 'weekly': 'weekly', 'monthly': 'monthly'};
      final backendPeriod = periodMap[effectivePeriod.toLowerCase()] ?? 'daily';

      // Fetch both APIs concurrently
      final futures = await Future.wait([
        http.get(
          Uri.parse(
              ApiConfig.machineEfficiencyByDate(productionArea, equipmentId, backendPeriod)),
          headers: {'Content-Type': 'application/json'},
        ).timeout(const Duration(seconds: 15)),
        http.get(
          Uri.parse(
              ApiConfig.machinePlannedInput(equipmentId, effectivePeriod)),
          headers: {'Content-Type': 'application/json'},
        ).timeout(const Duration(seconds: 15)),
      ]);

      final efficiencyResponse = futures[0];
      final plannedInputResponse = futures[1];

      // Process efficiency response (actual production)
      if (efficiencyResponse.statusCode == 200) {
        final Map<String, dynamic> responseData =
            jsonDecode(efficiencyResponse.body);
        final List<dynamic> data = responseData['data'] ?? [];
        final String responsePeriod = responseData['period'] ?? effectivePeriod;

        setState(() {
          periodMachineEfficiencyData = data.cast<Map<String, dynamic>>();
          currentEfficiencyPeriod = responsePeriod;
          periodActualProduction = 0;

          for (var record in periodMachineEfficiencyData) {
            periodActualProduction +=
                (record['Machine_Actual_Quantity'] as num?)?.toInt() ?? 0;
          }
        });

        print('✅ PERIOD efficiency (actual) fetched ($responsePeriod):');
        print('   Actual: $periodActualProduction');
      } else {
        setState(() {
          periodMachineEfficiencyData = [];
          periodActualProduction = 0;
        });
      }

      // Process planned input response (planned production)
      if (plannedInputResponse.statusCode == 200) {
        final Map<String, dynamic> responseData =
            jsonDecode(plannedInputResponse.body);
        final List<dynamic> data = responseData['data'] ?? [];

        setState(() {
          periodPlannedInputData = data.cast<Map<String, dynamic>>();
          periodTotalPlannedQty = 0;

          for (var record in periodPlannedInputData) {
            periodTotalPlannedQty +=
                (record['Planned_Production_Qty'] as num?)?.toInt() ?? 0;
          }
        });

        print('✅ PERIOD planned input fetched:');
        print('   Total Planned: $periodTotalPlannedQty');
        print('   Data points: ${periodPlannedInputData.length}');
      } else {
        print('⚠ï¸ No planned input data available');
        setState(() {
          periodPlannedInputData = [];
          periodTotalPlannedQty = 0;
        });
      }
    } catch (e) {
      print('âŒ Error fetching period data: $e');
      setState(() {
        periodMachineEfficiencyData = [];
        periodActualProduction = 0;
        periodPlannedInputData = [];
        periodTotalPlannedQty = 0;
      });
    } finally {
      setState(() {
        isLoadingPeriodEfficiency = false;
        isLoadingPlannedInput = false;
        isLoadingEfficiencyPeriodChange = false;
      });
    }
  }

  Future<void> onEfficiencyPeriodChanged(String newPeriod) async {
    if (newPeriod == currentEfficiencyPeriod ||
        isLoadingEfficiencyPeriodChange) {
      return;
    }

    print('Period changed from $currentEfficiencyPeriod to $newPeriod');
    await fetchMachineEfficiencyByDate(period: newPeriod);
  }

  Future<void> fetchDowntimeData() async {
    if (selectedEquipmentDetails == null) {
      print('No equipment selected, skipping downtime fetch');
      setState(() {
        isLoadingDowntime = false;
        downtimeCategories = [];
        downtimeTimeValues = [];
        downtimeAccumulatedValues = [];
        totalDowntime = 0;
        downtimeMaxY = 1200;
      });
      return;
    }

    if (selectedWorkID == 'N/A' ||
        selectedWorkID == 'Unknown Work ID' ||
        selectedWorkID.isEmpty) {
      print('No valid work order ID for downtime fetch: $selectedWorkID');
      setState(() {
        isLoadingDowntime = false;
        downtimeCategories = [];
        downtimeTimeValues = [];
        downtimeAccumulatedValues = [];
        totalDowntime = 0;
        downtimeMaxY = 1200;
      });
      return;
    }

    setState(() => isLoadingDowntime = true);

    try {
      final String machineId =
          selectedEquipmentDetails!['name']?.toString().trim() ?? '';

      if (machineId.isEmpty) {
        throw Exception('Machine ID is empty or null');
      }

      final String apiUrl =
          ApiConfig.downtimeStatusDuration(machineId, selectedWorkID);

      print('ðŸ” Fetching downtime data:');
      print('   URL: $apiUrl');
      print('   Machine ID: $machineId');
      print('   Work Order ID: $selectedWorkID');

      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/json',
        },
      ).timeout(const Duration(seconds: 15));

      print('ðŸ“¡ Downtime API Response:');
      print('   Status Code: ${response.statusCode}');
      print(
          '   Body Preview: ${response.body.length > 200 ? response.body.substring(0, 200) + "..." : response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> data = jsonDecode(response.body);

        setState(() {
          // Map 'categories' field (alarm status descriptions)
          downtimeCategories = List<String>.from(data['categories'] ?? []);

          // Map 'durations' field to timeValues (time in minutes)
          downtimeTimeValues = (data['durations'] ?? []).map<double>((v) {
            if (v is int) return v.toDouble();
            if (v is double) return v;
            if (v is String) return double.tryParse(v) ?? 0.0;
            return 0.0;
          }).toList();

          // Map 'percentages' field to accumulatedValues (cumulative percentages)
          downtimeAccumulatedValues =
              (data['percentages'] ?? []).map<double>((v) {
            if (v is int) return v.toDouble();
            if (v is double) return v;
            if (v is String) return double.tryParse(v) ?? 0.0;
            return 0.0;
          }).toList();

          // Map 'totalDuration' field to totalDowntime
          final rawTotalDowntime = data['totalDuration'];
          if (rawTotalDowntime is int) {
            totalDowntime = rawTotalDowntime;
          } else if (rawTotalDowntime is double) {
            totalDowntime = rawTotalDowntime.round();
          } else if (rawTotalDowntime is String) {
            totalDowntime = int.tryParse(rawTotalDowntime) ?? 0;
          } else {
            totalDowntime = 0;
          }

          // Map 'chartConfig.maxY' field to downtimeMaxY
          final rawMaxY = data['chartConfig']?['maxY'];
          if (rawMaxY is int) {
            downtimeMaxY = rawMaxY.toDouble();
          } else if (rawMaxY is double) {
            downtimeMaxY = rawMaxY;
          } else if (rawMaxY is String) {
            downtimeMaxY = double.tryParse(rawMaxY) ?? 1200.0;
          } else {
            downtimeMaxY = 1200.0;
          }

          isLoadingDowntime = false;
        });

        print('✅ Successfully fetched downtime data:');
        print('   Categories: ${downtimeCategories.length}');
        print('   Total Downtime: $totalDowntime minutes');
        print('   Max Y: $downtimeMaxY');
        print('   Categories: $downtimeCategories');
        print('   Durations: $downtimeTimeValues');
        print('   Percentages: $downtimeAccumulatedValues');
      } else if (response.statusCode == 400) {
        final errorData = jsonDecode(response.body);
        print('âŒ API Error 400: ${errorData['error']}');

        setState(() {
          downtimeCategories = [];
          downtimeTimeValues = [];
          downtimeAccumulatedValues = [];
          totalDowntime = 0;
          downtimeMaxY = 1200;
          isLoadingDowntime = false;
        });
      } else if (response.statusCode == 404) {
        print('ℹï¸ No downtime data found');
        setState(() {
          downtimeCategories = [];
          downtimeTimeValues = [];
          downtimeAccumulatedValues = [];
          totalDowntime = 0;
          downtimeMaxY = 1200;
          isLoadingDowntime = false;
        });
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      print('âŒ Error fetching downtime data: $e');
      setState(() {
        downtimeCategories = [];
        downtimeTimeValues = [];
        downtimeAccumulatedValues = [];
        totalDowntime = 0;
        downtimeMaxY = 1200;
        isLoadingDowntime = false;
      });
    }
  }

  Future<void> fetchEquipmentProcessIds() async {
    if (selectedEquipmentDetails == null) {
      print('No equipment selected, skipping process IDs fetch');
      return;
    }

    try {
      final requestBody = [
        {
          'equipmentId': selectedEquipmentDetails!['equipment_id'] ??
              selectedEquipmentDetails!['name'],
          'productionArea': selectedEquipmentDetails!['productionArea'],
        }
      ];

      const url =
          '${ApiConfig.dataUrl}/equipmentDetails/equipment-process-id/batch';
      print('Fetching ProcessID from: $url');
      print('Request body: ${jsonEncode(requestBody)}');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'equipmentList': requestBody}),
          )
          .timeout(const Duration(seconds: 15));

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>;

        if (results.isNotEmpty) {
          final result = results[0];

          setState(() {
            // Safe conversion for processID
            final rawProcessID = result['processID'];
            processID = rawProcessID?.toString() ?? 'N/A';
            equipProcessID = rawProcessID?.toString() ?? 'N/A';

            // Safe conversion for quantities
            jobOrderGrossQuantity =
                (result['JobOrder_GrossQuantity'] as num?)?.toInt() ?? 0;
            jobOrderExpectedQuantity =
                (result['JobOrder_ExpectedQuantity'] as num?)?.toInt() ?? 0;

            // Safe conversion for runStatus
            final rawRunStatus = result['RunStatus'];
            runStatus = rawRunStatus?.toString() ?? 'N/A';

            final rawRunJobOrderID = result['JobOrderID'];
            jobOrderID = rawRunJobOrderID?.toString() ?? 'N/A';

            // CRITICAL FIX: Update selectedWorkID and workOrderID for fetchWorkProgress
            if (jobOrderID != 'N/A' && jobOrderID.isNotEmpty) {
              selectedWorkID = jobOrderID;
            }

            // Store in the full data map
            final equipmentKey = selectedEquipmentDetails!['equipment_id'] ??
                selectedEquipmentDetails!['name'];
            equipmentFullProcessData[equipmentKey] = {
              'processID': processID,
              'JobOrder_GrossQuantity': jobOrderGrossQuantity,
              'JobOrder_ExpectedQuantity': jobOrderExpectedQuantity,
              'RunStatus': runStatus,
              'JobOrderID': jobOrderID,
            };
          });

          print('✅ Successfully fetched process data:');
          print('   ProcessID: $processID');
          print('   JobOrderID: $jobOrderID');
          print('   selectedWorkID: $selectedWorkID');
          print('   Gross Quantity: $jobOrderGrossQuantity');
          print('   Expected Quantity: $jobOrderExpectedQuantity');
          print('   Run Status: $runStatus');
        }
      } else {
        print('Failed to fetch ProcessID: ${response.statusCode}');
      }
    } catch (e, stackTrace) {
      print('Error fetching ProcessID: $e');
      print('Stack trace: $stackTrace');
    }
  }

  Future<void> fetchMachinePerformance() async {
    try {
      if (selectedEquipmentDetails == null) {
        print('No equipment selected, skipping machine performance fetch');
        return;
      }

      // Use ApiConfig.baseUrl instead of just 'baseUrl'
      const url =
          '${ApiConfig.dataUrl}/equipmentDetails/machine-performance-data/daily';

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'machineIds': [
                selectedEquipmentDetails!['name'].toString().trim()
              ]
            }),
          )
          .timeout(const Duration(seconds: 30));

      print('Combined Performance Response status: ${response.statusCode}');
      print('Combined Performance Response body: ${response.body}');

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        final Map<String, dynamic> dataMap = responseData['data'];

        // Store the combined performance data
        final Map<String, Map<String, dynamic>> newPerformanceData = {};

        final machineId = selectedEquipmentDetails!['name'].toString().trim();

        if (dataMap.containsKey(machineId)) {
          final machineData = dataMap[machineId] as List<dynamic>;

          // Get the latest (first) record
          if (machineData.isNotEmpty) {
            final latestData = machineData[0];
            newPerformanceData[machineId] = {
              'Machine_Actual_Quantity':
                  latestData['Machine_Actual_Quantity'] ?? 0,
              'Planned_Production_Qty':
                  latestData['Planned_Production_Qty'] ?? 0,
              'date_only': latestData['date_only'] ?? '',
              'formatted_date': latestData['formatted_date'] ?? '',
            };
            print(
                'Fetched performance for $machineId: Actual=${latestData['Machine_Actual_Quantity']}, Planned=${latestData['Planned_Production_Qty']}');
          } else {
            print('No performance data found for $machineId');
            newPerformanceData[machineId] = {
              'Machine_Actual_Quantity': 0,
              'Planned_Production_Qty': 0,
              'date_only': '',
              'formatted_date': '',
            };
          }
        } else {
          print('Machine $machineId not found in response');
          newPerformanceData[machineId] = {
            'Machine_Actual_Quantity': 0,
            'Planned_Production_Qty': 0,
            'date_only': '',
            'formatted_date': '',
          };
        }

        setState(() {
          equipmentPerformanceData = newPerformanceData;
        });

        print(
            'Successfully fetched combined performance data for ${equipmentPerformanceData.length} equipment');
      } else {
        print(
            'Failed to fetch combined performance data: ${response.statusCode}');
      }
    } catch (e) {
      print('Error in fetchMachinePerformance: $e');
    }
  }

  Future<void> fetchWOCycleTimes() async {
    if (selectedEquipmentDetails == null ||
        jobOrderID == 'N/A' ||
        processID == 'N/A') {
      print('Missing required data for cycle time fetch');
      setState(() {
        woPlannedCycleTime = '';
        woActualCycleTime = '';
        isLoadingCycleTime = false;
      });
      return;
    }

    setState(() => isLoadingCycleTime = true);

    try {
      final machineId =
          selectedEquipmentDetails!['name']?.toString().trim() ?? '';

      if (machineId.isEmpty) {
        throw Exception('Machine ID is empty');
      }

      final url =
          '${ApiConfig.dataUrl}/equipmentDetails/overall-wo-op-efficiency/$machineId/$jobOrderID/$processID';
      print('ðŸ” Fetching cycle times from: $url');
      print('   Machine ID: $machineId');
      print('   Work Order ID: $jobOrderID');
      print('   Process ID: $processID');

      final response = await http.get(Uri.parse(url), headers: {
        'Content-Type': 'application/json'
      }).timeout(const Duration(seconds: 10));

      print('ðŸ“¡ Cycle Time Response status: ${response.statusCode}');
      print('ðŸ“¡ Cycle Time Response body: ${response.body}');

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);

        setState(() {
          woPlannedCycleTime = data['WO_Planned_Cycle_Time']?.toString() ?? '';
          woActualCycleTime = data['WO_Actual_Cycle_Time']?.toString() ?? '';
          isLoadingCycleTime = false;
        });

        print('✅ Successfully fetched cycle times:');
        print('   Planned: $woPlannedCycleTime');
        print('   Actual: $woActualCycleTime');
      } else if (response.statusCode == 404) {
        print('ℹï¸ No cycle time data found');
        setState(() {
          woPlannedCycleTime = '';
          woActualCycleTime = '';
          isLoadingCycleTime = false;
        });
      } else {
        throw Exception('HTTP ${response.statusCode}: ${response.body}');
      }
    } catch (e) {
      print('âŒ Error fetching cycle times: $e');
      setState(() {
        woPlannedCycleTime = '';
        woActualCycleTime = '';
        isLoadingCycleTime = false;
      });
    }
  }

  // ── Cyberpunk dropdown — matches Equipment Overview style ─────────────────
  Widget _buildCyberpunkDropdown({
    required String? value,
    required List<String> options,
    required String hint,
    required double width,
    required void Function(String?) onChanged,
  }) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final theme = FlutterFlowTheme.of(context);
    const cyan = Color(0xFF00D4FF);
    final String? safeValue =
        (value != null && options.contains(value)) ? value : null;
    return Container(
      width: width,
      height: 42,
      decoration: BoxDecoration(
        color: isLight ? theme.secondaryBackground : const Color(0xFF071A2E).withOpacity(0.95),
        border: Border.all(color: isLight ? theme.alternate : cyan.withOpacity(0.5), width: 1.2),
        boxShadow: [BoxShadow(color: cyan.withOpacity(0.12), blurRadius: 10)],
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            decoration: BoxDecoration(
              color: isLight ? theme.primary : cyan,
              boxShadow: [
                BoxShadow(color: (isLight ? theme.primary : cyan).withOpacity(0.85), blurRadius: 8)
              ],
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: safeValue,
                  isExpanded: true,
                  dropdownColor: isLight ? theme.secondaryBackground : const Color(0xFF071A2E),
                  menuMaxHeight: 300,
                  hint: Text(hint,
                      style: GoogleFonts.poppins(
                          color: isLight ? theme.secondaryText : cyan.withOpacity(0.82),
                          fontSize: 13,
                          fontWeight: FontWeight.w600)),
                  style: GoogleFonts.poppins(
                      color: isLight ? theme.primaryText : Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                  icon: Icon(Icons.keyboard_arrow_down_rounded,
                      color: isLight ? theme.primary : cyan, size: 22),
                  items: options
                      .map((opt) => DropdownMenuItem<String>(
                            value: opt,
                            child: Text(opt,
                                style: GoogleFonts.poppins(
                                    color: isLight ? theme.primaryText : Colors.white,
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

  @override
  Widget build(BuildContext context) {
    if (!_heightMeasurementScheduled) {
      _heightMeasurementScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _heightMeasurementScheduled = false;
        if (!mounted) return;
        final box =
            _equipmentCardKey.currentContext?.findRenderObject() as RenderBox?;
        if (box != null &&
            box.hasSize &&
            box.size.height != _equipmentCardHeight) {
          Future.delayed(Duration.zero, () {
            if (!mounted) return;
            setState(() => _equipmentCardHeight = box.size.height);
          });
        }
      });
    }

    if (selectedProductionAreaName == null ||
        selectedProductionAreaName!.isEmpty) {
      return Scaffold(
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SafeArea(
          top: true,
          child: isLoading
              ? const Center(child: CircularProgressIndicator())
              : Row(
                  mainAxisSize: MainAxisSize.max,
                  children: [
                    Expanded(
                      child: Align(
                        alignment: const AlignmentDirectional(0, -1),
                        child: Container(
                          width: double.infinity,
                          height: double.infinity,
                          decoration: BoxDecoration(
                            color:
                                FlutterFlowTheme.of(context).primaryBackground,
                            image: DecorationImage(
                              fit: BoxFit.cover,
                              image: Image.asset(
                                      'assets/images/backgroundanimated.gif')
                                  .image,
                            ),
                          ),
                          child: Padding(
                            padding: const EdgeInsetsDirectional.fromSTEB(
                                16, 24, 16, 24),
                            child: isLoading
                                ? const Center(
                                    child: CircularProgressIndicator())
                                : SingleChildScrollView(
                                    physics:
                                        const AlwaysScrollableScrollPhysics(),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        // Breadcrumb Text
                                        Padding(
                                          padding: const EdgeInsetsDirectional
                                              .fromSTEB(0, 0, 0, 4),
                                          child: Text(
                                            // 'Dashboard/EquipmentDetails',
                                            widget.isWorkOrderDetails == true
                                                ? 'Dashboard/WorkOrderDetails'
                                                : 'Dashboard/EquipmentDetails',
                                            style: FlutterFlowTheme.of(context)
                                                .titleLarge
                                                .override(
                                                  fontFamily: 'Poppins',
                                                  color: FlutterFlowTheme.of(
                                                          context)
                                                      .txtPrimary,
                                                  fontSize: 12,
                                                  font: GoogleFonts.poppins(),
                                                ),
                                          ),
                                        ),
                                        // Page Title
                                        Padding(
                                          padding: const EdgeInsetsDirectional
                                              .fromSTEB(0, 0, 0, 4),
                                          child: Text(
                                            widget.isWorkOrderDetails == true
                                                ? 'Work Order Details'
                                                : 'Equipment Details',
                                            style: FlutterFlowTheme.of(context)
                                                .headlineMedium
                                                .override(
                                                  fontFamily: 'Poppins',
                                                  font: GoogleFonts.poppins(),
                                                ),
                                          ),
                                        ),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Row(
                                              children: [
                                                // Production Area Dropdown
                                                Padding(
                                                  padding: const EdgeInsets
                                                      .symmetric(vertical: 8),
                                                  child:
                                                      _buildCyberpunkDropdown(
                                                    value:
                                                        selectedProductionAreaName,
                                                    options: productionAreaList
                                                        .map((a) =>
                                                            a['name'] as String)
                                                        .toList(),
                                                    hint:
                                                        'Select Production Area...',
                                                    width: 284,
                                                    onChanged: (val) {
                                                      if (val == null) return;
                                                      setState(() {
                                                        selectedProductionAreaId =
                                                            productionAreaList
                                                                .firstWhere((a) =>
                                                                    a['name'] ==
                                                                    val)['id'];
                                                        selectedProductionAreaName =
                                                            val;
                                                        selectedEquipmentId =
                                                            null;
                                                        selectedEquipmentDetails =
                                                            null;
                                                        equipmentFromFirestore =
                                                            [];
                                                        equipmentStatusData =
                                                            {};
                                                        prodAreaName = "";
                                                        selectEquipId = "";
                                                        isLoading2 = true;
                                                        isLoading1 = true;
                                                        isLoading3 = true;
                                                        isLoading4 = true;
                                                        isLoadingStatus = true;
                                                      });
                                                      fetchEquipmentFromFirestore();
                                                    },
                                                  ),
                                                ),
                                                // Equipment Dropdown
                                                Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                          left: 10,
                                                          top: 8,
                                                          bottom: 8),
                                                  child:
                                                      _buildCyberpunkDropdown(
                                                    value:
                                                        selectedEquipmentDetails?[
                                                            'name'] as String?,
                                                    options:
                                                        equipmentFromFirestore
                                                            .map((e) =>
                                                                e['name']
                                                                    as String)
                                                            .toList(),
                                                    hint: equipmentFromFirestore
                                                            .isEmpty
                                                        ? 'No Equipment Available'
                                                        : 'Select Equipment...',
                                                    width: 284,
                                                    onChanged: (val) async {
                                                      if (val == null) return;
                                                      setState(() {
                                                        final selectedEquip =
                                                            equipmentFromFirestore
                                                                .firstWhere((e) =>
                                                                    e['name'] ==
                                                                    val);
                                                        selectedEquipmentId =
                                                            selectedEquip['id']
                                                                as String?;
                                                        selectedEquipmentDetails =
                                                            selectedEquip;
                                                        selectedWorkID =
                                                            selectedEquip[
                                                                    'work_id'] ??
                                                                'N/A';
                                                        equipmentStatusData =
                                                            {};
                                                        oeeData = {};
                                                        isLoadingStatus = true;
                                                        isLoadingOEE = true;
                                                        actualIdleMinutes = 0;
                                                        actualRunningMinutes =
                                                            0;
                                                        actualAlarmMinutes = 0;
                                                        actualStoppedMinutes =
                                                            0;
                                                        utilizationData = [];
                                                        downtimeCategories = [];
                                                        downtimeTimeValues = [];
                                                        downtimeAccumulatedValues =
                                                            [];
                                                        totalDowntime = 0;
                                                        currentEfficiencyPeriod =
                                                            'daily';
                                                        jobOrderGrossQuantity =
                                                            0;
                                                        jobOrderExpectedQuantity =
                                                            0;
                                                        runStatus = 'N/A';
                                                        workOrderID = null;
                                                        processIDWoP = null;
                                                        quantity = 0;
                                                        unit = '';
                                                        productId = '';
                                                        productName = '';
                                                        date = '';
                                                        show = false;
                                                        plannedStartTime = '';
                                                        checkInTime = '';
                                                        targetCompletionTime =
                                                            '';
                                                        estimatedCompletionTime =
                                                            '';
                                                        remainingHours = 0.0;
                                                        estimatedDelay = 0.0;
                                                        isLateStart = false;
                                                        isOverdue = false;
                                                      });
                                                      await fetchEquipmentProcessIds();
                                                      await Future.wait([
                                                        fetchEquipmentStatus(),
                                                        fetchAlarm(),
                                                        fetchEquipmentOEE(),
                                                        fetchMachineEfficiency(),
                                                        fetchMachineStatus24h(),
                                                        fetchDowntimeData(),
                                                        fetchEstimatedCompletionTime(),
                                                        fetchMachineEfficiencyByDate(
                                                            period:
                                                                currentEfficiencyPeriod),
                                                        fetchMachinePerformance(),
                                                        fetchWOCycleTimes()
                                                      ]);
                                                      if (selectedWorkID !=
                                                              'N/A' &&
                                                          selectedWorkID !=
                                                              'Unknown Work ID' &&
                                                          selectedWorkID
                                                              .isNotEmpty) {
                                                        await fetchWorkProgress();
                                                      }
                                                    },
                                                  ),
                                                ),
                                              ],
                                            ),
                                            Padding(
                                              padding: const EdgeInsets.only(
                                                  right: 10.0),
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.end,
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  // Last Update — redesigned RichText
                                                  RichText(
                                                    text: TextSpan(
                                                      children: [
                                                        TextSpan(
                                                          text: 'Last Update: ',
                                                          style: GoogleFonts
                                                              .poppins(
                                                            color: const Color(
                                                                    0xFF00D4FF)
                                                                .withOpacity(
                                                                    0.58),
                                                            fontWeight:
                                                                FontWeight.w600,
                                                            fontSize: 11,
                                                            letterSpacing: 0.4,
                                                          ),
                                                        ),
                                                        TextSpan(
                                                          text: lastUpdateTime,
                                                          style: GoogleFonts
                                                              .poppins(
                                                            color: FlutterFlowTheme.of(context).txtPrimary,
                                                            fontWeight:
                                                                FontWeight.w700,
                                                            fontSize: 11,
                                                          ),
                                                        ),
                                                      ],
                                                    ),
                                                  ),
                                                  const SizedBox(height: 5),
                                                  // Refresh — TNB-style icon box
                                                  GestureDetector(
                                                    onTap: () {
                                                      setState(() {
                                                        lastUpdateTime =
                                                            DateTime.now()
                                                                .toLocal()
                                                                .toString()
                                                                .substring(
                                                                    0, 19);
                                                        isLoading2 = true;
                                                        isLoading3 = true;
                                                        isLoading4 = true;
                                                      });
                                                      fetchEquipmentFromFirestore();
                                                      fetchEquipmentOEE();
                                                      fetchMachineEfficiency();
                                                      fetchMachineStatus24h();
                                                      fetchDowntimeData();
                                                      fetchMachineEfficiencyByDate(
                                                          period:
                                                              currentEfficiencyPeriod);
                                                    },
                                                    child: Container(
                                                      padding:
                                                          const EdgeInsets.all(
                                                              6),
                                                      decoration: BoxDecoration(
                                                        color: const Color(
                                                                0xFF00D4FF)
                                                            .withOpacity(0.08),
                                                        border: Border.all(
                                                          color: const Color(
                                                              0xFF00D4FF),
                                                          width: 1,
                                                        ),
                                                      ),
                                                      child: Icon(
                                                        Icons.refresh_rounded,
                                                        color: const Color(
                                                                0xFF00D4FF)
                                                            .withOpacity(0.80),
                                                        size: 18,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        Row(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: [
                                            Expanded(
                                              child: KeyedSubtree(
                                                key: _equipmentCardKey,
                                                child:
                                                    EquipmentcardmaindetailsWidget(
                                                  equipmentData:
                                                      selectedEquipmentDetails !=
                                                              null
                                                          ? {
                                                              selectedProductionAreaName!:
                                                                  {
                                                                selectedEquipmentId ??
                                                                        '':
                                                                    selectedEquipmentDetails!
                                                              }
                                                            }
                                                          : {},
                                                  productionAreaName:
                                                      selectedProductionAreaName!,
                                                  isLoading: isLoading1,
                                                  progress: progress,
                                                  quantity: quantity,
                                                  unit: unit,
                                                  selectedWorkID: jobOrderID,
                                                  selectedEquipmentId:
                                                      selectedEquipmentId ?? '',
                                                  equipmentName:
                                                      selectedEquipmentDetails !=
                                                              null
                                                          ? selectedEquipmentDetails![
                                                                      'name']
                                                                  .toString()
                                                                  .trim() ??
                                                              ''
                                                          : '',
                                                  equipmentStatus:
                                                      selectedEquipmentDetails !=
                                                              null
                                                          ? selectedEquipmentDetails![
                                                                  'equipment_status'] ??
                                                              ''
                                                          : '-1',
                                                  availability: availability,
                                                  performance: performance,
                                                  quality: quality,
                                                  oee: oee,
                                                  isLoadingOEE: isLoadingOEE,
                                                  runStatus: runStatus,
                                                  jobOrderGrossQuantity:
                                                      jobOrderGrossQuantity,
                                                  jobOrderExpectedQuantity:
                                                      jobOrderExpectedQuantity,
                                                  processID:
                                                      equipProcessID ?? "N/A",
                                                  equipmentFromFirestore:
                                                      equipmentFromFirestore,
                                                  jobOrderID: jobOrderID,
                                                  equipmentPerformanceData:
                                                      equipmentPerformanceData,
                                                ),
                                              ),
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: ConstrainedBox(
                                                constraints: BoxConstraints(
                                                  minHeight:
                                                      _equipmentCardHeight,
                                                  maxHeight:
                                                      _equipmentCardHeight > 0
                                                          ? _equipmentCardHeight
                                                          : double.infinity,
                                                ),
                                                child: RuntimeoeecardWidget(
                                                  running: actualRunningMinutes,
                                                  idle: actualIdleMinutes,
                                                  stopped: actualStoppedMinutes,
                                                  isLoading: isLoading2 ||
                                                      isLoadingMachineStatus,
                                                  utilizationData:
                                                      machineStatusData, // Pass machine status data
                                                  machineId:
                                                      selectedEquipmentDetails?[
                                                              'name'] ??
                                                          selectedEquipmentDetails?[
                                                              'name'],
                                                  workOrderId: selectedWorkID !=
                                                              'N/A' &&
                                                          selectedWorkID !=
                                                              'Unknown Work ID'
                                                      ? selectedWorkID
                                                      : null,
                                                  processID:
                                                      processID, // Pass the process ID
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 10),
                                        _buildAlarmAndWorkOrder(),
                                        const SizedBox(height: 10),
                                        _buildProductionAndEquipment(),
                                        const SizedBox(height: 10),
                                        _buildDowntimeAnalysisAndEquipmentDowntime()
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

  Widget _buildAlarmAndWorkOrder() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: AlarmlistcardproductionWidget(
            alarmData: alarmData,
            isLoading: isLoading3,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: WorkordercardWidget(
            workOrderName: selectedWorkID,
            productionArea: selectedProductionAreaName!,
            productName: productName,
            processID: processID ?? "N/A",
            date: date,
            progress: jobOrderGrossQuantity,
            quantity: jobOrderExpectedQuantity,
            unit: unit,
            name: selectedEquipmentDetails != null
                ? selectedEquipmentDetails!['name'] ?? combinedEquipmentNames
                : combinedEquipmentNames,
            show: show,
            status: status,
            isLoading: isLoading3,
            plannedStartTime: plannedStartTime,
            checkInTime: checkInTime,
            targetCompletionTime: targetCompletionTime,
            estimatedCompletionTime: estimatedCompletionTime,
            remainingHours: remainingHour,
            estimatedDelay: estimatedDelay,
            isLateStart: isLateStart,
            isOverdue: isOverdue,
            woPlannedCycleTime: woPlannedCycleTime,
            woActualCycleTime: woActualCycleTime,
          ),
        ),
      ],
    );
  }

  Widget _buildProductionAndEquipment() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: ProductionCardWidget(
              actualProduction: dailyActualProduction,
              plannedProduction: dailyPlannedProduction,
              isLoading: isLoadingDailyEfficiency,
              machineEfficiencyData: dailyMachineEfficiencyData,
              woId: workOrderID,
              opId: processIDWoP),
        ),
        const SizedBox(width: 10),
        const Flexible(child: EquipmentCardWidget()),
      ],
    );
  }

  Widget _buildDowntimeAnalysisAndEquipmentDowntime() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: DowntimeAnalysisCardWidget(
            machineEfficiencyData: periodMachineEfficiencyData,
            plannedInputData: periodPlannedInputData,
            isLoading: isLoadingPeriodEfficiency,
            onPeriodChanged: onEfficiencyPeriodChanged,
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: EquipmentDowntimeCard(
            categories: downtimeCategories,
            timeValues: downtimeTimeValues,
            accumulatedValues: downtimeAccumulatedValues,
            totalDowntime: totalDowntime.toInt(),
            maxY: downtimeMaxY,
            isLoading: isLoadingDowntime,
          ),
        ),
      ],
    );
  }
}
