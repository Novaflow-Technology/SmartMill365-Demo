import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:formz/formz.dart';
import 'package:intl/intl.dart';
import 'package:smartmachine365/web_app_template/work_order_overview/cubits/cubits.dart';
import 'package:smartmachine365/web_app_template/work_order_overview/firestore_service.dart';
import 'package:smartmachine365/web_app_template/work_order_overview/widgets/widgets.dart';
import 'package:smartmachine365/web_app_template/production_task_work_station/production_task_card_widget.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import 'package:http/http.dart' as http;

Map<String, dynamic> normalizeProductionTask(Map<String, dynamic> item) {
  return {
    'id': item['ID']?.toString() ?? '',
    'machineId': item['MachineID']?.toString() ?? '',
    'work_id': item['WorkOrderID']?.toString() ?? '',
    'plannedStartDate': item['Planned_Start_Date']?.toString() ?? '',
    'plannedEndDate': item['Planned_End_Date']?.toString() ?? '',
    'plannedQuantity': item['Planned_Quantity']?.toString() ?? '',
    'productId': item['ProductID']?.toString() ?? 'N/A',
    'processDescriptionNote': item['Process_Description_Note']?.toString() ?? 'N/A',
    'processRouting': item['Process_Routing']?.toString() ?? 'N/A',
    'actualStartDate': item['CheckIn_Timestamp']?.toString() ?? '',
    'actualQuantity': item['Total_Good_Quantity']?.toString() ?? '',
    'remainingQuantity': item['Remaining_Production_Quantity']?.toString() ?? '',
    'ngQuantity': item['Total_NG_Quantity']?.toString() ?? '',
    'estimatedEndDate': item['CheckOut_Timestamp']?.toString() ?? '',
    'taskStatus': item['Status']?.toString() ?? 'N/A',
    'taskUrgency': item['Urgency']?.toString() ?? 'Normal',
    'taskProgress': item['Progress']?.toString() ?? 'On Track',
  };
}

class Debouncer {
  final int milliseconds;
  Timer? _timer;

  Debouncer({required this.milliseconds});

  void run(VoidCallback action) {
    _timer?.cancel();
    _timer = Timer(Duration(milliseconds: milliseconds), action);
  }
}


class ProductionTaskWorkStationView extends StatefulWidget {
  final String companyID;
  final String userRole;

  const ProductionTaskWorkStationView(
      {super.key, required this.companyID, required this.userRole});

  @override
  _WordOrderViewState createState() => _WordOrderViewState();
}

class _WordOrderViewState extends State<ProductionTaskWorkStationView> {
  @override
  void initState() {
    super.initState();
    fetchProductionTaskStatus();
  }

  @override
  void dispose() {
    _scrollController.dispose();
        workOrderSearchController.dispose();
    workStationSearchController.dispose();
    super.dispose();
  }

  final ScrollController _scrollController = ScrollController();
  final workStationController = TextEditingController();
  final productController = TextEditingController();
  final classController = TextEditingController();
  final dueDateController = TextEditingController();
  final queryController = TextEditingController();
  final machineController = TextEditingController();

  static const String _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api'
  ;

  List<Map<String, dynamic>> productionTaskTicketData = [];
  List<Map<String, dynamic>> productionTaskTicketList = [];
  List<Map<String, dynamic>> originalProductionTaskTicketList = [];
  List<Map<String, dynamic>> filteredTaskList = [];  
  int currentWorkOrderPage = 0;
  final int workOrdersPerPage = 13;
  TextEditingController workOrderSearchController = TextEditingController();
  TextEditingController workStationSearchController = TextEditingController();
  String searchCategoryController = ["Product", "Class"][0];
  String lastUpdateTime = '';
  bool _isLoading = false;
  Timer? _debounce;
  final _debouncer = Debouncer(milliseconds: 500);
  Map<String, bool> statusFilters = {
    'Pending': false,
    'In Progress': false,
    'Pause': false,
    'Overdue': false,
    'Completed': false,
  };
  Map<String, bool> classFilters = {
    'High': false,
    'Normal': false,
  };


  String? selectedSortOption;
    final Map<String, GlobalKey<_WordOrderViewState>> _childKeys = {};
  bool _showProgressIndicator = false;
  bool isLoading1 = true;
  bool isLoading = true;
  bool isFilterActive = false;

