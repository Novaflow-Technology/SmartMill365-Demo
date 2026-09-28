import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:cloud_firestore/cloud_firestore.dart';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import 'statusbaroverview_widget.dart';
import 'equipmentcardmain_widget.dart';
import 'equipment_overview_model.dart';
export 'equipment_overview_model.dart';

import '../../flutter_flow/nav/router_tracker.dart';

class EquipmentOverviewWidget extends StatefulWidget {
  const EquipmentOverviewWidget({super.key});

  @override
  State<EquipmentOverviewWidget> createState() =>
      _EquipmentOverviewWidgetState();
}

class _EquipmentOverviewWidgetState extends State<EquipmentOverviewWidget> {
  late EquipmentOverviewModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  bool isLoading = true;
  bool isLoading1 = true;
  bool apiError = false;
  String apiErrorMessage = '';

  final Map<String, GlobalKey<EquipmentcardmainWidgetState>> _childKeys = {};

  List<Map<String, String>> productionAreaList = [];
  List<Map<String, dynamic>> equipmentList = [];
  List<Map<String, dynamic>> equipmentFromFirestore = [];
  String? selectedProductionAreaId;
  String? selectedSortOption = 'All';
  List<Map<String, dynamic>> equipmentData = [];
  int running = 0;
  int offline = 0;
  int idle = 0;
  int alarm = 0;
  int stopped = 0;

  Timer? _timer; // Changed to nullable
  String lastUpdateTime = '';
  bool _showProgressIndicator = true;
  Map<String, String> equipmentProcessIds = {};
  Map<String, Map<String, dynamic>> equipmentFullProcessData = {};
  Map<String, Map<String, dynamic>> equipmentOverallOEE = {};
  Map<String, Map<String, dynamic>> equipmentPerformanceData = {};

