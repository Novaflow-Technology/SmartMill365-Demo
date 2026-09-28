import 'package:dropdown_search/dropdown_search.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import '/flutter_flow/flutter_flow_theme.dart';

class StartRunDialog extends StatefulWidget {
  final String checkType;
  final String workId;
  final String machineId;
  final String productId;
  final String plannedQuantity;
  final String actualQuantity;
  final DateTime checkInTime;
  // final String operatorId;

  const StartRunDialog({
    super.key,
    required this.checkType,
    required this.workId,
    required this.machineId,
    required this.productId,
    required this.plannedQuantity,
    required this.actualQuantity,
    required this.checkInTime,
    // required this.operatorId,
  });

  @override
  _StartRunDialogState createState() => _StartRunDialogState();
}

class _StartRunDialogState extends State<StartRunDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late TextEditingController _workIdController;
  late TextEditingController _machineIdController;
  late TextEditingController _productIdController;
  late TextEditingController _plannedQuantityController;
  late TextEditingController _partialCheckOutQuantityController;
  late TextEditingController _checkInTimeController;
  late TextEditingController _operatorIdController;
  List<String> fetchedWork = [];
  List<String>? selectedWork;
  List<dynamic> fetchedProductionArea = [];
  String? selectedProductionArea;
  List<dynamic> fetchedFactory = [];
  String? selectedFactory;

  String? selectedRole;
  String? _errorMessage;
  String? _serialNoError;
  List<String> previousWorkOrderList = [];

  @override
  void initState() {
    super.initState();
    _workIdController = TextEditingController(text: widget.workId);
    _machineIdController = TextEditingController(text: widget.machineId);
    _productIdController = TextEditingController(text: widget.productId);
    _plannedQuantityController = TextEditingController(text: widget.plannedQuantity);
    _partialCheckOutQuantityController = TextEditingController(text: widget.actualQuantity);
    // _operatorIdController = TextEditingController(text: widget.operatorId);
    final dateFormat = DateFormat('yyyy-MM-dd');
    _checkInTimeController = TextEditingController.fromValue(
      TextEditingValue(text: dateFormat.format(widget.checkInTime)),
    );
    fetchWork();
  }

  @override
  void dispose() {
    _workIdController.dispose();
    _machineIdController.dispose();
    _productIdController.dispose();
    _plannedQuantityController.dispose();
    _partialCheckOutQuantityController.dispose();
    _checkInTimeController.dispose();
    super.dispose();
  }

  final RegExp serialNoRegex = RegExp(r'^#\d{5}$');

  final ButtonStyle blueRoundedButtonStyle = ButtonStyle(
  padding: MaterialStatePropertyAll(
    const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
  ),
  backgroundColor: MaterialStateProperty.resolveWith<Color?>((states) {
    if (states.contains(MaterialState.hovered)) {
      return Colors.blue.shade200; // Darker on hover
    }
    return Colors.blue;
  }),
  foregroundColor: MaterialStatePropertyAll(Colors.white),
  shape: MaterialStatePropertyAll(
    RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(12),
    ),
  ),
  overlayColor: MaterialStateProperty.resolveWith<Color?>((states) {
    if (states.contains(MaterialState.hovered)) {
      return Colors.blue.withOpacity(0.1); // Blue ripple on hover
    }
    return null;
  }),
);

  Future<void> fetchWork() async {
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
          fetchedWork = workOrderIdList;
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
      backgroundColor: Color.fromRGBO(0, 4, 51, 1),
      title: const Text(
        'Start Production Run',
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
                if (widget.checkType == "in") ...[
                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Machine ID:', widget.machineId),
                _buildFieldRow('Product ID:', widget.productId),
                _buildFieldRow('Planned Quantity:', widget.plannedQuantity),
                ] else if (widget.checkType == "out") ...[

                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Product ID:', widget.productId),
                buildTextField(_partialCheckOutQuantityController, 'Partial Check Out Quantity', enabled: true),
                ],
                const SizedBox(height: 20),
                // buildTextField(_checkInTimeController, 'Serial no.*', enabled: true),
                if (_serialNoError != null)
                  Container(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _serialNoError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  ),
                const SizedBox(height: 20),
              ],
            ),
          ),
        ),
      ),
      actions: [
          TextButton(
            onPressed: () => Navigator.pop(context), // Close dialog
            style: blueRoundedButtonStyle,
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context); // Close first dialog
              _showOperatorDialog(context, widget.workId, widget.machineId, widget.productId, widget.plannedQuantity);
            },
            style: blueRoundedButtonStyle,
            child: Text('Next'),
          ),
        ],
    );
  }

  void _showOperatorDialog(BuildContext context, String workId, String machineId, String productId, String plannedQuantity) {
  final TextEditingController operatorIdController = TextEditingController();
  final String checkInTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());

  showDialog(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
      backgroundColor: Color.fromRGBO(0, 4, 51, 1),
      title: const Text(
        'Scan Operator Badge ID to Start Production',
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
            _buildFieldRow('Work Order ID:', checkInTime),
            SizedBox(height: 12),
            buildTextField(operatorIdController, 'Enter or Scan Operator ID', enabled: true),
          ],
            ),
          ),
        ),
      ),
      actions: [ 
          TextButton(
            onPressed: () => Navigator.pop(context), // Close dialog
            style: blueRoundedButtonStyle,
            child: Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final operatorId = operatorIdController.text.trim();
              if (operatorId.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Please enter operator ID')),
                );
                return;
              }

              Navigator.pop(context); // Close dialog
              // TODO: Call your API or function here to start production
              print('Production run started:');
              print('Work ID: $workId');
              print('Machine ID: $machineId');
              print('Product ID: $productId');
              print('Planned Qty: $plannedQuantity');
              print('Check-in Time: $checkInTime');
              print('Operator ID: $operatorId');
            },
            style: blueRoundedButtonStyle,
            child: Text('Submit'),
        ),
        ],
    );
  }
  );
}

  Widget buildTextField(TextEditingController controller, String labelText, {int maxLines = 1, bool enabled = true}) {
    return TextField(
      controller: controller,
      maxLines: maxLines,
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
  
Widget _buildFieldRow(String label, String value) {
  final labelTextStyle = FlutterFlowTheme.of(context).bodyMedium.override(
        fontFamily: 'Poppins',
        fontWeight: FontWeight.w400,
        font: GoogleFonts.poppins(),
      );
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: 15.0, vertical: 2.0),
    child: Row(
  mainAxisAlignment: MainAxisAlignment.spaceBetween,
  crossAxisAlignment: CrossAxisAlignment.start,
  children: [
    Text(label, style: labelTextStyle),
    const SizedBox(width: 12), // spacing between label and box
    SizedBox(
      width: 300, // uniform width for all value boxes
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6.0, horizontal: 6.0),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8.0),
          border: Border.all(color: Colors.grey.shade300),
        ),
        child: Text(
          value,
          textAlign: TextAlign.end,
          style: labelTextStyle.copyWith(color: Colors.black),
          overflow: TextOverflow.ellipsis,
          maxLines: 2, // Optional: allows wrapping
        ),
      ),
    ),
  ],
)

  );
}


  Widget buildDateField(TextEditingController controller, String labelText) {
    return TextField(
      controller: controller,
      decoration: InputDecoration(
        labelText: labelText,
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(15.0)),
        ),
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
          controller.text = "${pickedDate.toLocal()}".split(' ')[0];
        }
      },
    );
  }

  Widget buildDropdownField({
    required String? value,
    required List<dynamic> items,
    required String labelText,
    required ValueChanged<String?> onChanged,
  }) {
    final uniqueItems = items.toSet().toList();

    return SizedBox(
      width: double.infinity,
      child: DropdownButtonFormField<String>(
        value: value,
        dropdownColor: const Color.fromRGBO(0, 4, 51, 1),
        style: const TextStyle(color: Colors.white), // Selected value text style
        items: uniqueItems.map((dynamic equipment) {
          return DropdownMenuItem<String>(
            value: equipment['id'],
            child: Text(
              equipment['name'],
              style: const TextStyle(color: Colors.white), // Menu item text style
            ),
          );
        }).toList(),
        onChanged: onChanged,
        decoration: InputDecoration(
          labelText: labelText,
          labelStyle: const TextStyle(color: Colors.white),
          fillColor: const Color.fromRGBO(0, 4, 51, 1),
          filled: true,
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
