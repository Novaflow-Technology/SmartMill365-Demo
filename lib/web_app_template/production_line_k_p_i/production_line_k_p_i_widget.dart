import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:flutter/rendering.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/downtime_analysis_chart_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/filter_controls_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/header_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/kpi_metrics_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/machine_availability_comparison_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/machine_oee_comparison_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/machine_output_comparison_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/machine_performance_ranking_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/machine_quality_comparison_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/oee_chart_widget.dart';
import 'package:smartmachine365/web_app_template/production_line_k_p_i/output_comparison_chart_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';
import '/utils/report_exporter.dart';

import 'production_line_k_p_i_model.dart';
export 'production_line_k_p_i_model.dart';

class ProductionLineKPIWidget extends StatefulWidget {
  const ProductionLineKPIWidget({super.key});

  @override
  State<ProductionLineKPIWidget> createState() => _ProductionLineKPIWidgetState();
}

class _ProductionLineKPIWidgetState extends State<ProductionLineKPIWidget> {
  late ProductionLineKPIModel _model;
  final scaffoldKey = GlobalKey<ScaffoldState>();
  String lastUpdateTime = '';

  // API Base URL - Update this to your server URL
  final String baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api/productionLineKpi';

  // Filter states
  String? selectedShift;
  String? selectedMachine;
  String? selectedMetric;
  DateTime? startDate;
  DateTime? endDate;

  // Data from APIs
  Map<String, dynamic>? oeeData;
  Map<String, dynamic>? performanceData;
  Map<String, dynamic>? availabilityData;
  Map<String, dynamic>? qualityData;
  bool isLoading = false;

