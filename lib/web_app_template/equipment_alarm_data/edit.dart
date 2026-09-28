import 'dart:convert';

import 'package:dropdown_search/dropdown_search.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

class EditDataDialog extends StatefulWidget {
  const EditDataDialog({
    super.key,
    required this.id,
    required this.initialTriggerDate,
    required this.initialWorkOrder,
    required this.initialOperator,
    required this.initialResolveDate,
    required this.onDataEdited,
  });

  final int id;
  final String initialTriggerDate;
  final String initialWorkOrder;
  final String initialOperator;
  final String initialResolveDate;
  final VoidCallback onDataEdited;

  @override
  State<EditDataDialog> createState() => _EditDataDialogState();
}

class _EditDataDialogState extends State<EditDataDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late TextEditingController _operatorController;

  List<dynamic> fetchedWorkOrder = [];
  String selectedWorkOrder = '';
  String? _errorMessage;
  String previousWorkOrder = '';

  @override
  void initState() {
    super.initState();

    _operatorController = TextEditingController(text: widget.initialOperator);

    fetchWorkOrder();
  }

  @override
  void dispose() {
    _operatorController.dispose();

    super.dispose();
  }

  Future<void> fetchWorkOrder() async {
    try {
      const String apiUrl = "https://us-central1-smartmill365-demo.cloudfunctions.net/api/workOrders";

      // Send GET request
      final response = await http.get(Uri.parse(apiUrl));

      if (response.statusCode == 200) {
        // Parse JSON response
        final List<dynamic> workOrders = json.decode(response.body);
        List<String> workOrderIdList = [];

        if (workOrders.isNotEmpty) {
          for (dynamic workOrder in workOrders) {
            workOrderIdList.add(workOrder['id']);
          }
        }

        setState(() {
          fetchedWorkOrder = workOrderIdList;
          selectedWorkOrder =
              widget.initialWorkOrder.isNotEmpty ? widget.initialWorkOrder : '';
        });
      } else {
        throw Exception("Failed to fetch work orders: ${response.statusCode}");
      }
    } catch (e) {
      setState(() {
        _errorMessage = 'Error fetching work orders: $e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text(
        'Edit Data Details',
        style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold),
      ),
      content: Container(
        constraints: BoxConstraints(
          minWidth: MediaQuery.of(context).size.width * 0.4,
          minHeight: MediaQuery.of(context).size.height * 0.2,
          maxWidth: MediaQuery.of(context).size.width * 0.4,
          maxHeight: MediaQuery.of(context).size.height * 0.8,
        ),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _DropdownButton<String>(
                  selectedItem: selectedWorkOrder.isNotEmpty
                      ? fetchedWorkOrder.firstWhere(
                          (workOrder) => workOrder == selectedWorkOrder)
                      : null,
                  onChanged: (workOrder) {
                    if (workOrder != null) {
                      setState(() {
                        previousWorkOrder = selectedWorkOrder;
                        selectedWorkOrder = workOrder;
                        _errorMessage = null;
                      });
                    }
                  },
                  items: List<String>.from(fetchedWorkOrder),
                  dropdownBuilder: (context, selectedWorkOrder) =>
                      Text(selectedWorkOrder ?? ''),
                  filterFn: (workOrder, filter) =>
                      workOrder.toLowerCase().contains(filter.toLowerCase()),
                  itemAsString: (workOrder) => workOrder,
                  compareFn: (workOrder1, workOrder2) =>
                      workOrder1 == workOrder2,
                  itemBuilder: (context, workOrder, isDisabled, isSelected) =>
                      ListTile(
                    title: Text(workOrder),
                    selectedColor: Colors.black,
                    selected: isSelected,
                    selectedTileColor: Colors.blueGrey[50],
                  ),
                  disabledItemFn: (workOrder) => workOrder == selectedWorkOrder,
                  labelText: 'Work Order ID',
                ),
                const SizedBox(height: 20),
                buildTextField(_operatorController, 'Operator'),
                const SizedBox(height: 20),
                if (_errorMessage != null)
                  Container(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _errorMessage!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () async {
            setState(() {
              _errorMessage = null;
            });

            if (_formKey.currentState!.validate()) {
              if (selectedWorkOrder.isEmpty ||
                  _operatorController.text.isEmpty) {
                setState(() {
                  _errorMessage = 'All fields are required.';
                });
              } else {
                try {
                  final String apiUrl =
                      "https://us-central1-smartmill365-demo.cloudfunctions.net/api/equipmentAlarmData/update/${widget.id}";

                  // Prepare JSON data
                  final Map<String, dynamic> requestData = {
                    "workOrder": selectedWorkOrder,
                    "operator": _operatorController.text,
                  };

                  // Send PUT request
                  final response = await http.put(
                    Uri.parse(apiUrl),
                    headers: {
                      "Content-Type": "application/json",
                    },
                    body: json.encode(requestData),
                  );

                  if (response.statusCode == 200) {
                    widget.onDataEdited();
                    Navigator.of(context).pop();
                  } else {
                    throw Exception(
                        "Failed to edit data: ${json.decode(response.body)['error']}");
                  }
                } catch (e) {
                  String errorMessage = e is Exception
                      ? e.toString()
                      : 'An unknown error occurred.';
                  int lastColonIndex = errorMessage.lastIndexOf(':');
                  if (lastColonIndex != -1) {
                    errorMessage =
                        errorMessage.substring(lastColonIndex + 1).trim();
                  }
                }
              }
            }
          },
          child: const Text('Save Changes'),
        ),
        TextButton(
          onPressed: () {
            Navigator.of(context).pop();
          },
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget buildTextField(
    TextEditingController controller,
    String labelText, {
    int visibleLines = 1,
    bool unlimitedLines = false,
    bool isNumeric = false,
    bool enabled = true,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: isNumeric
          ? const TextInputType.numberWithOptions(decimal: true)
          : TextInputType.multiline,
      inputFormatters: isNumeric
          ? [FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d*$'))]
          : [],
      minLines: visibleLines,
      maxLines: unlimitedLines ? null : visibleLines,
      decoration: InputDecoration(
        labelText: labelText,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(15.0)),
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(15.0)),
          borderSide: BorderSide(color: Colors.grey),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(15.0)),
          borderSide: BorderSide(color: Colors.blue, width: 2.0),
        ),
      ),
      enabled: enabled,
    );
  }
}