  // Firestore-backed endpoints (production areas, equipment list) — intechsf365
  static const String _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  // MySQL-backed endpoints (equipment status, process IDs, OEE) — smartmachine
  static const String _dataUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => EquipmentOverviewModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);

    // Set up the timer with proper mounted check
    _timer = Timer.periodic(const Duration(minutes: 2), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }

      fetchEquipmentProcessIds();
      fetchEquipmentStatus();
      fetchEquipmentOverallOEE();
      fetchMachinePerformance();
      _childKeys.forEach((key, globalKey) {
        globalKey.currentState?.refreshData();
      });
    });

    fetchProductionAreas();
    fetchEquipmentByProductionArea(null);

    Timer(const Duration(seconds: 10), () {
      if (mounted) {
        setState(() {
          _showProgressIndicator = false;
        });
      }
    });

    routeTracker.addListener(_onRouteChanged);
  }

  void _onRouteChanged() {
    const allowedRoutes = ['/', '/equipmentOverview'];
    if (!allowedRoutes.contains(routeTracker.currentRoute)) {
      _timer?.cancel();
      routeTracker.removeListener(_onRouteChanged);
    }
  }

  @override
  void dispose() {
    _timer?.cancel(); // Use null-aware operator
    _timer = null;
    routeTracker.removeListener(_onRouteChanged);
    _model.dispose();
    super.dispose();
  }

  Future<void> fetchProductionAreas() async {
    try {
      final response = await http
          .get(Uri.parse('$_baseUrl/productionAreas'))
          .timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final areas = data
            .map((item) => {
                  'id': item['id'] as String,
                  'name': item['name'] as String,
                })
            .toList();

        if (!mounted) return; // Check before setState

        setState(() {
          productionAreaList = [
            {'id': '', 'name': 'All Equipment'},
            ...areas,
          ];
        });
        print(
            'Successfully fetched production areas from: $_baseUrl/productionAreas');
      } else {
        throw Exception(
            'Failed to load production areas (status ${response.statusCode}, body: ${response.body})');
      }
    } catch (e) {
      print('Error fetching production areas: $e');

      if (!mounted) return; // Check before setState

      setState(() {
        apiError = true;
        apiErrorMessage = 'Failed to load production areas: $e';
      });
    }
    updateRunning();
  }

  Future<void> fetchEquipmentFromFirestore(String? productionAreaId) async {
    try {
      print(
          'Fetching equipment from Firestore for production area: $productionAreaId');

      Query query = FirebaseFirestore.instance.collection('equipments');

      if (productionAreaId != null && productionAreaId.isNotEmpty) {
        query = query.where('productionArea', isEqualTo: productionAreaId);
      }

      final querySnapshot = await query.get();
      final currentUserId = AppStateNotifier.instance.uid ?? '';

      final equipments = await Future.wait(querySnapshot.docs.map((doc) async {
        final data = doc.data() as Map<String, dynamic>;

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

        // Only show image if the current user has their own image saved
        String imageUrl = '';
        if (currentUserId.isNotEmpty) {
          final userImageDoc = await FirebaseFirestore.instance
              .collection('equipments')
              .doc(doc.id)
              .collection('userImages')
              .doc(currentUserId)
              .get();
          if (userImageDoc.exists) {
            imageUrl = userImageDoc.data()?['imageUrl'] as String? ?? '';
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
          'work_order_id': data['work_order_id'] as String? ?? '',
          'imageUrl': imageUrl,
        };
      }));

      if (!mounted) return; // Check before setState

      setState(() {
        equipmentFromFirestore = equipments;
      });

      print(
          'Successfully fetched ${equipments.length} equipment from Firestore');
      print(
          'Equipment with images: ${equipments.where((e) => e['imageUrl'].toString().isNotEmpty).length}');
    } catch (e) {
      print('Error fetching equipment from Firestore: $e');

      if (!mounted) return; // Check before setState

      setState(() {
        equipmentFromFirestore = [];
      });
    }
  }

  Future<void> fetchEquipmentByProductionArea(String? productionAreaId) async {
    if (!mounted) return; // Check before setState

    setState(() {
      isLoading1 = true;
      apiError = false;
      apiErrorMessage = '';
    });

    try {
      const areaMap = {
        'Intech-P1': 'P1',
        'Intech-P2': 'P2',
        'intech-p1': 'P1',
        'intech-p2': 'P2'
      };
      final resolvedId =
          (productionAreaId != null && productionAreaId.isNotEmpty)
              ? (areaMap[productionAreaId] ?? productionAreaId)
              : null;
      final idSegment = (resolvedId?.isNotEmpty ?? false) ? resolvedId! : 'all';
      final uri = Uri.parse('$_baseUrl/productionAreas/equipment/$idSegment');
      final response = await http.get(uri).timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw Exception(
            'Failed to load equipment: ${response.statusCode}, body: ${response.body}');
      }

      final List<dynamic> data = jsonDecode(response.body);
      final List<Map<String, dynamic>> flatList = [];

      for (final item in data) {
        final rawName = (item['name'] as String?)?.trim() ?? '';
        if (rawName.isEmpty) continue;
        final equipmentId =
            (item['equipment_id'] as String?)?.trim() ?? rawName;
        final parent =
            rawName.contains('_') ? rawName.split('_').first : rawName;

        flatList.add({
          'id': equipmentId,
          'name': rawName,
          'work_id': item['work_id'] ?? 'Unknown Work ID',
          'productionArea': item['productionArea'],
          'parent': parent,
          'unit': item['unit'] ?? 'units',
          'process': item['process'] ?? '1',
        });
      }

      if (!mounted) return; // Check before setState

      setState(() {
        equipmentList = flatList;
        if (flatList.isEmpty) {
          apiError = true;
          apiErrorMessage = 'No equipments assigned for production area';
          isLoading1 = false;
        }
      });
      print(
          'Successfully fetched equipment list from: $_baseUrl/productionAreas/equipment/$idSegment');

      if (flatList.isEmpty) return;

      await fetchEquipmentFromFirestore(resolvedId);

      await Future.wait([
        fetchEquipmentProcessIds(),
        fetchEquipmentOverallOEE(),
        fetchMachinePerformance(),
      ]);

      await fetchEquipmentStatus();

      if (!mounted) return; // Check before setState

      setState(() {
        isLoading1 = false;
      });
    } catch (e) {
      print('Error fetching equipment: $e');

      if (!mounted) return; // Check before setState

      setState(() {
        isLoading1 = false;
        apiError = true;
        apiErrorMessage = 'Failed to load equipment: $e';
      });
    }
  }

  Future<void> fetchEquipmentStatus() async {
    if (equipmentList.isEmpty) return;
    try {
      final uniqueEquipment = <String, Map<String, dynamic>>{};
      for (var equipment in equipmentList) {
        uniqueEquipment[equipment['id']] = equipment;
      }
      final requestBody = uniqueEquipment.values
          .map((equipment) => {
                'equipmentId': equipment['id'],
                'productionArea': equipment['productionArea'],
              })
          .toList();

      const url = '$_dataUrl/equipmentStatus/status';
      print('Sending POST request to: $url');
      print('Request body: ${jsonEncode(requestBody)}');
      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');
      print('Response headers: ${response.headers}');

      if (!mounted) return; // Check before processing response

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);

        setState(() {
          apiError = false;
          apiErrorMessage = '';
          equipmentData.clear();
          for (var item in data) {
            final rawId = (item['id'] as String?)?.trim() ?? '';
            if (rawId.isEmpty) continue;
            final parent = rawId.contains('_') ? rawId.split('_').first : rawId;

            final runStatus = equipmentFullProcessData[rawId]?['RunStatus'] ??
                item['machine_status']?['m_status'] ??
                -1;

            equipmentData.add({
              'id': rawId,
              'parent': parent,
              'status': {
                'id': rawId,
                'machine_status': {'m_status': runStatus},
                'total_good_quantity': item['total_good_quantity'] ?? 0,
                'total_gross_quantity': item['total_gross_quantity'] ?? 0,
                'job_order_id': item['job_order_id'],
                'work_id':
                    item['job_order_id'] ?? uniqueEquipment[rawId]?['work_id'],
                'oee': item['oee'],
                'alarm': item['alarm'] ?? {},
                'unit': uniqueEquipment[rawId]?['unit'] ?? 'units',
                'process': uniqueEquipment[rawId]?['process'] ?? '1',
              }
            });
          }
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
          print('Processed ${equipmentData.length} equipment entries');
        });
        updateRunning();
      } else {
        print('Failed to fetch equipment status: ${response.statusCode}');

        if (!mounted) return; // Check before setState

        setState(() {
          apiError = true;
          apiErrorMessage =
              'Failed to fetch equipment status (Error ${response.statusCode}, Body: ${response.body}).';
          equipmentData.clear();
          for (var equipment in uniqueEquipment.values) {
            final rawId = equipment['id'];
            final parent = equipment['parent'];

            final runStatus =
                equipmentFullProcessData[rawId]?['RunStatus'] ?? -1;

            equipmentData.add({
              'id': rawId,
              'parent': parent,
              'status': {
                'id': rawId,
                'machine_status': {'m_status': runStatus},
                'total_good_quantity': 0,
                'total_gross_quantity': 0,
                'job_order_id': null,
                'work_id': equipment['work_id'],
                'oee': null,
                'alarm': {},
                'unit': equipment['unit'] ?? 'units',
                'process': equipment['process'] ?? '1',
              }
            });
          }
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        });
        Future.delayed(const Duration(seconds: 10), () {
          if (mounted && apiError) fetchEquipmentStatus();
        });
        updateRunning();
      }
    } catch (e) {
      print('Error fetching equipment status: $e');

      if (!mounted) return; // Check before setState

      setState(() {
        apiError = true;
        apiErrorMessage = 'Error fetching equipment status: $e.';
        equipmentData.clear();
        for (var equipment in equipmentList) {
          final rawId = equipment['id'];
          final parent = equipment['parent'];

          final runStatus = equipmentFullProcessData[rawId]?['RunStatus'] ?? -1;

          equipmentData.add({
            'id': rawId,
            'parent': parent,
            'status': {
              'id': rawId,
              'machine_status': {'m_status': runStatus},
              'total_good_quantity': 0,
              'total_gross_quantity': 0,
              'job_order_id': null,
              'work_id': equipment['work_id'],
              'oee': null,
              'alarm': {},
              'unit': equipment['unit'] ?? 'units',
              'process': equipment['process'] ?? '1',
            }
          });
        }
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
      Future.delayed(const Duration(seconds: 10), () {
        if (mounted && apiError) fetchEquipmentStatus();
      });
      updateRunning();
    }
  }

  void updateRunning() {
    if (!mounted) return; // Check before processing

    int countRunning = 0;
    int countOffline = 0;
    int countIdle = 0;
    int countAlarm = 0;
    int countStopped = 0;

    final uniqueIds = <String>{};
    for (var entry in equipmentData) {
      final equipmentId = entry['id'];
      if (uniqueIds.contains(equipmentId)) continue;
      uniqueIds.add(equipmentId);

      final equipmentStatus = entry['status'];

      if (equipmentStatus.containsKey('alarm') &&
          equipmentStatus['alarm'] is Map) {
        equipmentStatus['alarm'].forEach((key, value) {
          if (value == true) {
            countAlarm++;
          }
        });
      }

      final equipment = equipmentList.firstWhere(
        (e) => e['id'] == equipmentId,
        orElse: () => {'id': equipmentId},
      );

      final machineId = equipment['id'];

      print('Equipment ID: $equipmentId, Machine ID: $machineId');
      print('Process Data: ${equipmentFullProcessData[machineId]}');

      final processData = equipmentFullProcessData[machineId];
      final runStatus = processData?['RunStatus'];

      final status = int.tryParse(runStatus?.toString() ?? '-1') ?? -1;

      print('RunStatus for $equipmentId: $runStatus (parsed: $status)');

      if (status == 1) {
        countRunning++;
      } else if (status == 2) {
        countIdle++;
      } else if (status == 3) {
        countStopped++;
      } else {
        countOffline++;
      }
    }

    if (!mounted) return; // Final check before setState

    setState(() {
      running = countRunning;
      offline = countOffline;
      idle = countIdle;
      alarm = countAlarm;
      stopped = countStopped;
      isLoading = false;
    });
  }

  String getEquipmentStatus(Map<String, dynamic> equipment) {
    final id = equipment['id'] as String? ?? '';
    final runStatus = equipmentFullProcessData[id]?['RunStatus'];
    final statusCode = int.tryParse(runStatus?.toString() ?? '-1') ?? -1;

    switch (statusCode) {
      case 1:
        return 'Running';
      case 2:
        return 'Idle';
      case 3:
        return 'Stopped';
      default:
        return 'Unknown';
    }
  }

  List<Map<String, dynamic>> getFilteredEquipmentData() {
    List<Map<String, dynamic>> sortedData = List.from(equipmentData);

    final seenIds = <String>{};
    sortedData = sortedData.where((entry) {
      final equipmentId = entry['id'];
      if (seenIds.contains(equipmentId)) return false;
      seenIds.add(equipmentId);
      return true;
    }).toList();

    if (selectedSortOption != null && selectedSortOption != 'All') {
      sortedData.sort((a, b) {
        final statusA = getEquipmentStatus(a);
        final statusB = getEquipmentStatus(b);
        final aMatch = statusA == selectedSortOption;
        final bMatch = statusB == selectedSortOption;
        if (aMatch == bMatch) return 0;
        return aMatch ? -1 : 1;
      });
    }

    return sortedData;
  }

  Future<void> fetchEquipmentProcessIds() async {
    try {
      final uniqueEquipment = <String, Map<String, dynamic>>{};
      for (var equipment in equipmentList) {
        uniqueEquipment[equipment['id']] = equipment;
      }

      final requestBody = uniqueEquipment.values
          .map((equipment) => {
                'equipmentId': equipment['id'],
                'productionArea': equipment['productionArea'],
              })
          .toList();

      const url = '$_dataUrl/equipmentDetails/equipment-process-id/batch';
      print('Fetching ProcessIDs from: $url');
      print(
          'First 3 equipment IDs being sent: ${requestBody.take(3).map((e) => e['equipmentId']).toList()}');

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'equipmentList': requestBody}),
          )
          .timeout(const Duration(seconds: 15));

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');

      if (!mounted) return; // Check before processing

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final results = data['results'] as List<dynamic>;

        final newProcessIds = <String, Map<String, dynamic>>{};
        for (var result in results) {
          final equipmentId = result['equipmentId'];
          final processId = result['processID'];
          final totalGross = result['JobOrder_GrossQuantity'];
          final totalGood = result['JobOrder_ExpectedQuantity'];
          final runStatus = result['RunStatus'];
          final jobOrderID = result['JobOrderID'];

          newProcessIds[equipmentId] = {
            'processID': processId ?? 'N/A',
            'JobOrder_GrossQuantity': totalGross ?? 0,
            'JobOrder_ExpectedQuantity': totalGood ?? 0,
            'RunStatus': runStatus ?? 'N/A',
            'JobOrderID': jobOrderID ?? 'N/A'
          };
        }

        if (!mounted) return; // Check before setState

        setState(() {
          equipmentProcessIds = newProcessIds
              .map((key, value) => MapEntry(key, value['processID'] as String));
          equipmentFullProcessData = newProcessIds;
        });

        print(
            'Successfully fetched ${equipmentProcessIds.length} ProcessIDs out of ${data['totalRequested']} requested');
        print('ProcessIDs map: $equipmentProcessIds');
      } else {
        print('Failed to fetch ProcessIDs: ${response.statusCode}');
      }
    } catch (e) {
      print('Error fetching ProcessIDs: $e');
    }
  }

  Future<void> fetchEquipmentOverallOEE() async {
    try {
      final uniqueEquipment = <String, Map<String, dynamic>>{};
      for (var equipment in equipmentList) {
        uniqueEquipment[equipment['name']] = equipment;
      }

      final machineIds = uniqueEquipment.keys.toList();
      print(
          'Fetching Overall OEE for ${machineIds.length} equipment in a single request');

      const url =
          '$_dataUrl/equipmentDetails/overall-daily-machine-oee/latest/batch';

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'machineIds': machineIds}),
          )
          .timeout(const Duration(seconds: 30));

      if (!mounted) return; // Check before processing

      if (response.statusCode == 200) {
        final Map<String, dynamic> dataMap = jsonDecode(response.body);

        final Map<String, Map<String, dynamic>> newOverallOEE = {};

        for (var machineId in machineIds) {
          if (dataMap.containsKey(machineId)) {
            newOverallOEE[machineId] = {
              'Overall_Machine_OEE':
                  dataMap[machineId]['Overall_Machine_OEE'] ?? 0.0,
              'Machine_Quality': dataMap[machineId]['Machine_Quality'] ?? 0.0,
              'Machine_Availability':
                  dataMap[machineId]['Machine_Availability'] ?? 0.0,
              'Machine_Efficiency':
                  dataMap[machineId]['Machine_Efficiency'] ?? 0.0,
            };
            print(
                'Fetched Overall OEE for $machineId: ${dataMap[machineId]['Overall_Machine_OEE']}');
          } else {
            print('No Overall OEE data found for $machineId');
            newOverallOEE[machineId] = {
              'Overall_Machine_OEE': 0.0,
              'Machine_Quality': 0.0,
              'Machine_Availability': 0.0,
              'Machine_Efficiency': 0.0,
            };
          }
        }

        if (!mounted) return; // Check before setState

        setState(() {
          equipmentOverallOEE = newOverallOEE;
        });

        print(
            'Successfully fetched Overall OEE for ${equipmentOverallOEE.length} equipment');
      } else {
        print('Failed to fetch Overall OEE batch: ${response.statusCode}');
      }
    } catch (e) {
      print('Error in fetchEquipmentOverallOEE: $e');
    }
  }

  Future<void> fetchMachinePerformance() async {
    try {
      final uniqueEquipment = <String, Map<String, dynamic>>{};
      for (var equipment in equipmentList) {
        uniqueEquipment[equipment['name']] = equipment;
      }

      final machineIds = uniqueEquipment.keys.toList();
      print(
          'Fetching combined machine performance for ${machineIds.length} equipment');

      const url = '$_dataUrl/equipmentDetails/machine-performance-data/daily';

      final response = await http
          .post(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'machineIds': machineIds}),
          )
          .timeout(const Duration(seconds: 30));

      print('Combined Performance Response status: ${response.statusCode}');
      print('Combined Performance Response body: ${response.body}');

      if (!mounted) return; // Check before processing

      if (response.statusCode == 200) {
        final Map<String, dynamic> responseData = jsonDecode(response.body);
        final Map<String, dynamic> dataMap = responseData['data'];

        final Map<String, Map<String, dynamic>> newPerformanceData = {};

        for (var machineId in machineIds) {
          if (dataMap.containsKey(machineId)) {
            final machineData = dataMap[machineId] as List<dynamic>;

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
        }

        if (!mounted) return; // Check before setState

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
      print('Error in fetchCombinedMachinePerformance: $e');
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
    final String? safeValue =
        (value != null && options.contains(value)) ? value : null;
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
            : [
                BoxShadow(
                    color: cyan.withOpacity(0.12),
                    blurRadius: 10,
                    spreadRadius: 0),
              ],
      ),
      child: Row(
        children: [
          // Left neon accent bar
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
                          spreadRadius: 0),
                    ],
            ),
          ),
          // Dropdown
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: safeValue,
                  isExpanded: true,
                  dropdownColor: isLight
                      ? theme.secondaryBackground
                      : const Color(0xFF071A2E),
                  menuMaxHeight: 300,
                  hint: Text(
                    hint,
                    style: GoogleFonts.poppins(
                      color: isLight
                          ? theme.secondaryText
                          : cyan.withOpacity(0.82),
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  style: GoogleFonts.poppins(
                    color: isLight ? theme.primaryText : Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  icon: Icon(Icons.keyboard_arrow_down_rounded,
                      color: isLight ? theme.primary : cyan, size: 22),
                  items: options
                      .map((opt) => DropdownMenuItem<String>(
                            value: opt,
                            child: Text(
                              opt,
                              style: GoogleFonts.poppins(
                                color:
                                    isLight ? theme.primaryText : Colors.white,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
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
    final filteredEquipmentData = getFilteredEquipmentData();

    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: SafeArea(
          top: true,
          child: isLoading || isLoading1
              ? const Center(child: CircularProgressIndicator())
              : Stack(
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.max,
                      children: [
                        Expanded(
                          child: Align(
                            alignment: const AlignmentDirectional(0, -1),
                            child: Container(
                              width: double.infinity,
                              height: double.infinity,
                              decoration: BoxDecoration(
                                color: FlutterFlowTheme.of(context)
                                    .primaryBackground,
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
                                child: SingleChildScrollView(
                                  physics:
                                      const AlwaysScrollableScrollPhysics(),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Padding(
                                        padding: const EdgeInsetsDirectional
                                            .fromSTEB(0, 0, 0, 4),
                                        child: Text(
                                          'Dashboard/EquipmentOverview',
                                          style: FlutterFlowTheme.of(context)
                                              .titleLarge
                                              .override(
                                                fontFamily: 'Poppins',
                                                color:
                                                    FlutterFlowTheme.of(context)
                                                        .primaryText,
                                                fontSize: 12,
                                                font: GoogleFonts.poppins(),
                                              ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsetsDirectional
                                            .fromSTEB(0, 0, 0, 4),
                                        child: Text(
                                          'Equipment Overview',
                                          style: FlutterFlowTheme.of(context)
                                              .headlineMedium
                                              .override(
                                                fontFamily: 'Poppins',
                                                font: GoogleFonts.poppins(),
                                              ),
                                        ),
                                      ),
                                      // ── Filter bar — responsive ────────────────────────────────
                                      LayoutBuilder(
                                        builder: (context, filterConstraints) {
                                          final isMobileFilter =
                                              filterConstraints.maxWidth <
                                                  kBreakpointLarge;

                                          // Shared: last update + refresh column
                                          final lastUpdateCol = Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.end,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              RichText(
                                                text: TextSpan(
                                                  children: [
                                                    TextSpan(
                                                      text: 'Last Update: ',
                                                      style:
                                                          GoogleFonts.poppins(
                                                        color:
                                                            FlutterFlowTheme.of(
                                                                    context)
                                                                .secondaryText,
                                                        fontWeight:
                                                            FontWeight.w600,
                                                        fontSize: 11,
                                                        letterSpacing: 0.4,
                                                      ),
                                                    ),
                                                    TextSpan(
                                                      text: lastUpdateTime,
                                                      style:
                                                          GoogleFonts.poppins(
                                                        color:
                                                            FlutterFlowTheme.of(
                                                                    context)
                                                                .primaryText,
                                                        fontWeight:
                                                            FontWeight.w700,
                                                        fontSize: 11,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                              const SizedBox(height: 5),
                                              GestureDetector(
                                                onTap: () {
                                                  if (!mounted) return;
                                                  setState(() {
                                                    lastUpdateTime =
                                                        DateTime.now()
                                                            .toLocal()
                                                            .toString()
                                                            .substring(0, 19);
                                                    apiError = false;
                                                    apiErrorMessage = '';
                                                  });
                                                  fetchEquipmentFromFirestore(
                                                      selectedProductionAreaId);
                                                  fetchEquipmentProcessIds();
                                                  fetchEquipmentStatus();
                                                  fetchEquipmentOverallOEE();
                                                  fetchMachinePerformance();
                                                  _childKeys.forEach(
                                                      (key, globalKey) {
                                                    globalKey.currentState
                                                        ?.refreshData();
                                                  });
                                                },
                                                child: Container(
                                                  padding:
                                                      const EdgeInsets.all(6),
                                                  decoration: BoxDecoration(
                                                    color:
                                                        const Color(0xFF00D4FF)
                                                            .withOpacity(0.08),
                                                    border: Border.all(
                                                        color: const Color(
                                                            0xFF00D4FF),
                                                        width: 1),
                                                  ),
                                                  child: Icon(
                                                    Icons.refresh_rounded,
                                                    color:
                                                        const Color(0xFF00D4FF)
                                                            .withOpacity(0.80),
                                                    size: 18,
                                                  ),
                                                ),
                                              ),
                                            ],
                                          );

                                          if (isMobileFilter) {
                                            // Mobile: dropdowns full-width on one row, refresh below
                                            return Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              children: [
                                                Row(
                                                  children: [
                                                    Expanded(
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                vertical: 6),
                                                        child:
                                                            _buildCyberpunkDropdown(
                                                          context: context,
                                                          value: selectedProductionAreaId !=
                                                                  null
                                                              ? productionAreaList
                                                                      .firstWhere(
                                                                  (a) =>
                                                                      a['id'] ==
                                                                      selectedProductionAreaId,
                                                                  orElse: () =>
                                                                      {
                                                                    'name': ''
                                                                  },
                                                                )['name']
                                                                  as String
                                                              : null,
                                                          options:
                                                              productionAreaList
                                                                  .map((a) => a[
                                                                          'name']
                                                                      as String)
                                                                  .toList(),
                                                          hint: 'All Equipment',
                                                          width:
                                                              double.infinity,
                                                          onChanged: (val) {
                                                            if (val == null)
                                                              return;
                                                            setState(() {
                                                              selectedProductionAreaId =
                                                                  productionAreaList
                                                                      .firstWhere((a) =>
                                                                          a['name'] ==
                                                                          val)['id'];
                                                              selectedSortOption =
                                                                  'All';
                                                            });
                                                            fetchEquipmentByProductionArea(
                                                                selectedProductionAreaId);
                                                          },
                                                        ),
                                                      ),
                                                    ),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .symmetric(
                                                                vertical: 6),
                                                        child:
                                                            _buildCyberpunkDropdown(
                                                          context: context,
                                                          value:
                                                              selectedSortOption,
                                                          options: const [
                                                            'All',
                                                            'Running',
                                                            'Idle',
                                                            'Stopped',
                                                            'Unknown'
                                                          ],
                                                          hint:
                                                              'Sort by Status',
                                                          width:
                                                              double.infinity,
                                                          onChanged: (val) =>
                                                              setState(() =>
                                                                  selectedSortOption =
                                                                      val),
                                                        ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 4),
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment.end,
                                                  children: [lastUpdateCol],
                                                ),
                                              ],
                                            );
                                          }

                                          // Desktop: original side-by-side layout
                                          return Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.spaceBetween,
                                            children: [
                                              Row(
                                                children: [
                                                  Padding(
                                                    padding: const EdgeInsets
                                                        .symmetric(vertical: 8),
                                                    child:
                                                        _buildCyberpunkDropdown(
                                                      context: context,
                                                      value: selectedProductionAreaId !=
                                                              null
                                                          ? productionAreaList
                                                              .firstWhere(
                                                              (a) =>
                                                                  a['id'] ==
                                                                  selectedProductionAreaId,
                                                              orElse: () =>
                                                                  {'name': ''},
                                                            )['name'] as String
                                                          : null,
                                                      options:
                                                          productionAreaList
                                                              .map((a) =>
                                                                  a['name']
                                                                      as String)
                                                              .toList(),
                                                      hint: 'All Equipment',
                                                      width: 284,
                                                      onChanged: (val) {
                                                        if (val == null) return;
                                                        setState(() {
                                                          selectedProductionAreaId =
                                                              productionAreaList
                                                                  .firstWhere((a) =>
                                                                      a['name'] ==
                                                                      val)['id'];
                                                          selectedSortOption =
                                                              'All';
                                                        });
                                                        fetchEquipmentByProductionArea(
                                                            selectedProductionAreaId);
                                                      },
                                                    ),
                                                  ),
                                                  Padding(
                                                    padding:
                                                        const EdgeInsets.only(
                                                            left: 10,
                                                            top: 8,
                                                            bottom: 8),
                                                    child:
                                                        _buildCyberpunkDropdown(
                                                      context: context,
                                                      value: selectedSortOption,
                                                      options: const [
                                                        'All',
                                                        'Running',
                                                        'Idle',
                                                        'Stopped',
                                                        'Unknown'
                                                      ],
                                                      hint: 'Sort by Status',
                                                      width: 200,
                                                      onChanged: (val) =>
                                                          setState(() =>
                                                              selectedSortOption =
                                                                  val),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                              Padding(
                                                padding: const EdgeInsets.only(
                                                    right: 10.0),
                                                child: lastUpdateCol,
                                              ),
                                            ],
                                          );
                                        },
                                      ),
                                      const SizedBox(height: 10),
                                      // ── Status Bar — fixed height for CardSizing ──
                                      SizedBox(
                                        height: 80,
                                        child: Row(
                                          children: [
                                            Expanded(
                                              child: wrapWithModel(
                                                model: _model
                                                    .statusbaroverviewModel,
                                                updateCallback: () =>
                                                    setState(() {}),
                                                child: StatusbaroverviewWidget(
                                                  running: running,
                                                  alarm: alarm,
                                                  idle: idle,
                                                  offline: offline,
                                                  stopped: stopped,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      const SizedBox(height: 10),
                                      if (apiError &&
                                          apiErrorMessage ==
                                              'No equipments assigned for production area')
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 20),
                                          child: Center(
                                            child: Text(
                                              apiErrorMessage,
                                              style: FlutterFlowTheme.of(
                                                      context)
                                                  .bodyMedium
                                                  .override(
                                                    fontFamily: 'Poppins',
                                                    color: Colors.red,
                                                    fontSize: 16,
                                                    font: GoogleFonts.poppins(),
                                                  ),
                                            ),
                                          ),
                                        )
                                      else if (filteredEquipmentData.isEmpty &&
                                          !apiError)
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 20),
                                          child: Center(
                                            child: Text(
                                              'No equipment found with status: ${selectedSortOption ?? 'All'}',
                                              style: FlutterFlowTheme.of(
                                                      context)
                                                  .bodyMedium
                                                  .override(
                                                    fontFamily: 'Poppins',
                                                    color: Colors.grey,
                                                    fontSize: 16,
                                                    font: GoogleFonts.poppins(),
                                                  ),
                                            ),
                                          ),
                                        )
                                      else
                                        LayoutBuilder(
                                          builder: (context, constraints) {
                                            final availW = constraints.maxWidth;
                                            // 280px per card → 4 cols at ~1140px (1440p screen + 270px nav)
                                            // Clamp 1–5 to stay readable on both mobile and ultrawide
                                            final cols = (availW / 280)
                                                .floor()
                                                .clamp(1, 5);
                                            // Gap: 1% of width, floored between 6–16px for clean spacing
                                            final gap = (availW * 0.01)
                                                .clamp(6.0, 16.0);
                                            final cardW =
                                                (availW - gap * (cols - 1)) /
                                                    cols;
                                            // 0.72 width/height ratio keeps card portrait and content readable
                                            final cardH = cardW / 0.72;

                                            return Wrap(
                                              spacing: gap,
                                              runSpacing: gap,
                                              children: List.generate(
                                                  filteredEquipmentData.length,
                                                  (index) {
                                                final entry =
                                                    filteredEquipmentData[
                                                        index];
                                                final equipmentId = entry['id'];
                                                final parent = entry['parent'];
                                                final equipmentStatus =
                                                    entry['status'];

                                                final equipment =
                                                    equipmentList.firstWhere(
                                                  (e) => e['id'] == equipmentId,
                                                  orElse: () => {
                                                    'id': equipmentId,
                                                    'name': equipmentId,
                                                    'work_id':
                                                        'Unknown Work ID',
                                                    'productionArea': '',
                                                    'parent': parent,
                                                    'unit': 'units',
                                                    'process': '1',
                                                  },
                                                );

                                                final productionArea =
                                                    equipmentList.firstWhere(
                                                  (e) => e['id'] == equipmentId,
                                                  orElse: () => {
                                                    'productionArea': '',
                                                  },
                                                )['productionArea'];

                                                final machineID =
                                                    equipmentList.firstWhere(
                                                  (e) => e['id'] == equipmentId,
                                                  orElse: () => {
                                                    'id': '',
                                                  },
                                                )['id'];

                                                final uniqueKey =
                                                    '$equipmentId-$index';
                                                if (!_childKeys
                                                    .containsKey(uniqueKey)) {
                                                  _childKeys[uniqueKey] = GlobalKey<
                                                      EquipmentcardmainWidgetState>();
                                                }

                                                return SizedBox(
                                                  width: cardW,
                                                  height: cardH,
                                                  child: equipmentStatus ==
                                                              null &&
                                                          _showProgressIndicator
                                                      ? const Center(
                                                          child:
                                                              CircularProgressIndicator())
                                                      : EquipmentcardmainWidget(
                                                          key: _childKeys[
                                                              uniqueKey],
                                                          parent: parent,
                                                          equipmentList: {
                                                            equipmentId: {
                                                              'id': equipment[
                                                                  'id'],
                                                              'name': equipment[
                                                                  'name'],
                                                              'work_id':
                                                                  equipmentStatus[
                                                                      'work_id'],
                                                              'productionArea':
                                                                  equipment[
                                                                      'productionArea'],
                                                              'parent':
                                                                  equipment[
                                                                      'parent'],
                                                              'unit':
                                                                  equipmentStatus[
                                                                      'unit'],
                                                              'process':
                                                                  equipmentStatus[
                                                                      'process'],
                                                              'processID':
                                                                  equipmentProcessIds[
                                                                          machineID] ??
                                                                      '0/0',
                                                              'JobOrder_GrossQuantity':
                                                                  equipmentFullProcessData[
                                                                              machineID]
                                                                          ?[
                                                                          'JobOrder_GrossQuantity'] ??
                                                                      0,
                                                              'JobOrder_ExpectedQuantity':
                                                                  equipmentFullProcessData[
                                                                              machineID]
                                                                          ?[
                                                                          'JobOrder_ExpectedQuantity'] ??
                                                                      0,
                                                              'RunStatus':
                                                                  equipmentFullProcessData[
                                                                              machineID]
                                                                          ?[
                                                                          'RunStatus'] ??
                                                                      -1,
                                                              'JobOrderID':
                                                                  equipmentFullProcessData[
                                                                              machineID]
                                                                          ?[
                                                                          'JobOrderID'] ??
                                                                      "N/A",
                                                              'Overall_Machine_OEE':
                                                                  equipmentOverallOEE[
                                                                              equipmentId]
                                                                          ?[
                                                                          'Overall_Machine_OEE'] ??
                                                                      0.0,
                                                              'Machine_Actual_Quantity':
                                                                  equipmentPerformanceData[
                                                                              equipmentId]
                                                                          ?[
                                                                          'Machine_Actual_Quantity'] ??
                                                                      0,
                                                              'Planned_Production_Qty':
                                                                  equipmentPerformanceData[
                                                                              equipmentId]
                                                                          ?[
                                                                          'Planned_Production_Qty'] ??
                                                                      0,
                                                              'performance_date':
                                                                  equipmentPerformanceData[
                                                                              equipmentId]
                                                                          ?[
                                                                          'date_only'] ??
                                                                      '',
                                                              'formatted_date':
                                                                  equipmentPerformanceData[
                                                                              equipmentId]
                                                                          ?[
                                                                          'formatted_date'] ??
                                                                      '',
                                                            }
                                                          },
                                                          equipmentData: {
                                                            equipmentId:
                                                                equipmentStatus
                                                          },
                                                          productionAreaName:
                                                              productionArea,
                                                          selectedProductionAreaName:
                                                              selectedProductionAreaId !=
                                                                      null
                                                                  ? selectedProductionAreaId!
                                                                  : productionArea,
                                                          isLoading: isLoading1,
                                                          equipmentFromFirestore:
                                                              equipmentFromFirestore,
                                                        ),
                                                );
                                              }),
                                            );
                                          },
                                        ),
                                      if (apiError &&
                                          apiErrorMessage !=
                                              'No equipments assigned for production area')
                                        Padding(
                                          padding:
                                              const EdgeInsets.only(top: 10),
                                          child: Row(
                                            mainAxisAlignment:
                                                MainAxisAlignment.center,
                                            children: [
                                              Text(
                                                apiErrorMessage,
                                                style: FlutterFlowTheme.of(
                                                        context)
                                                    .bodyMedium
                                                    .override(
                                                      fontFamily: 'Poppins',
                                                      color: Colors.red,
                                                      font:
                                                          GoogleFonts.poppins(),
                                                    ),
                                              ),
                                              const SizedBox(width: 10),
                                              ElevatedButton(
                                                onPressed: () {
                                                  if (!mounted)
                                                    return; // Check before setState

                                                  setState(() {
                                                    apiError = false;
                                                    apiErrorMessage = '';
                                                  });
                                                  fetchEquipmentStatus();
                                                },
                                                child: const Text('Retry'),
                                              ),
                                            ],
                                          ),
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
                  ],
                ),
        ),
      ),
    );
  }
}
