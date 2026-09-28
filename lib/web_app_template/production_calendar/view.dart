import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_drop_down.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/flutter_flow/form_field_controller.dart';
import 'package:smartmachine365/web_app_template/production_calendar/production_calendar_model.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import 'package:http/http.dart' as http;

class ProductionCalendarView extends StatefulWidget {
  const ProductionCalendarView({super.key});

  @override
  State<ProductionCalendarView> createState() => _ProductionCalendarViewState();
}

class _ProductionCalendarViewState extends State<ProductionCalendarView> {
  List<dynamic> areaList = [];
  List<dynamic> originalArea = [];
  TextEditingController areaSearchController = TextEditingController();
  String areaFilterController = 'WO';
  String lastUpdateTime = '';
  bool _isLoading = false;
  final ScrollController _scrollController = ScrollController();
  late ProductionCalendarModel _model;
  String? selectedInterval;
  List<String> intervalList = ['Daily', 'Weekly', 'Monthly'];

  @override
  void initState() {
    super.initState();

    _model = createModel(context, () => ProductionCalendarModel());

    setState(() {
      selectedInterval = intervalList[0];
    });

    fetchArea();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _model.dispose();

        areaSearchController.dispose();
    super.dispose();
  }

  Future<void> fetchArea() async {
    setState(() {
      _isLoading = true;
    });
    try {
      // Define API URL
      String apiUrl =
          "https://us-central1-smartmill365-demo.cloudfunctions.net/api/productionAreas/equipments/workOrders";

      // Send GET request
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        // Parse JSON response
        final List<dynamic> fetchedArea = json.decode(response.body);

        setState(() {
          areaList = fetchedArea;
          originalArea = List.from(areaList);
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        });
      } else {
        throw Exception("Failed to fetch area list: ${response.statusCode}");
      }
    } catch (e) {
      print('Error fetching area list: $e');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '$e',
            style: const TextStyle(color: Colors.red),
          ),
          backgroundColor: Colors.black,
          duration: const Duration(seconds: 2),
        ),
      );
    } finally {
      setState(() {
        _isLoading = false;
      });
    }
  }

  void searchArea(String query) {
    final results = originalArea.where((area) {
      final searchLower = query.toLowerCase();
      switch (areaFilterController) {
        case 'WO':
          // Collect all workOrders across equipments in this area
          List<String> allWorkOrders = [];
          for (var equipment in area['equipments']) {
            if (equipment['work_id'] != null) {
              allWorkOrders.addAll(List<String>.from(equipment['work_id']));
            }
          }
          final workOrderName = allWorkOrders.join(', ').toLowerCase();
          return workOrderName.contains(searchLower);
        default:
          return false;
      }
    }).toList();
    setState(() {
      areaList = results;
    });
  }

  String getShiftBreak(int i) {
    switch (i) {
      case 0:
        {
          return 'Night Shift\nLunch Break';
        }
      case 5:
        {
          return 'Night Shift\nTea Break';
        }
      case 12:
        {
          return 'Morning Shift\nLunch Break';
        }
      case 16:
        {
          return 'Morning Shift\nTea Break';
        }
      default:
        {
          return '';
        }
    }
  }

  List<Widget> getDailyCells(dynamic area) {
    List<Widget> cells = [];
    DateTime now = DateTime.now();
    bool idDisplayed = false;

    // Collect all workOrders across equipments in this area
    List<dynamic> allWorkOrders = [];
    for (var equipment in area['equipments']) {
      if (equipment['workOrders'] != null) {
        allWorkOrders.addAll(equipment['workOrders']);
      }
    }

    for (int i = 0; i < 24; i++) {
      DateTime iDate = DateTime(now.year, now.month, now.day, i);
      bool isInRange = false;
      bool showId = false;
      dynamic w;

      for (var work in allWorkOrders) {
        DateTime start = DateTime.parse(work['planStartDate']);
        DateTime end = DateTime.parse(work['planEndDate']);

        // Must be same day
        if ((iDate.isAfter(start) && iDate.isBefore(end)) ||
            iDate.isAtSameMomentAs(start) ||
            iDate.isAtSameMomentAs(end)) {
          isInRange = true;
          w = work;
          break;
        }
      }

      if (isInRange && !idDisplayed) {
        showId = true;
        idDisplayed = true;
      }

      cells.add(TableCell(
        child: Container(
          color: isInRange
              ? getCellColor(w['status'])
              : getShiftBreak(i).isNotEmpty
                  ? const Color.fromARGB(255, 33, 150, 243).withOpacity(0.3)
                  : Colors.transparent,
          padding: const EdgeInsets.all(8.0),
          child: Text(showId ? w['id'] : ''),
        ),
      ));
    }

    return cells;
  }

  List<Widget> getDayCells(dynamic area, int startDay, int endDay) {
    List<Widget> cells = [];
    DateTime now = DateTime.now();
    bool idDisplayed = false;

    // Collect all workOrders across equipments in this area
    List<dynamic> allWorkOrders = [];
    for (var equipment in area['equipments']) {
      if (equipment['workOrders'] != null) {
        allWorkOrders.addAll(equipment['workOrders']);
      }
    }

    for (int i = startDay; i <= endDay; i++) {
      DateTime iDate = DateTime(now.year, now.month, i);
      bool isInRange = false;
      bool showId = false;
      dynamic w;

      for (var work in allWorkOrders) {
        DateTime start = DateTime.parse(work['planStartDate']);
        DateTime startDate = DateTime(start.year, start.month, start.day);
        DateTime end = DateTime.parse(work['planEndDate']);
        DateTime endDate = DateTime(end.year, end.month, end.day);

        // Must be same day
        if ((iDate.isAfter(startDate) && iDate.isBefore(endDate)) ||
            iDate.isAtSameMomentAs(startDate) ||
            iDate.isAtSameMomentAs(endDate)) {
          isInRange = true;
          w = work;
          break;
        }
      }

      if (isInRange && !idDisplayed) {
        showId = true;
        idDisplayed = true;
      }

      cells.add(TableCell(
        child: Container(
          color: isInRange ? getCellColor(w['status']) : Colors.transparent,
          padding: const EdgeInsets.all(8.0),
          child: Text(showId ? w['id'] : ''),
        ),
      ));
    }

    return cells;
  }

  List<TableRow> get rows {
    switch (selectedInterval) {
      case 'Daily':
        {
          return [
            TableRow(
              children: [
                const TableCell(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text('Machine'),
                  ),
                ),
                for (int i = 0; i < 24; i++)
                  TableCell(
                    child: Container(
                      padding: const EdgeInsets.all(8.0),
                      color: getShiftBreak(i).isNotEmpty
                          ? const Color.fromARGB(255, 33, 150, 243)
                              .withOpacity(0.3)
                          : Colors.transparent,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${i.toString().padLeft(2, '0')}:00:00'),
                          Text(getShiftBreak(i)),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
            ...areaList.map((area) => TableRow(
                  children: [
                    TableCell(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(area['name'] ?? ''),
                      ),
                    ),
                    ...getDailyCells(area),
                  ],
                )),
          ];
        }
      case 'Weekly':
        {
          DateTime today = DateTime.now();
          int weekday = today.weekday;
          DateTime start = today.subtract(Duration(days: weekday % 7));
          DateTime end = today.add(Duration(days: 6 - (weekday % 7)));

          return [
            TableRow(
              children: [
                const TableCell(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text('Machine'),
                  ),
                ),
                for (int i = start.day; i <= end.day; i++)
                  TableCell(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(DateFormat('dd-MM-yyyy')
                          .format(DateTime(today.year, today.month, i))),
                    ),
                  ),
              ],
            ),
            ...areaList.map((area) => TableRow(
                  children: [
                    TableCell(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(area['name'] ?? ''),
                      ),
                    ),
                    ...getDayCells(area, start.day, end.day),
                  ],
                )),
          ];
        }
      case 'Monthly':
        {
          DateTime today = DateTime.now();
          DateTime first = DateTime(today.year, today.month, 1);
          DateTime last = DateTime(today.year, today.month + 1, 0);

          return [
            TableRow(
              children: [
                const TableCell(
                  child: Padding(
                    padding: EdgeInsets.all(8.0),
                    child: Text('Machine'),
                  ),
                ),
                for (int i = first.day; i <= last.day; i++)
                  TableCell(
                    child: Padding(
                      padding: const EdgeInsets.all(8.0),
                      child: Text(DateFormat('dd-MM-yyyy')
                          .format(DateTime(today.year, today.month, i))),
                    ),
                  ),
              ],
            ),
            ...areaList.map((area) => TableRow(
                  children: [
                    TableCell(
                      child: Padding(
                        padding: const EdgeInsets.all(8.0),
                        child: Text(area['name'] ?? ''),
                      ),
                    ),
                    ...getDayCells(area, first.day, last.day),
                  ],
                )),
          ];
        }
      default:
        {
          return [];
        }
    }
  }

  Color getCellColor(int status) {
    switch (status) {
      case 0:
        {
          return const Color.fromARGB(255, 255, 72, 59).withOpacity(0.8);
        }
      case 1:
        {
          return const Color.fromARGB(255, 255, 165, 0).withOpacity(0.8);
        }
      case 2:
        {
          return const Color.fromARGB(255, 102, 235, 106).withOpacity(0.8);
        }
      default:
        {
          return Colors.transparent;
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding:
                    const EdgeInsets.only(top: 30.0, left: 20.0, right: 20.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Dashboard/ProductionCalendar',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade300,
                          ),
                        ),
                        const Text(
                          'Production Calendar',
                          style: TextStyle(
                              fontSize: 24,
                              color: Colors.white,
                              fontWeight: FontWeight.bold),
                        ),
                      ],
                    ),
                    const SizedBox(width: 10),
                    Padding(
                      padding: const EdgeInsets.only(right: 10.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          RichText(
                            text: TextSpan(
                              children: [
                                const TextSpan(
                                  text: 'Last Update: ',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                TextSpan(
                                  text: lastUpdateTime,
                                  style: const TextStyle(color: Colors.white),
                                ),
                              ],
                            ),
                          ),
                          TextButton.icon(
                            onPressed: fetchArea,
                            icon: const Icon(Icons.refresh,
                                size: 16, color: Colors.white),
                            label: const Text('Refresh',
                                style: TextStyle(color: Colors.white)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(vertical: 5),
                              backgroundColor: Colors.transparent,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.only(left: 20.0, right: 20.0, top: 10.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.start,
                      children: <Widget>[
                        FlutterFlowDropDown<String>(
                          controller: _model.dropDownValueController ??=
                              FormFieldController<String>(selectedInterval),
                          options: intervalList,
                          onChanged: (val) {
                            setState(() {
                              selectedInterval = val;
                            });
                            fetchArea();
                          },
                          width: 284,
                          height: 40,
                          textStyle:
                              FlutterFlowTheme.of(context).bodyMedium.override(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w600,
                                    font: GoogleFonts.poppins(),
                                  ),
                          hintText: 'Select Interval',
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: FlutterFlowTheme.of(context).primaryText,
                            size: 30,
                          ),
                          fillColor: const Color(0xBB31ECFC),
                          elevation: 2,
                          borderColor: FlutterFlowTheme.of(context).primary,
                          borderWidth: 1,
                          borderRadius: 10,
                          margin: const EdgeInsetsDirectional.fromSTEB(
                              12, 0, 12, 0),
                          hidesUnderline: true,
                          value: null,
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: MediaQuery.of(context).size.width * 0.3,
                          height: 30,
                          child: TextField(
                            controller: areaSearchController,
                            decoration: InputDecoration(
                              hintText: 'Search by $areaFilterController...',
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10.0),
                                borderSide: BorderSide.none,
                              ),
                              prefixIcon: const Icon(
                                Icons.search,
                                color: Colors.grey,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  vertical: 5.0, horizontal: 10.0),
                            ),
                            onChanged: (value) {
                              Timer(const Duration(milliseconds: 300), () {
                                searchArea(value);
                              });
                            },
                          ),
                        ),
                        const SizedBox(width: 10),
                        SizedBox(
                          width: 185,
                          height: 30,
                          child: DropdownButtonFormField<String>(
                            decoration: InputDecoration(
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(10.0),
                                borderSide: BorderSide.none,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  vertical: 5.0, horizontal: 10.0),
                            ),
                            value: areaFilterController,
                            items: [
                              'WO',
                            ].map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: (String? newValue) {
                              setState(() {
                                areaFilterController = newValue!;
                              });
                              searchArea(areaSearchController.text);
                            },
                            icon: const Icon(
                              Icons.arrow_drop_down,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                    left: 20.0, right: 20.0, top: 21.0, bottom: 15),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: areaList.isNotEmpty
                      ? Scrollbar(
                          thumbVisibility: true,
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            controller: _scrollController,
                            child: Table(
                              border: TableBorder(
                                borderRadius: BorderRadius.circular(10),
                                top: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                                horizontalInside: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                                verticalInside: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                                bottom: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                                left: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                                right: BorderSide(
                                  width: 0.5,
                                  color: FlutterFlowTheme.of(context).primary,
                                ),
                              ),
                              children: rows,
                              defaultColumnWidth: const IntrinsicColumnWidth(),
                              defaultVerticalAlignment:
                                  TableCellVerticalAlignment.intrinsicHeight,
                            ),
                          ),
                        )
                      : const Center(
                          child: Text(
                            'No area found.',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ),
        if (_isLoading)
          Positioned.fill(
            child: Container(
              color: Colors.black.withOpacity(0.5),
              child: const Center(
                child: CircularProgressIndicator(
                  color: Colors.black,
                ),
              ),
            ),
          ),
      ],
    );
  }
}
