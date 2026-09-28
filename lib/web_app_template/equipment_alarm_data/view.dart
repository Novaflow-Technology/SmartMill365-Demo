import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_drop_down.dart';
import 'package:smartmachine365/flutter_flow/flutter_flow_util.dart';
import 'package:smartmachine365/flutter_flow/form_field_controller.dart';
import 'package:smartmachine365/web_app_template/equipment_alarm_data/edit.dart';
import 'package:smartmachine365/web_app_template/equipment_alarm_data/equipment_alarm_data_model.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import 'package:http/http.dart' as http;

class EquipmentAlarmDataView extends StatefulWidget {
  const EquipmentAlarmDataView({super.key});

  @override
  State<EquipmentAlarmDataView> createState() => _EquipmentAlarmDataViewState();
}

class _EquipmentAlarmDataViewState extends State<EquipmentAlarmDataView> {
  List<dynamic> dataList = [];
  List<dynamic> originalData = [];
  int currentDataPage = 0;
  final int dataListPerPage = 13;
  TextEditingController dataSearchController = TextEditingController();
  String dataFilterController = 'Work Order ID';
  String lastUpdateTime = '';
  bool _isLoading = false;
  final ScrollController _scrollController = ScrollController();
  late EquipmentAlarmDataModel _model;
  String? selectedProductionAreaId;
  List<Map<String, String>> productionAreaList = [];
  List<Map<String, String>> statusList = [];

  @override
  void initState() {
    super.initState();

    _model = createModel(context, () => EquipmentAlarmDataModel());
    fetchProductionAreas();
    fetchStatuses();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _model.dispose();

        dataSearchController.dispose();
    super.dispose();
  }

