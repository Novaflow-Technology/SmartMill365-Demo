import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/user/add.dart';
import 'package:smartmachine365/web_app_template/manage_user_groups/user/edit.dart';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:smartmachine365/services/app_config.dart';
import 'package:smartmachine365/services/site_tenant.dart';

import '/flutter_flow/flutter_flow_theme.dart';
import '/flutter_flow/nav/nav.dart';
import '/flutter_flow/rbac.dart';
import '/flutter_flow/user_presence.dart';
import '../../../../components/dialogs/custom_dialog.dart';
import '../../../../components/data_table/data_table_widget.dart';
import '../../../../components/data_table/table_column.dart';

class UserView extends StatefulWidget {
  final String userUid;
  final String userName;
  final String userEmail;
  final String userRole;
  const UserView({
    super.key,
    required this.userUid,
    required this.userName,
    required this.userEmail,
    required this.userRole,
  });

  @override
  _UserViewState createState() => _UserViewState();
}

class _UserViewState extends State<UserView> {
  final ScrollController _scrollController = ScrollController();
  int currentUserPage = 0;
  List<dynamic> customers = [];
  Map<String, String> groupIdToName = {};
  List<dynamic> groups = [];
  String lastUpdateTime = '';
  List<dynamic> originalCustomers = [];
  String userFilterController = 'Name';
  TextEditingController userSearchController = TextEditingController();
  final int usersPerPage = 13;
  String userRole = '';

  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    final appRole = AppStateNotifier.instance.userRole ?? '';
    userRole = widget.userRole.trim().isNotEmpty ? widget.userRole : appRole;
    fetchCustomers();
    fetchGroups();
  }

  @override
  void dispose() {
    _scrollController.dispose();
        userSearchController.dispose();
    super.dispose();
  }

  Future<void> fetchGroups() async {
    try {
      // Primary: read directly from Firestore
      final snapshot = await FirebaseFirestore.instance
          .collection('groups')
          .get();
      final fetchedGroups = snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        return data;
      }).toList();
      setState(() {
        groups = fetchedGroups;
        groupIdToName = {
          for (var group in groups)
            group['id'].toString(): (group['name'] ?? '').toString()
        };
      });
    } catch (e) {
      debugPrint('Firestore fetchGroups failed, trying API fallback: $e');
      try {
        final url = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/groups/');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final fetchedGroups = jsonDecode(response.body);
          setState(() {
            groups = fetchedGroups;
            groupIdToName = {
              for (var group in groups) group['id']: group['name']
            };
          });
        }
      } catch (e2) {
        debugPrint('API fallback also failed: $e2');
      }
    }
  }

  /// Drops user records that belong to a different customer.
  ///
  /// Every tenant's users live in one `customers` collection, separated only by
  /// `factory_id`, and the backend hands the whole list to whoever asks. Without
  /// this, a Thong Guan admin sees Danapac's users and the reverse.
  ///
  /// Only rows that name *another* customer are removed. A blank `factory_id`
  /// is left visible on purpose: those are older records that predate the field,
  /// and hiding them would look like data going missing rather than like a
  /// permission boundary. A Super Admin administers every customer, so nothing
  /// is filtered for them.
  /// Accounts belonging to the other customer's site are dropped before
  /// anything else. See [SiteTenant] for why the split is by email domain and
  /// what replaces it.

  List<Map<String, dynamic>> _ownTenantOnly(
      List<Map<String, dynamic>> rows) {
    // The host split applies to everyone, Super Admins included: the point is
    // that the two sites keep separate lists, and a Super Admin looking at the
    // demo site is asking about demo accounts.
    final scoped =
        SiteTenant.filter(rows, (r) => r['email']?.toString() ?? '');
    if (AppRoles.normalizeRole(userRole) == AppRoles.superAdmin) return scoped;

    final myTenant = AppConfig.clientId;
    if (myTenant.isEmpty) return scoped;

    return scoped.where((r) {
      final owner = r['factory_id']?.toString().trim() ?? '';
      return owner.isEmpty || owner == myTenant;
    }).toList();
  }

  Future<void> fetchCustomers() async {
    setState(() => _isLoading = true);
    try {
      // Primary: read directly from Firestore (no backend dependency)
      final snapshot = await FirebaseFirestore.instance
          .collection('customers')
          .get();
      final List<Map<String, dynamic>> all = snapshot.docs.map((doc) {
        final data = Map<String, dynamic>.from(doc.data());
        data['id'] = doc.id;
        // Normalize group_id to List
        if (data['group_id'] is! List) {
          data['group_id'] = data['group_id'] != null ? [data['group_id']] : [];
        }
        return data;
      }).toList();

      // Load account_status for each user (disable/enable state)
      // and roles/{uid} for latest role edits
      final uids = all
          .map((c) => c['UID']?.toString())
          .where((u) => u != null && u.isNotEmpty)
          .toSet();

      if (uids.isNotEmpty) {
        // Batch-load account_status docs
        final statusSnap = await FirebaseFirestore.instance
            .collection('account_status')
            .where(FieldPath.documentId, whereIn: uids.take(10).toList())
            .get();
        final statusMap = {
          for (var doc in statusSnap.docs) doc.id: doc.data()
        };
        // Load remaining if > 10
        if (uids.length > 10) {
          final remaining = uids.skip(10).toList();
          for (var i = 0; i < remaining.length; i += 10) {
            final batch = remaining.skip(i).take(10).toList();
            final snap = await FirebaseFirestore.instance
                .collection('account_status')
                .where(FieldPath.documentId, whereIn: batch)
                .get();
            for (var doc in snap.docs) {
              statusMap[doc.id] = doc.data();
            }
          }
        }

        // Batch-load roles docs for latest role names
        final rolesSnap = await FirebaseFirestore.instance
            .collection('roles')
            .where(FieldPath.documentId, whereIn: uids.take(10).toList())
            .get();
        final rolesMap = {
          for (var doc in rolesSnap.docs) doc.id: doc.data()
        };
        if (uids.length > 10) {
          final remaining = uids.skip(10).toList();
          for (var i = 0; i < remaining.length; i += 10) {
            final batch = remaining.skip(i).take(10).toList();
            final snap = await FirebaseFirestore.instance
                .collection('roles')
                .where(FieldPath.documentId, whereIn: batch)
                .get();
            for (var doc in snap.docs) {
              rolesMap[doc.id] = doc.data();
            }
          }
        }

        // Merge account_status and roles into customer data
        for (final c in all) {
          final uid = c['UID']?.toString() ?? '';
          if (uid.isEmpty) continue;

          // Account status from account_status/{uid}
          final acctStatus = statusMap[uid];
          if (acctStatus != null) {
            c['status'] = !(acctStatus['disabled'] == true);
            c['allow_multiple_logins'] = acctStatus['allow_multiple_logins'] == true;
          }

          // Role + per-user permissions from roles/{uid} (overrides customers collection)
          final roleData = rolesMap[uid];
          if (roleData != null) {
            final roleName = roleData['name']?.toString();
            if (roleName != null && roleName.isNotEmpty) {
              c['roles'] = roleName;
            }
            // Per-user permission lists assigned by an admin. These are the
            // source of truth for what each user can actually access — the
            // MODULE PERMISSIONS column renders directly from them so it
            // updates the moment an admin changes assignments.
            c['_modules'] =
                (roleData['accessible_modules'] as List<dynamic>?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    <String>[];
            c['_subModules'] =
                (roleData['accessible_sub_modules'] as List<dynamic>?)
                        ?.map((e) => e.toString())
                        .toList() ??
                    <String>[];
          }
        }
      }

      final visible = _ownTenantOnly(all);
      setState(() {
        customers = visible;
        originalCustomers = List.from(visible);
        lastUpdateTime =
            DateTime.now().toLocal().toString().substring(0, 19);
      });
    } catch (e) {
      debugPrint('Firestore fetchCustomers failed, trying API fallback: $e');
      // Fallback: try the backend API
      try {
        final url = Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/users');
        final response = await http.get(url);
        if (response.statusCode == 200) {
          final visible = _ownTenantOnly(
            (jsonDecode(response.body) as List<dynamic>)
                .whereType<Map<String, dynamic>>()
                .toList(),
          );
          setState(() {
            customers = visible;
            originalCustomers = List.from(visible);
            lastUpdateTime =
                DateTime.now().toLocal().toString().substring(0, 19);
          });
        }
      } catch (e2) {
        debugPrint('API fallback also failed: $e2');
      }
    } finally {
      setState(() => _isLoading = false);
    }
  }

  Future<void> deleteCustomer(String id) async {
    final url =
        Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/delete/$id');
    try {
      final response = await http.delete(url);
      if (response.statusCode == 200) {
        setState(() {
          customers.removeWhere((c) => c['id'] == id);
          originalCustomers.removeWhere((c) => c['id'] == id);
        });
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content:
                Text('User deleted.', style: TextStyle(color: Colors.green)),
            backgroundColor: Colors.black,
            duration: Duration(seconds: 2),
          ));
        }
      }
    } catch (e) {
      debugPrint('Error deleting customer: $e');
    }
  }

  Future<void> deleteUser(String uid) async {
    try {
      final response = await http.delete(
        Uri.parse('https://us-central1-smartmill365-demo.cloudfunctions.net/api/users/delete'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'uid': uid}),
      );
      if (response.statusCode == 200) {
        await FirebaseFirestore.instance.collection('roles').doc(uid).delete();
      }
    } catch (e) {
      debugPrint('Failed to delete user: $e');
    }
  }

  // ── Enable / Disable account ────────────────────────────────────────────
  void toggleAccountStatus(String docId, bool currentlyEnabled) {
    final newEnabled = !currentlyEnabled;

    final targetUid = customers
        .firstWhere((c) => c['id'] == docId,
            orElse: () => <String, dynamic>{})['UID']
        ?.toString();

    // Optimistic UI update
    setState(() {
      for (final c in customers) {
        if (c['id'] == docId) c['status'] = newEnabled;
      }
      for (final c in originalCustomers) {
        if (c['id'] == docId) c['status'] = newEnabled;
      }
    });

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          'Account ${newEnabled ? "enabled" : "disabled"} successfully.',
          style: const TextStyle(color: Colors.green),
        ),
        backgroundColor: Colors.black,
        duration: const Duration(seconds: 2),
      ));
    }

    // Write to Firestore account_status/{uid} (same pattern as presence/)
    if (targetUid != null && targetUid.isNotEmpty) {
      FirebaseFirestore.instance
          .collection('account_status')
          .doc(targetUid)
          .set({
            'disabled': !newEnabled,
            'updated_at': FieldValue.serverTimestamp(),
          }, SetOptions(merge: true))
          .catchError((e) => debugPrint('account_status update failed: $e'));
    }
  }

  // ── Helpers ─────────────────────────────────────────────────────────────

  Color _getBadgeColor(String role) {
    final r = role.toLowerCase();
    if (r.contains('super')) return const Color(0xFF9C27B0);
    if (r.contains('admin')) return FlutterFlowTheme.of(context).error;
    if (r.contains('manager')) return const Color(0xFFFF7043);
    if (r.contains('engineer')) return FlutterFlowTheme.of(context).primary;
    return FlutterFlowTheme.of(context).success;
  }

  /// Build the permission chip labels for a single row directly from the
  /// per-user `accessible_modules` list (loaded from `roles/{uid}`).
  /// Falls back to the role's hardcoded labels only when no per-user list
  /// has been assigned yet, so newly-added users still show something.
  List<String> _permissionLabelsForRow(
      Map<String, dynamic> row, String role) {
    final n = AppRoles.normalizeRole(role);
    if (n == AppRoles.superAdmin) {
      return const ['Full System Access', 'All Modules', 'User Management'];
    }
    final mods = (row['_modules'] as List?)
            ?.map((e) => e.toString())
            .where((m) => m.isNotEmpty)
            .toList() ??
        const <String>[];
    if (mods.isEmpty) {
      // No assignment record yet → fall back to legacy role labels.
      return AppRoles.permissionLabels(role);
    }
    return mods.map((m) => AppRoles.moduleLabels[m] ?? m).toList();
  }

  /// Popup that lists every module assigned to a user, grouped by section,
  /// with a small "read-only" tag where applicable. Opened by tapping the
  /// MODULE PERMISSIONS cell so admins can see the full assignment without
  /// navigating to the edit dialog.
  void _showPermissionsDialog(
    BuildContext context,
    String userName,
    String role,
    List<String> modules,
    List<String> subModules,
    String groupNames,
  ) {
    final t = FlutterFlowTheme.of(context);
    final isSA =
        AppRoles.normalizeRole(role) == AppRoles.superAdmin;

    // Group assigned modules by section using AppRoles.moduleGroups.
    final assigned = modules.toSet();
    final grouped = <String, List<String>>{};
    AppRoles.moduleGroups.forEach((section, keys) {
      final hits = keys.where(assigned.contains).toList();
      if (hits.isNotEmpty) grouped[section] = hits;
    });
    // Anything not in any group (custom keys, etc.)
    final knownKeys =
        AppRoles.moduleGroups.values.expand((v) => v).toSet();
    final ungrouped =
        modules.where((m) => !knownKeys.contains(m)).toList();
    if (ungrouped.isNotEmpty) grouped['Other'] = ungrouped;

    showDialog(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: FlutterFlowTheme.of(context).primaryBackground,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: t.primary.withOpacity(0.35)),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560, maxHeight: 600),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Header ─────────────────────────────────────────────
                Row(
                  children: [
                    Icon(Icons.shield_outlined,
                        color: t.primary, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        'Module Permissions',
                        style: TextStyle(
                          color: t.primaryText,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(Icons.close,
                          color: t.secondaryText, size: 20),
                      onPressed: () => Navigator.of(ctx).pop(),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  '$userName  ·  $role',
                  style: TextStyle(
                    color: t.secondaryText,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (groupNames.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Groups: $groupNames',
                    style: TextStyle(
                        color: t.secondaryText.withOpacity(0.7),
                        fontSize: 11),
                  ),
                ],
                const SizedBox(height: 14),
                Divider(color: t.primary.withOpacity(0.15), height: 1),
                const SizedBox(height: 12),

                // ── Body ───────────────────────────────────────────────
                Flexible(
                  child: SingleChildScrollView(
                    child: Builder(builder: (_) {
                      if (isSA) {
                        return Text(
                          'Super Admin has full access to every module in the system.',
                          style: TextStyle(
                              color: t.primaryText, fontSize: 13),
                        );
                      }
                      if (modules.isEmpty) {
                        return Text(
                          'No modules have been assigned to this user yet.',
                          style: TextStyle(
                              color: t.secondaryText, fontSize: 13),
                        );
                      }
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: grouped.entries.map((e) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  e.key.toUpperCase(),
                                  style: TextStyle(
                                    color: t.primary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Wrap(
                                  spacing: 6,
                                  runSpacing: 6,
                                  children: e.value.map((m) {
                                    final readOnly =
                                        subModules.contains('readonly_$m');
                                    final label =
                                        AppRoles.moduleLabels[m] ?? m;
                                    final color = readOnly
                                        ? t.secondaryText
                                        : t.primary;
                                    return Container(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: color.withOpacity(0.1),
                                        borderRadius:
                                            BorderRadius.circular(6),
                                        border: Border.all(
                                            color: color.withOpacity(0.35)),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            label,
                                            style: TextStyle(
                                              color: color,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                          if (readOnly) ...[
                                            const SizedBox(width: 5),
                                            Icon(Icons.lock_outline,
                                                size: 11,
                                                color: color.withOpacity(0.7)),
                                          ],
                                        ],
                                      ),
                                    );
                                  }).toList(),
                                ),
                              ],
                            ),
                          );
                        }).toList(),
                      );
                    }),
                  ),
                ),

                const SizedBox(height: 8),
                Divider(color: t.primary.withOpacity(0.15), height: 1),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    isSA
                        ? 'Full access'
                        : '${modules.length} module${modules.length == 1 ? '' : 's'} assigned',
                    style: TextStyle(
                      color: t.secondaryText,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getGroupNames(List<dynamic> groupIds, [String? role]) {
    if (groupIds.isEmpty) {
      if (role != null) {
        final n = AppRoles.normalizeRole(role);
        if (n == AppRoles.superAdmin || n == AppRoles.admin) return 'All Groups';
      }
      return 'No Group';
    }
    return groupIds.map((id) => groupIdToName[id] ?? id.toString()).join(', ');
  }

  /// Account status: null/missing = enabled (default), explicit false = disabled
  bool _isAccountEnabled(dynamic status) {
    return status != false && status != 'false';
  }

  Color _avatarColor(String role) {
    final r = role.toLowerCase();
    if (r.contains('super')) return const Color(0xFF9C27B0);
    if (r.contains('admin')) return const Color(0xFFE53935);
    if (r.contains('manager')) return const Color(0xFFFF7043);
    if (r.contains('engineer')) return FlutterFlowTheme.of(context).primary;
    return const Color(0xFF24A891);
  }

  String _getInitials(String name) {
    if (name.trim().isEmpty) return '??';
    final parts = name.trim().split(' ');
    if (parts.length >= 2) return (parts[0][0] + parts[1][0]).toUpperCase();
    return parts[0].substring(0, parts[0].length >= 2 ? 2 : 1).toUpperCase();
  }

  void _showAddUserDialog(BuildContext context) {
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (_) => AddCustomerDialog(
        userRole: userRole,
        onCustomerAdded: () => fetchCustomers(),
      ),
    );
  }

  void _showEditCustomerDialog(BuildContext context, String id) {
    final customer = customers.firstWhere((c) => c['id'] == id);
    showDialog(
      barrierDismissible: false,
      context: context,
      builder: (_) => EditCustomerDialog(
        uid: widget.userUid,
        editedUserUid: customer['UID']?.toString() ?? '',
        id: id,
        email: widget.userEmail,
        initialName: customer['name'],
        initialEmail: customer['email'],
        initialPhone: customer['phone'],
        initialGroups: List<String>.from(customer['group_id']),
        initialRoles: customer['roles'],
        initialFactoryId: customer['factory_id']?.toString() ?? '',
        initialAllowMultipleLogins: customer['allow_multiple_logins'] == true,
        userRole: userRole,
        onCustomerAdded: () => fetchCustomers(),
      ),
    );
  }

  Widget _buildCustomHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 25),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'User Access Management',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: FlutterFlowTheme.of(context).primaryText,
                  fontFamily: 'Poppins',
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Define system roles, permissions, and register new personnel.',
                style: TextStyle(
                  fontSize: 14,
                  color: FlutterFlowTheme.of(context).secondaryText,
                  fontFamily: 'Poppins',
                ),
              ),
            ],
          ),
          Row(
            children: [
              Text(
                '${userRole.isNotEmpty ? userRole : 'User'}: ${widget.userName}',
                style: TextStyle(
                  color: FlutterFlowTheme.of(context).primaryText,
                  fontFamily: 'Poppins',
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 12),
              CircleAvatar(
                backgroundColor: FlutterFlowTheme.of(context).error,
                child: Text(
                  _getInitials(widget.userName),
                  style: const TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          )
        ],
      ),
    );
  }

  // ── Live avatar with online dot ─────────────────────────────────────────
  Widget _buildLiveAvatar({
    required String uid,
    required String role,
    required String initials,
    required bool showOnlineDot,
  }) {
    final aColor = _avatarColor(role);
    final rowIsSA = AppRoles.normalizeRole(role) == AppRoles.superAdmin;

    return SizedBox(
      width: 42,
      height: 42,
      child: Stack(
        children: [
          // Avatar circle
          Center(
            child: Container(
              width: 38,
              height: 38,
              decoration: BoxDecoration(
                color: aColor.withOpacity(0.18),
                shape: BoxShape.circle,
                border: Border.all(color: aColor.withOpacity(0.5), width: 1.5),
              ),
              child: Center(
                child: Text(
                  initials,
                  style: TextStyle(
                    color: aColor,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),
          // Online dot — live from StreamBuilder
          if (showOnlineDot && uid.isNotEmpty)
            StreamBuilder<String?>(
              stream: UserPresence.statusStream(uid),
              builder: (context, snap) {
                if (snap.hasError) {
                  debugPrint('[Avatar] stream error for $uid: ${snap.error}');
                }
                final isOnline = snap.data == 'online';
                // Show green dot for online, grey dot for offline (always visible)
                return Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: isOnline
                          ? const Color(0xFF22C55E)
                          : const Color(0xFF64748B),
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: const Color(0xFF0A0E1A), width: 2),
                      boxShadow: isOnline
                          ? [
                              BoxShadow(
                                color: const Color(0xFF22C55E).withOpacity(0.5),
                                blurRadius: 4,
                                spreadRadius: 1,
                              ),
                            ]
                          : [],
                    ),
                  ),
                );
              },
            ),
          // SA crown icon instead of online dot
          if (rowIsSA)
            Positioned(
              right: 0,
              bottom: 0,
              child: Container(
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  color: const Color(0xFF9C27B0),
                  shape: BoxShape.circle,
                  border:
                      Border.all(color: const Color(0xFF0A0E1A), width: 1.5),
                ),
                child: const Center(
                  child: Icon(Icons.shield, size: 8, color: Color(0xFFE1BEE7)),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Build ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final t = FlutterFlowTheme.of(context);
    final isSuperAdmin =
        AppRoles.normalizeRole(userRole) == AppRoles.superAdmin;

    // Pre-process rows
    final List<Map<String, dynamic>> structuredRows = originalCustomers
        .map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          final email = m['email']?.toString() ?? '';
          final id = m['id']?.toString() ?? '';
          final role = m['roles']?.toString() ?? '';
          m['_subtitle'] = id.isNotEmpty ? '$email  ·  ID: $id' : email;

          // Searchable MODULE PERMISSIONS text — built from the per-user
          // module list stored on roles/{uid}, so it reflects exactly what
          // an admin assigned. SA always shows "Full System Access".
          final permLabels = _permissionLabelsForRow(m, role);
          final groupNames = _getGroupNames(m['group_id'] ?? [], role);
          m['_permissions'] = permLabels.isNotEmpty
              ? '${permLabels.join(", ")} | $groupNames'
              : groupNames;

          // Searchable ACCOUNT text
          final rowIsSA =
              AppRoles.normalizeRole(role) == AppRoles.superAdmin;
          if (rowIsSA) {
            m['_account'] = 'Protected';
          } else {
            m['_account'] =
                _isAccountEnabled(m['status']) ? 'Active' : 'Disabled';
          }

          return m;
        })
        .toList();

    return Stack(
      children: [
        Container(
          color: t.primaryBackground,
          child: Column(
            children: [
              _buildCustomHeader(context),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20.0, vertical: 10.0),
                  child: DataTableWidget(
                    columns: const [
                      TableColumn('PERSONNEL', 'name', 260, sortable: true),
                      TableColumn('MULTI-LOGIN', 'allow_multiple_logins', 110),
                      TableColumn('ACCESS LEVEL', 'roles', 170, sortable: true),
                      TableColumn('MODULE PERMISSIONS', '_permissions', 260),
                      TableColumn('ACCOUNT', '_account', 160, sortable: true),
                    ],
                    rows: structuredRows,
                    primaryKey: 'id',
                    primarySubtitleKey: '_subtitle',
                    primaryIcon: Icons.account_circle,
                    onEdit: (row) => _showEditCustomerDialog(
                        context, row['id'].toString()),
                    onDelete: (row) {
                      showDialog(
                        context: context,
                        builder: (_) => CustomDialog(
                          icon: Icons.delete_outline,
                          title: 'Confirm Deletion',
                          subtitle:
                              'Are you sure you want to remove this personnel?',
                          sections: const [
                            CustomDialogSection(
                              title: 'Warning',
                              subtitle:
                                  'This will permanently remove the user from the database. This action cannot be undone.',
                              children: [],
                            )
                          ],
                          submitLabel: 'REMOVE',
                          cancelLabel: 'CANCEL',
                          onSubmit: () async {
                            await deleteUser(row['UID']);
                            await deleteCustomer(row['id'].toString());
                            return true;
                          },
                        ),
                      );
                    },
                    // ── Super Admin rows: shield badge instead of edit/delete
                    actionBuilder: (row) {
                      final rowRole = row['roles']?.toString() ?? '';
                      final rowIsSA = AppRoles.normalizeRole(rowRole) ==
                          AppRoles.superAdmin;
                      if (!rowIsSA) return null;
                      return Tooltip(
                        message: 'Super Admin — Protected Account',
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            color: const Color(0xFF9C27B0).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                                color:
                                    const Color(0xFF9C27B0).withOpacity(0.4)),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.shield,
                                  size: 14, color: Color(0xFFCE93D8)),
                              SizedBox(width: 4),
                              Text('SA',
                                  style: TextStyle(
                                    color: Color(0xFFCE93D8),
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 0.5,
                                  )),
                            ],
                          ),
                        ),
                      );
                    },
                    actions: [
                      TableAction(
                          label: 'Export Audit Log',
                          icon: Icons.file_download_outlined,
                          onTap: () {}),
                      if (userRole.isEmpty ||
                          AppRoles.canRegisterUsers(userRole))
                        TableAction(
                            label: 'Register New User',
                            icon: Icons.add,
                            isPrimary: true,
                            onTap: () => _showAddUserDialog(context)),
                    ],
                    cellBuilder: (key, value, row) {
                      // ── PERSONNEL: avatar with live online dot ────────
                      if (key == 'name') {
                        final name = row['name']?.toString() ?? '';
                        final email = row['email']?.toString() ?? '';
                        final docId = row['id']?.toString() ?? '';
                        final role = row['roles']?.toString() ?? '';
                        final uid = row['UID']?.toString() ?? '';
                        final initials = _getInitials(name);
                        final rowIsSA = AppRoles.normalizeRole(role) ==
                            AppRoles.superAdmin;

                        // Everyone sees online dots, except:
                        // - SA rows hidden from non-SA users
                        final showDot = rowIsSA
                            ? isSuperAdmin
                            : true;

                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            _buildLiveAvatar(
                              uid: uid,
                              role: role,
                              initials: initials,
                              showOnlineDot: showDot && !rowIsSA,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    name,
                                    style: TextStyle(
                                      color: t.primaryText,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w700,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    '$email  ·  ID: $docId',
                                    style: TextStyle(
                                      color: t.secondaryText,
                                      fontSize: 11,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        );
                      }

                      // ── MULTI-LOGIN toggle ────────────────────────────
                      if (key == 'allow_multiple_logins') {
                        final rowRole = row['roles']?.toString() ?? '';
                        final rowIsSA = AppRoles.normalizeRole(rowRole) ==
                            AppRoles.superAdmin;
                        final enabled = row['allow_multiple_logins'] == true;
                        final targetUid = row['UID']?.toString() ?? '';
                        return Switch(
                          value: enabled,
                          onChanged: isSuperAdmin && targetUid.isNotEmpty
                              ? (v) {
                                  setState(() {
                                    for (final c in customers) {
                                      if (c['UID'] == targetUid) {
                                        c['allow_multiple_logins'] = v;
                                      }
                                    }
                                    for (final c in originalCustomers) {
                                      if (c['UID'] == targetUid) {
                                        c['allow_multiple_logins'] = v;
                                      }
                                    }
                                  });
                                  FirebaseFirestore.instance
                                      .collection('account_status')
                                      .doc(targetUid)
                                      .set({
                                        'allow_multiple_logins': v,
                                        'updated_at':
                                            FieldValue.serverTimestamp(),
                                      }, SetOptions(merge: true))
                                      .catchError((_) {});
                                }
                              : null,
                          activeColor: const Color(0xFF00D4FF),
                        );
                      }

                      // ── ACCESS LEVEL badge ────────────────────────────
                      if (key == 'roles') {
                        final badgeColor = _getBadgeColor(value);
                        return Align(
                          alignment: Alignment.centerLeft,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: badgeColor.withOpacity(0.15),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: badgeColor.withOpacity(0.5),
                                  width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 6,
                                  height: 6,
                                  decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: badgeColor),
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  value.toUpperCase(),
                                  style: TextStyle(
                                    color: badgeColor,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 0.5,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      // ── MODULE PERMISSIONS ────────────────────────────
                      if (key == '_permissions') {
                        final role = row['roles']?.toString() ?? '';
                        final perms = _permissionLabelsForRow(row, role);
                        final rowSubs =
                            (row['_subModules'] as List?)
                                    ?.map((e) => e.toString())
                                    .toList() ??
                                const <String>[];
                        // "Edit" = there is at least one assigned module that
                        // is not flagged read-only. SA is always editable.
                        final rowMods =
                            (row['_modules'] as List?)
                                    ?.map((e) => e.toString())
                                    .toList() ??
                                const <String>[];
                        final saRow = AppRoles.normalizeRole(role) ==
                            AppRoles.superAdmin;
                        final isEdit = saRow ||
                            rowMods.any((m) => !rowSubs.contains('readonly_$m'));
                        final permColor =
                            isEdit ? t.primary : t.secondaryText;
                        final groupNames =
                            _getGroupNames(row['group_id'] ?? [], role);

                        // Compact preview chips (first 3) + tap to view all.
                        const previewCount = 3;
                        final visible = perms.take(previewCount).toList();
                        final extra = perms.length - visible.length;

                        Widget chip(String p) => Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: permColor.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(4),
                                border: Border.all(
                                    color: permColor.withOpacity(0.3)),
                              ),
                              child: Text(
                                p,
                                style: TextStyle(
                                  color: permColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            );

                        return InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () => _showPermissionsDialog(
                            context,
                            row['name']?.toString() ?? '',
                            role,
                            rowMods,
                            rowSubs,
                            groupNames,
                          ),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 4),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                if (perms.isNotEmpty)
                                  Wrap(
                                    spacing: 4,
                                    runSpacing: 3,
                                    children: [
                                      ...visible.map(chip),
                                      if (extra > 0) chip('+$extra more'),
                                    ],
                                  )
                                else
                                  Text('No Permissions',
                                      style: TextStyle(
                                          color: t.secondaryText,
                                          fontSize: 12)),
                                const SizedBox(height: 3),
                                Text(
                                  groupNames,
                                  style: TextStyle(
                                      color: t.secondaryText, fontSize: 11),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      // ── ACCOUNT: Active/Disabled + toggle ─────────────
                      if (key == '_account') {
                        final role = row['roles']?.toString() ?? '';
                        final rowDocId = row['id']?.toString() ?? '';
                        final rowIsSA = AppRoles.normalizeRole(role) ==
                            AppRoles.superAdmin;
                        final enabled = _isAccountEnabled(row['status']);

                        // Super Admin: protected badge
                        if (rowIsSA) {
                          return Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 5),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(colors: [
                                const Color(0xFF9C27B0).withOpacity(0.2),
                                const Color(0xFF7B1FA2).withOpacity(0.1),
                              ]),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: const Color(0xFFCE93D8)
                                      .withOpacity(0.5)),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.verified_user,
                                    size: 13, color: Color(0xFFCE93D8)),
                                SizedBox(width: 5),
                                Text('Protected',
                                    style: TextStyle(
                                      color: Color(0xFFCE93D8),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    )),
                              ],
                            ),
                          );
                        }

                        // SA can toggle all non-SA accounts
                        final canToggle = isSuperAdmin;

                        final statusColor = enabled
                            ? const Color(0xFF22C55E)
                            : const Color(0xFFEF4444);
                        final statusLabel = enabled ? 'Active' : 'Disabled';

                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Status badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: statusColor.withOpacity(0.12),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                    color: statusColor.withOpacity(0.4)),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 6,
                                    height: 6,
                                    decoration: BoxDecoration(
                                      shape: BoxShape.circle,
                                      color: statusColor,
                                    ),
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    statusLabel,
                                    style: TextStyle(
                                      color: statusColor,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Toggle button — SA only
                            if (canToggle) ...[
                              const SizedBox(width: 6),
                              Tooltip(
                                message: enabled
                                    ? 'Disable Account'
                                    : 'Enable Account',
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: () => toggleAccountStatus(
                                      rowDocId, enabled),
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: BoxDecoration(
                                      color: (enabled
                                              ? const Color(0xFFEF4444)
                                              : const Color(0xFF22C55E))
                                          .withOpacity(0.12),
                                      borderRadius:
                                          BorderRadius.circular(6),
                                      border: Border.all(
                                        color: (enabled
                                                ? const Color(0xFFEF4444)
                                                : const Color(0xFF22C55E))
                                            .withOpacity(0.4),
                                      ),
                                    ),
                                    child: Icon(
                                      enabled
                                          ? Icons.block
                                          : Icons.check_circle_outline,
                                      size: 14,
                                      color: enabled
                                          ? const Color(0xFFEF4444)
                                          : const Color(0xFF22C55E),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        );
                      }

                      return null;
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_isLoading)
          Positioned.fill(
            child: Center(
              child: CircularProgressIndicator(color: t.primary),
            ),
          ),
      ],
    );
  }
}
