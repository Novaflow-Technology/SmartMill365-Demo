import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/components/data_table/data_table_widget.dart';
import 'package:smartmachine365/components/data_table/table_column.dart';
import 'package:smartmachine365/components/dialogs/custom_dialog.dart';
import 'package:smartmachine365/components/page_header/breadcrumb_item.dart';
import 'package:smartmachine365/components/page_header/page_header_widget.dart';
import 'package:smartmachine365/services/app_config.dart';
import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/flutter_flow_util.dart';

const String _baseUrl = 'https://us-central1-smartmill365-demo.cloudfunctions.net/api';

const List<TableColumn> _tariffColumns = [
  TableColumn('Voltage Level', 'voltageLevel', 100, sortable: true),
  TableColumn('Voltage Name', 'voltageName', 100, sortable: true),
  TableColumn('Tariff Category', 'tariffCategory', 150, sortable: true),
  TableColumn('Tariff Name', 'tariffName', 200, sortable: true),
  TableColumn('Typical User', 'typicalUser', 150),
  TableColumn('Status', 'status', 90),
  TableColumn('Billing Config', 'billingConfigured', 130),
  TableColumn('Base Energy Rate', 'baseEnergyRate', 130),
  TableColumn('MD Capacity Charge', 'mdCapacityCharge', 150),
  TableColumn('Current AFA', 'currentAFA', 110),
];

const _voltageLevels = ['LV', 'MV', 'MV TOU', 'HV'];

// ── Delete result variants ────────────────────────────────────────────────────

enum _DeleteOutcome { deleted, hasBillingData, failed }

class _DeleteResult {
  final _DeleteOutcome outcome;
  final String? message;
  const _DeleteResult(this.outcome, {this.message});
}

// ─────────────────────────────────────────────────────────────────────────────

class TariffCategoryWidget extends StatefulWidget {
  const TariffCategoryWidget({super.key});

  @override
  State<TariffCategoryWidget> createState() => _TariffCategoryWidgetState();
}

class _TariffCategoryWidgetState extends State<TariffCategoryWidget> {
  final scaffoldKey = GlobalKey<ScaffoldState>();

  List<Map<String, dynamic>> _rows = [];
  bool _isLoading = false;
  String? _errorMessage;

