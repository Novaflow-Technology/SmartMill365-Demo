import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:cloud_firestore/cloud_firestore.dart';
import '/flutter_flow/flutter_flow_drop_down.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/form_field_controller.dart';

// Configuration class for API URLs
class ApiConfig {
  static const String baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';
  static String get productionAreas => '$baseUrl/productionAreas';
}

class FilterControlsWidget extends StatefulWidget {
  final Function()? onExportPressed;
  final Function(String?)? onShiftChanged;
  final Function(String?)? onMachineChanged;
  final Function(String?)? onMetricChanged;
  final Function(DateTime, DateTime)? onDateRangeChanged;

  // Initial values to maintain state
  final String? initialShift;
  final String? initialMachine;
  final String? initialMetric;
  final DateTime? initialStartDate;
  final DateTime? initialEndDate;

  const FilterControlsWidget({
    super.key,
    this.onExportPressed,
    this.onShiftChanged,
    this.onMachineChanged,
    this.onMetricChanged,
    this.onDateRangeChanged,
    this.initialShift,
    this.initialMachine,
    this.initialMetric,
    this.initialStartDate,
    this.initialEndDate,
  });

  @override
  State<FilterControlsWidget> createState() => _FilterControlsWidgetState();
}

class _FilterControlsWidgetState extends State<FilterControlsWidget> {
  String? selectedShift;
  String? selectedMachine;
  String? selectedMetric;
  DateTime? startDate;
  DateTime? endDate;

  // Production Area related variables
  List<Map<String, String>> productionAreaList = [];
  String? selectedProductionAreaId;
  String? selectedProductionAreaName;
  bool isLoadingProductionAreas = true;

  // Equipment/Machine related variables
  List<Map<String, dynamic>> equipmentFromFirestore = [];
  bool isLoadingMachines = true;

  // Form field controllers
  FormFieldController<String>? productionAreaController;
  FormFieldController<String>? shiftController;
  FormFieldController<String>? machineController;
  FormFieldController<String>? metricController;

  final shiftOptions = ['All Shifts', 'Morning Shift', 'Night Shift'];
  final metricOptions = ['OEE (Overall Equipment Effectiveness)', 'Availability', 'Performance', 'Quality'];

  @override
  void initState() {
    super.initState();

    // Initialize with the provided values or defaults
    selectedShift = widget.initialShift ?? 'All Shifts';
    selectedMachine = widget.initialMachine ?? 'All Machines';
    selectedMetric = widget.initialMetric ?? metricOptions.first;
    startDate = widget.initialStartDate ?? DateTime.now();
    endDate = widget.initialEndDate ?? DateTime.now();

    // Initialize controllers
    shiftController = FormFieldController<String>(selectedShift);
    metricController = FormFieldController<String>(selectedMetric);

    // Fetch production areas first
    fetchProductionAreas();
  }

  @override
  void didUpdateWidget(FilterControlsWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Update local state when parent widget updates
    if (widget.initialShift != oldWidget.initialShift) {
      setState(() {
        selectedShift = widget.initialShift ?? 'All Shifts';
        shiftController?.value = selectedShift;
      });
    }

    if (widget.initialMachine != oldWidget.initialMachine) {
      setState(() {
        selectedMachine = widget.initialMachine ?? 'All Machines';
        machineController?.value = selectedMachine;
      });
    }

    if (widget.initialMetric != oldWidget.initialMetric) {
      setState(() {
        selectedMetric = widget.initialMetric ?? metricOptions.first;
        metricController?.value = selectedMetric;
      });
    }
  }

  // Helper method to get default machine based on production area
  String getDefaultMachineForProductionArea(String? productionAreaId) {
    if (productionAreaId == null) return 'All Machines';

    // Check if it's All Plants -> default to All Machines
    if (productionAreaId.toLowerCase() == 'all') {
      return 'All Machines';
    }
    // Check if it's Plant 1 (p1) -> default to PE123
    else if (productionAreaId.toLowerCase() == 'p1') {
      return 'PE123';
    }
    // Check if it's Plant 2 (p2) -> default to PE120
    else if (productionAreaId.toLowerCase() == 'p2') {
      return 'PE120';
    }

    return 'All Machines';
  }

  Future<void> fetchProductionAreas() async {
    if (!mounted) return;

    setState(() => isLoadingProductionAreas = true);

    try {
      print('Fetching production areas from: ${ApiConfig.productionAreas}');
      final response = await http.get(Uri.parse(ApiConfig.productionAreas));

      print('Response status: ${response.statusCode}');

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

              if (id != null && name != null && id.isNotEmpty && name.isNotEmpty) {
                areas.add({
                  'id': id,
                  'name': name,
                });
              }
            }
          }