  Future<void> fetchData() async {
    setState(() {
      _isLoading = true;
    });
    try {
      // Define API URL
      String apiUrl =
          "https://us-central1-smartmill365-demo.cloudfunctions.net/api/equipmentAlarmData/$selectedProductionAreaId";

      // Send GET request
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        // Parse JSON response
        final List<dynamic> fetchedData = json.decode(response.body);

        setState(() {
          dataList = fetchedData;
          originalData = List.from(dataList);
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        });
      } else {
        throw Exception("Failed to fetch data list: ${response.statusCode}");
      }
    } catch (e) {
      print('Error fetching data list: $e');
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

  void searchData(String query) {
    final results = originalData.where((data) {
      final searchLower = query.toLowerCase();
      switch (dataFilterController) {
        case 'Work Order ID':
          return data['workOrder'].toLowerCase().contains(searchLower);
        default:
          return false;
      }
    }).toList();
    setState(() {
      dataList = results;
    });
  }

  List<DataRow> _createDataRows() {
    return dataList
        .skip(currentDataPage * dataListPerPage)
        .take(dataListPerPage)
        .map(
          (data) => DataRow(
            cells: [
              DataCell(
                Text(
                  getDateFormat(data['triggerDate']),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  data['workOrder'] ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  data['equipment'],
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  data['operator'] ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  getDescription(data['description']),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  getDateFormat(data['resolveDate'] ?? ''),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Text(
                  data['duration'] ?? '',
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              DataCell(
                Center(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.edit),
                        onPressed: () {
                          _showEditDataDialog(context, data['id']);
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        )
        .toList();
  }

  void _showEditDataDialog(BuildContext context, int id) {
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (BuildContext context) {
        final data = dataList.firstWhere((data) => data['id'] == id);

        return EditDataDialog(
          id: id,
          initialTriggerDate: data['triggerDate'],
          initialWorkOrder: data['workOrder'] ?? '',
          initialOperator: data['operator'] ?? '',
          initialResolveDate: data['resolveDate'] ?? '',
          onDataEdited: fetchData,
        );
      },
    );
  }

  Future<void> fetchProductionAreas() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
          Uri.parse("https://us-central1-smartmill365-demo.cloudfunctions.net/api/productionAreas"));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final areas = data
            .map((item) => {
                  'id': item['id'] as String,
                  'name': item['name'] as String,
                })
            .toList();
        setState(() {
          productionAreaList = [
            ...areas,
          ];
          selectedProductionAreaId = productionAreaList[0]['name'];
        });
        print(
            "Successfully get production area from: https://us-central1-smartmill365-demo.cloudfunctions.net/api/productionAreas");

        _model.dropDownValueController?.value = selectedProductionAreaId;

        fetchData();
      } else {
        throw Exception(
            'Failed to load production areas (status ${response.statusCode})');
      }
    } catch (e) {
      print('Error fetching production areas from API: $e');
    }
    setState(() => _isLoading = false);
  }

  String getDateFormat(String date) {
    try {
      DateTime parsedDate = DateTime.parse(date);

      return DateFormat('dd/MM/yyyy HH:mm:ss').format(parsedDate);
    } catch (_) {
      return '';
    }
  }

  Future<void> fetchStatuses() async {
    setState(() => _isLoading = true);
    try {
      final response = await http.get(
          Uri.parse("https://us-central1-smartmill365-demo.cloudfunctions.net/api/equipment/statuses"));

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final statuses = data
            .map((item) => {
                  'id': item['id'] as String,
                  'description': item['description'] as String,
                })
            .toList();
        setState(() {
          statusList = [
            ...statuses,
          ];
        });
        print(
            "Successfully get status from: https://us-central1-smartmill365-demo.cloudfunctions.net/api/equipment/statuses");
      } else {
        throw Exception(
            'Failed to load statuses (status ${response.statusCode})');
      }
    } catch (e) {
      print('Error fetching statuses from API: $e');
    }
    setState(() => _isLoading = false);
  }

  String getDescription(String id) {
    try {
      List<String> subs = id.split('_');
      String sub1 = '';
      String sub2 = '';
      String? sub1Num;
      String? sub2Num;

      if (subs.length == 4) {
        sub1 = '${subs[0]}_${subs[1]}';
        sub2 = '${subs[2]}_${subs[3]}';
      } else if (subs.length == 3) {
        sub1 = subs[0];
        sub2 = '${subs[1]}_${subs[2]}';
      }

      RegExpMatch? sub1Match = RegExp(r'\d+').firstMatch(sub1);
      if (sub1Match != null) {
        sub1Num = sub1Match.group(0);
        sub1 = sub1.replaceFirst(RegExp(r'\d+'), '');
      }

      RegExpMatch? sub2Match = RegExp(r'\d+').firstMatch(sub2);
      if (sub2Match != null) {
        sub2Num = sub2Match.group(0);
        sub2 = sub2.replaceFirst(RegExp(r'\d+'), '');
      }

      String? desc1 = statusList.firstWhere(
          (status) => status['id'] == '${sub1}_xxx',
          orElse: () => {'description': sub1})['description'];

      String? desc2 = statusList.firstWhere(
          (status) => status['id'] == 'xxx_$sub2',
          orElse: () => {'description': sub2})['description'];

      if (sub1Num != null) {
        desc1 = "$desc1 $sub1Num";
      }
      if (sub2Num != null) {
        desc2 = "$desc2 $sub2Num";
      }

      return '$desc1, $desc2';
    } catch (_) {
      return id;
    }
  }

  @override
  Widget build(BuildContext context) {
    int totalPages =
        (dataList.isNotEmpty) ? (dataList.length / dataListPerPage).ceil() : 0;
    if (currentDataPage >= totalPages) {
      currentDataPage = totalPages > 0 ? totalPages - 1 : 0;
    }

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
                          'Dashboard/EquipmentAlarmData',
                          style: TextStyle(
                            fontSize: 12,
                            color: Colors.grey.shade300,
                          ),
                        ),
                        const Text(
                          'Equipment Alarm Data',
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
                            onPressed: fetchData,
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
                              FormFieldController<String>(''),
                          options: productionAreaList
                              .map((area) => area['name'] as String)
                              .toList(),
                          onChanged: (val) {
                            setState(() {
                              selectedProductionAreaId =
                                  productionAreaList.firstWhere(
                                      (area) => area['name'] == val)['name'];
                            });
                            fetchData();
                          },
                          width: 284,
                          height: 40,
                          textStyle:
                              FlutterFlowTheme.of(context).bodyMedium.override(
                                    fontFamily: 'Poppins',
                                    fontWeight: FontWeight.w600,
                                    font: GoogleFonts.poppins(),
                                  ),
                          hintText: 'Select Machine',
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
                            controller: dataSearchController,
                            decoration: InputDecoration(
                              hintText: 'Search by $dataFilterController...',
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
                                searchData(value);
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
                            value: dataFilterController,
                            items: [
                              'Work Order ID',
                            ].map((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value),
                              );
                            }).toList(),
                            onChanged: (String? newValue) {
                              setState(() {
                                dataFilterController = newValue!;
                              });
                              searchData(dataSearchController.text);
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
                padding:
                    const EdgeInsets.only(left: 20.0, right: 20.0, top: 21.0),
                child: Container(
                  width: double.infinity,
                  decoration: BoxDecoration(
                    color: Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: dataList.isNotEmpty
                      ? Scrollbar(
                          thumbVisibility: true,
                          controller: _scrollController,
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            controller: _scrollController,
                            child: DataTable(
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
                              columns: const [
                                DataColumn(
                                  label: Text(
                                    'Alarm Trigger Date',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Work Order ID',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Machine ID',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Operator',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Alarm Description Status',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Alarm Resolved Date',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                  label: Text(
                                    'Spending Duration',
                                    style:
                                        TextStyle(fontWeight: FontWeight.bold),
                                    softWrap: true,
                                    overflow: TextOverflow.visible,
                                    maxLines: 2,
                                  ),
                                ),
                                DataColumn(
                                    label: Text('Action',
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold))),
                              ],
                              rows: _createDataRows(),
                            ),
                          ),
                        )
                      : const Center(
                          child: Text(
                            'No data found.',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey,
                            ),
                          ),
                        ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(
                    top: 35, left: 50.0, right: 50.0, bottom: 15),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    ElevatedButton(
                      onPressed: currentDataPage > 0
                          ? () {
                              setState(() {
                                currentDataPage--;
                              });
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        fixedSize: const Size(110, 30),
                        backgroundColor: currentDataPage < totalPages - 1
                            ? Colors.grey[300]
                            : Colors.grey[200],
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Previous'),
                    ),
                    Visibility(
                      visible: totalPages > 0,
                      child: Row(
                        children: [
                          const SizedBox(width: 5),
                          Padding(
                            padding:
                                const EdgeInsets.only(left: 5.0, right: 5.0),
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  currentDataPage = 0;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: currentDataPage == 0
                                    ? const Color.fromARGB(255, 122, 34, 236)
                                    : Colors.grey[300],
                                foregroundColor: currentDataPage == 0
                                    ? Colors.white
                                    : Colors.black,
                              ),
                              child: const Text('${0 + 1}'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Visibility(
                      visible: totalPages > 1,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(width: 5),
                          Padding(
                            padding:
                                const EdgeInsets.only(left: 5.0, right: 5.0),
                            child: ElevatedButton(
                              onPressed: () {
                                setState(() {
                                  currentDataPage = totalPages - 1;
                                });
                              },
                              style: ElevatedButton.styleFrom(
                                backgroundColor: currentDataPage ==
                                        totalPages - 1
                                    ? const Color.fromARGB(255, 122, 34, 236)
                                    : Colors.grey[300],
                                foregroundColor:
                                    currentDataPage == totalPages - 1
                                        ? Colors.white
                                        : Colors.black,
                              ),
                              child: Text('${(totalPages - 1) + 1}'),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 5),
                    ElevatedButton(
                      onPressed: currentDataPage < totalPages - 1
                          ? () {
                              setState(() {
                                currentDataPage++;
                              });
                            }
                          : null,
                      style: ElevatedButton.styleFrom(
                        fixedSize: const Size(110, 30),
                        backgroundColor: currentDataPage < totalPages - 1
                            ? Colors.grey[300]
                            : Colors.grey[200],
                        foregroundColor: Colors.black,
                      ),
                      child: const Text('Next'),
                    ),
                  ],
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
