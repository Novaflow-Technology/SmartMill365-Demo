import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/widgets/data_scope_picker.dart';
import 'package:smartmachine365/models/user_scope.dart';
import 'package:country_code_picker/country_code_picker.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:dropdown_search/dropdown_search.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/nav/nav.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '../../../../components/dialogs/custom_dialog.dart';
import 'package:smartmachine365/services/app_config.dart';

// ─────────────────────────────────────────────────────────────────────────────

class AddCustomerDialog extends StatefulWidget {
  final String userRole;
  final VoidCallback onCustomerAdded;

  const AddCustomerDialog({
    super.key,
    required this.userRole,
    required this.onCustomerAdded,
  });

  @override
  _AddCustomerDialogState createState() => _AddCustomerDialogState();
}

class _AddCustomerDialogState extends State<AddCustomerDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  final TextEditingController _nameController        = TextEditingController();
  final TextEditingController _phoneController       = TextEditingController();
  final TextEditingController _emailController       = TextEditingController();
  final TextEditingController _passwordController    = TextEditingController();
  final TextEditingController _conPasswordController = TextEditingController();

  String?       selectedRole;
  Set<String>   _enabledModules = {};

  /// Which plants and areas the new account may see. Empty means unrestricted,
  /// which is the right default: an admin who has not thought about scope yet
  /// should not accidentally create someone who can see nothing.
  UserScope _dataScope = UserScope.unrestricted;
  List<String>? selectedGroups = [];
  List<String>  groups         = [];
  List<String>  groupsName     = [];
  String        _countryCode   = '+60';
  String?       _errorMessage;

  String?                    _selectedFactoryId;
  List<Map<String, String>>  _factories = [];

  bool _isPasswordVisible        = false;
  bool _isConfirmPasswordVisible = false;
  bool _allowMultipleLogins      = false;

  // ── Style tokens ──────────────────────────────────────────────────────────
  static const _kFieldFill  = Color(0xFF151C2E);
  static const _kLabelColor = Color(0xFF6B7FA3);
  static const _kTextColor  = Color(0xFFE2E8F0);

  // ── Regexes ───────────────────────────────────────────────────────────────
  final _emailRegex = RegExp(r'^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$');
  final _phoneRegex = RegExp(r'^\d{9,14}$');
  final _pwRegex    = RegExp(
    r'^(?=.*[A-Z])(?=.*[a-z])(?=.*\d)(?=.*[@$!%*?&])[A-Za-z\d@$!%*?&]{8,}$',
  );

  @override
  void initState() {
    super.initState();
    fetchGroups();
    if (widget.userRole == AppRoles.superAdmin) fetchFactories();
    // Start on the customer whose console this is. Creating an account for
    // someone else is then a deliberate change rather than the default.
    _selectedFactoryId =
        AppConfig.clientId.isNotEmpty ? AppConfig.clientId : null;
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _passwordController.dispose();
    _conPasswordController.dispose();
    super.dispose();
  }

  // ── API ───────────────────────────────────────────────────────────────────
  Future<void> fetchGroups() async {
    try {
      final res = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List<dynamic>;
        setState(() {
          groups     = data.map((g) => g['id'].toString()).toList();
          groupsName = data.map((g) => g['name'].toString()).toList();
        });
      }
    } catch (e) { debugPrint('fetchGroups: $e'); }
  }

  Future<void> fetchFactories() async {
    try {
      final res = await http.get(Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/factory'));
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as List<dynamic>;
        setState(() {
          final all = data
              .map((f) => {
                    'id': f['id'].toString(),
                    'name': f['name'].toString(),
                    'customer_id': (f['customer_id'] ?? '').toString(),
                  })
              .toList();
          // This field decides which customer the account belongs to, and that
          // is what keeps one customer's user list out of another's. The master
          // mixes customers and their plants in one list, so a plant picked
          // here would put the account in a tenant that does not exist and it
          // would show up for nobody. A row is a customer when its customer_id
          // is not another row's id; the rest are plants and are labelled.
          final ids = all.map((f) => f['id']).toSet();
          for (final f in all) {
            final owner = f['customer_id'] ?? '';
            f['isCustomer'] = ids.contains(owner) ? 'false' : 'true';
            f['ownerName'] = ids.contains(owner)
                ? (all.firstWhere((x) => x['id'] == owner,
                        orElse: () => const {'name': ''})['name'] ??
                    '')
                : '';
          }
          all.sort((a, b) {
            final ac = a['isCustomer'] == 'true' ? 0 : 1;
            final bc = b['isCustomer'] == 'true' ? 0 : 1;
            if (ac != bc) return ac - bc;
            return (a['name'] ?? '').compareTo(b['name'] ?? '');
          });
          _factories = all;
        });
      }
    } catch (e) { debugPrint('fetchFactories: $e'); }
  }

  Future<String> createUser(String email, String password) async {
    const apiKey = 'AIzaSyAVXSR75QEzZ6mjzacYNtXagZZlvhbN9IM';
    final res = await http.post(
      Uri.parse('https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=$apiKey'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'email': email, 'password': password, 'returnSecureToken': true}),
    );

    if (res.statusCode == 200) {
      final body = jsonDecode(res.body);
      final uid = body['localId']?.toString() ?? '';
      if (uid.isEmpty) throw Exception('Auth account created but UID missing in response.');
      return uid;
    }

    String apiError;
    try {
      apiError = jsonDecode(res.body)['error']['message']?.toString() ?? res.body;
    } catch (_) {
      apiError = res.body;
    }
    throw Exception('Auth creation failed (${res.statusCode}): $apiError');
  }

  /// Seed a new user with the same settings as the currently logged-in
  /// admin/superadmin (energy, kanban, facilities) — the only settings still
  /// scoped per-account. Billing config, tariff categories, and TNB meters
  /// are shared across every user of this client (see
  /// AppConfig.sharedConfigOwnerId) and need no per-account copy.
  /// Failures here are non-fatal — user creation must still succeed.
  Future<void> _seedDefaultSettingsFor(String newUid) async {
    final sourceUid = AppStateNotifier.instance.uid ?? '';
    if (sourceUid.isEmpty || sourceUid == newUid) return;

    Future<void> copyJson(String getUrl, String postUrl) async {
      try {
        final r = await http.get(Uri.parse(getUrl));
        if (r.statusCode != 200 || r.body.isEmpty) return;
        final body = jsonDecode(r.body);
        if (body == null) return;
        await http.post(
          Uri.parse(postUrl),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(body is Map ? (body['settings'] ?? body) : body),
        );
      } catch (_) {}
    }

    // Energy system settings (contract capacity, TOU, overload risk, etc.)
    await copyJson(
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energy-settings/$sourceUid',
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/energy-settings/$newUid',
    );

    // Tariff categories and master billing config are shared across every
    // user of this client now (see AppConfig.sharedConfigOwnerId) — no
    // longer copied per-account.

    // Kanban dashboard settings (templates + active settings).
    await copyJson(
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings/$sourceUid',
      'https://us-central1-smartmill365-demo.cloudfunctions.net/api/kanban-settings/$newUid',
    );

    // Master facility settings — the GET returns a list, so copy each one.
    try {
      final r = await http.get(Uri.parse(
          'https://us-central1-smartmill365-demo.cloudfunctions.net/api/facilities/$sourceUid'));
      if (r.statusCode == 200 && r.body.isNotEmpty) {
        final decoded = jsonDecode(r.body);
        final List<dynamic> items = decoded is List ? decoded : [];
        for (final item in items) {
          if (item is! Map) continue;
          await http.post(
            Uri.parse(
                'https://us-central1-smartmill365-demo.cloudfunctions.net/api/facilities/$newUid'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(item),
          );
        }
      }
    } catch (_) {}

    // TNB meters are shared across every user of this client now — no
    // longer copied per-account.
  }

  Future<void> addCustomer(String name, String phone, String email,
      List<dynamic> groupIds, String role, String uid, String factoryId) async {
    final res = await http.post(
      Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/add'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'name': name, 'phone': phone, 'email': email,
          'groupIds': groupIds, 'role': role, 'uid': uid, 'factory_id': factoryId}),
    );
    if (res.statusCode != 201) {
      String apiError;
      try {
        apiError = jsonDecode(res.body)['error']?.toString() ?? res.body;
      } catch (_) {
        apiError = res.body;
      }
      throw Exception('Failed to add user record: $apiError');
    }
  }

  Future<bool> _handleSubmit() async {
    setState(() => _errorMessage = null);
    if (!_formKey.currentState!.validate()) return false;
    if (selectedRole == null || selectedRole!.isEmpty) {
      setState(() => _errorMessage = 'A role must be assigned before registering.');
      return false;
    }
    // An account with no customer belongs to no one, and a user list that keeps
    // unassigned rows visible to everybody then shows it under every customer.
    // That is how an account created here turned up on another customer's
    // screen, so the field is answered before the account exists rather than
    // corrected afterwards.
    if (widget.userRole == AppRoles.superAdmin &&
        (_selectedFactoryId ?? '').isEmpty) {
      setState(() => _errorMessage =
          "Choose the customer this account belongs to. Without one it appears on every customer's user list.");
      return false;
    }
    try {
      final uid = await createUser(
        _emailController.text.trim(),
        _passwordController.text,
      );
      await addCustomer(
        _nameController.text.trim(),
        '$_countryCode ${_phoneController.text.trim()}',
        _emailController.text.trim(),
        selectedGroups ?? [],
        selectedRole!,
        uid,
        _selectedFactoryId ?? '',
      );
      // Seed default settings (energy + master billing) from current admin
      // so every new account starts populated like a superadmin would.
      await _seedDefaultSettingsFor(uid);
      await FirebaseFirestore.instance.collection('account_status').doc(uid).set({
        'disabled': false,
        'allow_multiple_logins': _allowMultipleLogins,
        'updated_at': FieldValue.serverTimestamp(),
      });
      await FirebaseFirestore.instance.collection('roles').doc(uid).set({
        'name': selectedRole,
        // Seed with granular module keys only (no broad legacy keys), and
        // no readonly_* sub-modules. The admin assigns the rest from the
        // edit dialog. Roles no longer carry implicit access.
        'accessible_modules': _enabledModules.toList(),
        // Baseline of what the admin was shown, so a module switched off here
        // is not read back as one that simply had not shipped yet.
        'modules_reviewed': AppRoles.allModuleKeys,
        // Written at creation so the account starts with the access it was
        // meant to have, instead of being created wide open and narrowed in a
        // second pass someone might forget.
        'data_scope': _dataScope.toJson(),
        'accessible_sub_modules': const <String>[],
      });
      widget.onCustomerAdded();
      return true;
    } catch (e) {
      setState(() {
        _errorMessage = e.toString().replaceFirst('Exception: ', '');
      });
      return false;
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final t = FlutterFlowTheme.of(context);
    final assignable = AppRoles.assignableRoles(widget.userRole);
    final List<String> roles = assignable.isEmpty
        ? AppRoles.assignableRoles(AppRoles.superAdmin)
        : assignable;

    return CustomDialog(
      formKey: _formKey,
      icon: Icons.person_add_outlined,
      title: 'Register New Personnel',
      subtitle: 'Create a new user account with role and group assignment.',
      requiredNote: true,
      submitLabel: 'CONFIRM & REGISTER',
      cancelLabel: 'CANCEL',
      onSubmit: _handleSubmit,
      sections: [
        // ── Section 1: Personal Information ─────────────────────────────────
        CustomDialogSection(
          number: 1,
          title: 'Personal Information',
          subtitle: 'Enter the user\'s name, email, phone, and assigned role.',
          children: [
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth > 480;
              if (wide) {
                return Column(children: [
                  Row(children: [
                    Expanded(child: _buildField(_nameController, 'Full Name *', t,
                        validator: (v) => (v == null || v.trim().isEmpty)
                            ? 'Full name is required'
                            : null)),
                    const SizedBox(width: 12),
                    Expanded(child: _buildRoleDropdown(t, roles)),
                  ]),
                  const SizedBox(height: 16),
                  Row(children: [
                    Expanded(child: _buildField(_emailController, 'Work Email *', t,
                        keyboardType: TextInputType.emailAddress,
                        validator: (v) {
                          if (v == null || v.isEmpty) return 'Email is required';
                          if (!_emailRegex.hasMatch(v)) return 'Enter a valid email';
                          return null;
                        })),
                    const SizedBox(width: 12),
                    Expanded(child: _buildPhoneRow(t)),
                  ]),
                ]);
              }
              return Column(children: [
                _buildField(_nameController, 'Full Name *', t,
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? 'Full name is required'
                        : null),
                const SizedBox(height: 16),
                _buildField(_emailController, 'Work Email *', t,
                    keyboardType: TextInputType.emailAddress,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Email is required';
                      if (!_emailRegex.hasMatch(v)) return 'Enter a valid email';
                      return null;
                    }),
                const SizedBox(height: 16),
                _buildPhoneRow(t),
                const SizedBox(height: 16),
                _buildRoleDropdown(t, roles),
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

        // ── Section 3: Group Assignment ─────────────────────────────────────
        CustomDialogSection(
          number: widget.userRole == AppRoles.superAdmin ? 3 : 2,
          title: 'Group Assignment (Optional)',
          subtitle: 'Assign the user to one or more permission groups.',
          children: [
            _buildGroupDropdown(t),
          ],
        ),

        // ── Section: Password ───────────────────────────────────────────────
        CustomDialogSection(
          number: widget.userRole == AppRoles.superAdmin ? 4 : 3,
          title: 'Set Password',
          subtitle:
              'Create a secure password for the new user account.',
          children: [
            LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth > 480;
              if (wide) {
                return Row(children: [
                  Expanded(child: _buildField(
                    _passwordController, 'Password *', t,
                    isPassword: true, isNew: true,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Password is required';
                      if (!_pwRegex.hasMatch(v))
                        return 'Min 8 chars: uppercase, lowercase, number & special char';
                      return null;
                    },
                  )),
                  const SizedBox(width: 12),
                  Expanded(child: _buildField(
                    _conPasswordController, 'Confirm Password *', t,
                    isPassword: true, isNew: false,
                    validator: (v) {
                      if (v == null || v.isEmpty) return 'Please confirm your password';
                      if (v != _passwordController.text) return 'Passwords do not match';
                      return null;
                    },
                  )),
                ]);
              }
              return Column(children: [
                _buildField(
                  _passwordController, 'Password *', t,
                  isPassword: true, isNew: true,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Password is required';
                    if (!_pwRegex.hasMatch(v))
                      return 'Min 8 chars: uppercase, lowercase, number & special char';
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _buildField(
                  _conPasswordController, 'Confirm Password *', t,
                  isPassword: true, isNew: false,
                  validator: (v) {
                    if (v == null || v.isEmpty) return 'Please confirm your password';
                    if (v != _passwordController.text) return 'Passwords do not match';
                    return null;
                  },
                ),
              ]);
            }),
          ],
        ),

        // ── Section: Module Permissions ──────────────────────────────────────
        if (selectedRole != null)
          CustomDialogSection(
            number: widget.userRole == AppRoles.superAdmin ? 5 : 4,
            title: 'Module Permissions',
            subtitle: 'Pre-loaded from role defaults. Toggle to customise access before creating.',
            children: [
              _buildDataScope(),
              const SizedBox(height: 20),
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

        // ── Error display ───────────────────────────────────────────────────
        if (_errorMessage != null)
          CustomDialogSection(
            title: 'Error',
            subtitle: _errorMessage!,
            children: const [],
          ),
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
    TextInputType? keyboardType,
    String? Function(String?)? validator,
  }) {
    final obscure = isPassword &&
        (isNew ? !_isPasswordVisible : !_isConfirmPasswordVisible);
    return TextFormField(
      controller: controller,
      enabled: enabled,
      obscureText: obscure,
      keyboardType: keyboardType,
      validator: validator,
      style: const TextStyle(color: _kTextColor, fontSize: 14),
      decoration: _inputDeco(t, label).copyWith(
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  (isNew ? _isPasswordVisible : _isConfirmPasswordVisible)
                      ? Icons.visibility
                      : Icons.visibility_off,
                  color: _kLabelColor,
                  size: 18,
                ),
                onPressed: () => setState(() {
                  if (isNew) {
                    _isPasswordVisible = !_isPasswordVisible;
                  } else {
                    _isConfirmPasswordVisible = !_isConfirmPasswordVisible;
                  }
                }),
              )
            : null,
      ),
    );
  }

  /// Which data this account sees, as opposed to which screens it can open.
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

  Widget _buildModuleToggles() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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

  Widget _buildRoleDropdown(FlutterFlowTheme t, List<String> roles) {
    return DropdownButtonFormField<String>(
      value: selectedRole,
      dropdownColor: const Color(0xFF1E2432),
      style: const TextStyle(color: _kTextColor, fontSize: 14),
      validator: (v) => (v == null || v.isEmpty) ? 'A role must be assigned' : null,
      items: roles
          .map((r) => DropdownMenuItem(value: r, child: Text(r)))
          .toList(),
      onChanged: (v) => setState(() {
        selectedRole = v;
        if (v != null) {
          _enabledModules = AppRoles.defaultGranularModules(v).toSet();
        }
      }),
      decoration: _inputDeco(t, 'Assigned Access Role *'),
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
          child: _buildField(_phoneController, 'Phone *', t,
              keyboardType: TextInputType.phone,
              validator: (v) {
                if (v == null || v.isEmpty) return 'Required';
                if (!_phoneRegex.hasMatch(v)) return 'Invalid phone number';
                return null;
              }),
        ),
      ],
    );
  }

  Widget _buildFactoryDropdown(FlutterFlowTheme t) {
    return DropdownButtonFormField<String>(
      value: _selectedFactoryId,
      dropdownColor: const Color(0xFF1E2432),
      style: const TextStyle(color: _kTextColor, fontSize: 14),
      items: [
        const DropdownMenuItem(value: '', child: Text('— No factory assigned —')),
        ..._factories.map((f) {
          final isCustomer = f['isCustomer'] != 'false';
          final owner = f['ownerName'] ?? '';
          return DropdownMenuItem(
            value: f['id'],
            child: Text(
              isCustomer
                  ? '${f['id']} · ${f['name']}'
                  : '${f['id']} · ${f['name']}  — plant of $owner',
              style: TextStyle(
                  color: isCustomer ? _kTextColor : _kTextColor.withOpacity(0.6),
                  fontSize: 14),
            ),
          );
        }),
      ],
      onChanged: (v) => setState(() => _selectedFactoryId = v),
      decoration: _inputDeco(t, 'Customer (owns this account)'),
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