          // Add "All Plants" option at the end
          areas.add({
            'id': 'all',
            'name': 'All Plants',
          });
        }

        if (!mounted) return;

        setState(() {
          productionAreaList = areas;

          // Select first production area by default
          if (productionAreaList.isNotEmpty) {
            selectedProductionAreaId = productionAreaList[0]['id'];
            selectedProductionAreaName = productionAreaList[0]['name'];
            productionAreaController = FormFieldController<String>(selectedProductionAreaName);
          }
        });

        print("Successfully fetched production areas: ${productionAreaList.length}");

        // Fetch equipment for the selected production area
        if (selectedProductionAreaId?.isNotEmpty == true) {
          await fetchEquipmentFromFirestore();
        }
      } else {
        throw Exception('Failed to load production areas (status ${response.statusCode})');
      }
    } catch (e) {
      print('Error fetching production areas: $e');

      // Fallback to default production areas
      if (mounted) {
        setState(() {
          productionAreaList = [
            {'id': 'p1', 'name': 'Plant 1'},
            {'id': 'p2', 'name': 'Plant 2'},
            {'id': 'all', 'name': 'All Plants'}
          ];
          selectedProductionAreaId = 'p2';
          selectedProductionAreaName = 'Plant 2';
          productionAreaController = FormFieldController<String>('Plant 2');
        });

        await fetchEquipmentFromFirestore();
      }
    } finally {
      if (mounted) {
        setState(() => isLoadingProductionAreas = false);
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
          selectedMachine = 'All Machines';
          machineController = FormFieldController<String>('All Machines');
          isLoadingMachines = false;
        });
      }
      return;
    }

    setState(() => isLoadingMachines = true);

    try {
      QuerySnapshot querySnapshot;

      // If "All Plants" is selected, fetch equipment from all production areas
      if (selectedProductionAreaId!.toLowerCase() == 'all') {
        querySnapshot = await FirebaseFirestore.instance.collection('equipments').get();
      } else {
        querySnapshot = await FirebaseFirestore.instance.collection('equipments').where('productionArea', isEqualTo: selectedProductionAreaId).get();
      }

      final equipments = querySnapshot.docs.map((doc) {
        final data = doc.data() as Map<String, dynamic>;
        // Handle work_id as either String or List
        String workId;
        final rawWorkId = data['work_id'];
        if (rawWorkId is String) {
          workId = rawWorkId;
        } else if (rawWorkId is List) {
          workId = rawWorkId.isNotEmpty ? rawWorkId[0].toString() : 'Unknown Work ID';
        } else {
          workId = 'Unknown Work ID';
        }

        return {
          'id': doc.id,
          'equipment_id': data['equipment_id'] as String? ?? '',
          'name': data['name'] as String? ?? 'Unknown Equipment',
          'productionArea': data['productionArea'] as String? ?? '',
          'work_id': workId,
        };
      }).toList();

      if (!mounted) return;

      // Get the default machine for this production area
      String defaultMachine = getDefaultMachineForProductionArea(selectedProductionAreaId);

      // Check if the default machine exists in the equipment list
      bool defaultExists = equipments.any((equip) => equip['name'] == defaultMachine);

      // If default machine doesn't exist, fall back to 'All Machines'
      if (!defaultExists) {
        defaultMachine = 'All Machines';
      }

      setState(() {
        equipmentFromFirestore = equipments;

        // Set default machine based on production area
        selectedMachine = defaultMachine;
        machineController = FormFieldController<String>(defaultMachine);
      });

      print("Successfully fetched ${equipments.length} equipments for production area: $selectedProductionAreaId");
      print("Default machine set to: $defaultMachine");

      // Notify parent about machine change
      widget.onMachineChanged?.call(defaultMachine);
    } catch (e) {
      print('Error fetching equipments from Firestore: $e');
      if (mounted) {
        setState(() {
          equipmentFromFirestore = [];
          selectedMachine = 'All Machines';
          machineController = FormFieldController<String>('All Machines');
        });
      }
    } finally {
      if (mounted) {
        setState(() => isLoadingMachines = false);
      }
    }
  }

  @override
  void dispose() {
    productionAreaController?.dispose();
    shiftController?.dispose();
    machineController?.dispose();
    metricController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: FlutterFlowTheme.of(context).alternate,
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.1),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // Production Area Dropdown
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 10, 10, 10),
                child: isLoadingProductionAreas
                    ? Container(
                        width: 284,
                        height: 40,
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xBB31ECFC),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: FlutterFlowTheme.of(context).primary,
                            width: 1,
                          ),
                        ),
                        child: const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                            ),
                          ),
                        ),
                      )
                    : FlutterFlowDropDown<String>(
                        controller: productionAreaController ??= FormFieldController<String>(selectedProductionAreaName),
                        options: productionAreaList.map((area) => area['name'] as String).toList(),
                        onChanged: (val) {
                          setState(() {
                            selectedProductionAreaId = productionAreaList.firstWhere((area) => area['name'] == val)['id'];
                            selectedProductionAreaName = val;
                            productionAreaController?.value = val;

                            // Reset equipment selection
                            equipmentFromFirestore = [];
                            selectedMachine = getDefaultMachineForProductionArea(selectedProductionAreaId);
                            machineController?.value = selectedMachine;
                            isLoadingMachines = true;
                          });

                          fetchEquipmentFromFirestore();
                        },
                        width: 284,
                        height: 40,
                        textStyle: FlutterFlowTheme.of(context).bodyMedium.copyWith(
                              fontFamily: 'Poppins',
                              fontWeight: FontWeight.w600,
                            ),
                        hintText: 'Select Production Area...',
                        icon: Icon(
                          Icons.keyboard_arrow_down_rounded,
                          color: FlutterFlowTheme.of(context).primaryText,
                        ),
                        fillColor: const Color(0xBB31ECFC),
                        borderColor: FlutterFlowTheme.of(context).primary,
                        borderWidth: 1,
                        borderRadius: 10,
                        margin: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0),
                        hidesUnderline: true,
                        value: null,
                        elevation: 0,
                      ),
              ),

              // Shift Dropdown
              Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(0, 10, 10, 10),
                child: FlutterFlowDropDown<String>(
                  controller: shiftController ??= FormFieldController<String>(selectedShift),
                  options: shiftOptions,
                  onChanged: (val) {
                    setState(() {
                      selectedShift = val;
                      shiftController?.value = val;
                    });
                    widget.onShiftChanged?.call(val);
                  },
                  width: 284,
                  height: 40,
                  maxHeight: 300,
                  textStyle: FlutterFlowTheme.of(context).labelLarge.override(
                        fontFamily: 'Poppins',
                        color: FlutterFlowTheme.of(context).primaryText,
                        fontSize: 14,
                        font: GoogleFonts.poppins(),
                      ),
                  hintText: 'Select Shift',
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: FlutterFlowTheme.of(context).primaryText,
                    size: 20,
                  ),
                  fillColor: const Color(0xBB31ECFC),
                  elevation: 2,
                  borderColor: FlutterFlowTheme.of(context).primary,
                  borderWidth: 1,
                  borderRadius: 10,
                  margin: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0),
                  hidesUnderline: true,
                  value: null,
                ),
              ),

              // Metric Dropdown
              SizedBox(
                width: 280,
                child: FlutterFlowDropDown<String>(
                  controller: metricController ??= FormFieldController<String>(selectedMetric),
                  options: metricOptions,
                  onChanged: (val) {
                    setState(() {
                      selectedMetric = val;
                      metricController?.value = val;
                    });
                    widget.onMetricChanged?.call(val);
                  },
                  width: double.infinity,
                  height: 40,
                  textStyle: FlutterFlowTheme.of(context).labelLarge.override(
                        fontFamily: 'Poppins',
                        color: FlutterFlowTheme.of(context).primaryText,
                        fontSize: 14,
                        font: GoogleFonts.poppins(),
                      ),
                  hintText: 'Select Metric',
                  icon: Icon(
                    Icons.keyboard_arrow_down_rounded,
                    color: FlutterFlowTheme.of(context).primaryText,
                    size: 20,
                  ),
                  fillColor: const Color(0xBB31ECFC),
                  elevation: 2,
                  borderColor: FlutterFlowTheme.of(context).primary,
                  borderWidth: 1,
                  borderRadius: 10,
                  margin: const EdgeInsetsDirectional.fromSTEB(12, 0, 12, 0),
                  hidesUnderline: true,
                  value: null,
                ),
              ),

              const Spacer(),

              // Export Report Button
              Container(
                height: 40,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      FlutterFlowTheme.of(context).primary.withOpacity(0.8),
                      FlutterFlowTheme.of(context).primary,
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: ElevatedButton.icon(
                  onPressed: widget.onExportPressed,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: Colors.white,
                    size: 18,
                  ),
                  label: Text(
                    'Export Report',
                    style: FlutterFlowTheme.of(context).labelLarge.override(
                          fontFamily: 'Poppins',
                          color: Colors.white,
                          fontSize: 14,
                          font: GoogleFonts.poppins(),
                          fontWeight: FontWeight.w500,
                        ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
