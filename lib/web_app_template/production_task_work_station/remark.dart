import 'dart:io';

import 'package:dropdown_search/dropdown_search.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:image_picker/image_picker.dart';
import '/flutter_flow/flutter_flow_theme.dart';

class RemarkDialog extends StatefulWidget {
  final String checkType;
  final String workId;
  final String machineId;
  final String productId;
  final String plannedQuantity;
  final String actualQuantity;
  final DateTime checkInTime;
  // final String operatorId;

  const RemarkDialog({
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
  _RemarkDialogState createState() => _RemarkDialogState();
}

class _RemarkDialogState extends State<RemarkDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late TextEditingController _workIdController;
  late TextEditingController _machineIdController;
  late TextEditingController _productIdController;
  late TextEditingController _plannedQuantityController;
  late TextEditingController _defectQuantityController;
  late TextEditingController _checkInTimeController;
  late TextEditingController _operatorIdController;
  late TextEditingController _descriptionController;
  List<String> fetchedWork = [];
  String? selectedQueryType;
  File? uploadedImage;
  String selectedImpactLevel = "Low";

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
    _defectQuantityController = TextEditingController(text: widget.actualQuantity);
    _descriptionController = TextEditingController();
    _operatorIdController = TextEditingController(); // Assuming operatorId is not used in this
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
    _defectQuantityController.dispose();
    _descriptionController.dispose();
    _checkInTimeController.dispose();
    _operatorIdController.dispose();
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
  final String checkInTime = DateFormat('yyyy-MM-dd HH:mm:ss').format(DateTime.now());
    return AlertDialog(
      backgroundColor: Color.fromRGBO(0, 4, 51, 1),
      title: buildTitle(widget.checkType),
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
                if (widget.checkType == "remark") ...[
                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Machine ID:', widget.machineId),
                _buildFieldRow('Date Time:', checkInTime),
                const SizedBox(height: 20),
                buildDropdownField(value: selectedQueryType, 
                  items: [
                    "Equipment Faulty",
                    "Material Defect",
                    "Quality Abnormal",
                    "Parameter Out of Tolerance",
                    "Other"
                  ],
                  labelText: "Query Type", 
                  onChanged: (String? newQueryType) {
                    setState(() {
                      selectedQueryType = newQueryType;
                      _errorMessage = null;
                    });
                  },),
                  const SizedBox(height: 16),
                buildDescriptionField(_descriptionController, "Problem Description"),
                  const SizedBox(height: 16),
                  buildSelectionField(
                  labelText: "Impact Level",
                  options: ["Low", "Moderate", "High"],
                  selectedOption: selectedImpactLevel,
                  onChanged: (value) {
                    setState(() {
                      selectedImpactLevel = value;
                    });
                  },
                ),
                ] else if (widget.checkType == "defect") ...[
                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Machine ID:', widget.machineId),
                _buildFieldRow('Date Time:', checkInTime),
                // _buildFieldRow("Operator ID:", widget.operatorId),
                const SizedBox(height: 20),
                buildDropdownField(value: selectedQueryType, 
                  items: [
                    "Equipment Faulty",
                    "Material Defect",
                    "Quality Abnormal",
                    "Parameter Out of Tolerance",
                    "Other"
                  ],
                  labelText: "Defect Category", 
                  onChanged: (String? newQueryType) {
                    setState(() {
                      selectedQueryType = newQueryType;
                      _errorMessage = null;
                    });
                  },),
                  const SizedBox(height: 20),
                  buildTextField(_defectQuantityController, 'Quantity of Defect', enabled: true),
                    const SizedBox(height: 16),
                    buildDescriptionField(_descriptionController, "Defect Description"),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        buildImageUploadButton((file) {
                          setState(() => uploadedImage = file);
                        }),
                        const SizedBox(width: 10),
                        buildImageCaptureButton((file) {
                          setState(() => uploadedImage = file);
                        }),
                      ],
                    ),
                    if (uploadedImage != null) ...[
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.file(uploadedImage!, height: 150),
                      ),
                    ],
                    const SizedBox(height: 16),
                    buildSelectionField(
                    labelText: "Impact Level",
                    options: ["Low", "Moderate", "High"],
                    selectedOption: selectedImpactLevel,
                    onChanged: (value) {
                      setState(() {
                        selectedImpactLevel = value;
                      });
                    },
                  ),
                ]  else if (widget.checkType == "hold") ...[
                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Machine ID:', widget.machineId),
                _buildFieldRow('Date Time:', checkInTime),
                // _buildFieldRow("Operator ID:", widget.operatorId),
                const SizedBox(height: 20),
                buildDropdownField(value: selectedQueryType, 
                  items: [
                    "Equipment Faulty",
                    "Material Defect",
                    "Quality Abnormal",
                    "Parameter Out of Tolerance",
                    "Other"
                  ],
                  labelText: "Query Type", 
                  onChanged: (String? newQueryType) {
                    setState(() {
                      selectedQueryType = newQueryType;
                      _errorMessage = null;
                    });
                  },),
                const SizedBox(height: 20),
                buildTextField(_defectQuantityController, 'Quantity of Departure', enabled: true),
                    const SizedBox(height: 16),
                  buildDescriptionField(_descriptionController, "Task On Hold Description"),
                    const SizedBox(height: 16),
                    buildSelectionField(
                    labelText: "Impact Level",
                    options: ["Low", "Moderate", "High"],
                    selectedOption: selectedImpactLevel,
                    onChanged: (value) {
                      setState(() {
                        selectedImpactLevel = value;
                      });
                    },
                  ),
                    Row(
                      children: [
                        buildImageUploadButton((file) {
                          setState(() => uploadedImage = file);
                        }),
                        const SizedBox(width: 10),
                        buildImageCaptureButton((file) {
                          setState(() => uploadedImage = file);
                        }),
                      ],
                    ),
                    if (uploadedImage != null) ...[
                      const SizedBox(height: 16),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(15),
                        child: Image.file(uploadedImage!, height: 150),
                      ),
                    ],
                const SizedBox(height: 20),
                buildTextField(_defectQuantityController, 'Quantity of Departure', enabled: true),
                ]  else if (widget.checkType == "complete") ...[
                _buildFieldRow('Work Order ID:', widget.workId),
                _buildFieldRow('Machine ID:', widget.machineId),
                _buildFieldRow('Date Time:', checkInTime),
                // _buildFieldRow("Operator ID:", widget.operatorId),

                _buildFieldRow('Planned Quantity:', widget.plannedQuantity),
                _buildFieldRow('Actual Quantity:', widget.actualQuantity),
                const SizedBox(height: 20),
                buildTextField(_defectQuantityController, 'Quantity of Departure', enabled: true),
                const SizedBox(height: 20),
                  buildDescriptionField(_descriptionController, "Report Remark"),
                    const SizedBox(height: 16),
                    buildSelectionField(
                    labelText: "Impact Level",
                    options: ["Low", "Moderate", "High"],
                    selectedOption: selectedImpactLevel,
                    onChanged: (value) {
                      setState(() {
                        selectedImpactLevel = value;
                      });
                    },
                  ),
                ],
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