  Future<void> fetchProductionTaskStatus() async {
    setState(() => isLoading = true);
    try {
      const url = '$_baseUrl/productionTask/all-status';
      print('Sending GET request to: $url');
      final response = await http
          .get(
            Uri.parse(url),
            headers: {'Content-Type': 'application/json'},
            // body: jsonEncode(requestBody),
          )
          .timeout(const Duration(seconds: 10));

      print('Response status: ${response.statusCode}');
      print('Response body: ${response.body}');
      print('Response headers: ${response.headers}');
      print("STEP 1: Response received");

      if (response.statusCode == 200) {
        final List<dynamic> data = jsonDecode(response.body);

        setState(() {
          productionTaskTicketData = data.map((item) => {
                'id': item['ID']?.toString(),
                'machineId': item['MachineID']?.toString(),
                'work_id': item['WorkOrderID']?.toString(),
                'plannedStartDate': item['Planned_Start_Date']?.toString() ,
                'plannedEndDate': item['Planned_End_Date']?.toString(),
                'plannedQuantity': item['Planned_Quantity']?.toString(),
                'productId': item['ProductID']?.toString() ?? 'N/A',
                'processDescriptionNote': item['Process_Description_Note']?.toString() ?? 'N/A',
                'processRouting': item['Process_Routing']?.toString() ?? 'N/A',
                'actualStartDate': item['CheckIn_Timestamp']?.toString(),
                'actualQuantity': item['Total_Good_Quantity']?.toString(),
                'remainingQuantity': item['Remaining_Production_Quantity']?.toString(),
                'ngQuantity': item['Total_NG_Quantity']?.toString(),
                'estimatedEndDate': item['CheckOut_Timestamp']?.toString(),
                'taskStatus': item['Status']?.toString() ?? 'N/A',
                'taskUrgency': item['Urgency']?.toString() ?? 'Normal',
                'taskProgress': item['Progress']?.toString() ?? 'On Track',
          }).toList();
          isLoading = false;
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
          productionTaskTicketList = List.from(productionTaskTicketData); // <-- add this line
          print('Processed ${productionTaskTicketList.length} production task entries');
        });
        // updateRunning();
      } else {
        print('Failed to fetch production task status: ${response.statusCode}');
        setState(() {
          // apiError = true;
          // apiErrorMessage = 'Failed to fetch equipment status (Error ${response.statusCode}, Body: ${response.body}).';
          productionTaskTicketData.clear();
          for (var equipment in productionTaskTicketData) {
            final rawId = equipment['ID'];
            final parent = equipment['parent'];
            productionTaskTicketData.add({
              'id': rawId,
              'parent': parent,
              'status': {
                'ID': '',
                'MachineID': '',
                'WorkOrderID': '',
                'parent': parent ?? '',
                'Planned_Start_Date': '',
                'Planned_End_Date': '',
                'Planned_Quantity': 0,
                'ProductID': '',
                'Process_Description_Note': '',
                'CheckIn_Timestamp': '',
                'Total_Good_Quantity': 0,
                'Remaining_Production_Quantity': 0,
                'Total_NG_Quantity': 0,
                'CheckOut_Timestamp': '',
                'Status': '',
                "Urgency": "Normal",
                "Progress": "On Track",
              }
            });
          }
          productionTaskTicketList = List.from(productionTaskTicketData); // <-- add this line
          isLoading = false;
          lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
        });
        // Future.delayed(const Duration(seconds: 10), () {
        //   if (apiError) fetchProductionTaskStatus();
        // });
        // updateRunning();
      }
    } catch (e) {
      print('Error fetching production task status: $e');
      setState(() {
        // apiError = true;
        // apiErrorMessage = 'Error fetching equipment status: $e.';
        productionTaskTicketData.clear();
        for (var equipment in productionTaskTicketList) {
          final rawId = equipment['ID'];
          final parent = equipment['parent'];
          productionTaskTicketData.add({
            'id': rawId,
            'parent': parent,
            'status': {
              'ID': '',
              'MachineID': '',
              'WorkOrderID': '',
              'parent': parent ?? '',
              'Planned_Start_Date': '',
              'Planned_End_Date': '',
              'Planned_Quantity': 0,
              'ProductID': '',
              'Process_Description_Note': '',
              'CheckIn_Timestamp': '',
              'Total_Good_Quantity': 0,
              'Remaining_Production_Quantity': 0,
              'Total_NG_Quantity': 0,
              'CheckOut_Timestamp': '',
              'Status': '',
              "Urgency": "Normal",
              "Progress": "On Track",
            }
          });
        }
        productionTaskTicketList = List.from(productionTaskTicketData); // <-- add this line
        isLoading = false;
        lastUpdateTime = DateTime.now().toLocal().toString().substring(0, 19);
      });
      // Future.delayed(const Duration(seconds: 10), () {
      //   if (apiError) fetchProductionTaskStatus();
      // });
      // updateRunning();
    }
  }
  