  // Global keys for capturing chart widgets
  final GlobalKey _oeeChartKey = GlobalKey();
  final GlobalKey _outputChartKey = GlobalKey();
  final GlobalKey _downtimeChartKey = GlobalKey();
  final GlobalKey _machineOeeChartKey = GlobalKey();
  final GlobalKey _machineOutputChartKey = GlobalKey();
  final GlobalKey _machineAvailabilityChartKey = GlobalKey();
  final GlobalKey _machineQualityChartKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _model = createModel(context, () => ProductionLineKPIModel());
    lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);

    // Set default dates to today
    startDate = DateTime.now();
    endDate = DateTime.now();

    // Load initial data
    _fetchAllData();

    WidgetsBinding.instance.addPostFrameCallback((_) => safeSetState(() {}));
  }

  @override
  void dispose() {
    _model.dispose();
    super.dispose();
  }

  // Format date to DD/MM/YYYY
  String _formatDate(DateTime date) {
    return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';
  }

  // Build query parameters
  String _buildQueryParams() {
    List<String> params = [];

    if (selectedMachine != null && selectedMachine != 'All Machines') {
      params.add('machineId=$selectedMachine');
    }

    if (selectedShift != null && selectedShift != 'All Shifts') {
      String shiftValue = selectedShift == 'Morning Shift'
          ? 'morning'
          : selectedShift == 'Night Shift'
              ? 'night'
              : '';
      if (shiftValue.isNotEmpty) {
        params.add('shift=$shiftValue');
      }
    }

    if (startDate != null) {
      params.add('startDate=${_formatDate(startDate!)}');
    }

    if (endDate != null) {
      params.add('endDate=${_formatDate(endDate!)}');
    }

    return params.isNotEmpty ? '?${params.join('&')}' : '';
  }

  // Fetch OEE data
  Future<void> _fetchOEEData() async {
    try {
      final queryParams = _buildQueryParams();
      final response = await http.get(Uri.parse('$baseUrl/oee$queryParams'));

      if (response.statusCode == 200) {
        setState(() {
          oeeData = json.decode(response.body);
        });
      } else {
        _showError('Failed to load OEE data');
      }
    } catch (e) {
      _showError('Error fetching OEE data: $e');
    }
  }

  // Fetch Performance data
  Future<void> _fetchPerformanceData() async {
    try {
      final queryParams = _buildQueryParams();
      final response = await http.get(Uri.parse('$baseUrl/performance$queryParams'));

      if (response.statusCode == 200) {
        setState(() {
          performanceData = json.decode(response.body);
        });
      } else {
        _showError('Failed to load Performance data');
      }
    } catch (e) {
      _showError('Error fetching Performance data: $e');
    }
  }

  // Fetch Availability data
  Future<void> _fetchAvailabilityData() async {
    try {
      final queryParams = _buildQueryParams();
      final response = await http.get(Uri.parse('$baseUrl/availability$queryParams'));

      if (response.statusCode == 200) {
        setState(() {
          availabilityData = json.decode(response.body);
        });
      } else {
        _showError('Failed to load Availability data');
      }
    } catch (e) {
      _showError('Error fetching Availability data: $e');
    }
  }

  // Fetch Quality data
  Future<void> _fetchQualityData() async {
    try {
      final queryParams = _buildQueryParams();
      final response = await http.get(Uri.parse('$baseUrl/quality$queryParams'));

      if (response.statusCode == 200) {
        setState(() {
          qualityData = json.decode(response.body);
        });
      } else {
        _showError('Failed to load Quality data');
      }
    } catch (e) {
      _showError('Error fetching Quality data: $e');
    }
  }

  // Fetch all data
  Future<void> _fetchAllData() async {
    setState(() {
      isLoading = true;
    });

    await Future.wait([
      _fetchOEEData(),
      _fetchPerformanceData(),
      _fetchAvailabilityData(),
      _fetchQualityData(),
    ]);

    setState(() {
      isLoading = false;
      lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
    });
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Colors.red,
      ),
    );
  }

  void _refreshData() {
    _fetchAllData();
  }

  // Capture widget as image
  Future<Uint8List?> _captureWidget(GlobalKey key) async {
    try {
      await Future.delayed(Duration(milliseconds: 100)); // Wait for rendering

      RenderRepaintBoundary? boundary = key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
      if (boundary == null) return null;

      ui.Image image = await boundary.toImage(pixelRatio: 2.0);
      ByteData? byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      print('Error capturing widget: $e');
      return null;
    }
  }

  // Updated export handler with dialog
  void _handleExportReport() {
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: Text(
            'Export Report',
            style: GoogleFonts.poppins(
              fontWeight: FontWeight.w600,
              fontSize: 20,
            ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose export format:',
                style: GoogleFonts.poppins(fontSize: 14),
              ),
              SizedBox(height: 16),
              Text(
                'Current Filters:',
                style: GoogleFonts.poppins(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: Colors.grey[700],
                ),
              ),
              SizedBox(height: 8),
              Text('• Shift: ${selectedShift ?? "All Shifts"}', style: GoogleFonts.poppins(fontSize: 12)),
              Text('• Machine: ${selectedMachine ?? "All Machines"}', style: GoogleFonts.poppins(fontSize: 12)),
              Text('• Date: ${_formatDate(startDate!)} - ${_formatDate(endDate!)}', style: GoogleFonts.poppins(fontSize: 12)),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text('Cancel', style: GoogleFonts.poppins()),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _exportToPdf();
              },
              icon: Icon(Icons.picture_as_pdf, size: 18),
              label: Text('PDF', style: GoogleFonts.poppins()),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[700],
                foregroundColor: Colors.white,
              ),
            ),
            ElevatedButton.icon(
              onPressed: () async {
                Navigator.of(context).pop();
                await _exportToExcel();
              },
              icon: Icon(Icons.table_chart, size: 18),
              label: Text('Excel', style: GoogleFonts.poppins()),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.green[700],
                foregroundColor: Colors.white,
              ),
            ),
          ],
        );
      },
    );
  }

  // Export to PDF with chart images
  Future<void> _exportToPdf() async {
    setState(() => isLoading = true);

    try {
      // Capture all chart images
      final oeeChartImage = await _captureWidget(_oeeChartKey);
      final outputChartImage = await _captureWidget(_outputChartKey);
      final downtimeChartImage = await _captureWidget(_downtimeChartKey);
      final machineOeeChartImage = await _captureWidget(_machineOeeChartKey);
      final machineOutputChartImage = await _captureWidget(_machineOutputChartKey);
      final machineAvailabilityChartImage = await _captureWidget(_machineAvailabilityChartKey);
      final machineQualityChartImage = await _captureWidget(_machineQualityChartKey);

      final reportData = {
        'oeeData': oeeData,
        'performanceData': performanceData,
        'availabilityData': availabilityData,
        'qualityData': qualityData,
        'totalMachines': _calculateTotalMachines(),
        'averageOee': _calculateAverageOEE(),
        'totalOutput': _calculateTotalOutput(),
        'uptime': _calculateAverageUptime(),
        // Add chart images
        'oeeChartImage': oeeChartImage,
        'performanceChartImage': outputChartImage,
        'availabilityChartImage': downtimeChartImage,
        'machineOeeChartImage': machineOeeChartImage,
        'machinePerformanceChartImage': machineOutputChartImage,
        'machineAvailabilityChartImage': machineAvailabilityChartImage,
        'machineQualityChartImage': machineQualityChartImage,
      };

      await ReportExporter.exportToPdf(
        context: context,
        reportData: reportData,
        selectedShift: selectedShift,
        selectedMachine: selectedMachine,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (e) {
      _showError('Failed to export PDF: $e');
    } finally {
      setState(() => isLoading = false);
    }
  }

  // Export to Excel
  Future<void> _exportToExcel() async {
    setState(() => isLoading = true);

    try {
      final reportData = {
        'oeeData': oeeData,
        'performanceData': performanceData,
        'availabilityData': availabilityData,
        'qualityData': qualityData,
        'totalMachines': _calculateTotalMachines(),
        'averageOee': _calculateAverageOEE(),
        'totalOutput': _calculateTotalOutput(),
        'uptime': _calculateAverageUptime(),
      };

      await ReportExporter.exportToExcel(
        context: context,
        reportData: reportData,
        selectedShift: selectedShift,
        selectedMachine: selectedMachine,
        startDate: startDate,
        endDate: endDate,
      );
    } catch (e) {
      _showError('Failed to export Excel: $e');
    } finally {
      setState(() => isLoading = false);
    }
  }

  void _handleShiftChanged(String? value) {
    setState(() {
      selectedShift = value;
    });
    print('Shift changed: $value');
    _refreshData();
  }

  void _handleMachineChanged(String? value) {
    setState(() {
      selectedMachine = value;
    });
    print('Machine changed: $value');
    _refreshData();
  }

  void _handleMetricChanged(String? value) {
    setState(() {
      selectedMetric = value;
    });
    print('Metric changed: $value');
    _refreshData();
  }

  void _handleDateRangeChanged(DateTime start, DateTime end) {
    setState(() {
      startDate = start;
      endDate = end;
    });
    print('Date range changed: ${_formatDate(start)} - ${_formatDate(end)}');
    _refreshData();
  }

  // Calculate total machines from API data
  int _calculateTotalMachines() {
    if (oeeData == null || oeeData!['data'] == null) return 30;

    List<dynamic> data = oeeData!['data'];
    if (data.isEmpty) return 30;

    // Get unique machine IDs from the data
    Set<String> machineIds = {};
    for (var item in data) {
      if (item['MachineID'] != null) {
        machineIds.add(item['MachineID'].toString());
      }
    }

    return machineIds.isNotEmpty ? machineIds.length : 30;
  }

  // Calculate aggregated metrics from API data
  double _calculateAverageOEE() {
    if (oeeData == null || oeeData!['data'] == null) return 0.0;

    List<dynamic> data = oeeData!['data'];
    if (data.isEmpty) return 0.0;

    double total = 0.0;
    int count = 0;

    for (var item in data) {
      if (selectedShift == null || selectedShift == 'All Shifts') {
        if (item['Morning_OEE'] != null) {
          total += item['Morning_OEE'];
          count++;
        }
        if (item['Night_OEE'] != null) {
          total += item['Night_OEE'];
          count++;
        }
      } else {
        if (item['OEE'] != null) {
          total += item['OEE'];
          count++;
        }
      }
    }

    return count > 0 ? total / count : 0.0;
  }

  int _calculateTotalOutput() {
    if (performanceData == null || performanceData!['data'] == null) return 0;

    List<dynamic> data = performanceData!['data'];
    if (data.isEmpty) return 0;

    int total = 0;

    for (var item in data) {
      if (selectedShift == null || selectedShift == 'All Shifts') {
        total += (item['Morning_NGQuantity'] ?? 0) as int;
        total += (item['Night_NGQuantity'] ?? 0) as int;
      } else {
        total += (item['NGQuantity'] ?? 0) as int;
      }
    }

    return total;
  }

  double _calculateAverageUptime() {
    if (availabilityData == null || availabilityData!['data'] == null) return 0.0;

    List<dynamic> data = availabilityData!['data'];
    if (data.isEmpty) return 0.0;

    double total = 0.0;
    int count = 0;

    for (var item in data) {
      if (selectedShift == null || selectedShift == 'All Shifts') {
        if (item['Morning_Availability'] != null) {
          total += item['Morning_Availability'];
          count++;
        }
        if (item['Night_Availability'] != null) {
          total += item['Night_Availability'];
          count++;
        }
      } else {
        if (item['Availability'] != null) {
          total += item['Availability'];
          count++;
        }
      }
    }

    return count > 0 ? total / count : 0.0;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
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
                    height: double.infinity,
                    decoration: BoxDecoration(
                      color: FlutterFlowTheme.of(context).primaryBackground,
                      image: DecorationImage(
                        fit: BoxFit.cover,
                        image: Image.asset('assets/images/backgroundanimated.gif').image,
                      ),
                    ),
                    child: Stack(
                      children: [
                        Padding(
                          padding: const EdgeInsetsDirectional.fromSTEB(16, 24, 16, 24),
                          child: SingleChildScrollView(
                            physics: const AlwaysScrollableScrollPhysics(),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Breadcrumb Text
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 4),
                                  child: Text(
                                    'Dashboard/ProductionLineKPI',
                                    style: FlutterFlowTheme.of(context).titleLarge.override(
                                          fontFamily: 'Poppins',
                                          color: FlutterFlowTheme.of(context).primaryText,
                                          fontSize: 12,
                                          font: GoogleFonts.poppins(),
                                        ),
                                  ),
                                ),
                                // Page Title
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 24),
                                  child: Text(
                                    'Production Line KPI',
                                    style: FlutterFlowTheme.of(context).headlineMedium.override(
                                          fontFamily: 'Poppins',
                                          font: GoogleFonts.poppins(),
                                        ),
                                  ),
                                ),
                                HeaderWidget(
                                  title: 'SM365 Production Line KPI Dashboard',
                                  subtitle: 'Monitoring performance of ${_calculateTotalMachines()} machines across morning and night shifts',
                                  lastUpdateTime: lastUpdateTime,
                                  initialStartDate: startDate,
                                  initialEndDate: endDate,
                                  onDateRangeChanged: _handleDateRangeChanged,
                                  onApply: () {
                                    _refreshData();
                                  },
                                ),
                                const SizedBox(height: 24),

                                // Filter Controls - Pass current filter values
                                FilterControlsWidget(
                                  initialShift: selectedShift,
                                  initialMachine: selectedMachine,
                                  initialMetric: selectedMetric,
                                  initialStartDate: startDate,
                                  initialEndDate: endDate,
                                  onExportPressed: _handleExportReport,
                                  onShiftChanged: _handleShiftChanged,
                                  onMachineChanged: _handleMachineChanged,
                                  onMetricChanged: _handleMetricChanged,
                                  onDateRangeChanged: _handleDateRangeChanged,
                                ),

                                const SizedBox(height: 24),

                                // KPI Metrics Row (with real data)
                                KpiMetricsWidget(
                                  totalMachines: _calculateTotalMachines(),
                                  averageOee: _calculateAverageOEE(),
                                  totalOutput: _calculateTotalOutput(),
                                  uptime: _calculateAverageUptime(),
                                ),

                                const SizedBox(height: 24),

                                // Charts Grid - Wrap with RepaintBoundary for capture
                                GridView.count(
                                  shrinkWrap: true,
                                  physics: const NeverScrollableScrollPhysics(),
                                  crossAxisCount: responsiveGridColumns(context),
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16,
                                  childAspectRatio:
                                      MediaQuery.sizeOf(context).width <
                                              kBreakpointMedium
                                          ? 4 / 3
                                          : 16 / 9,
                                  children: [
                                    RepaintBoundary(
                                      key: _oeeChartKey,
                                      child: OEEChartWidget(
                                        data: oeeData,
                                        selectedShift: selectedShift,
                                      ),
                                    ),
                                    RepaintBoundary(
                                      key: _outputChartKey,
                                      child: OutputComparisonChartWidget(
                                        data: performanceData,
                                        selectedShift: selectedShift,
                                      ),
                                    ),
                                    RepaintBoundary(
                                      key: _downtimeChartKey,
                                      child: DowntimeAnalysisChartWidget(
                                        data: availabilityData,
                                        selectedShift: selectedShift,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 24),

                                Container(
                                  height: 400,
                                  child: MachinePerformanceRankingWidget(
                                    oeeData: oeeData,
                                    performanceData: performanceData,
                                    availabilityData: availabilityData,
                                    qualityData: qualityData,
                                    selectedShift: selectedShift,
                                  ),
                                ),

                                const SizedBox(height: 24),
                                Padding(
                                  padding: const EdgeInsetsDirectional.fromSTEB(0, 0, 0, 24),
                                  child: Text(
                                    'Machine Detailed Comparison',
                                    style: FlutterFlowTheme.of(context).headlineMedium.override(
                                          fontFamily: 'Poppins',
                                          font: GoogleFonts.poppins(),
                                        ),
                                  ),
                                ),

                                Column(
                                  children: [
                                    // Output Comparison by Machine
                                    RepaintBoundary(
                                      key: _machineOutputChartKey,
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        child: MachineOutputComparisonWidget(
                                          data: performanceData,
                                          selectedShift: selectedShift,
                                        ),
                                      ),
                                    ),

                                    // OEE Comparison by Machine
                                    RepaintBoundary(
                                      key: _machineOeeChartKey,
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        child: MachineOEEComparisonWidget(
                                          data: oeeData,
                                          selectedShift: selectedShift,
                                        ),
                                      ),
                                    ),

                                    // Availability Comparison by Machine
                                    RepaintBoundary(
                                      key: _machineAvailabilityChartKey,
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        child: MachineAvailabilityComparisonWidget(
                                          data: availabilityData,
                                          selectedShift: selectedShift,
                                        ),
                                      ),
                                    ),

                                    // Quality Rate Comparison by Machine
                                    RepaintBoundary(
                                      key: _machineQualityChartKey,
                                      child: Container(
                                        margin: const EdgeInsets.only(bottom: 24),
                                        child: MachineQualityComparisonWidget(
                                          data: qualityData,
                                          selectedShift: selectedShift,
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Loading Overlay
                        if (isLoading)
                          Container(
                            color: Colors.black.withOpacity(0.3),
                            child: const Center(
                              child: Card(
                                child: Padding(
                                  padding: EdgeInsets.all(24.0),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      CircularProgressIndicator(),
                                      SizedBox(height: 16),
                                      Text(
                                        'Loading data...',
                                        style: TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
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
              ),
            ],
          ),
        ),
      ),
    );
  }
}