  // ── Form state ─────────────────────────────────────────────────────────────
  final _formKey = GlobalKey<FormState>();
  final _categoryCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _userCtrl = TextEditingController();
  final _voltageNameCtrl = TextEditingController();
  String _voltageLevel = _voltageLevels.first;
  bool _isActive = true;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _fetchList());
  }

  @override
  void dispose() {
    _categoryCtrl.dispose();
    _nameCtrl.dispose();
    _userCtrl.dispose();
    _voltageNameCtrl.dispose();
    super.dispose();
  }

  // ── API helpers ────────────────────────────────────────────────────────────

  // Tariff categories are shared across every user of this client, not
  // per-login — see AppConfig.sharedConfigOwnerId.
  String get _userId => AppConfig.sharedConfigOwnerId;

  /// GET /tariff-categories/list?userId=
  Future<void> _fetchList() async {
    if (_userId.isEmpty) {
      debugPrint('[TariffCategory] _fetchList: userId is empty, aborting.');
      return;
    }
    debugPrint('[TariffCategory] _fetchList: fetching for userId=$_userId');

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final uri = Uri.parse('$_baseUrl/tariff-categories/list').replace(queryParameters: {'userId': _userId});
      debugPrint('[TariffCategory] _fetchList: GET $uri');

      final response = await http.get(uri, headers: AppConfig.headers);
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[TariffCategory] _fetchList: status=${response.statusCode} body=$body');

      if (response.statusCode == 200 && body['success'] == true) {
        final list = (body['data'] as List).cast<Map<String, dynamic>>();
        debugPrint('[TariffCategory] _fetchList: loaded ${list.length} record(s).');
        setState(() => _rows = list);
      } else {
        final msg = body['message'] ?? 'Failed to load data.';
        debugPrint('[TariffCategory] _fetchList: error response — $msg');
        setState(() => _errorMessage = msg);
      }
    } catch (e, stackTrace) {
      debugPrint('[TariffCategory] _fetchList: exception — $e\n$stackTrace');
      setState(() => _errorMessage = 'Network error: $e');
    } finally {
      setState(() => _isLoading = false);
    }
  }

  /// POST /tariff-categories/create
  Future<bool> _createRecord(Map<String, dynamic> payload) async {
    final response = await http.post(
      Uri.parse('$_baseUrl/tariff-categories/create'),
      headers: AppConfig.headers,
      body: jsonEncode(payload),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode == 201 && body['success'] == true) {
      final created = body['data'] as Map<String, dynamic>;
      setState(() => _rows.insert(0, created));
      return true;
    }

    _showSnackbar(body['message'] ?? 'Failed to create record.', isError: true);
    return false;
  }

  /// PUT /tariff-categories/edit/:id
  Future<bool> _editRecord(String id, Map<String, dynamic> payload) async {
    final response = await http.put(
      Uri.parse('$_baseUrl/tariff-categories/edit/$id'),
      headers: AppConfig.headers,
      body: jsonEncode(payload),
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;

    if (response.statusCode == 200 && body['success'] == true) {
      final updated = body['data'] as Map<String, dynamic>;
      setState(() {
        final idx = _rows.indexWhere((r) => r['id'] == id);
        if (idx != -1) _rows[idx] = updated;
      });
      return true;
    }

    _showSnackbar(body['message'] ?? 'Failed to update record.', isError: true);
    return false;
  }

  /// DELETE /tariff-categories/delete/:id?userId=&forceDelete=true|false
  Future<_DeleteResult> _deleteRecord(String id, {bool force = false}) async {
    final uri = Uri.parse('$_baseUrl/tariff-categories/delete/$id').replace(
      queryParameters: {
        'userId': _userId,
        if (force) 'forceDelete': 'true',
      },
    );

    debugPrint('[TariffCategory] _deleteRecord: DELETE $uri');

    try {
      final response = await http.delete(uri, headers: AppConfig.headers).timeout(const Duration(seconds: 15));
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      debugPrint('[TariffCategory] _deleteRecord: status=${response.statusCode} body=$body');

      if (response.statusCode == 200 && body['success'] == true) {
        setState(() => _rows.removeWhere((r) => r['id'] == id));
        return const _DeleteResult(_DeleteOutcome.deleted);
      }

      if (response.statusCode == 409) {
        return _DeleteResult(
          _DeleteOutcome.hasBillingData,
          message: body['message'] as String?,
        );
      }

      return _DeleteResult(
        _DeleteOutcome.failed,
        message: body['message'] as String? ?? 'Failed to delete record.',
      );
    } catch (e) {
      return _DeleteResult(_DeleteOutcome.failed, message: 'Network error: $e');
    }
  }

  // ── Delete flow ────────────────────────────────────────────────────────────

  Future<void> _onDelete(Map<String, dynamic> row) async {
    final id = row['id'] as String;
    final name = row['tariffName'] as String? ?? row['tariffCategory'] as String? ?? id;

    // Step 1: confirm plain deletion
    final confirmed = await _showDeleteConfirmDialog(name);
    if (!confirmed) return;

    // Step 2: attempt delete (no force)
    final result = await _deleteRecord(id);

    switch (result.outcome) {
      case _DeleteOutcome.deleted:
        _showSnackbar('Tariff category deleted.');
        return;

      case _DeleteOutcome.hasBillingData:
        // Step 3: billing data conflict — let user choose
        await _showBillingConflictDialog(id: id, name: name, row: row);
        return;

      case _DeleteOutcome.failed:
        _showSnackbar(result.message ?? 'Delete failed.', isError: true);
        return;
    }
  }

  // ── Delete confirm dialog (FacilityDeleteDialog style) ────────────────────

  Future<bool> _showDeleteConfirmDialog(String name) async {
    return await showDialog<bool>(
          context: context,
          builder: (ctx) {
            final theme = FlutterFlowTheme.of(ctx);
            return Dialog(
              backgroundColor: Colors.transparent,
              child: Container(
                width: responsiveDialogWidth(ctx, 400),
                decoration: BoxDecoration(
                  color: theme.primaryBackground,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: theme.primary.withOpacity(0.12),
                    width: 0.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.4),
                      blurRadius: 30,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // ── Top bar ──────────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border(
                          bottom: BorderSide(
                            color: theme.primary.withOpacity(0.1),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 30,
                            height: 30,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF5252).withOpacity(0.12),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Center(
                              child: Icon(
                                Icons.warning_amber_rounded,
                                size: 16,
                                color: Color(0xFFFF5252),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          const Text(
                            'Confirm Deletion',
                            style: TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: Colors.white,
                              letterSpacing: -0.2,
                            ),
                          ),
                          const Spacer(),
                          InkWell(
                            onTap: () => Navigator.of(ctx).pop(false),
                            borderRadius: BorderRadius.circular(6),
                            child: Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: Colors.white.withOpacity(0.05),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Icon(
                                Icons.close,
                                size: 16,
                                color: Colors.white.withOpacity(0.4),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),

                    // ── Body ─────────────────────────────────────────────────
                    Padding(
                      padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                      child: Column(
                        children: [
                          // Tariff info card
                          Container(
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFF5252).withOpacity(0.06),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: const Color(0xFFFF5252).withOpacity(0.12),
                                width: 0.5,
                              ),
                            ),
                            child: Row(
                              children: [
                                Container(
                                  width: 32,
                                  height: 32,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFFF5252).withOpacity(0.12),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: const Icon(
                                    Icons.receipt_long_outlined,
                                    color: Color(0xFFFF5252),
                                    size: 16,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Text(
                                        'TARIFF CATEGORY',
                                        style: TextStyle(
                                          color: Colors.white.withOpacity(0.3),
                                          fontSize: 10,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.8,
                                        ),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        name,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 14,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(height: 18),
                          Text(
                            'This action cannot be undone. Are you sure you want to permanently delete this tariff category?',
                            style: TextStyle(
                              color: Colors.white.withOpacity(0.5),
                              fontSize: 13,
                              height: 1.5,
                            ),
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),

                    // ── Footer ────────────────────────────────────────────────
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                      decoration: BoxDecoration(
                        border: Border(
                          top: BorderSide(
                            color: theme.primary.withOpacity(0.1),
                            width: 0.5,
                          ),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          InkWell(
                            onTap: () => Navigator.of(ctx).pop(false),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: theme.primary.withOpacity(0.15),
                                  width: 0.5,
                                ),
                              ),
                              child: Text(
                                'CANCEL',
                                style: TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white.withOpacity(0.5),
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 10),
                          InkWell(
                            onTap: () => Navigator.of(ctx).pop(true),
                            borderRadius: BorderRadius.circular(8),
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF5252),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.delete_outline, size: 14, color: Colors.white),
                                  SizedBox(width: 6),
                                  Text(
                                    'DELETE',
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ) ??
        false;
  }

  // ── Billing conflict dialog ────────────────────────────────────────────────

  Future<void> _showBillingConflictDialog({
    required String id,
    required String name,
    required Map<String, dynamic> row,
  }) async {
    final choice = await showDialog<_ConflictChoice>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final theme = FlutterFlowTheme.of(ctx);
        return Dialog(
          backgroundColor: Colors.transparent,
          child: Container(
            width: responsiveDialogWidth(ctx, 440),
            decoration: BoxDecoration(
              color: theme.primaryBackground,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: theme.primary.withOpacity(0.12),
                width: 0.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.4),
                  blurRadius: 30,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Top bar ────────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color: theme.primary.withOpacity(0.1),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6F00).withOpacity(0.12),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Center(
                          child: Icon(
                            Icons.warning_amber_rounded,
                            size: 16,
                            color: Color(0xFFFF6F00),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Billing Data Linked',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const Spacer(),
                      InkWell(
                        onTap: () => Navigator.of(ctx).pop(_ConflictChoice.cancel),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.05),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Icon(
                            Icons.close,
                            size: 16,
                            color: Colors.white.withOpacity(0.4),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── Body ──────────────────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // Tariff info card
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: const Color(0xFFFF6F00).withOpacity(0.06),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(0xFFFF6F00).withOpacity(0.12),
                            width: 0.5,
                          ),
                        ),
                        child: Row(
                          children: [
                            Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: const Color(0xFFFF6F00).withOpacity(0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Icon(
                                Icons.receipt_long_outlined,
                                color: Color(0xFFFF6F00),
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'TARIFF CATEGORY',
                                    style: TextStyle(
                                      color: Colors.white.withOpacity(0.3),
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'This category has saved billing configuration data. '
                        'Deleting it will permanently remove all linked billing config. '
                        'Alternatively, deactivate it to hide it from the dropdown '
                        'while keeping the billing data intact.',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withOpacity(0.5),
                          height: 1.55,
                        ),
                      ),
                      const SizedBox(height: 20),
                      _ConflictOption(
                        icon: Icons.delete_forever_outlined,
                        iconColor: const Color(0xFFFF5252),
                        title: 'Force Delete',
                        subtitle: 'Permanently deletes the category AND its billing config.',
                        onTap: () => Navigator.pop(ctx, _ConflictChoice.forceDelete),
                      ),
                      const SizedBox(height: 10),
                      _ConflictOption(
                        icon: Icons.visibility_off_outlined,
                        iconColor: const Color(0xFFFF9800),
                        title: 'Deactivate Instead',
                        subtitle: 'Hides the category from the dropdown. Billing data is preserved.',
                        onTap: () => Navigator.pop(ctx, _ConflictChoice.deactivate),
                      ),
                    ],
                  ),
                ),

                // ── Footer ────────────────────────────────────────────────
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: theme.primary.withOpacity(0.1),
                        width: 0.5,
                      ),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      InkWell(
                        onTap: () => Navigator.of(ctx).pop(_ConflictChoice.cancel),
                        borderRadius: BorderRadius.circular(8),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 9),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: theme.primary.withOpacity(0.15),
                              width: 0.5,
                            ),
                          ),
                          child: Text(
                            'CANCEL',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: Colors.white.withOpacity(0.5),
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (choice == null || choice == _ConflictChoice.cancel) return;

    if (choice == _ConflictChoice.forceDelete) {
      final result = await _deleteRecord(id, force: true);
      if (result.outcome == _DeleteOutcome.deleted) {
        _showSnackbar('Category and linked billing config deleted.');
      } else {
        _showSnackbar(result.message ?? 'Force delete failed.', isError: true);
      }
    } else if (choice == _ConflictChoice.deactivate) {
      final payload = <String, dynamic>{
        'userId': _userId,
        'voltageLevel': row['voltageLevel'],
        'voltageName': row['voltageName'],
        'tariffCategory': row['tariffCategory'],
        'tariffName': row['tariffName'],
        'typicalUser': row['typicalUser'] ?? '',
        'status': 'Inactive',
      };
      final success = await _editRecord(id, payload);
      if (success) _showSnackbar('"$name" deactivated. Billing data preserved.');
    }
  }

  // ── UI helpers ─────────────────────────────────────────────────────────────

  /// Shows whether this category has a saved Master Billing Config, and
  /// whether it's the one currently applied — merged into each row by the
  /// backend's GET /list (joins masterBillingConfig/{userId}/categories).
  Widget _billingConfigBadge(Map<String, dynamic> row) {
    final configured = row['billingConfigured'] == true;
    final applied = row['isAppliedBillingConfig'] == true;

    if (!configured) {
      return Text(
        'Not configured',
        style: TextStyle(color: Colors.white.withOpacity(0.3), fontSize: 12),
      );
    }

    final color = applied ? const Color(0xFF10B981) : const Color(0xFF6C3FE8);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.35), width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(applied ? Icons.check_circle : Icons.receipt_long_outlined, size: 12, color: color),
          const SizedBox(width: 5),
          Text(
            applied ? 'Applied' : 'Configured',
            style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }

  /// Renders a saved Master Billing Config rate value (baseEnergyRate,
  /// mdCapacityCharge, currentAFA — merged into each row by GET /list),
  /// labelled with the same unit shown on the Master Billing Config form
  /// (RM/kWh for energy/AFA rates, RM/kW/month for MD capacity charge).
  /// Empty/missing values show a dim placeholder instead of blank.
  Widget _billingRateCell(String value, String unit) {
    if (value.isEmpty) {
      return Text('—', style: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 12));
    }
    // unit is e.g. "RM/kWh" or "RM/kW/month" — render as "RM 20/kWh".
    final perUnit = unit.startsWith('RM/') ? unit.substring(3) : unit;
    return Text('RM $value/$perUnit', style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500));
  }

  void _showSnackbar(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? const Color(0xFFFF5252) : const Color(0xFF6C3FE8),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  void _prepareControllers([Map<String, dynamic>? row]) {
    _voltageLevel = row?['voltageLevel'] ?? _voltageLevels.first;
    _voltageNameCtrl.text = row?['voltageName'] ?? '';
    _categoryCtrl.text = row?['tariffCategory'] ?? '';
    _nameCtrl.text = row?['tariffName'] ?? '';
    _userCtrl.text = row?['typicalUser'] ?? '';
    _isActive = (row?['status'] ?? 'Active') == 'Active';
  }

  // ── Input field builder ────────────────────────────────────────────────────

  Widget _inputField({
    required String label,
    required TextEditingController controller,
    bool isRequired = false,
  }) {
    final theme = FlutterFlowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (isRequired) const Text('* ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6C3FE8))),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4),
              letterSpacing: 0.8,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        TextFormField(
          controller: controller,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          validator: isRequired ? (v) => (v == null || v.isEmpty) ? 'Required' : null : null,
          decoration: InputDecoration(
            hintText: 'Enter ${label.toLowerCase()}',
            hintStyle: TextStyle(color: Colors.white.withOpacity(0.2), fontSize: 13),
            filled: true,
            fillColor: theme.primaryBackground.withOpacity(0.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primary.withOpacity(0.15), width: 0.5)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primary.withOpacity(0.15), width: 0.5)),
            focusedBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF6C3FE8), width: 1)),
            errorBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFFF5252), width: 0.8)),
            focusedErrorBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFFF5252), width: 1)),
            errorStyle: const TextStyle(fontSize: 10, color: Color(0xFFFF5252)),
          ),
        ),
      ],
    );
  }

  // ── Dropdown field builder ─────────────────────────────────────────────────

  Widget _dropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
    required StateSetter setDialogState,
    bool isRequired = false,
  }) {
    final theme = FlutterFlowTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(children: [
          if (isRequired) const Text('* ', style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF6C3FE8))),
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Colors.white.withOpacity(0.4),
              letterSpacing: 0.8,
            ),
          ),
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(
          value: value,
          dropdownColor: theme.primaryBackground,
          style: const TextStyle(color: Colors.white, fontSize: 13),
          decoration: InputDecoration(
            filled: true,
            fillColor: theme.primaryBackground.withOpacity(0.5),
            contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primary.withOpacity(0.15), width: 0.5)),
            enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8), borderSide: BorderSide(color: theme.primary.withOpacity(0.15), width: 0.5)),
            focusedBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFF6C3FE8), width: 1)),
            errorBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFFF5252), width: 0.8)),
            focusedErrorBorder:
                OutlineInputBorder(borderRadius: BorderRadius.circular(8), borderSide: const BorderSide(color: Color(0xFFFF5252), width: 1)),
            errorStyle: const TextStyle(fontSize: 10, color: Color(0xFFFF5252)),
          ),
          items: items.map((v) => DropdownMenuItem(value: v, child: Text(v))).toList(),
          onChanged: (v) => setDialogState(() => onChanged(v)),
          validator: isRequired ? (v) => (v == null || v.isEmpty) ? 'Required' : null : null,
        ),
      ],
    );
  }

  // ── Create / Edit dialog ───────────────────────────────────────────────────

  void _openDialog({Map<String, dynamic>? editRow}) {
    _prepareControllers(editRow);
    final isEdit = editRow != null;

    showDialog(
      context: context,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setDialogState) => CustomDialog(
          formKey: _formKey,
          icon: isEdit ? Icons.edit_outlined : Icons.add_circle_outline,
          title: isEdit ? 'Edit Tariff Category' : 'Add New Tariff Category',
          subtitle: isEdit ? 'Update the details of the selected tariff category.' : 'Register a new tariff category to the system.',
          requiredNote: true,
          submitLabel: isEdit ? 'SAVE' : 'SUBMIT',
          sections: [
            CustomDialogSection(
              title: 'Tariff Details',
              subtitle: 'Voltage level, category code, name and typical user.',
              children: [
                _dropdownField(
                  label: 'Voltage Level',
                  value: _voltageLevel,
                  items: _voltageLevels,
                  onChanged: (v) => _voltageLevel = v!,
                  setDialogState: setDialogState,
                  isRequired: true,
                ),
                const SizedBox(height: 16),
                _inputField(
                  label: 'Voltage Name',
                  controller: _voltageNameCtrl,
                  isRequired: true,
                ),
                const SizedBox(height: 16),
                _inputField(
                  label: 'Tariff Category',
                  controller: _categoryCtrl,
                  isRequired: true,
                ),
                const SizedBox(height: 16),
                _inputField(
                  label: 'Tariff Name',
                  controller: _nameCtrl,
                  isRequired: true,
                ),
                const SizedBox(height: 16),
                _inputField(
                  label: 'Typical User',
                  controller: _userCtrl,
                ),
                const SizedBox(height: 20),
                _ActiveToggle(
                  value: _isActive,
                  onChanged: (v) => setDialogState(() => _isActive = v),
                ),
              ],
            ),
          ],
          onSubmit: () async {
            final payload = <String, dynamic>{
              'userId': _userId,
              'voltageLevel': _voltageLevel,
              'voltageName': _voltageNameCtrl.text.trim(),
              'tariffCategory': _categoryCtrl.text.trim(),
              'tariffName': _nameCtrl.text.trim(),
              'typicalUser': _userCtrl.text.trim(),
              'status': _isActive ? 'Active' : 'Inactive',
            };

            final success = isEdit ? await _editRecord(editRow!['id'], payload) : await _createRecord(payload);

            if (success) {
              _showSnackbar(isEdit ? 'Record updated successfully.' : 'Record created successfully.');
              _fetchList();
            }

            return success;
          },
        ),
      ),
    );
  }

  // ── Callbacks ──────────────────────────────────────────────────────────────

  void _onEdit(Map<String, dynamic> row) => _openDialog(editRow: row);

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => FocusScope.of(context).unfocus(),
      child: Scaffold(
        key: scaffoldKey,
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageHeader(
              breadcrumbs: [
                BreadcrumbItem(label: 'Settings', icon: Icons.settings),
                BreadcrumbItem(label: 'Tariff Category Setup'),
              ],
              title: 'Tariff Category Setup',
              subtitle: 'Manage your tariff categories, all in one place.',
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: _isLoading
                    ? const Center(child: CircularProgressIndicator(color: Color(0xFF6C3FE8)))
                    : _errorMessage != null
                        ? Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(_errorMessage!, style: const TextStyle(color: Color(0xFFFF5252))),
                                const SizedBox(height: 12),
                                TextButton.icon(
                                  onPressed: _fetchList,
                                  icon: const Icon(Icons.refresh, color: Color(0xFF6C3FE8)),
                                  label: const Text('Retry', style: TextStyle(color: Color(0xFF6C3FE8))),
                                ),
                              ],
                            ),
                          )
                        : DataTableWidget(
                            columns: _tariffColumns,
                            rows: _rows,
                            perPage: 10,
                            primaryKey: 'id',
                            primaryColumnKey: 'tariffCategory',
                            primarySubtitleKey: 'tariffName',
                            sortKey: 'voltageLevel',
                            onEdit: _onEdit,
                            onDelete: _onDelete,
                            onSelectionChanged: (ids) {},
                            showSelection: false,
                            showFilterDropdown: false,
                            cellBuilder: (key, value, row) {
                              if (key == 'billingConfigured') return _billingConfigBadge(row);
                              if (key == 'baseEnergyRate') return _billingRateCell(value, 'RM/kWh');
                              if (key == 'mdCapacityCharge') return _billingRateCell(value, 'RM/kW/month');
                              if (key == 'currentAFA') return _billingRateCell(value, 'RM/kWh');
                              return null;
                            },
                            actions: [
                              TableAction(
                                label: 'Add new',
                                icon: Icons.add,
                                isPrimary: true,
                                onTap: () => _openDialog(),
                              ),
                            ],
                          ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Conflict choice enum ──────────────────────────────────────────────────────

enum _ConflictChoice { forceDelete, deactivate, cancel }

// ── Conflict option tile ──────────────────────────────────────────────────────

class _ConflictOption extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ConflictOption({
    required this.icon,
    required this.iconColor,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: iconColor.withOpacity(0.06),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: iconColor.withOpacity(0.25), width: 1),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: iconColor.withOpacity(0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, color: iconColor, size: 18),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: iconColor,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.45),
                      height: 1.4,
                    ),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: Colors.white.withOpacity(0.2), size: 18),
          ],
        ),
      ),
    );
  }
}

// ── Active toggle row ─────────────────────────────────────────────────────────

class _ActiveToggle extends StatelessWidget {
  final bool value;
  final ValueChanged<bool> onChanged;

  const _ActiveToggle({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.04),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.08), width: 0.5),
      ),
      child: Row(children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: value ? const Color(0xFF6C3FE8).withOpacity(0.15) : Colors.white.withOpacity(0.05),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Center(
            child: Icon(
              value ? Icons.check_circle_outline : Icons.radio_button_unchecked,
              size: 16,
              color: value ? const Color(0xFF9D8AEE) : Colors.white.withOpacity(0.25),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Active', style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white)),
              const SizedBox(height: 2),
              Text(
                value ? 'This tariff category is currently active.' : 'This tariff category is currently inactive.',
                style: TextStyle(fontSize: 11, color: Colors.white.withOpacity(0.3)),
              ),
            ],
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
          activeColor: const Color(0xFF6C3FE8),
          activeTrackColor: const Color(0xFF6C3FE8).withOpacity(0.3),
          inactiveThumbColor: Colors.white.withOpacity(0.3),
          inactiveTrackColor: Colors.white.withOpacity(0.08),
        ),
      ]),
    );
  }
}