  Future<void> searchMachine(String keyword) async {
  final url = Uri.parse('$_baseUrl/productionTask/searchMachine?q=$keyword');
  print('Sending GET request to: $url');
  if (keyword.isEmpty) {
    // Just reload the full data
    await fetchProductionTaskStatus();
    setState(() {
      filteredTaskList.clear();
      isFilterActive = false; // <-- Reset filter state
    });
    return;
  }

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List data = jsonDecode(response.body);
      print('Search results: $data');
      setState(() {
        filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
        isFilterActive = true;
      });
    } else {
      print('Search failed: ${response.statusCode}');
    }
  } catch (e) {
    print('Error fetching search results: $e');
  }
}

Future<void> searchProduct(String keyword) async {
  final url = Uri.parse('$_baseUrl/productionTask/searchProduct?q=$keyword');
  print('Sending GET request to: $url');

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      setState(() {
        filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
        isFilterActive = true;
      });
    }else {
      print('Search failed: ${response.statusCode}');
    }
  } catch (e) {
    print('Error fetching search results: $e');
  }
}

// Future<void> filterClass(String keyword) async {
//   final url = Uri.parse('$_baseUrl/productionTask/filter?q=$keyword');
//   print('Sending GET request to: $url');

//   try {
//     final response = await http.get(url);
//     if (response.statusCode == 200) {
//       final List<dynamic> data = jsonDecode(response.body);
//       setState(() {
//         filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
//       });
//     } else {
//       print('Search failed: ${response.statusCode}');
//     }
//   } catch (e) {
//     print('Error fetching search results: $e');
//   }
// }

// Future<void> searchDue(String keyword) async {
//   final url = Uri.parse('$_baseUrl/productionTask/searchMachine?q=$keyword');
//   print('Sending GET request to: $url');

//   try {
//     final response = await http.get(url);
//     if (response.statusCode == 200) {
//       final List<dynamic> data = jsonDecode(response.body);
//       setState(() {
//         filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
//       });
//     } else {
//       print('Search failed: ${response.statusCode}');
//     }
//   } catch (e) {
//     print('Error fetching search results: $e');
//   }
// }

Future<void> searchQuery(String keyword) async {
  final url = Uri.parse('$_baseUrl/productionTask/searchMachine?q=$keyword');
  print('Sending GET request to: $url');

  try {
    final response = await http.get(url);
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      setState(() {
        filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
        isFilterActive = true;
      });
    } else {
      print('Search failed: ${response.statusCode}');
    }
  } catch (e) {
    print('Error fetching search results: $e');
  }
}

