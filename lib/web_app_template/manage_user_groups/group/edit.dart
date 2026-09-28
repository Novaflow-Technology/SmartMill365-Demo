import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;

import '/flutter_flow/flutter_flow_theme.dart';
import '../../../../components/dialogs/custom_dialog.dart';

class EditGroupDialog extends StatefulWidget {
  final String id;
  final String initialName;
  final String initialDescription;
  final String userName;
  final VoidCallback onGroupAdded;

  const EditGroupDialog({
    super.key,
    required this.id,
    required this.initialName,
    required this.initialDescription,
    required this.userName,
    required this.onGroupAdded,
  });

  @override
  _EditGroupDialogState createState() => _EditGroupDialogState();
}

class _EditGroupDialogState extends State<EditGroupDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _groupNameController;
  late final TextEditingController _descriptionController;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _groupNameController = TextEditingController(text: widget.initialName);
    _descriptionController =
        TextEditingController(text: widget.initialDescription);
  }

  @override
  void dispose() {
    _groupNameController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<bool> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return false;

    if (_groupNameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'Group name is required.');
      return false;
    }

    try {
      final url = Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/edit/${widget.id}');
      final response = await http.put(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _groupNameController.text.trim(),
          'description': _descriptionController.text.trim(),
          'assignby': widget.userName,
          'initialName': widget.initialName,
        }),
      );
      if (response.statusCode == 200) {
        widget.onGroupAdded();
        return true;
      } else {
        setState(() {
          _errorMessage =
              jsonDecode(response.body)['error'] ?? 'Failed to update group.';
        });
        return false;
      }
    } catch (e) {
      setState(() => _errorMessage = e.toString());
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = FlutterFlowTheme.of(context);

    return CustomDialog(
      formKey: _formKey,
      icon: Icons.edit_outlined,
      title: 'Edit Group',
      subtitle: 'Update group details for #${widget.id.padLeft(5, '0')}',
      requiredNote: true,
      submitLabel: 'SAVE CHANGES',
      cancelLabel: 'CANCEL',
      onSubmit: _handleSubmit,
      sections: [
        CustomDialogSection(
          number: 1,
          title: 'Group Information',
          subtitle: 'Modify the group name and description.',
          children: [
            TextFormField(
              controller: _groupNameController,
              style: TextStyle(color: t.primaryText, fontSize: 14),
              decoration: _inputDecoration(t, 'Group Name *'),
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Group name is required' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              maxLines: 3,
              inputFormatters: [LengthLimitingTextInputFormatter(110)],
              style: TextStyle(color: t.primaryText, fontSize: 14),
              decoration: _inputDecoration(t, 'Description'),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerRight,
              child: Text(
                '${_descriptionController.text.length}/110',
                style: TextStyle(color: t.secondaryText, fontSize: 11),
              ),
            ),
            if (_errorMessage != null) ...[
              const SizedBox(height: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: t.error.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: t.error.withOpacity(0.3)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.error_outline, size: 16, color: t.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _errorMessage!,
                        style: TextStyle(color: t.error, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  InputDecoration _inputDecoration(FlutterFlowTheme t, String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: TextStyle(color: t.secondaryText, fontSize: 13),
      filled: true,
      fillColor: const Color(0xFF151C2E),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.primary.withOpacity(0.2)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.primary.withOpacity(0.15)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.primary, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.error.withOpacity(0.5)),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: t.error, width: 1.5),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    );
  }
}