class _DropdownButton<T> extends StatelessWidget {
  const _DropdownButton(
      {required this.selectedItem,
      required this.onChanged,
      required this.items,
      required this.dropdownBuilder,
      required this.filterFn,
      required this.itemAsString,
      required this.compareFn,
      this.showSearchBox = true,
      required this.itemBuilder,
      required this.disabledItemFn,
      required this.labelText});

  final T? selectedItem;
  final void Function(T?) onChanged;
  final List<T> items;
  final Widget Function(BuildContext, T?) dropdownBuilder;
  final bool Function(T, String) filterFn;
  final String Function(T) itemAsString;
  final bool Function(T, T) compareFn;
  final bool showSearchBox;
  final Widget Function(BuildContext, T, bool, bool) itemBuilder;
  final bool Function(T) disabledItemFn;
  final String labelText;

  @override
  Widget build(BuildContext context) {
    return DropdownSearch<T>(
      selectedItem: selectedItem,
      onChanged: onChanged,
      items: (filter, loadProps) => items,
      dropdownBuilder: dropdownBuilder,
      filterFn: filterFn,
      itemAsString: itemAsString,
      compareFn: compareFn,
      popupProps: PopupProps.menu(
        fit: FlexFit.loose,
        showSearchBox: showSearchBox,
        searchFieldProps:
            const TextFieldProps(style: TextStyle(fontSize: 14.0)),
        scrollbarProps: const ScrollbarProps(thumbVisibility: true),
        searchDelay: Duration.zero,
        itemBuilder: itemBuilder,
        showSelectedItems: true,
        disabledItemFn: disabledItemFn,
      ),
      decoratorProps: DropDownDecoratorProps(
        decoration: InputDecoration(
          labelText: labelText,
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(15.0)),
          ),
          enabledBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(15.0)),
            borderSide: BorderSide(color: Colors.grey),
          ),
          focusedBorder: const OutlineInputBorder(
            borderRadius: BorderRadius.all(Radius.circular(15.0)),
            borderSide: BorderSide(color: Colors.blue, width: 2.0),
          ),
        ),
      ),
    );
  }
}