Future<void> applyFilters([_]) async {
  // Get selected status filters
  final selectedStatuses = statusFilters.entries
      .where((e) => e.value)
      .map((e) => e.key)
      .join(',');

  // Get selected class filters
  final selectedClasses = classFilters.entries
      .where((e) => e.value)
      .map((e) => e.key)
      .join(',');

  // Get due date
  final dueDate = dueDateController.text;

  final queryParameters = {
    if (selectedStatuses.isNotEmpty) 'status': selectedStatuses,
    if (selectedClasses.isNotEmpty) 'class': selectedClasses,
    if (dueDate.isNotEmpty) 'due': dueDate,
  };

  final uri = Uri.parse('$_baseUrl/productionTask/filter')
    .replace(queryParameters: queryParameters);

  // Debug: log the URI being used
  print('Sending GET request to: $uri');

  try {
    final response = await http.get(uri);
    if (response.statusCode == 200) {
      final List<dynamic> data = jsonDecode(response.body);
      setState(() {
        filteredTaskList = data.map<Map<String, dynamic>>((item) => normalizeProductionTask(item)).toList();
        isFilterActive = true;
      });
    } else {
      print('Filter failed: ${response.statusCode}');
    }
  } catch (e) {
    print('Error applying filters: $e');
  }
}



  String getDateFormat(String date) {
    try {
      DateTime parsedDate = DateTime.parse(date);

      return DateFormat('yyyy-MM-dd HH:mm').format(parsedDate);
    } catch (_) {
      return '';
    }
  }

  int getStatus({required String plan, required String actual}) {
    try {
      DateTime planDate = DateTime.parse(plan);
      DateTime actualDate = DateTime.parse(actual);

      return actualDate.compareTo(planDate);
    } catch (_) {
      return -2;
    }
  }

  String getDateDelay({required String plan, required String actual}) {
    try {
      DateTime planDate = DateTime.parse(plan);
      DateTime actualDate = DateTime.parse(actual);
      int hour = actualDate.difference(planDate).inHours;
      int minute = actualDate.difference(planDate).inMinutes.remainder(60);

      if (hour == 0) {
        return '$minute mins';
      } else if (minute == 0) {
        return '$hour hrs';
      } else {
        return '$hour hrs $minute mins';
      }
    } catch (_) {
      return '';
    }
  }

  String getProductName(String id) {
    try {
      return context
          .read<WorkOrderCubit>()
          .state
          .productList
          .firstWhere((product) => product['id'] == id)['name'];
    } catch (_) {
      return id;
    }
  }

  Widget buildLabeledField({
  required String searchLabel,
  required String searchHintText,
  required TextEditingController controller,
  required Function(String) onSearchChanged,
  }) {
    return SizedBox(
      width: 250,
      height: 30,
      child: Row(
        children: [
          SizedBox(
            child: Text(
              '$searchLabel:',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                hintText: '$searchHintText',
                hintStyle: const TextStyle(
                  color: Colors.grey, // Set your desired grey color here
                  fontSize: 14,      // Optional: adjust font size if needed
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10.0),
                  borderSide: BorderSide.none,
                ),
                prefixIcon: const Icon(
                  Icons.search,
                  color: const Color.fromARGB(255, 110, 110, 110),
                ),
                
                contentPadding:
                    const EdgeInsets.symmetric(vertical: 5.0, horizontal: 10.0),
                fillColor: Colors.white,
                filled: true,
              ),

               onChanged: (value) {
                if (_debounce?.isActive ?? false) _debounce!.cancel();
                _debounce = Timer(const Duration(milliseconds: 300), () {
                  onSearchChanged(value); 
                });
              }
            ),
          ),
        ],
      ),
    );
  }
