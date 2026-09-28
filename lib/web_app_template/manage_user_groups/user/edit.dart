import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/models/user_scope.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/widgets/data_scope_picker.dart';
import 'package:country_code_picker/country_code_picker.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dropdown_search/dropdown_search.dart';
import 'package:provider/provider.dart';
import 'package:smartmachine365/flutter_flow/nav/nav.dart';
import 'package:smartmachine365/flutter_flow/nav/user_provider.dart';
import 'package:smartmachine365/flutter_flow/rbac.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '../../../../components/dialogs/custom_dialog.dart';

class EditCustomerDialog extends StatefulWidget {
  final String uid;           // Logged-in user's UID
  final String editedUserUid; // The UID of the user being edited
  final String email;
  final String id;
  final String initialName;
  final String initialEmail;
  final String initialPhone;
  final List<String> initialGroups;
  final String initialRoles;
  final String initialFactoryId;
  final bool initialAllowMultipleLogins;
  final VoidCallback onCustomerAdded;
  final String userRole;

  const EditCustomerDialog({
    super.key,
    required this.email,
    required this.uid,
    this.editedUserUid = '',
    required this.id,
    required this.userRole,
    required this.initialName,
    required this.initialEmail,
    required this.initialPhone,
    required this.initialGroups,
    required this.initialRoles,
    this.initialFactoryId = '',
    this.initialAllowMultipleLogins = false,
    required this.onCustomerAdded,
  });

  @override
  _EditCustomerDialogState createState() => _EditCustomerDialogState();
}