Widget buildTitle(String checkType) {
  switch (checkType) {
    case "remark":
      return const Text('Production Remark',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold));
    case "defect":
      return const Text('Production Defect',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold));
    case "hold":
      return const Text('Task On Hold',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold));
    default:
      return const Text('Task Complete',
          style: TextStyle(fontSize: 36, fontWeight: FontWeight.bold));
  }
}

Widget buildSelectionField({
  required String labelText,
  required List<String> options,
  required String selectedOption,
  required ValueChanged<String> onChanged,
}) {
  return Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        labelText,
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
      const SizedBox(height: 8),
      Wrap(
        spacing: 8,
        children: options.map((option) {
          final isSelected = option == selectedOption;
          return GestureDetector(
            onTap: () => onChanged(option),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: isSelected ? Colors.blue : Colors.grey.shade200,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: isSelected ? Colors.blue : Colors.grey,
                  width: 1.5,
                ),
              ),
              child: Text(
                option,
                style: TextStyle(
                  color: isSelected ? Colors.white : Colors.black,
                  fontWeight:
                      isSelected ? FontWeight.bold : FontWeight.normal,
                ),
              ),
            ),
          );
        }).toList(),
      ),
    ],
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
        items: uniqueItems.map((item) {
          return DropdownMenuItem<String>(
            value: item,
            child: Text(item, style: const TextStyle(color: Colors.white)),
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

  // Description field
Widget buildDescriptionField(TextEditingController controller, String labelText, {bool enabled = true}) {
  return TextField(
    controller: controller,
    maxLines: 4,
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

// Image picker button
Widget buildImageUploadButton(Function(File) onImageSelected) {
  return ElevatedButton.icon(
    icon: const Icon(Icons.upload_file),
    label: const Text('Upload Image'),
    style: ElevatedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
    onPressed: () async {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.gallery);
      if (pickedFile != null) {
        onImageSelected(File(pickedFile.path));
      }
    },
  );
}

// Camera capture button
Widget buildImageCaptureButton(Function(File) onImageCaptured) {
  return ElevatedButton.icon(
    icon: const Icon(Icons.camera_alt),
    label: const Text('Capture Image'),
    style: ElevatedButton.styleFrom(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(15)),
    ),
    onPressed: () async {
      final picker = ImagePicker();
      final pickedFile = await picker.pickImage(source: ImageSource.camera);
      if (pickedFile != null) {
        onImageCaptured(File(pickedFile.path));
      }
    },
  );
}
}