Widget buildCheckboxes({
  required String searchLabel,
  required Map<String, bool> filterMap,
  required Function(String) onSearchChanged,
  required VoidCallback refresh, // for setState
}) {
  return Row(
  crossAxisAlignment: CrossAxisAlignment.center,
  children: [
    Text('$searchLabel:', style: const TextStyle(fontSize: 14)),
    const SizedBox(width: 10),
    Wrap(
        spacing: 10,
        runSpacing: 8,
        children: filterMap.entries.map((entry) {
          return FilterChip(
            label: Text(entry.key),
            selected: entry.value,
            onSelected: (bool selected) {
              print('[DEBUG][$searchLabel] Toggling "${entry.key}" to $selected');

              filterMap[entry.key] = selected;
              refresh();

              print('[DEBUG][$searchLabel] Current filter map: $filterMap');

              final selectedItems = filterMap.entries
                  .where((e) => e.value)
                  .map((e) => e.key)
                  .join(',');

              print('[DEBUG][$searchLabel] Selected items: $selectedItems');
              print('[DEBUG][$searchLabel] Debouncer triggered for: $selectedItems');

              _debouncer.run(() => onSearchChanged(selectedItems));
            },
          );
        }).toList(),
      ),
  ],
);

}



  Widget buildDateField({
  required BuildContext context,
  required String searchLabel,
  required String searchHintText,
  required TextEditingController controller,
  required Function(String) onSearchChanged,
}) {
  return SizedBox(
    width: 250,
    height: 30,
    child:  Row(
        children: [
          SizedBox(
            child: Text(
              '$searchLabel:',
              style: const TextStyle(fontSize: 14),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              decoration: InputDecoration(
                        hintText: '$searchHintText',
                        hintStyle: const TextStyle(
                          color: Colors.grey, // Set your desired grey color here
                          fontSize: 14,      // Optional: adjust font size if needed
                        ),
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(10.0),
                          borderSide: BorderSide.none,
                        ),
                        prefixIcon: const Icon(
                          Icons.search,
                          color: const Color.fromARGB(255, 110, 110, 110),
                        ),
                        suffixIcon: dueDateController.text.isNotEmpty ? IconButton(
                                icon: Icon(Icons.clear),
                                color: Colors.grey,
                                onPressed: () {
                                  setState(() {
                                    dueDateController.clear();
                                    applyFilters();       // Call your filtering logic again
                                  });
                                },
                                )
                            : null,
                        
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 1.0, horizontal: 10.0),
                        fillColor: Colors.white,
                        filled: true,
                      ),

                      readOnly: true,
                      onTap: () async {
                        DateTime? pickedDate = await showDatePicker(
                          context: context,
                          initialDate: DateTime.now(),
                          firstDate: DateTime(2000),
                          lastDate: DateTime(2100),
                        );
                        if (pickedDate != null) {
                          final formatted = "${pickedDate.toLocal()}".split(' ')[0];
                          controller.text = formatted;
                          onSearchChanged(formatted); // Optional: trigger onTap change
                        }
                      },
                      // onChanged: (value) {
                      //   if (_debounce?.isActive ?? false) _debounce!.cancel();
                      //   _debounce = Timer(const Duration(milliseconds: 300), () {
                      //     onSearchChanged(value);
                      //   });
                      // },
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // final filteredproductionTaskTicketData = getFilteredproductionTaskTicketData();

    int totalPages = (productionTaskTicketList.isNotEmpty)
        ? (productionTaskTicketList.length / workOrdersPerPage).ceil()
        : 0;
    if (currentWorkOrderPage >= totalPages) {
      currentWorkOrderPage = totalPages > 0 ? totalPages - 1 : 0;
    }
    // double screenWidth = MediaQuery.of(context).size.width;

    return BlocBuilder<WorkOrderCubit, WorkOrderState>(
      builder: (context, state) {
        return Stack(
          children: [
            SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(
                          top: 30.0, left: 20.0, right: 20.0),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                'Dashboard/Production Task Overview',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey.shade300,
                                ),
                              ),
                              const Text(
                                'Production Task Work Station',
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
                                        style: const TextStyle(
                                            color: Colors.white),
                                      ),
                                    ],
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () {
                                    fetchProductionTaskStatus();
                                  },
                                  icon: const Icon(Icons.refresh,
                                      size: 16, color: Colors.white),
                                  label: const Text('Refresh',
                                      style: TextStyle(color: Colors.white)),
                                  style: TextButton.styleFrom(
                                    padding:
                                        const EdgeInsets.symmetric(vertical: 5),
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
                      padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Row 1: Work Station - Query
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                buildLabeledField(
                                    searchLabel: 'Work Station', searchHintText: 'Work Station Selection', controller: workStationController, onSearchChanged: searchMachine),
                                buildLabeledField(
                                    searchLabel: 'Product',  searchHintText: 'Product Selection', controller: productController, onSearchChanged: searchProduct),
                                // buildLabeledField(searchLabel: 'Class',  searchHintText: 'Class Selection', controller: classController, onSearchChanged: searchClass),
                                buildDateField(context: context, searchLabel: 'Due',  searchHintText: 'Due Date', controller: dueDateController, onSearchChanged: applyFilters),
                                buildLabeledField(searchLabel: 'Query',  searchHintText: 'Please Enter Keyword', controller: queryController, onSearchChanged: searchQuery),
                              ],
                            ),

                            // Row 2: Status Checkboxes
                            const SizedBox(height: 10),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.start,
                              children: [
                                buildCheckboxes(
                                  searchLabel: 'Status',
                                  filterMap: statusFilters,
                                  onSearchChanged: applyFilters,
                                  refresh: () => setState(() {}),
                                ),
                                const SizedBox(width: 30),
                                buildCheckboxes(
                                  searchLabel: 'Class',
                                  filterMap: classFilters,
                                  onSearchChanged: applyFilters,
                                  refresh: () => setState(() {}),
                                ),

                                const SizedBox(width: 20),
                                // buildLabeledField(searchLabel: 'Filter Result',  searchHintText: 'Machine Selection', controller: machineController, onSearchChanged: searchMachine),
                              ],
                            ),

                            // Row 4: Job Task Ticket Title
                            const SizedBox(height: 10),
                            const SizedBox(height: 20, child: Text('Job Task Ticket', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
                        ],
                      ),
                    ),
                    GridView.extent(
                                          shrinkWrap: true,
                                          physics: const NeverScrollableScrollPhysics(),
                                          maxCrossAxisExtent: double.infinity,
                                          mainAxisSpacing: 1,
                                          crossAxisSpacing: 1,
                                          childAspectRatio: 3.4,
                                            children: (isFilterActive ? filteredTaskList : productionTaskTicketList).map((entry) {
                                              return ProductionTaskCardWidget(
                                                key: ValueKey(entry['id']),
                                                parent: entry['parent'] ?? '',
                                                productionTaskTicketList: {
                                                  entry['id']: {
                                                    'id': entry['id'],
                                                    'machineId': entry['machineId'],
                                                    'work_id': entry['work_id'],
                                                    'plannedStartDate': entry['plannedStartDate'],
                                                    'plannedEndDate': entry['plannedEndDate'],
                                                    'plannedQuantity': entry['plannedQuantity'],
                                                    'productId': entry['productId'],
                                                    'processDescriptionNote': entry['processDescriptionNote'],
                                                    'processRouting': entry['processRouting'],
                                                    'actualStartDate': entry['actualStartDate'],
                                                    'actualQuantity': entry['actualQuantity'],
                                                    'remainingQuantity': entry['remainingQuantity'],
                                                    'ngQuantity': entry['ngQuantity'],
                                                    'estimatedEndDate': entry['estimatedEndDate'],
                                                    'taskStatus': entry['taskStatus'],
                                                    'taskUrgency': entry['taskUrgency'],
                                                    'taskProgress': entry['taskProgress'],
                                                  }
                                                },
                                                productionTaskTicketData: entry,
                                                isLoading: false,
                                                workOrder: entry,
                                              );
                                            }).toList(),
                                          ),
                    Padding(
                      padding: const EdgeInsets.only(
                          top: 35, left: 50.0, right: 50.0, bottom: 15),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          ElevatedButton(
                            onPressed: currentWorkOrderPage > 0
                                ? () {
                                    setState(() {
                                      currentWorkOrderPage--;
                                    });
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              fixedSize: const Size(110, 30),
                              backgroundColor:
                                  currentWorkOrderPage < totalPages - 1
                                      ? Colors.grey[300]
                                      : Colors.grey[200],
                              foregroundColor: Colors.black,
                            ),
                            child: const Text('Previous'),
                          ),
                          const SizedBox(width: 5),
                          for (int i = 0; i < totalPages; i++)
                            Padding(
                              padding:
                                  const EdgeInsets.only(left: 5.0, right: 5.0),
                              child: ElevatedButton(
                                onPressed: () {
                                  setState(() {
                                    currentWorkOrderPage = i;
                                  });
                                },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: currentWorkOrderPage == i
                                      ? const Color.fromARGB(255, 122, 34, 236)
                                      : Colors.grey[300],
                                  foregroundColor: currentWorkOrderPage == i
                                      ? Colors.white
                                      : Colors.black,
                                ),
                                child: Text('${i + 1}'),
                              ),
                            ),
                          const SizedBox(width: 5),
                          ElevatedButton(
                            onPressed: currentWorkOrderPage < totalPages - 1
                                ? () {
                                    setState(() {
                                      currentWorkOrderPage++;
                                    });
                                  }
                                : null,
                            style: ElevatedButton.styleFrom(
                              fixedSize: const Size(110, 30),
                              backgroundColor:
                                  currentWorkOrderPage < totalPages - 1
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
            if (_isLoading && state.status.isInProgress)
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
      },
    );
  }
}