class _EditCustomerDialogState extends State<EditCustomerDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _phoneController;
  late final TextEditingController _emailController;
  final _newPasswordController = TextEditingController();
  final _confirmPasswordController = TextEditingController();

  String? selectedRole;
  List<String>? selectedGroups;
  String? _errorMessage;
  List<String> groups = [];
  List<String> groupsName = [];
  List<String> roles = [];
  String? _countryCode;
  String? uid;

  String? _selectedFactoryId;
  String? _pendingFactoryId;
  List<Map<String, String>> _factories = [];
  bool _loadingFactories = false;

  // Module permissions
  Set<String> _enabledModules = {};

  /// Module keys this screen has already shown an admin for this user.
  /// Empty until the first save that records it.
  Set<String> _reviewedModules = {};

  /// Which plants and areas this user may see. Empty means unrestricted, which
  /// is what every account saved before this feature existed will load as.
  UserScope _dataScope = UserScope.unrestricted;

  bool _allowMultipleLogins = false;

  bool _isNewPasswordVisible = false;
  bool _isConfirmPasswordVisible = false;

  // ── Style tokens ──────────────────────────────────────────────────────────
  static const _kFieldFill = Color(0xFF151C2E);
  static const _kLabelColor = Color(0xFF6B7FA3);
  static const _kTextColor = Color(0xFFE2E8F0);

  // ── Regexes ───────────────────────────────────────────────────────────────
  final _phoneRegex = RegExp(r'^\d{9,14}$');
  final _pwRegex = RegExp(
    r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$',
  );

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.initialName);
    _emailController = TextEditingController(text: widget.initialEmail);
    final parts = widget.initialPhone.split(' ');
    _phoneController = TextEditingController(
      text: parts.length > 1 ? parts[1] : widget.initialPhone,
    );
    _countryCode = parts.isNotEmpty ? parts[0] : '+60';
    selectedRole = widget.initialRoles;
    roles = AppRoles.assignableRoles(widget.userRole);
    _allowMultipleLogins = widget.initialAllowMultipleLogins;
    _pendingFactoryId = widget.initialFactoryId.isNotEmpty ? widget.initialFactoryId : null;
    // Pre-populate uid from the passed editedUserUid if available
    if (widget.editedUserUid.isNotEmpty) {
      uid = widget.editedUserUid;
    }
    fetchGroups();
    if (widget.userRole == AppRoles.superAdmin) fetchFactories();
    // Fetch the edited user's UID (if not already set), then load their permissions
    _fetchUid().then((_) => _loadModulePermissions());
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _newPasswordController.dispose();
    _confirmPasswordController.dispose();
    super.dispose();
  }

  Future<void> fetchFactories() async {
    if (mounted) setState(() => _loadingFactories = true);
    try {
      final res = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/factory'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List<dynamic>;
        if (mounted) {
          setState(() {
            _factories = data
                .map((f) => {'id': f['id'].toString(), 'name': f['name'].toString()})
                .toList();
            _selectedFactoryId = _pendingFactoryId;
            _loadingFactories = false;
          });
        }
      }
    } catch (e) {
      debugPrint('fetchFactories: $e');
      if (mounted) setState(() => _loadingFactories = false);
    }
  }

  Future<void> fetchGroups() async {
    try {
      // Primary: read directly from Firestore (no backend dependency)
      final snapshot = await FirebaseFirestore.instance
          .collection('groups')
          .get();
      final ids = <String>[];
      final names = <String>[];
      for (var doc in snapshot.docs) {
        ids.add(doc.id);
        names.add((doc.data()['name'] ?? '').toString());
      }
      if (mounted) {
        setState(() {
          groups = ids;
          groupsName = names;
          selectedGroups = groups.isNotEmpty ? widget.initialGroups : [];
        });
      }
    } catch (e) {
      debugPrint('Firestore fetchGroups failed, trying API fallback: $e');
      try {
        final url = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final List<dynamic> groupResponse = jsonDecode(response.body);
          final ids = <String>[];
          final names = <String>[];
          for (var group in groupResponse) {
            ids.add(group['id'].toString());
            names.add(group['name'].toString());
          }
          if (mounted) {
            setState(() {
              groups = ids;
              groupsName = names;
              selectedGroups = groups.isNotEmpty ? widget.initialGroups : [];
            });
          }
        }
      } catch (e2) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('$e2', style: const TextStyle(color: Colors.red)),
              backgroundColor: Colors.black,
              duration: const Duration(seconds: 2),
            ),
          );
        }
      }
    }
  }

  Future<void> _fetchUid() async {
    // Skip if we already have it
    if (uid != null && uid!.isNotEmpty) return;
    try {
      // Primary: read directly from Firestore
      final doc = await FirebaseFirestore.instance
          .collection('customers')
          .doc(widget.id)
          .get();
      if (doc.exists) {
        uid = doc.data()?['UID']?.toString();
      }
    } catch (_) {}
    // Fallback: try API
    if (uid == null || uid!.isEmpty) {
      try {
        final apiUrl =
            'https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/id/${widget.id}';
        final response = await http.get(Uri.parse(apiUrl));
        if (response.statusCode == 200) {
          uid = json.decode(response.body)['UID'];
        }
      } catch (_) {}
    }
  }

  Future<void> _loadModulePermissions() async {
    final targetUid = uid;
    Set<String> stored = {};
    bool hasGranular = false;

    if (targetUid != null && targetUid.isNotEmpty) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('roles')
            .doc(targetUid)
            .get();
        if (doc.exists) {
          final modules = (doc.data()?['accessible_modules'] as List<dynamic>?)
              ?.cast<String>() ?? [];
          hasGranular = modules.any((m) => AppRoles.allModuleKeys.contains(m));
          if (hasGranular) stored = modules.toSet();
          // Which modules this screen has already put in front of an admin.
          // Falls back to the enabled set for records saved before the field
          // existed, which reproduces the old behaviour exactly rather than
          // changing what those accounts can reach.
          _reviewedModules =
              ((doc.data()?['modules_reviewed'] as List<dynamic>?)
                      ?.cast<String>() ??
                  modules)
                  .toSet();
          _dataScope = UserScope.fromJson(
              (doc.data()?['data_scope'] as Map<String, dynamic>?));
        }
      } catch (_) {}
    }

    if (hasGranular && selectedRole != null) {
      // Modules added to the product since this user was last saved should
      // switch themselves on, so an admin does not have to revisit every
      // account whenever a screen ships.
      //
      // "New" has to mean never offered, though — not merely absent. Absence
      // was the only test before, and a module the admin had deliberately
      // switched off is absent too, so every role-default module came back on
      // the next time this page opened. Disabling one and saving looked like
      // it did nothing. Comparing against what the screen has already offered
      // tells a new module apart from a rejected one.
      final roleDefaults = AppRoles.defaultGranularModules(selectedRole!).toSet();
      final neverOffered = roleDefaults.difference(_reviewedModules);
      if (mounted) {
        setState(() => _enabledModules = {...stored, ...neverOffered});
      }
      return;
    }

    // Fallback: no Firestore record → use role defaults
    if (selectedRole != null && mounted) {
      setState(() => _enabledModules =
          AppRoles.defaultGranularModules(selectedRole!).toSet());
    }
  }

  String _sanitize(String input) =>
      input.replaceAll(RegExp(r'[^\x20-\x7E]'), '').trim();

  Future<bool> _handleSubmit() async {
    setState(() => _errorMessage = null);

    if (!_formKey.currentState!.validate()) return false;

    // Role validation
    if (selectedRole == null || selectedRole!.isEmpty) {
      setState(() => _errorMessage = 'You must assign a role before saving.');
      return false;
    }

    if (_nameController.text.trim().isEmpty) {
      setState(() => _errorMessage = 'A name is required.');
      return false;
    }

    // Phone is optional. It used to be required, which meant an account
    // created without one could never be saved again — the admin would change
    // a role or a data scope, press Save, and be refused over a field they had
    // not touched and did not have. Checked for shape only when there is one.
    if (_phoneController.text.trim().isNotEmpty &&
        !_phoneRegex.hasMatch(_phoneController.text)) {
      setState(() => _errorMessage = 'Please enter a valid phone number.');
      return false;
    }

    // ── Password reset (optional) ──────────────────────────────────────────
    final isPasswordReset = _newPasswordController.text.isNotEmpty ||
        _confirmPasswordController.text.isNotEmpty;

    if (isPasswordReset) {
      if (_newPasswordController.text.isEmpty ||
          _confirmPasswordController.text.isEmpty) {
        setState(() => _errorMessage = 'Please fill in both password fields.');
        return false;
      }
      if (!_pwRegex.hasMatch(_newPasswordController.text)) {
        setState(() => _errorMessage =
            'Min 8 chars: uppercase, lowercase, number & special char');
        return false;
      }
      if (_newPasswordController.text != _confirmPasswordController.text) {
        setState(() => _errorMessage = 'Passwords do not match.');
        return false;
      }
      if (uid == null) await _fetchUid();
      if (uid == null) {
        setState(() => _errorMessage =
            'Could not fetch user UID. Try closing and reopening.');
        return false;
      }
      final currentUser = FirebaseAuth.instance.currentUser;
      if (uid == currentUser?.uid) {
        setState(() => _errorMessage =
            'To change your own password, use "Forgot Password" on the login page.');
        return false;
      }

      final cleanEmail = _sanitize(widget.initialEmail);
      final cleanPassword = _sanitize(_newPasswordController.text);

      try {
        final url = Uri.parse(
            'https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/updateUserPassword');
        final response = await http.put(
          url,
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'userUid': uid,
            'email': cleanEmail,
            'newPassword': cleanPassword,
          }),
        );
        if (response.statusCode != 200) {
          String apiErr;
          try {
            apiErr = jsonDecode(response.body)['error'] ?? 'Unknown error';
          } catch (_) {
            apiErr = response.body;
          }
          setState(() => _errorMessage =
              'Password reset failed (${response.statusCode}): $apiErr');
          return false;
        }
        _newPasswordController.clear();
        _confirmPasswordController.clear();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Password for ${widget.initialEmail} updated successfully.',
              style: const TextStyle(
                  color: Colors.greenAccent, fontWeight: FontWeight.bold),
            ),
            backgroundColor: Colors.black,
            duration: const Duration(seconds: 4),
          ));
        }
      } catch (e) {
        setState(
            () => _errorMessage = 'Network error during password reset: $e');
        return false;
      }
    }

    // ── Update user details — Firestore roles/{uid} (no backend dependency) ─
    try {
      if (uid == null) await _fetchUid();
      final targetUid = uid;

      if (targetUid == null || targetUid.isEmpty) {
        setState(() => _errorMessage = 'Could not resolve user UID.');
        return false;
      }

      // 1a. Write allow_multiple_logins to account_status/{uid}
      await FirebaseFirestore.instance.collection('account_status').doc(targetUid).set({
        'allow_multiple_logins': _allowMultipleLogins,
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 1b. Write role + permissions to Firestore roles/{uid}
      //    This is the authoritative source (same pattern as presence/).
      await FirebaseFirestore.instance.collection('roles').doc(targetUid).set({
        'name': selectedRole,
        'display_name': _nameController.text.trim(),
        'email': _emailController.text.trim(),
        'phone': '$_countryCode ${_phoneController.text}',
        'group_id': selectedGroups ?? [],
        'accessible_modules': _enabledModules.toList(),
        // The whole catalogue the admin just decided on, enabled or not, so a
        // switched-off module stays off while a module that ships later is
        // still recognised as new.
        'modules_reviewed': AppRoles.allModuleKeys,
        // Roles no longer impose readonly_* sub-modules. Anything the admin
        // assigned should be fully accessible (not downgraded to read-only)
        // unless explicitly toggled. Save an empty list so role defaults
        // don't silently re-restrict the user on every save.
        'accessible_sub_modules': const <String>[],
        // Which data this user may see, alongside which screens they may open.
        // Written even when empty so "unrestricted" is a recorded decision
        // rather than a missing field nobody is sure about.
        'data_scope': _dataScope.toJson(),
        'updated_at': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));

      // 2. Best-effort: also sync to backend API (fire-and-forget)
      http.put(
        Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/edit/${widget.id}'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'name': _nameController.text.trim(),
          'phone': '$_countryCode ${_phoneController.text}',
          'initialEmail': widget.initialEmail,
          'email': _emailController.text.trim(),
          'groupIds': selectedGroups,
          'role': selectedRole ?? '',
          'factory_id': _selectedFactoryId ?? '',
        }),
      ).then((_) {}).catchError((_) {});

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('User updated successfully!',
              style: TextStyle(color: Colors.green)),
          backgroundColor: Colors.black,
          duration: Duration(seconds: 2),
        ));
        widget.onCustomerAdded();

        // Only update current user's session if editing your own profile
        final isEditingSelf = targetUid == widget.uid;
        if (isEditingSelf && selectedRole != widget.initialRoles) {
          Provider.of<UserProvider>(context, listen: false)
              .updateUserRole(selectedRole!);
          // Refresh AppStateNotifier so sidebar/nav reflects new role
          final appState = AppStateNotifier.instance;
          appState.userRole = selectedRole;
          if (selectedRole != null) {
            appState.accessibleModules = _enabledModules.toList();
            AppRoles.setDynamicModules(
                appState.accessibleModules, appState.accessibleSubModules);
          }
          context.go('/');
        }
      }
      return true;
    } catch (e) {
      setState(() => _errorMessage = 'Error updating user: $e');
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final t = FlutterFlowTheme.of(context);

    return CustomDialog(
      formKey: _formKey,
      icon: Icons.person_outline,
      title: 'Edit User Details',
      subtitle: 'Update information for ${widget.initialName}',
      requiredNote: true,
      submitLabel: 'SAVE CHANGES',
      cancelLabel: 'CANCEL',
      onSubmit: _handleSubmit,
      sections: [
        // ── Section 1: Basic Info ────────────────────────────────────────────
        CustomDialogSection(
          number: 1,
          title: 'Personal Information',
          subtitle: 'Update the user\'s name, role, and contact details.',
          children: [
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth > 480;
              if (wide) {
                return Column(children: [
                  Row(children: [
                    Expanded(child: _buildField(_nameController, 'Username *', t)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildRoleDropdown(t)),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _buildField(_emailController, 'Email', t, enabled: false)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildPhoneRow(t)),
                  ]),
                ]);
              }
              return Column(children: [
                _buildField(_nameController, 'Username *', t),
                const SizedBox(height: 16),
                _buildRoleDropdown(t),
                const SizedBox(height: 16),
                _buildField(_emailController, 'Email', t, enabled: false),
                const SizedBox(height: 16),
                _buildPhoneRow(t),
              ]);
            }),
          ],
        ),

        // ── Section 2: Factory Assignment (Super Admin only) ────────────────
        if (widget.userRole == AppRoles.superAdmin)
          CustomDialogSection(
            number: 2,
            title: 'Factory Assignment',
            subtitle: 'Assign this user to a specific factory sub-account.',
            children: [_buildFactoryDropdown(t)],
          ),

        // ── Section 3: Group Assignment ──────────────────────────────────────
        CustomDialogSection(
          number: widget.userRole == AppRoles.superAdmin ? 3 : 2,
          title: 'Group Assignment',
          subtitle: 'Assign the user to one or more permission groups.',
          children: [
            _buildGroupDropdown(t),
          ],
        ),

        // ── Section 4: Password Reset ────────────────────────────────────────
        CustomDialogSection(
          number: widget.userRole == AppRoles.superAdmin ? 4 : 3,
          title: 'Reset Password (Optional)',
          subtitle:
              'Leave blank to keep the current password. Fill both fields to reset.',
          children: [
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth > 480;
              if (wide) {
                return Row(children: [
                  Expanded(child: _buildField(
                    _newPasswordController, 'New Password', t,
                    isPassword: true, isNew: true,
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _buildField(
                    _confirmPasswordController, 'Confirm Password', t,
                    isPassword: true, isNew: false,
                  )),
                ]);
              }
              return Column(children: [
                _buildField(
                  _newPasswordController, 'New Password', t,
                  isPassword: true, isNew: true,
                ),
                const SizedBox(height: 16),
                _buildField(
                  _confirmPasswordController, 'Confirm Password', t,
                  isPassword: true, isNew: false,
                ),
              ]);
            }),
          ],
        ),

        // ── Section 5: Module Permissions ─────────────────────────────────────
        CustomDialogSection(
          number: widget.userRole == AppRoles.superAdmin ? 5 : 4,
          title: 'Module Permissions',
          subtitle: 'Toggle which modules this user can access in the sidebar.',
          children: [
            _buildModuleToggles(),
          ],
        ),

        // ── Section: Session Settings ────────────────────────────────────────
        if (widget.userRole == AppRoles.superAdmin)
          CustomDialogSection(
            number: 6,
            title: 'Session Settings',
            subtitle: 'Configure login session behaviour for this user.',
            children: [
              SwitchListTile(
                value: _allowMultipleLogins,
                onChanged: (v) => setState(() => _allowMultipleLogins = v),
                title: const Text(
                  'Allow Multiple Logins',
                  style: TextStyle(color: Color(0xFFE2E8F0), fontSize: 14, fontWeight: FontWeight.w600),
                ),
                subtitle: const Text(
                  'Bypasses single-session enforcement — this user can be logged in from multiple devices simultaneously.',
                  style: TextStyle(color: Color(0xFF6B7FA3), fontSize: 12),
                ),
                activeColor: Color(0xFF00D4FF),
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),

        // ── Error display ────────────────────────────────────────────────────
        if (_errorMessage != null)
          CustomDialogSection(
            title: 'Error',
            subtitle: _errorMessage!,
            children: const [],
          ),
      ],
    );
  }

  Widget _buildFactoryDropdown(FlutterFlowTheme t) {
    const kFieldFill  = Color(0xFF151C2E);
    const kLabelColor = Color(0xFF6B7FA3);
    const kTextColor  = Color(0xFFE2E8F0);
    if (_loadingFactories) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    return DropdownButtonFormField<String>(
      value: _selectedFactoryId,
      dropdownColor: const Color(0xFF1E2432),
      style: const TextStyle(color: kTextColor, fontSize: 14),
      items: [
        const DropdownMenuItem(value: '', child: Text('— No factory assigned —')),
        ..._factories.map((f) => DropdownMenuItem(
              value: f['id'],
              child: Text('${f['id']} · ${f['name']}'),
            )),
      ],
      onChanged: (v) => setState(() => _selectedFactoryId = v),
      decoration: InputDecoration(
        labelText: 'Factory (Sub-Account)',
        labelStyle: const TextStyle(color: kLabelColor, fontSize: 13),
        filled: true,
        fillColor: kFieldFill,
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
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    );
  }

  // ── Data scope ─────────────────────────────────────────────────────────────

  /// Which data this user sees, as opposed to which screens they can open.
  /// Sits with the module toggles because an admin setting one almost always
  /// wants to think about the other in the same breath.
  Widget _buildDataScope() {
    final t = FlutterFlowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('DATA SCOPE',
            style: GoogleFonts.poppins(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: t.secondaryText)),
        const SizedBox(height: 4),
        Text(
          'Limits which plants and production areas this user sees across the '
          'dashboards. Leave everything unticked for full access.',
          style: GoogleFonts.poppins(fontSize: 12, color: t.secondaryText),
        ),
        const SizedBox(height: 10),
        DataScopePicker(
          initial: _dataScope,
          onChanged: (scope) => setState(() => _dataScope = scope),
        ),
      ],
    );
  }

  // ── Module toggles ─────────────────────────────────────────────────────────

  Widget _buildModuleToggles() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDataScope(),
        const SizedBox(height: 22),
        Divider(height: 1, color: FlutterFlowTheme.of(context).primary.withOpacity(0.12)),
        const SizedBox(height: 18),
        // Reset to defaults button
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: () {
              if (selectedRole != null) {
                setState(() => _enabledModules =
                    AppRoles.defaultGranularModules(selectedRole!).toSet());
              }
            },
            icon: const Icon(Icons.restart_alt, size: 16, color: Color(0xFF6B7FA3)),
            label: const Text(
              'Reset to role defaults',
              style: TextStyle(color: Color(0xFF6B7FA3), fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Grouped toggles
        ...AppRoles.moduleGroups.entries.map((group) {
          final groupModules = group.value;
          final allEnabled = groupModules.every((m) => _enabledModules.contains(m));
          return Container(
            margin: const EdgeInsets.only(bottom: 12),
            decoration: BoxDecoration(
              color: const Color(0xFF151C2E),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFF2C354A), width: 1),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Group header with select-all toggle
                InkWell(
                  onTap: () {
                    setState(() {
                      if (allEnabled) {
                        _enabledModules.removeAll(groupModules);
                      } else {
                        _enabledModules.addAll(groupModules);
                      }
                    });
                  },
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(14, 10, 10, 6),
                    child: Row(
                      children: [
                        Icon(
                          allEnabled ? Icons.check_box : Icons.check_box_outline_blank,
                          color: allEnabled ? const Color(0xFF7A68FF) : const Color(0xFF6B7FA3),
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          group.key,
                          style: const TextStyle(
                            color: Color(0xFFE2E8F0),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const Divider(height: 1, color: Color(0xFF2C354A)),
                // Individual module toggles
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 6,
                    children: groupModules.map((moduleKey) {
                      final enabled = _enabledModules.contains(moduleKey);
                      final label = AppRoles.moduleLabels[moduleKey] ?? moduleKey;
                      return FilterChip(
                        selected: enabled,
                        label: Text(
                          label,
                          style: TextStyle(
                            color: enabled ? Colors.white : const Color(0xFF6B7FA3),
                            fontSize: 12,
                          ),
                        ),
                        selectedColor: const Color(0xFF7A68FF).withOpacity(0.3),
                        backgroundColor: const Color(0xFF1E2432),
                        checkmarkColor: const Color(0xFF7A68FF),
                        side: BorderSide(
                          color: enabled
                              ? const Color(0xFF7A68FF).withOpacity(0.5)
                              : const Color(0xFF2C354A),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                        onSelected: (val) {
                          setState(() {
                            if (val) {
                              _enabledModules.add(moduleKey);
                            } else {
                              _enabledModules.remove(moduleKey);
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          );
        }),
      ],
    );
  }

  // ── Field builders ──────────────────────────────────────────────────────────

  Widget _buildField(
    TextEditingController controller,
    String label,
    FlutterFlowTheme t, {
    bool enabled = true,
    bool isPassword = false,
    bool isNew = true,
  }) {
    final obscure = isPassword &&
        (isNew ? !_isNewPasswordVisible : !_isConfirmPasswordVisible);
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      style: const TextStyle(color: _kTextColor, fontSize: 14),
      decoration: _inputDeco(t, label).copyWith(
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  (isNew ? _isNewPasswordVisible : _isConfirmPasswordVisible)
                      ? Icons.visibility
                      : Icons.visibility_off,
                  color: _kLabelColor,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  if (isNew) {
                    _isNewPasswordVisible = !_isNewPasswordVisible;
                  } else {
                    _isConfirmPasswordVisible = !_isConfirmPasswordVisible;
                  }
                }),
              )
            : null,
      ),
    );
  }

  Widget _buildRoleDropdown(FlutterFlowTheme t) {
    // If the user being edited has a role that the current user cannot assign,
    // show the role as read-only (e.g., admin trying to edit a superadmin).
    final canChangeRole = roles.contains(selectedRole);

    if (!canChangeRole) {
      return TextFormField(
        initialValue: selectedRole ?? '',
        enabled: false,
        style: const TextStyle(color: _kTextColor, fontSize: 14),
        decoration: _inputDeco(t, 'Role *').copyWith(
          suffixIcon: Tooltip(
            message: 'You do not have permission to change this role',
            child: Icon(Icons.lock_outline, color: _kLabelColor, size: 18),
          ),
        ),
      );
    }

    return DropdownButtonFormField<String>(
      value: selectedRole,
      dropdownColor: const Color(0xFF1E2432),
      style: const TextStyle(color: _kTextColor, fontSize: 14),
      items: roles
          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
          .toList(),
      onChanged: (v) {
        // Role no longer restricts module access — admins explicitly assign
        // modules per user. Changing the role must NOT wipe whatever the
        // admin has already ticked, otherwise assignments silently disappear
        // on save. Use the "Reset to role defaults" button for an explicit
        // reset instead.
        setState(() => selectedRole = v);
      },
      decoration: _inputDeco(t, 'Role *'),
    );
  }

  Widget _buildPhoneRow(FlutterFlowTheme t) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          height: 48,
          decoration: BoxDecoration(
            color: _kFieldFill,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: t.primary.withOpacity(0.15)),
          ),
          child: CountryCodePicker(
            onChanged: (c) => setState(() => _countryCode = c.dialCode ?? ''),
            initialSelection: _countryCode,
            showCountryOnly: false,
            showOnlyCountryWhenClosed: false,
            favorite: const ['+60', 'MY'],
            showFlag: true,
            showFlagDialog: true,
            showDropDownButton: true,
            alignLeft: false,
            padding: EdgeInsets.zero,
            dialogSize: const Size(280, 420),
            dialogBackgroundColor: const Color(0xFF1E2432),
            dialogTextStyle: const TextStyle(color: Colors.white),
            textStyle: const TextStyle(color: _kTextColor, fontSize: 13),
            searchDecoration: InputDecoration(
              hintText: 'Search...',
              filled: true,
              fillColor: _kFieldFill,
              hintStyle: const TextStyle(color: _kLabelColor),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide(color: t.primary.withOpacity(0.15)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _buildField(_phoneController, 'Phone *', t),
        ),
      ],
    );
  }

  Widget _buildGroupDropdown(FlutterFlowTheme t) {
    return DropdownSearch<String>.multiSelection(
      items: (filter, loadProps) => groups,
      filterFn: (groupId, filter) {
        final index = groups.indexOf(groupId);
        final name = (index != -1 && index < groupsName.length)
            ? groupsName[index]
            : '';
        return name.toLowerCase().contains(filter.toLowerCase());
      },
      itemAsString: (groupId) {
        final index = groups.indexOf(groupId);
        return (index != -1 && index < groupsName.length)
            ? groupsName[index]
            : groupId;
      },
      compareFn: (a, b) => a == b,
      selectedItems: selectedGroups ?? [],
      popupProps: PopupPropsMultiSelection.menu(
        containerBuilder: (_, popupWidget) => Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E2432),
            borderRadius: BorderRadius.circular(10),
          ),
          child: popupWidget,
        ),
        fit: FlexFit.loose,
        showSearchBox: true,
        searchFieldProps: TextFieldProps(
          style: const TextStyle(fontSize: 14, color: Colors.white),
          decoration: InputDecoration(
            hintText: 'Search...',
            hintStyle: const TextStyle(color: _kLabelColor),
            fillColor: _kFieldFill,
            filled: true,
            border: OutlineInputBorder(
              borderSide: BorderSide(color: t.primary.withOpacity(0.15)),
            ),
          ),
        ),
        scrollbarProps: const ScrollbarProps(thumbVisibility: true),
        searchDelay: Duration.zero,
        itemBuilder: (context, groupId, isDisabled, isSelected) {
          final index = groups.indexOf(groupId);
          final name = (index != -1 && index < groupsName.length)
              ? groupsName[index]
              : groupId;
          return ListTile(
            title: Text(name,
                style: TextStyle(
                  fontSize: 14,
                  color: isSelected ? Colors.black : Colors.white,
                )),
            selected: isSelected,
            selectedTileColor: t.primary,
          );
        },
        showSelectedItems: true,
        onItemAdded: (sel, _) => setState(() {
          selectedGroups = sel;
          _errorMessage = null;
        }),
        onItemRemoved: (sel, _) => setState(() {
          selectedGroups = sel;
          _errorMessage = null;
        }),
      ),
      dropdownBuilder: (context, selectedList) => Text(
        selectedList.isNotEmpty ? selectedList.join(', ') : 'Select groups...',
        style: TextStyle(
          color: selectedList.isNotEmpty ? _kTextColor : _kLabelColor,
          fontSize: 14,
        ),
      ),
      decoratorProps: DropDownDecoratorProps(
        decoration: _inputDeco(t, 'Groups').copyWith(
          floatingLabelBehavior: FloatingLabelBehavior.always,
        ),
      ),
    );
  }

  InputDecoration _inputDeco(FlutterFlowTheme t, String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: _kLabelColor, fontSize: 13),
      filled: true,
      fillColor: _kFieldFill,
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
